#!/usr/bin/env bash
# install-rehearsal-preflight.sh — one-command, READ-ONLY, fail-closed
# pre-flight for the testnet rehearsal (docs/CYCLE_GATE.md unit 7a,
# scripts/run-testnet-rehearsal.sh).
#
# CHAIN: none. This script has NO broadcast pathway. It does not invoke the
#        sanctioned broadcast wrapper under bin/, does not invoke
#        scripts/run-testnet-rehearsal.sh or scripts/sign-anchor-event.sh,
#        does not create or touch an operator token, and issues exactly one
#        chain call: a read-only POST to /v1/chain/get_account on a testnet
#        RPC (permission/key lookup — the same call
#        docs/ANCHOR_ACCOUNT_KEY_ROTATION.md established for this use).
#        tests/rehearsal-preflight/ greps this file and fails if a
#        broadcast-capable string appears in it.
# PRIME_DIRECTIVE: TESTNET-FIRST — not applicable in the sense that there is
#        nothing here to gate; this script's whole purpose is to make the
#        gate-1 rehearsal fail EARLY (on a check) instead of LATE (in front
#        of the operator, mid-run).
#
# IT INSTALLS NOTHING. The scripts/install-*.sh name is this repo's
# convention for "the one command that replaces a manual operator ritual"
# (memory/feedback_installer_script_first_for_operator_manual_actions), and
# the ritual being replaced here is the hand-checking of the rehearsal's
# preconditions. Nothing is written, moved, created or deleted outside
# mktemp scratch files. The keystore is NEVER unlocked, never written, and
# its files are never read directly — the only keystore access is
# `proton key:list`, a non-destructive listing (a direct read of an
# encrypted keystore file has destroyed an IV in this project before; see
# memory/reference_proton_keystore_per_project_network_separation).
#
# ---------------------------------------------------------------------------
# WHY THIS EXISTS
# ---------------------------------------------------------------------------
# On 2026-07-31 the rehearsal was found to be structurally incapable of
# succeeding — it compared the chain's anchor key against a hardcoded pin
# list that the 2026-07-10 key rotation had invalidated — and that was found
# at the day-of walkthrough, not before it (commit a3c803f). The cost of
# that class of failure is not the fix; it is that the operator was already
# standing there. Every check below is a thing that, if wrong, makes the
# rehearsal fail AFTER the operator has been called.
#
# The single most important check is #9 (the current on-chain <actor>@anchor
# key is present in the project testnet keystore). It is the one that
# needs the operator to have unlocked the keystore, which is why it must be
# run days before the rehearsal and not minutes before.
#
# ---------------------------------------------------------------------------
# --expect-cycle: WHICH OF THE TWO MEANINGS
# ---------------------------------------------------------------------------
# Two scripts in this repo take a flag spelled `--expect-cycle` and they mean
# DIFFERENT NUMBERS, one apart:
#
#   scripts/cycle-transition.sh --expect-cycle=N   N = the cycle CLOSING today
#                                                  (= FY_EXPECT_CYCLE for
#                                                  units 4 and 5)
#   scripts/run-testnet-rehearsal.sh --expect-cycle=M
#                                                  M = the cycle being
#                                                  INSCRIBED = N+1, compared
#                                                  against the anchor-source's
#                                                  observations_branch.cycle_number_observed
#
# scripts/cycle-transition.sh:610-622 states that meaning switch in the
# printed plan, deliberately.
#
# THIS SCRIPT TAKES THE REHEARSAL'S MEANING (M), because the thing it is
# validating is the exact command the operator is about to type. It prints
# the cycle-transition value (M-1) alongside, every run, so the two are never
# confused in the operator's hands.
#
# ---------------------------------------------------------------------------
# USAGE
# ---------------------------------------------------------------------------
#   HOME=~/.metal-fy-proton-test bash scripts/install-rehearsal-preflight.sh \
#       --expect-cycle=<M> [--source=<path>]
#
# The HOME prefix is MANDATORY (Constitution §3.5) and is checked before any
# proton invocation: this script lists the TESTNET keystore, so it refuses if
# HOME is the login home, the mainnet keystore, or anything that is not the
# project testnet keystore directory.
#
#   --expect-cycle=<M>  REQUIRED. The value that will be passed to
#                       run-testnet-rehearsal.sh --expect-cycle. There is no
#                       default and it is not derived: deriving it would make
#                       this script agree with a wrong declaration instead of
#                       checking it (the reasoning is stated at length under
#                       "THE OFF-BY-ONE" in scripts/cycle-transition.sh).
#   --source=<path>     The anchor-source the rehearsal will inscribe.
#                       Default: the canonical public/api/anchor-source.json,
#                       exactly as run-testnet-rehearsal.sh defaults.
#
# Environment overrides (all exist so the test suite can run hermetically —
# every URL variable also accepts a LOCAL PATH, in which case no network call
# is made at all, the same convention as cycle-transition.sh --public-base):
#   XPR_TESTNET_CHAIN_RPC   chain API base for get_account (shared spelling
#                           with run-testnet-rehearsal.sh, on purpose)
#   FYP_LEDGER_URL          published cycle-history.jsonl  (URL or path)
#   FYP_ANCHOR_SOURCE_URL   published anchor-source.json   (URL or path)
#   FYP_ANCHOR_HISTORY_URL  published anchor-history.jsonl (URL or path)
#   FYP_VALIDATOR_URL       published validator.json       (URL or path)
#   FYP_REHEARSAL_CFG       rehearsal config dir
#   FYP_MAINNET_CFG         mainnet broadcast config dir
#   FYP_IDENTITY_KEY        operator identity private key path
#   FYP_KEYSTORE_TESTNET    project testnet keystore dir
#   FYP_KEYSTORE_MAINNET    project mainnet keystore dir
#   FYP_CURL                curl binary
#
# Exit codes (the code of the FIRST failing check in listing order; every
# check is still evaluated and reported, so one run shows every problem):
#   0  every check PASSED
#   1  usage error
#   2  a prerequisite tool is missing            (check 1)
#   3  an operator-local config/key file is missing or malformed (checks 3-5)
#   4  the current on-chain anchor key is NOT in the testnet keystore, or the
#      account carries no anchor permission      (check 9)
#   5  the anchor-source bytes disagree (worktree vs committed vs published)
#                                                (check 6)
#   6  the ledger, the anchor-source, and --expect-cycle do not agree, or the
#      published boundary says the ledger is stale (checks 7-8)
#   7  the testnet keystore is LOCKED (or lists nothing), so check 9 could
#      not be made. INCONCLUSIVE, and inconclusive is not green.
#   8  keystore separation guard failed (Constitution §3.5) — same number and
#      same meaning as bin/, sign-anchor-event.sh and run-testnet-rehearsal.sh
#   9  an observation could not be made: an RPC or a published artifact was
#      unreachable/unparseable. INCONCLUSIVE, and inconclusive is not green.
#
# There is no bypass flag, no --skip-*, and no --offline that returns 0. A
# check that cannot be made is a failure, because the whole point is to find
# out now rather than in front of the operator.
#
# WHAT THIS SCRIPT CANNOT TELL YOU (stated because the half-claim is the one
# this repo keeps paying for):
#   * It cannot prove the declared cycle number matches the operator's
#     INTENT. It proves the number is the only one consistent with three
#     published artifacts read together (cycle-history, anchor-source,
#     anchor-history), and check 8 states which of the two runs — dress or
#     day-of — that makes it. cycle-transition.sh --status remains the
#     independent post-condition reading of the same day.
#   * It cannot prove the rehearsal will SUCCEED. It proves a specific list
#     of known ways it fails are not present right now.
#   * It says nothing about mainnet gate 1 / gate 4, which testnet execution
#     never reaches (bin/ wrapper, mainnet-only branch).

