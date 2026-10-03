#!/usr/bin/env bash
# tests/vps-bootstrap/test-vps-bootstrap-staking-dir.sh — proves that
# scripts/vps-bootstrap.sh step_metalgo looks for the staker keys where compose
# ACTUALLY mounts metalgo's /data, and refuses to start metalgo when it cannot
# tell where that is.
#
# Why this exists: step_metalgo used to test a hardcoded
# /var/lib/docker/volumes/metalgo_data/_data/staking. Compose never mounts that
# path (the volume is <project>_metalgo_data, and the project name differs
# between the repo files and the stack running in production). Keys restored
# to the right volume looked "missing", and keys restored to the printed path
# were never read by metalgo, which then generated new keys = new NodeID.
#
# CHAIN: none. PRIME_DIRECTIVE: safe — no broadcast, no network, no SSH, no
#        notification, no real docker. `docker`, `curl`, `jq` and `sleep` are
#        PATH stubs; the script is sourced with VPS_BOOTSTRAP_SOURCED=1 so
#        main() never runs; only step_metalgo is called, inside a subshell,
#        against a mktemp fixture DEPLOY_DIR.
#
# Coverage:
#   T1 own container whose /data is a non-default volume path holding keys
#      -> metalgo is started (compose up -d). Break-the-property: with the old
#      hardcoded path this case prints WARNING and never starts metalgo.
#   T2 a metalgo container from ANOTHER compose project exists -> rc != 0,
#      nothing created, nothing started (the production naming hazard).
#   T3 no container yet -> compose create (never up), WARNING names the
#      RESOLVED path, rc 0, not started.
#   T4 own container without a /data mount -> rc != 0, not started.
#   T5 two own containers -> rc != 0, not started.
#   T6 no .env -> NOTE, rc 0, docker never called.
#   T7 static: the old hardcoded volume path is gone from vps-bootstrap.sh.
#   T8 a metalgo container exists and the compose naming verifier reports
#      MISMATCH -> rc != 0, compose up never runs (production NodeID guard).
#
# Mutation: MUTATE_OLD_PATH=1 runs T1 against a copy of the script whose
# staking dir is forced back to the old hardcoded path; T1 must then FAIL.
set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BOOTSTRAP="${REPO_ROOT}/scripts/vps-bootstrap.sh"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "PASS  $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL  $1${2:+ — $2}"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

SCRIPT="$BOOTSTRAP"
if [ "${MUTATE_OLD_PATH:-0}" = 1 ]; then
	SCRIPT="$TMP/vps-bootstrap.mutant.sh"
	sed 's|^  STAKING_DIR="\$data_dir/staking"$|  STAKING_DIR=/var/lib/docker/volumes/metalgo_data/_data/staking|' \
		"$BOOTSTRAP" > "$SCRIPT"
	grep -q 'STAKING_DIR=/var/lib/docker/volumes/metalgo_data/_data/staking' "$SCRIPT" \
		|| { echo "FAIL  mutation did not apply"; exit 1; }
fi

# ---- stubs -----------------------------------------------------------------
BIN="$TMP/bin"
mkdir -p "$BIN"
cat > "$BIN/docker" <<'STUB'
#!/usr/bin/env bash
# State lives in $STUB_STATE: all (ids of every metalgo container), own (ids
# compose reports for its project), mount_<id> (/data source), create_id.
echo "docker $*" >> "$STUB_STATE/calls.log"
touch "$STUB_STATE/all" "$STUB_STATE/own"
case "$1" in
ps) cat "$STUB_STATE/all" ;;
inspect)
	id="${*: -1}"
	case "$*" in
	*Mounts*) [ -f "$STUB_STATE/mount_$id" ] && cat "$STUB_STATE/mount_$id"; echo ;;
	*) echo "/other-metalgo project=other-project" ;;
	esac ;;