set -u

# ---------------------------------------------------------------------------
# Locate self + libraries
# ---------------------------------------------------------------------------
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/lib/require-keystore-home.sh
. "${REPO_ROOT}/scripts/lib/require-keystore-home.sh"
# shellcheck source=scripts/lib/cycle-context.sh
. "${REPO_ROOT}/scripts/lib/cycle-context.sh"

# Operator-local paths must keep resolving under the LOGIN home even though
# this script is (correctly, per §3.5) invoked with HOME=<testnet keystore>.
# Same reasoning and same helper as run-testnet-rehearsal.sh:113-126.
LOGIN_HOME="$(fyd_login_home)"
[ -n "$LOGIN_HOME" ] || LOGIN_HOME="$HOME"

REHEARSAL_CFG="${FYP_REHEARSAL_CFG:-${LOGIN_HOME}/freedom-yield-rehearsal-config}"
MAINNET_CFG="${FYP_MAINNET_CFG:-${LOGIN_HOME}/.fy-mainnet-broadcast/config}"
IDENTITY_KEY="${FYP_IDENTITY_KEY:-${LOGIN_HOME}/.ssh/freedom-yield-operator-identity}"
KEYSTORE_TESTNET="${FYP_KEYSTORE_TESTNET:-${LOGIN_HOME}/.metal-fy-proton-test}"
KEYSTORE_MAINNET="${FYP_KEYSTORE_MAINNET:-${LOGIN_HOME}/.metal-fy-proton}"

TESTNET_CHAIN_RPC="${XPR_TESTNET_CHAIN_RPC:-https://rpc.api.testnet.metalx.com}"
LEDGER_URL="${FYP_LEDGER_URL:-https://metal.freedom-yield.com/api/cycle-history.jsonl}"
PUB_ANCHOR_URL="${FYP_ANCHOR_SOURCE_URL:-https://metal.freedom-yield.com/api/anchor-source.json}"
PUB_ANCHOR_HISTORY_URL="${FYP_ANCHOR_HISTORY_URL:-https://metal.freedom-yield.com/api/anchor-history.jsonl}"
PUB_VALIDATOR_URL="${FYP_VALIDATOR_URL:-https://metal.freedom-yield.com/api/validator.json}"
CURL_BIN="${FYP_CURL:-curl}"

# fyp_epoch_to_iso <epoch> — UTC ISO-8601, portable across BSD and GNU date.
# Prints nothing on failure; every caller treats an empty answer as "could
# not observe" rather than substituting a guess.
fyp_epoch_to_iso() {
	date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
		|| date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
		|| true
}

CANONICAL_TRACKED_PATH="public/api/anchor-source.json"
PUBKEY_HELPER="${REPO_ROOT}/scripts/lib/eosio-pubkey-raw-hex.js"

# ---------------------------------------------------------------------------
# Args
# ---------------------------------------------------------------------------
EXPECT_CYCLE=""
SOURCE_PATH=""
for arg in "$@"; do
	case "$arg" in
		--expect-cycle=*) EXPECT_CYCLE="${arg#--expect-cycle=}" ;;
		--source=*)       SOURCE_PATH="${arg#--source=}" ;;
		-h|--help)        sed -n '2,140p' "$0" | sed 's/^# \?//'; exit 0 ;;
		*)                echo "ERROR: unknown arg: $arg" >&2; exit 1 ;;
	esac
done
if [ -z "$EXPECT_CYCLE" ]; then
	echo "ERROR: --expect-cycle=<M> is required." >&2
	echo "       M is run-testnet-rehearsal.sh's meaning: the cycle being INSCRIBED," >&2
	echo "       i.e. the anchor-source's observations_branch.cycle_number_observed." >&2
	echo "       It is one MORE than scripts/cycle-transition.sh --expect-cycle." >&2
	echo "       It is deliberately not derived — see this script's header." >&2
	exit 1
fi
if ! printf '%s' "$EXPECT_CYCLE" | grep -qE '^[0-9]+$'; then
	echo "ERROR: --expect-cycle must be a non-negative integer, got: $EXPECT_CYCLE" >&2
	exit 1
fi
[ -n "$SOURCE_PATH" ] || SOURCE_PATH="${REPO_ROOT}/${CANONICAL_TRACKED_PATH}"

# ---------------------------------------------------------------------------
# §3.5 keystore separation guard — BEFORE the first proton invocation.
# ---------------------------------------------------------------------------
# The generic guard (HOME must not be the login default) comes first, then a
# stricter assertion: this script lists the TESTNET keystore, so pointing it
# at the MAINNET one would answer check 9 against the wrong key set and
# report green for a rehearsal that cannot sign. That is the same shape as
# the 2026-07-31 failure (a check that compares against the wrong key list),
# so it is refused rather than warned about.
require_project_keystore_home "$0" || exit 8
fyp_realpath() { ( cd "$1" 2>/dev/null && pwd -P ) || printf '%s' "$1"; }
HOME_REAL="$(fyp_realpath "${HOME}")"
KEYSTORE_TESTNET_REAL="$(fyp_realpath "${KEYSTORE_TESTNET}")"
KEYSTORE_MAINNET_REAL="$(fyp_realpath "${KEYSTORE_MAINNET}")"
if [ "$HOME_REAL" != "$KEYSTORE_TESTNET_REAL" ]; then
	echo "ERROR (keystore guard, Constitution §3.5): HOME must be the PROJECT TESTNET" >&2
	echo "                keystore for this script, because it lists that keystore in check 9." >&2
	echo "                HOME resolves to: ${HOME_REAL}" >&2
	echo "                expected:         ${KEYSTORE_TESTNET_REAL}" >&2
	if [ "$HOME_REAL" = "$KEYSTORE_MAINNET_REAL" ]; then
		echo "                That is the MAINNET keystore. Check 9 would compare the testnet" >&2
		echo "                chain's key against the mainnet key list and could only ever" >&2
		echo "                answer 'absent' — a wrong-key-list check is the exact 2026-07-31" >&2
		echo "                failure this script exists to prevent." >&2
	fi
	echo "                Re-invoke as:" >&2
	echo "                  HOME=~/.metal-fy-proton-test bash $0 --expect-cycle=${EXPECT_CYCLE}" >&2
	exit 8
fi

# ---------------------------------------------------------------------------
# Check bookkeeping
# ---------------------------------------------------------------------------
# Every check runs. Failures accumulate; the process exits with the code of
# the FIRST failure in listing order, so one run shows every problem and the
# exit code still names a single, stable cause.
FIRST_FAIL_CODE=0
FIRST_FAIL_ID=""
N_PASS=0
N_FAIL=0
SUMMARY=""

chk_pass() { # <id> <title> [detail]
	N_PASS=$((N_PASS + 1))
	printf '  PASS  [%s] %s\n' "$1" "$2"
	[ -n "${3:-}" ] && printf '          %s\n' "$3"
	SUMMARY="${SUMMARY}PASS  [$1] $2
"
	return 0
}
chk_fail() { # <id> <code> <title> <reason...>
	local id="$1" code="$2" title="$3"
	shift 3
	N_FAIL=$((N_FAIL + 1))
	if [ "$FIRST_FAIL_CODE" -eq 0 ]; then
		FIRST_FAIL_CODE="$code"
		FIRST_FAIL_ID="$id"
	fi
	printf '  FAIL  [%s] %s   (exit %s)\n' "$id" "$title" "$code" >&2
	local line
	for line in "$@"; do
		printf '          %s\n' "$line" >&2
	done
	SUMMARY="${SUMMARY}FAIL  [$id] $title  (exit $code)
"
	return 0
}
note() { printf '          %s\n' "$*"; }

# fyp_fetch <url-or-path> <outfile> — prints nothing, returns non-zero on
# failure. A value that does not start with http:// or https:// is treated as
# a LOCAL PATH and copied, so the suite can run with no network and no stub.
fyp_fetch() {
	local src="$1" out="$2" code
	case "$src" in
		http://*|https://*)
			# Cache-bust for the same reason preview-cycle-anchor-broadcast.sh
			# does: /api/*.json is edge-cached for up to 120s, and a stale
			# edge copy is precisely the divergence being looked for.
			code="$("$CURL_BIN" -sS -o "$out" -w '%{http_code}' --max-time 20 \
				-H 'Cache-Control: no-cache' -H 'Pragma: no-cache' \
				"${src}?cb=$(date +%s)-$$" 2>/dev/null || echo 000)"
			[ "$code" = "200" ] || return 1
			;;
		*)
			[ -r "$src" ] || return 1
			cat "$src" > "$out" 2>/dev/null || return 1
			;;
	esac
	[ -s "$out" ] || return 1
	return 0
}

WORK="$(mktemp -d -t fya-rehearsal-preflight.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

echo "════════════════════════════════════════════════════════════════"
echo "  REHEARSAL PRE-FLIGHT — read-only, fail-closed, nothing broadcast"
echo "════════════════════════════════════════════════════════════════"
echo "  repo:              $REPO_ROOT"
echo "  keystore (HOME):   $HOME_REAL"
echo "  anchor-source:     $SOURCE_PATH"
echo "  --expect-cycle:    $EXPECT_CYCLE   (rehearsal meaning: the cycle to INSCRIBE)"
echo "  sibling value:     $((EXPECT_CYCLE - 1))   (cycle-transition.sh --expect-cycle: the cycle CLOSING today)"
echo

# ===========================================================================
# Check 1 — prerequisite tools
# ===========================================================================
echo "── check 1 — prerequisite tools on PATH ──"
MISSING_TOOLS=""
for t in proton node jq curl git ssh-keygen ssh-add timeout; do
	command -v "$t" >/dev/null 2>&1 || MISSING_TOOLS="${MISSING_TOOLS} ${t}"