compose)
	case "$*" in
	*" ps -a -q metalgo") cat "$STUB_STATE/own" ;;
	*" create metalgo")
		id="$(cat "$STUB_STATE/create_id")"
		echo "$id" >> "$STUB_STATE/own"
		echo "$id" >> "$STUB_STATE/all" ;;
	*" up -d") echo UP >> "$STUB_STATE/started" ;;
	*) echo "stub: unexpected compose call: $*" >&2; exit 99 ;;
	esac ;;
*) echo "stub: unexpected docker call: $*" >&2; exit 99 ;;
esac
STUB
printf '#!/usr/bin/env bash\necho "{}"\n' > "$BIN/curl"
printf '#!/usr/bin/env bash\ncat >/dev/null; echo NodeID-stub\n' > "$BIN/jq"
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/sleep"
# naming-check stub: exits with $STUB_STATE/naming_rc (default 0 = MATCH), logs the call
printf '#!/usr/bin/env bash\necho naming-check >> "$STUB_STATE/calls.log"\nexit "$(cat "$STUB_STATE/naming_rc" 2>/dev/null || echo 0)"\n' > "$BIN/naming-check"
chmod +x "$BIN"/*

ID_A=aaaaaaaaaaaa1111111111111111111111111111111111111111111111111111
ID_B=bbbbbbbbbbbb2222222222222222222222222222222222222222222222222222

# new_case <name>: fresh state + deploy dir (with .env) + a fake volume dir
new_case() {
	C="$TMP/$1"
	export STUB_STATE="$C/state"
	mkdir -p "$STUB_STATE" "$C/deploy" "$C/vol/_data"
	: > "$C/deploy/.env"
	: > "$STUB_STATE/all"
	: > "$STUB_STATE/own"
}
add_keys() { mkdir -p "$1/staking" && : > "$1/staking/staker.crt"; }

# run_step: source the script and call step_metalgo in a subshell
run_step() {
	(
		export PATH="$BIN:$PATH" VPS_BOOTSTRAP_SOURCED=1 DEPLOY_DIR="$C/deploy" COMPOSE_NAMING_CHECK="$BIN/naming-check"
		# shellcheck disable=SC1090
		. "$SCRIPT"
		step_metalgo
	) > "$C/out.txt" 2>&1
	echo $? > "$C/rc"
}
rc() { cat "$C/rc"; }
started() { [ -s "$STUB_STATE/started" ]; }
called() { grep -q -- "$1" "$STUB_STATE/calls.log" 2>/dev/null; }

# ---- T1 --------------------------------------------------------------------
new_case t1
echo "$ID_A" > "$STUB_STATE/all"
echo "$ID_A" > "$STUB_STATE/own"
echo "$C/vol/_data" > "$STUB_STATE/mount_$ID_A"
add_keys "$C/vol/_data"
run_step
if [ "$(rc)" = 0 ] && started && ! grep -q WARNING "$C/out.txt"; then
	ok "T1 keys in the compose-mounted /data (non-default volume) -> metalgo started"
else
	bad "T1 keys in the compose-mounted /data (non-default volume) -> metalgo started" "rc=$(rc) out=$(tr '\n' ' ' < "$C/out.txt")"
fi

if [ "${MUTATE_OLD_PATH:-0}" = 1 ]; then
	echo "RESULT: PASS=$PASS FAIL=$FAIL (mutation run: T1 only)"
	[ "$FAIL" -eq 0 ]
	exit $?
fi

# ---- T2 --------------------------------------------------------------------
new_case t2
echo "$ID_B" > "$STUB_STATE/all"           # foreign project's metalgo
echo "$ID_A" > "$STUB_STATE/create_id"
run_step
if [ "$(rc)" != 0 ] && ! started && ! called "create metalgo" \
	&& grep -q "another compose project" "$C/out.txt"; then
	ok "T2 foreign-project metalgo present -> refuse, nothing created or started"
else
	bad "T2 foreign-project metalgo present -> refuse, nothing created or started" "rc=$(rc)"
fi

# ---- T3 --------------------------------------------------------------------
new_case t3
echo "$ID_A" > "$STUB_STATE/create_id"
echo "$C/vol/_data" > "$STUB_STATE/mount_$ID_A"
run_step
if [ "$(rc)" = 0 ] && ! started && called "create metalgo" \
	&& grep -q "WARNING: $C/vol/_data/staking/staker.crt not found" "$C/out.txt"; then
	ok "T3 no container -> compose create (not up), WARNING names the resolved path"
else
	bad "T3 no container -> compose create (not up), WARNING names the resolved path" "rc=$(rc) out=$(tr '\n' ' ' < "$C/out.txt")"
fi

# ---- T4 --------------------------------------------------------------------
new_case t4
echo "$ID_A" > "$STUB_STATE/all"
echo "$ID_A" > "$STUB_STATE/own"
run_step                                    # no mount_<id> file -> empty source
if [ "$(rc)" != 0 ] && ! started && grep -q "no /data mount" "$C/out.txt"; then
	ok "T4 unresolvable /data mount -> refuse, not started"
else
	bad "T4 unresolvable /data mount -> refuse, not started" "rc=$(rc)"
fi

# ---- T5 --------------------------------------------------------------------
new_case t5
printf '%s\n%s\n' "$ID_A" "$ID_B" > "$STUB_STATE/all"
printf '%s\n%s\n' "$ID_A" "$ID_B" > "$STUB_STATE/own"
run_step
if [ "$(rc)" != 0 ] && ! started && grep -q "expected exactly 1" "$C/out.txt"; then
	ok "T5 two metalgo containers in this project -> refuse, not started"
else
	bad "T5 two metalgo containers in this project -> refuse, not started" "rc=$(rc)"
fi

# ---- T6 --------------------------------------------------------------------
new_case t6
rm -f "$C/deploy/.env"
run_step
if [ "$(rc)" = 0 ] && ! started && ! [ -s "$STUB_STATE/calls.log" ] \
	&& grep -q "NOTE: .*\.env not present" "$C/out.txt"; then
	ok "T6 no .env -> NOTE, docker never called"
else
	bad "T6 no .env -> NOTE, docker never called" "rc=$(rc)"
fi

# ---- T8 --------------------------------------------------------------------
# Existing metalgo container + naming verifier says MISMATCH -> never compose up.
new_case t8
echo "$ID_A" > "$STUB_STATE/all"
echo "$ID_A" > "$STUB_STATE/own"
echo "$C/vol/_data" > "$STUB_STATE/mount_$ID_A"
add_keys "$C/vol/_data"
echo 1 > "$STUB_STATE/naming_rc"
run_step
if [ "$(rc)" != 0 ] && ! started && grep -q naming-check "$STUB_STATE/calls.log"; then
	ok "T8 existing container + naming MISMATCH -> refused, compose up never runs"
else
	bad "T8 existing container + naming MISMATCH -> refused, compose up never runs" "rc=$(rc) out=$(tr '\n' ' ' < "$C/out.txt")"
fi
# T1 must have consulted the verifier too (the gate is on the path to `up`).
if grep -q naming-check "$TMP/t1/state/calls.log"; then
	ok "T8b the naming verifier runs before compose up when a container exists"
else
	bad "T8b the naming verifier runs before compose up when a container exists"
fi

# ---- T7 --------------------------------------------------------------------
if grep -q '/var/lib/docker/volumes/metalgo_data/_data/staking' "$BOOTSTRAP"; then
	bad "T7 hardcoded metalgo_data staking path is gone from vps-bootstrap.sh"
else
	ok "T7 hardcoded metalgo_data staking path is gone from vps-bootstrap.sh"
fi

echo "test-vps-bootstrap-staking-dir.sh summary: PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then echo "RESULT: PASS"; exit 0; fi
echo "RESULT: FAIL"
exit 1