done
HAVE_SHA=0
command -v sha256sum >/dev/null 2>&1 && HAVE_SHA=1
command -v shasum    >/dev/null 2>&1 && HAVE_SHA=1
[ "$HAVE_SHA" -eq 1 ] || MISSING_TOOLS="${MISSING_TOOLS} sha256sum|shasum"
if [ -z "$MISSING_TOOLS" ]; then
	chk_pass 1 "prerequisite tools present" "proton node jq curl git ssh-keygen ssh-add timeout + a sha256 tool"
else
	# The bare-name `timeout` requirement gets its own sentence because
	# "gtimeout is installed" is the state that reads like success and is not:
	# run-testnet-rehearsal.sh:276-278 calls the bare name, and without it a
	# locked keystore hangs the rehearsal instead of exiting 2.
	TIMEOUT_HINT="(no additional detail)"
	case "$MISSING_TOOLS" in
		*timeout*)
			if command -v gtimeout >/dev/null 2>&1; then
				TIMEOUT_HINT="gtimeout IS present but the bare name 'timeout' is not — run-testnet-rehearsal.sh:276-278 calls the bare name. Put coreutils' gnubin on PATH."
			fi
			;;
	esac
	chk_fail 1 2 "prerequisite tools missing" "missing:${MISSING_TOOLS}" "$TIMEOUT_HINT"
fi

# ===========================================================================
# Check 2 — keystore separation (§3.5) beyond the hard guard above
# ===========================================================================
echo "── check 2 — keystore separation (§3.5) ──"
KS_PROBLEMS=""
[ -d "$KEYSTORE_TESTNET" ] || KS_PROBLEMS="${KS_PROBLEMS} testnet-keystore-dir-missing"
[ -d "$KEYSTORE_MAINNET" ] || KS_PROBLEMS="${KS_PROBLEMS} mainnet-keystore-dir-missing"
[ "$KEYSTORE_TESTNET_REAL" != "$KEYSTORE_MAINNET_REAL" ] || KS_PROBLEMS="${KS_PROBLEMS} testnet-and-mainnet-keystores-are-the-same-dir"
[ "$KEYSTORE_TESTNET_REAL" != "$(fyp_realpath "$LOGIN_HOME")" ] || KS_PROBLEMS="${KS_PROBLEMS} testnet-keystore-is-the-login-home"
if [ -z "$KS_PROBLEMS" ]; then
	chk_pass 2 "testnet and mainnet keystores exist and are separate dirs"
else
	chk_fail 2 8 "keystore separation problem" "problems:${KS_PROBLEMS}" \
		"§3.5 requires one keystore dir per network, neither of them the login home." \
		"Never repair this by pointing at the default shared keystore."
fi

# ===========================================================================
# Check 3 — rehearsal config dir (what run-testnet-rehearsal.sh step 2 reads)
# ===========================================================================
echo "── check 3 — rehearsal config dir ──"
echo "          $REHEARSAL_CFG"
RH_PROBLEMS=""
for f in xpr-account anchor-sink xpr-chain; do
	[ -r "${REHEARSAL_CFG}/${f}" ] || RH_PROBLEMS="${RH_PROBLEMS} missing:${f}"
done
RH_ACCOUNT=""
RH_SINK=""
RH_CHAIN=""
if [ -z "$RH_PROBLEMS" ]; then
	RH_ACCOUNT="$(tr -d '\r\n\t ' < "${REHEARSAL_CFG}/xpr-account")"
	RH_SINK="$(tr -d '\r\n\t ' < "${REHEARSAL_CFG}/anchor-sink")"
	RH_CHAIN="$(tr -d '\r\n\t ' < "${REHEARSAL_CFG}/xpr-chain")"
	[ -n "$RH_ACCOUNT" ] || RH_PROBLEMS="${RH_PROBLEMS} empty:xpr-account"
	[ -n "$RH_SINK" ]    || RH_PROBLEMS="${RH_PROBLEMS} empty:anchor-sink"
	# BLOCK-1, enforced by sign-anchor-event.sh:286: eosio.token rejects a
	# self-transfer, so an equal sink fails only once the tx is composed.
	[ "$RH_SINK" != "$RH_ACCOUNT" ] || RH_PROBLEMS="${RH_PROBLEMS} sink-equals-account(BLOCK-1)"
	[ "$RH_CHAIN" = "proton-test" ] || RH_PROBLEMS="${RH_PROBLEMS} xpr-chain-is-not-proton-test"
fi
if [ -z "$RH_PROBLEMS" ]; then
	chk_pass 3 "rehearsal config complete" "actor=${RH_ACCOUNT} chain=${RH_CHAIN}"
else
	chk_fail 3 3 "rehearsal config incomplete or wrong" "problems:${RH_PROBLEMS}" \
		"run-testnet-rehearsal.sh step 2/10 reads exactly these three files."
fi

# ===========================================================================
# Check 4 — mainnet broadcast config dir (unit 7b reads this on the same day)
# ===========================================================================
echo "── check 4 — mainnet broadcast config dir ──"
echo "          $MAINNET_CFG"
MN_PROBLEMS=""
for f in xpr-account anchor-sink; do
	[ -r "${MAINNET_CFG}/${f}" ] || MN_PROBLEMS="${MN_PROBLEMS} missing:${f}"
done
if [ -z "$MN_PROBLEMS" ]; then
	MN_ACCOUNT="$(tr -d '\r\n\t ' < "${MAINNET_CFG}/xpr-account")"
	MN_SINK="$(tr -d '\r\n\t ' < "${MAINNET_CFG}/anchor-sink")"
	[ -n "$MN_ACCOUNT" ] || MN_PROBLEMS="${MN_PROBLEMS} empty:xpr-account"
	[ -n "$MN_SINK" ]    || MN_PROBLEMS="${MN_PROBLEMS} empty:anchor-sink"
	[ "$MN_SINK" != "$MN_ACCOUNT" ] || MN_PROBLEMS="${MN_PROBLEMS} sink-equals-account(BLOCK-1)"
fi
if [ -z "$MN_PROBLEMS" ]; then
	QNOTE="xpr-quantity present"
	[ -r "${MAINNET_CFG}/xpr-quantity" ] || QNOTE="xpr-quantity absent — sign-anchor-event.sh:289 defaults it, so this is not a failure"
	chk_pass 4 "mainnet broadcast config complete" "$QNOTE"
else
	chk_fail 4 3 "mainnet broadcast config incomplete" "problems:${MN_PROBLEMS}" \
		"preview-cycle-anchor-broadcast.sh:311-321 exits 3 on this and leaves a 0-byte" \
		"dry-run log, which then fails much later at the mainnet gate."
fi

# ===========================================================================
# Check 5 — operator identity key pair
# ===========================================================================
echo "── check 5 — operator identity key ──"
ID_PROBLEMS=""
[ -f "$IDENTITY_KEY" ]        || ID_PROBLEMS="${ID_PROBLEMS} missing-private-key"
[ -f "${IDENTITY_KEY}.pub" ]  || ID_PROBLEMS="${ID_PROBLEMS} missing-public-key"
ID_MODE=""
if [ -f "$IDENTITY_KEY" ]; then
	ID_MODE="$(ls -l "$IDENTITY_KEY" | cut -c1-10)"
	case "$ID_MODE" in
		-rw-------) : ;;
		*)          ID_PROBLEMS="${ID_PROBLEMS} private-key-mode-not-600(${ID_MODE})" ;;
	esac
fi
if [ -z "$ID_PROBLEMS" ]; then
	chk_pass 5 "identity key pair present, private key is mode 600" "$IDENTITY_KEY"
else
	chk_fail 5 3 "operator identity key problem" "problems:${ID_PROBLEMS}" \
		"gen-identity.sh:167-175 exits 1 without the pair. It is unit 4's signing key," \
		"needed on transition day, not by the rehearsal itself."
fi

# ===========================================================================
# Check 6 — anchor-source bytes: worktree == committed == published
# ===========================================================================
echo "── check 6 — anchor-source bytes (worktree / committed / published) ──"
SRC_PROBLEMS=""
SRC_CODE=5
SRC_CYCLE=""
SRC_DAG=""
if [ ! -r "$SOURCE_PATH" ]; then
	SRC_PROBLEMS="unreadable --source: ${SOURCE_PATH}"
else
	SRC_CYCLE="$(jq -r '.observations_branch.cycle_number_observed // empty' "$SOURCE_PATH" 2>/dev/null)"
	SRC_DAG="$(jq -r '.dag_root_computed // empty' "$SOURCE_PATH" 2>/dev/null)"
	if [ -z "$SRC_CYCLE" ] || [ -z "$SRC_DAG" ]; then
		SRC_PROBLEMS="--source does not parse as an anchor-source (no cycle_number_observed / dag_root_computed)"
	else
		# 6a: committed-bytes guard — the precursor of
		# preview-cycle-anchor-broadcast.sh's exit 9.
		HEAD_TMP="${WORK}/head-anchor-source.json"
		if ! git -C "$REPO_ROOT" show "HEAD:${CANONICAL_TRACKED_PATH}" > "$HEAD_TMP" 2>/dev/null; then
			SRC_PROBLEMS="cannot read HEAD:${CANONICAL_TRACKED_PATH} from this repo"
			SRC_CODE=5
		elif ! cmp -s "$SOURCE_PATH" "$HEAD_TMP"; then
			SRC_PROBLEMS="--source is NOT byte-identical to git show HEAD:${CANONICAL_TRACKED_PATH}"
			SRC_CODE=5
		else
			# 6b: published-copy guard — the precursor of exit 10.
			PUB_TMP="${WORK}/published-anchor-source.json"
			if ! fyp_fetch "$PUB_ANCHOR_URL" "$PUB_TMP"; then
				SRC_PROBLEMS="could not fetch the published anchor-source: ${PUB_ANCHOR_URL}"
				SRC_CODE=9
			elif ! jq empty "$PUB_TMP" >/dev/null 2>&1; then
				SRC_PROBLEMS="the published anchor-source is not valid JSON: ${PUB_ANCHOR_URL}"
				SRC_CODE=9
			else
				PUB_DAG="$(jq -r '.dag_root_computed // empty' "$PUB_TMP")"
				if [ "$PUB_DAG" != "$SRC_DAG" ]; then
					SRC_PROBLEMS="published dag_root_computed (${PUB_DAG:-none}) != source's (${SRC_DAG})"
					SRC_CODE=5
				fi
			fi
		fi
	fi
fi
if [ -z "$SRC_PROBLEMS" ]; then
	chk_pass 6 "anchor-source: worktree == committed == published" \
		"cycle_number_observed=${SRC_CYCLE}  dag_root=${SRC_DAG:0:16}…"
else
	chk_fail 6 "$SRC_CODE" "anchor-source bytes disagree or are unobservable" "$SRC_PROBLEMS" \
		"These are the two guards preview-cycle-anchor-broadcast.sh enforces as exits 9 and 10." \
		"Failing them here means unit 7b would refuse on transition day."
fi

# ===========================================================================
# Check 7 — the published ledger, the anchor-source and --expect-cycle agree
# ===========================================================================
echo "── check 7 — ledger vs anchor-source vs --expect-cycle ──"
LEDGER="${WORK}/cycle-history.jsonl"
LED_PROBLEMS=""
LED_CODE=6
CLOSED=""
INSCRIBE=""
if ! fyp_fetch "$LEDGER_URL" "$LEDGER"; then
	LED_PROBLEMS="could not fetch the published cycle-history ledger: ${LEDGER_URL}"
	LED_CODE=9
else
	CC_RC=0
	CLOSED="$(fyc_closed_cycle_count "$LEDGER" 2>"${WORK}/cc.err")" || CC_RC=$?
	if [ "$CC_RC" -ne 0 ]; then
		# 65 = unreadable (cannot happen: fyp_fetch already proved it readable).
		# 66 = the ledger's own idioms disagree -> a real data problem, not an
		# observation failure, so it keeps the ledger exit code (6).
		LED_PROBLEMS="cycle-context refused to derive a count from the ledger (rc=${CC_RC}): $(tr '\n' ' ' < "${WORK}/cc.err")"
		[ "$CC_RC" = "65" ] && LED_CODE=9
	else
		INSCRIBE=$((CLOSED + 1))
		if [ "$EXPECT_CYCLE" -ne "$INSCRIBE" ]; then
			LED_PROBLEMS="--expect-cycle=${EXPECT_CYCLE} but the published ledger holds ${CLOSED} closed cycles, so the number to inscribe is ${INSCRIBE}"
		elif [ -n "$SRC_CYCLE" ] && [ "$SRC_CYCLE" != "$EXPECT_CYCLE" ]; then
			LED_PROBLEMS="the anchor-source's cycle_number_observed is ${SRC_CYCLE}, not ${EXPECT_CYCLE} — run-testnet-rehearsal.sh step 1/10 refuses on exactly this"
		fi
	fi
fi
if [ -z "$LED_PROBLEMS" ]; then
	chk_pass 7 "ledger, anchor-source and --expect-cycle agree" \
		"closed=${CLOSED} -> inscribe=${INSCRIBE} = --expect-cycle = anchor-source cycle_number_observed"
	note "cycle-transition.sh --expect-cycle for the same day would be $((INSCRIBE - 1)), not ${INSCRIBE}."
else
	chk_fail 7 "$LED_CODE" "ledger / anchor-source / --expect-cycle disagree" "$LED_PROBLEMS" \
		"If you meant the DAY-OF value, phase 1 (units 1-3) must land first: the rehearsal" \
		"runs AFTER the day's recompose+publish (units 5/6), never before." \
		"Remember the two meanings: cycle-transition.sh --expect-cycle is one LESS than this one."
fi

# ===========================================================================
# Check 8 — what is ALREADY inscribed, as the second observation
# ===========================================================================
# Check 7 proves --expect-cycle is the only number consistent with the
# published cycle-history ledger. It cannot tell a dress run apart from the
# day-of run, because both readings of the ledger are legitimate — that is
# the off-by-one recorded in scripts/cycle-transition.sh's header.
#
# The published anchor-history ledger CAN tell them apart, because it records
# what has actually been inscribed on mainnet:
#
#   --expect-cycle == last inscribed  ->  that cycle's anchor is already
#                                         on-chain. A rehearsal for it is a
#                                         DRESS run; its tx is not gate-1
#                                         evidence for anything outstanding.
#   --expect-cycle == last inscribed+1 -> nothing is inscribed for it yet.
#                                         DAY-OF; the tx IS the gate-1 input.
#   anything else                      -> REFUSED. Neither the cycle that was
#                                         inscribed nor the next one.
#
# The registered period's end (published validator.json) is read in the same
# check, for one narrow refusal it makes possible: if the period has already
# ended and the anchor ledger has NOT advanced past it, then the number being
# declared belongs to the cycle that just closed rather than the one opening.
echo "── check 8 — already-inscribed anchor ledger vs --expect-cycle ──"
HIST_TMP="${WORK}/anchor-history.jsonl"
VAL_TMP="${WORK}/validator.json"
BND_PROBLEMS=""
BND_CODE=6
CLASSIFICATION=""
LAST_INSCRIBED=""
END_ISO=""
if ! fyp_fetch "$PUB_ANCHOR_HISTORY_URL" "$HIST_TMP"; then
	BND_PROBLEMS="could not fetch the published anchor-history ledger: ${PUB_ANCHOR_HISTORY_URL}"
	BND_CODE=9
elif ! fyp_fetch "$PUB_VALIDATOR_URL" "$VAL_TMP"; then
	BND_PROBLEMS="could not fetch the published validator.json: ${PUB_VALIDATOR_URL}"
	BND_CODE=9
else
	LAST_INSCRIBED="$(grep -vE '^[[:space:]]*$' "$HIST_TMP" | tail -1 | jq -r '.cycle_number // empty' 2>/dev/null)"
	END_EPOCH="$(jq -r '.endTime // empty' "$VAL_TMP" 2>/dev/null)"
	if ! printf '%s' "$LAST_INSCRIBED" | grep -qE '^[0-9]+$'; then
		BND_PROBLEMS="the published anchor-history's newest record has no numeric cycle_number — refusing to classify this run"
		BND_CODE=9
	elif ! printf '%s' "$END_EPOCH" | grep -qE '^[0-9]+$'; then
		BND_PROBLEMS="the published validator.json has no numeric endTime — refusing to classify this run"
		BND_CODE=9
	else
		NOW_EPOCH="$(date -u +%s)"
		END_ISO="$(fyp_epoch_to_iso "$END_EPOCH")"
		[ -n "$END_ISO" ] || END_ISO="epoch ${END_EPOCH}"
		if [ "$EXPECT_CYCLE" -eq "$LAST_INSCRIBED" ]; then
			if [ "$NOW_EPOCH" -ge "$END_EPOCH" ]; then
				BND_PROBLEMS="cycle ${EXPECT_CYCLE} is already inscribed AND the registered period ended at ${END_ISO} — this number belongs to the cycle that just closed, not the one opening. The day's rehearsal is --expect-cycle=$((EXPECT_CYCLE + 1)), and it runs after units 5/6."
			else
				CLASSIFICATION="DRESS"
			fi
		elif [ "$EXPECT_CYCLE" -eq "$((LAST_INSCRIBED + 1))" ]; then
			CLASSIFICATION="DAY-OF"
		else
			BND_PROBLEMS="--expect-cycle=${EXPECT_CYCLE} is neither the last inscribed cycle (${LAST_INSCRIBED}) nor the next one ($((LAST_INSCRIBED + 1)))"
		fi
	fi
fi
if [ -z "$BND_PROBLEMS" ]; then
	chk_pass 8 "--expect-cycle is placed against what is already inscribed" \
		"last inscribed=${LAST_INSCRIBED}; registered period ends ${END_ISO}; classification: ${CLASSIFICATION}"
else
	chk_fail 8 "$BND_CODE" "--expect-cycle does not sit where the anchor ledger says it should" "$BND_PROBLEMS"
fi

# ===========================================================================
# Check 9 — the CURRENT on-chain <actor>@anchor key is in the testnet keystore
# ===========================================================================
# This is the 2026-07-31 check. It is re-implemented here rather than reused,
# because run-testnet-rehearsal.sh reaches it only at step 3/10 — i.e. after
# it has already begun, and (from step 5 onward) on a path that ends in a
# broadcast. This script's version stops at the comparison and has no
# continuation.
echo "── check 9 — current on-chain <actor>@anchor key present in the testnet keystore ──"
KEY_PROBLEMS=""
KEY_CODE=4
KEY_DETAIL=""
if [ -n "$RH_PROBLEMS" ]; then
	KEY_PROBLEMS="skipped: check 3 did not yield an actor to look up"
	KEY_CODE=3
elif ! command -v proton >/dev/null 2>&1 || ! command -v node >/dev/null 2>&1 || ! command -v timeout >/dev/null 2>&1; then
	KEY_PROBLEMS="skipped: check 1 is missing a tool this check needs (proton / node / timeout)"
	KEY_CODE=2
elif [ ! -r "$PUBKEY_HELPER" ]; then
	KEY_PROBLEMS="missing helper: ${PUBKEY_HELPER}"
	KEY_CODE=2
else
	ACCT_JSON="${WORK}/get_account.json"
	CURL_RC=0
	"$CURL_BIN" -sS --max-time 20 -X POST -H 'content-type: application/json' \
		-d "$(jq -nc --arg a "$RH_ACCOUNT" '{account_name:$a}')" \
		"${TESTNET_CHAIN_RPC}/v1/chain/get_account" > "$ACCT_JSON" 2>"${WORK}/curl.err" || CURL_RC=$?
	if [ "$CURL_RC" -ne 0 ] || [ ! -s "$ACCT_JSON" ]; then
		KEY_PROBLEMS="testnet chain RPC unreachable (rc=${CURL_RC}): ${TESTNET_CHAIN_RPC}/v1/chain/get_account — $(tr '\n' ' ' < "${WORK}/curl.err" 2>/dev/null)"
		KEY_CODE=9
	elif ! jq -e --arg a "$RH_ACCOUNT" '.account_name == $a and (.permissions | type == "array")' "$ACCT_JSON" >/dev/null 2>&1; then
		KEY_PROBLEMS="testnet get_account response malformed/unexpected for the rehearsal actor"
		KEY_CODE=9
	else
		CHAIN_KEY="$(jq -r '[.permissions[] | select(.perm_name=="anchor")][0].required_auth.keys[0].key // empty' "$ACCT_JSON")"
		if [ -z "$CHAIN_KEY" ]; then
			KEY_PROBLEMS="the testnet account carries no 'anchor' permission with a key (expected owner->active->anchor per docs/ANCHOR_ACCOUNT_KEY_ROTATION.md)"
			KEY_CODE=4
		elif ! CHAIN_RAW="$(node "$PUBKEY_HELPER" "$CHAIN_KEY" 2>&1)"; then
			KEY_PROBLEMS="could not decode the chain-returned anchor pubkey: ${CHAIN_RAW}"
			KEY_CODE=9
		else
			# Non-destructive listing only. stdin closed + timeout, so a
			# locked keystore's passphrase prompt fails fast instead of
			# hanging (reference_proton_cli_keystore_lock_quirk).
			KEYS_RC=0
			KEYS_JSON="$(timeout 5 proton key:list 2>/dev/null </dev/null)" || KEYS_RC=$?
			if [ "$KEYS_RC" -ne 0 ]; then
				KEY_PROBLEMS="the testnet keystore is LOCKED (proton key:list rc=${KEYS_RC}$( [ "$KEYS_RC" = 124 ] && printf ', timed out' )) — this check could not be made"
				KEY_CODE=7
			else
				CANDIDATES="$(printf '%s' "$KEYS_JSON" | grep -oE '(PUB_K1_|EOS)[1-9A-HJ-NP-Za-km-z]+' | sort -u || true)"
				if [ -z "$CANDIDATES" ]; then
					KEY_PROBLEMS="proton key:list succeeded but listed no public keys — a locked keystore can also list nothing, so this is INCONCLUSIVE, not proof the key is absent"
					KEY_CODE=7
				else
					MATCH=""
					while IFS= read -r cand; do
						[ -n "$cand" ] || continue
						CAND_RAW="$(node "$PUBKEY_HELPER" "$cand" 2>/dev/null)" || continue
						if [ "$CAND_RAW" = "$CHAIN_RAW" ]; then
							MATCH="$cand"
							break
						fi
					done <<-CANDLIST
					$CANDIDATES
					CANDLIST
					if [ -z "$MATCH" ]; then
						KEY_PROBLEMS="the CURRENT on-chain anchor key is NOT in the project testnet keystore"
						KEY_CODE=4
					else
						KEY_DETAIL="present: ${MATCH:0:16}…  (matches the current on-chain key)"
					fi
				fi
			fi
		fi
	fi
fi
if [ -z "$KEY_PROBLEMS" ]; then
	chk_pass 9 "current on-chain anchor key is in the testnet keystore" "$KEY_DETAIL"
else
	case "$KEY_CODE" in
		7) chk_fail 9 7 "keystore locked / empty listing — check could not be made" "$KEY_PROBLEMS" \
			"Operator action, in a separate terminal, one line:" \
			"  HOME=~/.metal-fy-proton-test proton key:unlock" \
			"then re-run this pre-flight. Do NOT follow the key-rotation runbook for this;" \
			"a locked keystore misdiagnosed as a missing key is the 2026-07-31 audit finding." ;;
		4) chk_fail 9 4 "current on-chain anchor key NOT in the testnet keystore" "$KEY_PROBLEMS" \
			"This is the 2026-07-31 failure class, found that time at the day-of walkthrough." \
			"Import the matching private key per docs/ANCHOR_ACCOUNT_KEY_ROTATION.md, then re-run." \
			"The chain is the authority here — nothing is pinned in this script." ;;
		*) chk_fail 9 "$KEY_CODE" "anchor key check could not be completed" "$KEY_PROBLEMS" ;;
	esac
fi

# ===========================================================================
# Advisory — ssh-agent (deliberately NOT part of the verdict)
# ===========================================================================
# The identity key's passphrase is supplied through ssh-agent, and agent
# state is per-session: it does not survive a reboot or a new login, so an
# assertion made days before the rehearsal says nothing about the rehearsal
# day. Making it a check would put a permanently-flickering red in a gate
# that is only useful while it is binary (memory/feedback_green_gate_must_be_binary).
# It is reported because the operator can act on it in ten seconds, and it is
# not counted because a stale answer is not evidence.
echo "── advisory — ssh-agent (not part of the verdict) ──"
AGENT_STATE="unknown"
if [ -f "${IDENTITY_KEY}.pub" ] && command -v ssh-keygen >/dev/null 2>&1 && command -v ssh-add >/dev/null 2>&1; then
	ID_FP="$(ssh-keygen -lf "${IDENTITY_KEY}.pub" 2>/dev/null | awk '{print $2}')"
	if [ -z "$ID_FP" ]; then
		AGENT_STATE="could not fingerprint the public key"
	elif ssh-add -l 2>/dev/null | awk '{print $2}' | grep -qxF "$ID_FP"; then
		AGENT_STATE="LOADED"
	else
		AGENT_STATE="NOT loaded"
	fi
fi
echo "          identity key in ssh-agent: ${AGENT_STATE}"
if [ "$AGENT_STATE" != "LOADED" ]; then
	echo "          Before unit 4 on transition day, operator runs (one line):"
	echo "            ssh-add ~/.ssh/freedom-yield-operator-identity"
	echo "          Dashlane entry: <entry name withheld - handed over in the operator ping>"
	echo "          Not needed for the rehearsal itself; needed for gen-identity.sh."
fi

# ===========================================================================
# Verdict
# ===========================================================================
echo
echo "════════════════════════════════════════════════════════════════"
printf '%s' "$SUMMARY"
echo "────────────────────────────────────────────────────────────────"
echo "checks: PASS=${N_PASS}  FAIL=${N_FAIL}"
if [ "$FIRST_FAIL_CODE" -eq 0 ]; then
	echo "VERDICT: PRE-FLIGHT GREEN — every check above was MADE and PASSED."
	if [ "$CLASSIFICATION" = "DRESS" ]; then
		echo
		echo "  CLASSIFICATION: DRESS REHEARSAL — the resulting tx is NOT gate-1 evidence."
		echo "  Cycle ${EXPECT_CYCLE}'s anchor is already on-chain (published anchor-history, newest row),"
		echo "  and the registered period has not ended yet. A run now exercises the whole"
		echo "  pipeline against today's real data, which is the point; but the mainnet gate 1"
		echo "  refuses cross-cycle evidence, so this tx id authorizes nothing."
		echo "  On transition day the rehearsal must be run AGAIN, after units 5/6, with"
		echo "  --expect-cycle=$((EXPECT_CYCLE + 1)). That second run is not optional."
	elif [ "$CLASSIFICATION" = "DAY-OF" ]; then
		echo
		echo "  CLASSIFICATION: DAY-OF — the resulting tx IS the mainnet gate-1 input."
		echo "  Nothing is inscribed for cycle ${EXPECT_CYCLE} yet (newest anchor-history row is $((EXPECT_CYCLE - 1))),"
		echo "  and the published ledger has advanced to match. Paste the sentinel line back."
	fi
	echo
	echo "  What green does NOT mean: it does not mean the rehearsal will succeed, and it"
	echo "  does not prove the operator's intent — it means ${EXPECT_CYCLE} is the only number consistent"
	echo "  with the published cycle-history ledger, the committed+published anchor-source,"
	echo "  and the published anchor-history, all read within this run."
	echo "  Run scripts/cycle-transition.sh --status --expect-cycle=$((EXPECT_CYCLE - 1)) for the"
	echo "  independent post-condition reading of the same day (note the -1: that flag means"
	echo "  the cycle CLOSING today, this one means the cycle being INSCRIBED)."
	echo "════════════════════════════════════════════════════════════════"
	exit 0
fi
echo "VERDICT: PRE-FLIGHT RED — first failure was [${FIRST_FAIL_ID}], exiting ${FIRST_FAIL_CODE}."
echo "         Do not call the operator until this is green. Every failure above is a way"
echo "         the rehearsal fails after the operator is already standing there."
echo "════════════════════════════════════════════════════════════════"
exit "$FIRST_FAIL_CODE"
