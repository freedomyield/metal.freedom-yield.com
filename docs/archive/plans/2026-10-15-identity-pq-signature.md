# Operator Identity PQ Signature (ML-DSA-65) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an additive ML-DSA-65 signature over `public/api/identity.json` (schema v2), produced on the operator Mac by `gen-identity.sh` from an operator-unlocked key that is auto-locked right after signing, and verified in CI with stock OpenSSL ≥ 3.5.

**Architecture:** One shared shell library (`scripts/lib/identity-pq.sh`) owns every PQ constant and primitive (OpenSSL resolution, fingerprint, sign, verify, unlocked-key checks). Operator-local scripts generate / unlock / lock the key; `gen-identity.sh` signs both ways and publishes fail-closed; a separate repo-mode checker (`scripts/check-identity-pq.sh`) verifies in CI. The validator host stays ed25519-only.

**Tech Stack:** bash (must run on macOS `/bin/bash` 3.2 and Ubuntu 26.04 bash), jq, OpenSSL ≥ 3.5 (Homebrew 3.6.3 on the Mac, 3.5.5 on `ubuntu-26.04`), GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-10-15-identity-pq-signature-design.md` (rev 2). Read it before any task.

## Global Constraints

- Algorithm `ML-DSA-65`, standard `FIPS 204`, context string `freedom-yield/validator-identity` — never hard-code these outside `scripts/lib/identity-pq.sh`.
- Published names: `public/.well-known/operator-identity-mldsa65.pub`, `public/api/identity.json.mldsa65.sig`, `public/api/identity.schema.v2.json`. Never `.pem` for a tracked file (`.gitignore:9` + pre-commit filename block).
- Private key at rest: scrypt + AES-256-CBC encrypted seed-only PEM, outside the repo, default dir `${HOME}/.freedom-yield-identity` (mode 0700).
- Unlocked key: same dir, basename `operator-identity-mldsa65.unlocked.pem`, mode 0600; deleted by `gen-identity.sh` on every exit path; refused if older than 7200 s.
- Never use `/usr/bin/openssl` on macOS (LibreSSL). OpenSSL calls that may read a passphrase or key redirect stdin from `/dev/null` when non-interactive.
- **The Dashlane entry name is never written in this repo** — scripts say "the Dashlane entry named in the AI's ping".
- CI uses the pinned label `ubuntu-26.04`, never `ubuntu-latest`, for any job that needs ML-DSA.
- The validator host (`scripts/resume-after-cycle-start.sh`) is NOT changed.
- Public wording limited to "identity.json also carries an ML-DSA-65 (FIPS 204) signature". EN pages carry no Japanese; JA pages mirror EN. No inline `style=` (CSP).
- Every test that claims a property is proven by a mutation that makes it fail; report `MUTATION NOT CAUGHT: …` on failure (repo convention). Tests named `tests/**/test-*.sh`, executable (`chmod +x`), picked up by `tests/run-all-tests.sh`.
- In tests, PQ prerequisites missing → graceful SKIP, **unless `FY_REQUIRE_PQ=1`** (set in CI), in which case missing prerequisites FAIL.
- `.githooks/pre-commit` blocks any staged line matching `BEGIN (PRIVATE|RSA|EC|OPENSSH|DSA|ENCRYPTED)` and filenames ending `.pem`. Never write a private-key PEM header literally in a tracked file (assemble it from fragments at runtime) and never commit key material, even throwaway; test keys are generated into `mktemp -d` at run time. Never bypass the hook (`--no-verify` is forbidden).
- No push, no deploy, no web-host or validator-host action in any task. Commits are single-purpose with a *why* body and end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. **Second run of `gen-identity.sh` on the same day** (after the auto-lock deleted the unlocked key) must stop with exit 5 and a message telling the operator to run `pq-identity-unlock.sh` — not a cryptic OpenSSL error. Owner: Task 3 (case R1).
2. **LibreSSL first on PATH on the Mac** (`/usr/bin/openssl`) must never be picked; with Homebrew absent the script must stop with exit 5 naming `FY_OPENSSL`. Owner: Task 1 (case L3).
3. **An unlocked key left over from a previous day** must be refused (exit 5) AND deleted. Owner: Task 3 (case R2).
4. **The committed `.pub` swapped for another key while the unlocked key is the old one** must fail self-verify with exit 11 and publish nothing. Owner: Task 3 (case R3).
5. **Transition window:** while the live manifest is still schema v1, CI must pass on ed25519 alone; once it is v2, a missing or bad PQ file must fail CI. Owner: Task 4 (cases C1, C4).

---

## Execution order and parallelism

- **Task 1 first (serial).** Every other task consumes its library.
- **Tasks 2–7 in parallel** after Task 1 is merged into the integration branch. Their file sets are disjoint (listed per task). Each runs in its own worktree.
- **Task 8 is the operator delivery runbook** — not an implementer task; executed by the coordinator with the operator after everything is merged and the whole-branch review passes.

---

### Task 1: Shared PQ library + test-key helper

**Files:**
- Create: `scripts/lib/identity-pq.sh`
- Create: `tests/lib/pq-test-key.sh`
- Test: `tests/identity-pq-lib/test-identity-pq-lib.sh`

**Interfaces:**
- Consumes: nothing.
- Produces (all later tasks use exactly these names):
  - Constants: `FYIPQ_ALGORITHM="ML-DSA-65"`, `FYIPQ_STANDARD="FIPS 204"`, `FYIPQ_CONTEXT="freedom-yield/validator-identity"`, `FYIPQ_MIN_OPENSSL="3.5"`, `FYIPQ_PUB_REL="public/.well-known/operator-identity-mldsa65.pub"`, `FYIPQ_SIG_REL="public/api/identity.json.mldsa65.sig"`, `FYIPQ_PUB_URL="https://metal.freedom-yield.com/.well-known/operator-identity-mldsa65.pub"`, `FYIPQ_SIG_URL="https://metal.freedom-yield.com/api/identity.json.mldsa65.sig"`, `FYIPQ_ENC_BASENAME="operator-identity-mldsa65.enc.pem"`, `FYIPQ_UNLOCKED_BASENAME="operator-identity-mldsa65.unlocked.pem"`, `FYIPQ_UNLOCK_MAX_AGE_SEC_DEFAULT=7200`.
  - `fyipq__key_dir` → prints `${FY_PQ_KEY_DIR:-$HOME/.freedom-yield-identity}`
  - `fyipq__enc_path` / `fyipq__unlocked_path` → full paths in that dir
  - `fyipq__openssl_ok <bin>` → 0 iff OpenSSL (not LibreSSL) ≥ 3.5
  - `fyipq__resolve_openssl` → prints a usable binary path; if `FY_OPENSSL` is set, only that binary is considered; returns 1 if none
  - `fyipq__sha256_hex` (stdin → 64 hex)
  - `fyipq__pub_fingerprint <pem>` → prints `sha256:<64 hex>` of the DER (base64 body of the single `PUBLIC KEY` block); returns 1 on malformed input. Needs no OpenSSL.
  - `fyipq__pub_algorithm <openssl> <pem>` → prints e.g. `ML-DSA-65`
  - `fyipq__sign <openssl> <key> <in> <out>` / `fyipq__verify <openssl> <pub> <in> <sig>` (0 = valid)
  - `fyipq__mtime <file>` → epoch seconds (BSD `stat -f %m` / GNU `stat -c %Y`)
  - `fyipq__check_unlocked <path> <repo_root>...` → 0 if the file exists, is a regular file, its basename is `FYIPQ_UNLOCKED_BASENAME`, it is not under any given repo root nor any `/public/` path, and its age ≤ `${FY_PQ_UNLOCK_MAX_AGE_SEC:-7200}`; otherwise prints one `ERROR:` line to stderr naming the reason and returns 1
  - `fyipq__drop_unlocked <path>` → `rm -f` only if the basename is `FYIPQ_UNLOCKED_BASENAME` (never deletes anything else)
  - Test helper (`tests/lib/pq-test-key.sh`): `fy_pq_prereq_or_skip <skip_fn>` (calls `<skip_fn> "<reason>"` when OpenSSL ≥ 3.5 is absent, unless `FY_REQUIRE_PQ=1`, in which case it prints `FATAL:` and exits 1); `fy_pq_make_master <dir>` (creates `<dir>/master.pem`, unencrypted seed-only ML-DSA-65); `fy_pq_install <dir> <fake_repo>` (copies master to `<dir>/operator-identity-mldsa65.unlocked.pem` mode 0600 and writes the public key to `<fake_repo>/public/.well-known/operator-identity-mldsa65.pub`).

- [ ] **Step 1: Write the failing test** — `tests/identity-pq-lib/test-identity-pq-lib.sh`

```bash
#!/usr/bin/env bash
# test-identity-pq-lib.sh — properties of scripts/lib/identity-pq.sh.
# CHAIN: none. PRIME_DIRECTIVE: TESTNET-FIRST — safe, no broadcast pathway.
set -u
REPO_SRC="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="${REPO_SRC}/scripts/lib/identity-pq.sh"
. "${REPO_SRC}/tests/lib/pq-test-key.sh"
PASS=0; FAIL=0
pass() { printf 'PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf 'FAIL  %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }
skip_pass() { echo "SKIP: $1"; echo "RESULT: PASS"; exit 0; }
[ -r "$LIB" ] || { echo "FATAL: $LIB missing" >&2; exit 1; }
. "$LIB"
fy_pq_prereq_or_skip skip_pass
OSSL="$(fyipq__resolve_openssl)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/repo/public/.well-known" "$WORK/keys"; chmod 700 "$WORK/keys"
fy_pq_make_master "$WORK/keys"
fy_pq_install "$WORK/keys" "$WORK/repo"
PUB="$WORK/repo/${FYIPQ_PUB_REL}"
UNL="$WORK/keys/${FYIPQ_UNLOCKED_BASENAME}"
printf 'payload\n' > "$WORK/msg"

# L1 fingerprint without OpenSSL equals OpenSSL's DER digest
want="sha256:$("$OSSL" pkey -pubin -in "$PUB" -outform DER </dev/null | fyipq__sha256_hex)"
got="$(fyipq__pub_fingerprint "$PUB")"
[ "$got" = "$want" ] && pass "L1 fingerprint matches OpenSSL DER digest" || bad "L1 got=$got want=$want"
# L1-mutation: a PEM with one changed body char must give a different fingerprint
sed '2s/^./A/' "$PUB" > "$WORK/mut.pub"
[ "$(fyipq__pub_fingerprint "$WORK/mut.pub" 2>/dev/null)" != "$want" ] && pass "L1m body change changes fingerprint" || bad "MUTATION NOT CAUGHT: L1m"
# L2 malformed input rejected
printf 'not a key\n' > "$WORK/junk.pub"
fyipq__pub_fingerprint "$WORK/junk.pub" >/dev/null 2>&1 && bad "L2 junk accepted" || pass "L2 junk PEM rejected"
# L3 LibreSSL / old OpenSSL never accepted; FY_OPENSSL is exclusive
cat > "$WORK/fake-libressl" <<'EOF'
#!/bin/sh
echo "LibreSSL 3.3.6"
EOF
cat > "$WORK/fake-ossl30" <<'EOF'
#!/bin/sh
echo "OpenSSL 3.0.13 30 Jan 2024 (Library: OpenSSL 3.0.13 30 Jan 2024)"
EOF
chmod +x "$WORK/fake-libressl" "$WORK/fake-ossl30"
fyipq__openssl_ok "$WORK/fake-libressl" && bad "L3 LibreSSL accepted" || pass "L3 LibreSSL rejected"
fyipq__openssl_ok "$WORK/fake-ossl30" && bad "L3 OpenSSL 3.0 accepted" || pass "L3 OpenSSL 3.0 rejected"
( FY_OPENSSL="$WORK/fake-libressl" fyipq__resolve_openssl >/dev/null ) && bad "L3 FY_OPENSSL fallthrough" || pass "L3 bad FY_OPENSSL is not silently replaced"
# L4 sign/verify round trip; wrong context rejected
fyipq__sign "$OSSL" "$UNL" "$WORK/msg" "$WORK/sig" && fyipq__verify "$OSSL" "$PUB" "$WORK/msg" "$WORK/sig" \
  && pass "L4 sign/verify round trip" || bad "L4 round trip failed"
"$OSSL" pkeyutl -sign -inkey "$UNL" -rawin -in "$WORK/msg" -pkeyopt context-string:other -out "$WORK/sig-other" </dev/null
fyipq__verify "$OSSL" "$PUB" "$WORK/msg" "$WORK/sig-other" && bad "MUTATION NOT CAUGHT: L4 other context verified" || pass "L4 other context rejected"
# L5 algorithm label
[ "$(fyipq__pub_algorithm "$OSSL" "$PUB")" = "ML-DSA-65" ] && pass "L5 algorithm ML-DSA-65" || bad "L5 algorithm"
# L6 unlocked checks: ok, inside repo, wrong basename, stale
fyipq__check_unlocked "$UNL" "$WORK/repo" 2>/dev/null && pass "L6 fresh unlocked key accepted" || bad "L6 fresh rejected"
cp "$UNL" "$WORK/repo/${FYIPQ_UNLOCKED_BASENAME}"
fyipq__check_unlocked "$WORK/repo/${FYIPQ_UNLOCKED_BASENAME}" "$WORK/repo" 2>/dev/null && bad "L6 in-repo accepted" || pass "L6 in-repo rejected"
cp "$UNL" "$WORK/keys/other.pem"
fyipq__check_unlocked "$WORK/keys/other.pem" "$WORK/repo" 2>/dev/null && bad "L6 wrong basename accepted" || pass "L6 wrong basename rejected"
touch -t 202001010000 "$UNL"
fyipq__check_unlocked "$UNL" "$WORK/repo" 2>/dev/null && bad "L6 stale accepted" || pass "L6 stale rejected"
# L7 drop_unlocked never deletes another basename
fyipq__drop_unlocked "$WORK/keys/other.pem"; [ -f "$WORK/keys/other.pem" ] && pass "L7 other file kept" || bad "L7 deleted a non-unlocked file"
fyipq__drop_unlocked "$UNL"; [ ! -e "$UNL" ] && pass "L7 unlocked file deleted" || bad "L7 unlocked not deleted"

echo "test-identity-pq-lib.sh summary: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && { echo "RESULT: PASS"; exit 0; } || { echo "RESULT: FAIL"; exit 1; }
```

- [ ] **Step 2: Run it to verify it fails**

Run: `chmod +x tests/identity-pq-lib/test-identity-pq-lib.sh && bash tests/identity-pq-lib/test-identity-pq-lib.sh`
Expected: `FATAL: …/scripts/lib/identity-pq.sh missing` (exit 1).

- [ ] **Step 3: Write `scripts/lib/identity-pq.sh`**

```bash
#!/usr/bin/env bash
# identity-pq.sh — the single home of the operator identity's post-quantum
# (ML-DSA, FIPS 204) constants and primitives. Sourced, never executed.
# Spec: docs/superpowers/specs/2026-10-15-identity-pq-signature-design.md.
# Must stay bash 3.2 compatible (macOS /bin/bash).
# CHAIN: none. PRIME_DIRECTIVE: TESTNET-FIRST — no broadcast pathway.

FYIPQ_ALGORITHM="ML-DSA-65"
FYIPQ_STANDARD="FIPS 204"
FYIPQ_CONTEXT="freedom-yield/validator-identity"
FYIPQ_MIN_OPENSSL="3.5"
FYIPQ_PUB_REL="public/.well-known/operator-identity-mldsa65.pub"
FYIPQ_SIG_REL="public/api/identity.json.mldsa65.sig"
FYIPQ_PUB_URL="https://metal.freedom-yield.com/.well-known/operator-identity-mldsa65.pub"
FYIPQ_SIG_URL="https://metal.freedom-yield.com/api/identity.json.mldsa65.sig"
FYIPQ_ENC_BASENAME="operator-identity-mldsa65.enc.pem"
FYIPQ_UNLOCKED_BASENAME="operator-identity-mldsa65.unlocked.pem"
FYIPQ_UNLOCK_MAX_AGE_SEC_DEFAULT=7200

fyipq__key_dir()       { printf '%s\n' "${FY_PQ_KEY_DIR:-${HOME}/.freedom-yield-identity}"; }
fyipq__enc_path()      { printf '%s/%s\n' "$(fyipq__key_dir)" "$FYIPQ_ENC_BASENAME"; }
fyipq__unlocked_path() { printf '%s/%s\n' "$(fyipq__key_dir)" "$FYIPQ_UNLOCKED_BASENAME"; }

# OpenSSL (not LibreSSL) >= 3.5 — ML-DSA arrived in 3.5.
fyipq__openssl_ok() {
	local v num maj rest min
	[ -n "${1:-}" ] && [ -x "$1" ] || return 1
	v="$("$1" version 2>/dev/null </dev/null)" || return 1
	case "$v" in "OpenSSL "*) ;; *) return 1 ;; esac
	num="${v#OpenSSL }"; num="${num%% *}"
	maj="${num%%.*}"; rest="${num#*.}"; min="${rest%%.*}"
	case "${maj}${min}" in ""|*[!0-9]*) return 1 ;; esac
	[ "$maj" -gt 3 ] && return 0
	[ "$maj" -eq 3 ] && [ "$min" -ge 5 ]
}

# FY_OPENSSL, when set, is the ONLY candidate: an explicit choice that is
# wrong must fail, not be silently replaced by another binary.
fyipq__resolve_openssl() {
	local c
	if [ -n "${FY_OPENSSL:-}" ]; then
		fyipq__openssl_ok "$FY_OPENSSL" && { printf '%s\n' "$FY_OPENSSL"; return 0; }
		return 1
	fi
	for c in /opt/homebrew/bin/openssl /usr/local/opt/openssl@3/bin/openssl "$(command -v openssl 2>/dev/null)"; do
		fyipq__openssl_ok "$c" && { printf '%s\n' "$c"; return 0; }
	done
	return 1
}

fyipq__sha256_hex() {
	if command -v sha256sum >/dev/null 2>&1; then sha256sum | awk '{print $1}'
	else shasum -a 256 | awk '{print $1}'; fi
}

# DER = base64 body of the single PUBLIC KEY block. No OpenSSL needed, so
# this also works where OpenSSL predates ML-DSA.
fyipq__pub_fingerprint() {
	local f="$1" begins body hex
	[ -r "$f" ] || return 1
	begins="$(grep -c '^-----BEGIN ' "$f")"
	[ "$begins" = "1" ] || return 1
	grep -q '^-----BEGIN PUBLIC KEY-----$' "$f" || return 1
	body="$(sed -n '/^-----BEGIN PUBLIC KEY-----$/,/^-----END PUBLIC KEY-----$/p' "$f" | sed '1d;$d' | tr -d '\r\n')"
	[ -n "$body" ] || return 1
	case "$body" in *[!A-Za-z0-9+/=]*) return 1 ;; esac
	hex="$(printf '%s' "$body" | base64 -d 2>/dev/null | fyipq__sha256_hex)" || return 1
	case "$hex" in [0-9a-f]*) ;; *) return 1 ;; esac
	[ "${#hex}" -eq 64 ] || return 1
	printf 'sha256:%s\n' "$hex"
}

fyipq__pub_algorithm() {
	"$1" pkey -pubin -in "$2" -noout -text </dev/null 2>/dev/null | head -n 1 | sed 's/ Public-Key:.*$//'
}

fyipq__sign() {
	"$1" pkeyutl -sign -inkey "$2" -rawin -in "$3" \
		-pkeyopt "context-string:${FYIPQ_CONTEXT}" -out "$4" </dev/null
}

fyipq__verify() {
	"$1" pkeyutl -verify -pubin -inkey "$2" -rawin -in "$3" -sigfile "$4" \
		-pkeyopt "context-string:${FYIPQ_CONTEXT}" </dev/null >/dev/null 2>&1
}

fyipq__mtime() {
	stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null
}

# fyipq__check_unlocked <path> <repo_root>...
fyipq__check_unlocked() {
	local p="$1" real root now mt max age
	shift
	if [ ! -f "$p" ]; then
		echo "ERROR: unlocked ML-DSA key not found: $p — run scripts/operator-local/pq-identity-unlock.sh first." >&2
		return 1
	fi
	if [ "$(basename "$p")" != "$FYIPQ_UNLOCKED_BASENAME" ]; then
		echo "ERROR: unlocked ML-DSA key must be named $FYIPQ_UNLOCKED_BASENAME (got $(basename "$p"))." >&2
		return 1
	fi
	real="$(cd "$(dirname "$p")" && pwd -P)/$(basename "$p")"
	case "$real" in */public/*)
		echo "ERROR: unlocked ML-DSA key is under a public/ path: $real" >&2; return 1 ;;
	esac
	for root in "$@"; do
		[ -n "$root" ] || continue
		root="$(cd "$root" 2>/dev/null && pwd -P)" || continue
		case "$real" in "$root"/*)
			echo "ERROR: unlocked ML-DSA key is inside the repo: $real" >&2; return 1 ;;
		esac
	done
	now="$(date +%s)"; mt="$(fyipq__mtime "$p")"
	max="${FY_PQ_UNLOCK_MAX_AGE_SEC:-$FYIPQ_UNLOCK_MAX_AGE_SEC_DEFAULT}"
	age=$((now - mt))
	if [ "$age" -gt "$max" ]; then
		echo "ERROR: unlocked ML-DSA key is ${age}s old (limit ${max}s) — run pq-identity-unlock.sh again." >&2
		return 1
	fi
	return 0
}

fyipq__drop_unlocked() {
	[ -n "${1:-}" ] || return 0
	[ "$(basename "$1")" = "$FYIPQ_UNLOCKED_BASENAME" ] || return 0
	rm -f "$1"
}
```

- [ ] **Step 4: Write `tests/lib/pq-test-key.sh`**

```bash
#!/usr/bin/env bash
# pq-test-key.sh — throwaway ML-DSA-65 keys for tests. Sourced.
# Requires scripts/lib/identity-pq.sh to be sourced first OR sources it.
_FY_PQ_TK_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "${_FY_PQ_TK_REPO}/scripts/lib/identity-pq.sh"

# fy_pq_prereq_or_skip <skip_fn>
fy_pq_prereq_or_skip() {
	if fyipq__resolve_openssl >/dev/null; then return 0; fi
	if [ "${FY_REQUIRE_PQ:-0}" = "1" ]; then
		echo "FATAL: FY_REQUIRE_PQ=1 but no OpenSSL >= ${FYIPQ_MIN_OPENSSL} found" >&2
		exit 1
	fi
	"$1" "no OpenSSL >= ${FYIPQ_MIN_OPENSSL} (set FY_REQUIRE_PQ=1 to make this a failure)"
}

fy_pq_make_master() {
	local o; o="$(fyipq__resolve_openssl)" || return 1
	"$o" genpkey -algorithm "$FYIPQ_ALGORITHM" -provparam ml-dsa.output_formats=seed-only \
		-out "$1/master.pem" </dev/null
	chmod 600 "$1/master.pem"
}

# fy_pq_install <keydir> <fake_repo> — (re)creates the unlocked key and the
# committed public key. Call before EVERY gen-identity.sh run: the script
# deletes the unlocked key on exit.
fy_pq_install() {
	local o; o="$(fyipq__resolve_openssl)" || return 1
	cp "$1/master.pem" "$1/${FYIPQ_UNLOCKED_BASENAME}"
	chmod 600 "$1/${FYIPQ_UNLOCKED_BASENAME}"
	mkdir -p "$2/public/.well-known"
	"$o" pkey -in "$1/master.pem" -pubout -out "$2/${FYIPQ_PUB_REL}" </dev/null
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `bash tests/identity-pq-lib/test-identity-pq-lib.sh`
Expected: every line `PASS`, `RESULT: PASS`.

- [ ] **Step 6: Mutation proof** — temporarily change `fyipq__openssl_ok`'s last line to `[ "$maj" -eq 3 ]` and re-run: L3 "OpenSSL 3.0 accepted" must FAIL. Temporarily remove the `basename` guard in `fyipq__drop_unlocked`: L7 must FAIL. Restore both (`git diff` shows only the intended files).

- [ ] **Step 7: Commit**

```bash
git add scripts/lib/identity-pq.sh tests/lib/pq-test-key.sh tests/identity-pq-lib/test-identity-pq-lib.sh
git commit -m "feat(identity-pq): shared ML-DSA-65 library for the operator identity signature" -m "<why body>"
```

---

### Task 2: Operator key tools — keygen / unlock / lock

**Files:**
- Create: `scripts/operator-local/pq-identity-keygen.sh`, `scripts/operator-local/pq-identity-unlock.sh`, `scripts/operator-local/pq-identity-lock.sh`
- Modify: `.gitignore` (after the ed25519 block at :15-18), `scripts/operator-local/README.md`
- Test: `tests/pq-identity-tools/test-pq-identity-tools.sh`

**Interfaces:**
- Consumes: Task 1 library.
- Produces: the three commands; the encrypted key at `$(fyipq__enc_path)`, the unlocked key at `$(fyipq__unlocked_path)`, the public key at `${REPO_ROOT}/${FYIPQ_PUB_REL}`. Test-only env: `FY_PQ_KEY_DIR`, `REPO_ROOT`, `FY_PQ_PASSIN` (an OpenSSL `-passin/-passout` source such as `file:/path`; when unset the scripts let OpenSSL prompt on the TTY and refuse to run without a TTY).

Behaviour:
- **keygen**: refuse if `$(fyipq__enc_path)` exists (never overwrite; exit 3). `umask 077`; `mkdir -p` key dir, `chmod 700`. Generate + encrypt in one pipe (no plaintext on disk):
  ```bash
  "$O" genpkey -algorithm "$FYIPQ_ALGORITHM" -provparam ml-dsa.output_formats=seed-only </dev/null \
   | "$O" pkcs8 -topk8 -v2 aes-256-cbc -scrypt ${PASSOUT_ARGS} \
       -provparam ml-dsa.output_formats=seed-only -out "$ENC.tmp"
  ```
  then `mv "$ENC.tmp" "$ENC"`. Derive the public key with `pkey -in "$ENC" ${PASSIN_ARGS} -pubout -out "${REPO_ROOT}/${FYIPQ_PUB_REL}"` (prompts again on TTY). Print algorithm, fingerprint (`fyipq__pub_fingerprint`), the encrypted file path, and: `Back up the encrypted key file to the Dashlane entry named in the AI's ping (the passphrase too).` Refuse (exit 99) on the same production-host guards as `gen-identity.sh` §1 (copy that block verbatim). Exit 1 on missing OpenSSL.
- **unlock**: without `FY_PQ_PASSIN`, require a TTY (`[ -t 0 ]`, else exit 4 with "run this yourself at a terminal"). `umask 077`; decrypt to `$UNL.tmp` with `pkey -in "$ENC" ${PASSIN_ARGS} -provparam ml-dsa.output_formats=seed-only -out "$UNL.tmp"`, then check that its public key fingerprint equals `fyipq__pub_fingerprint "${REPO_ROOT}/${FYIPQ_PUB_REL}"` (exit 5 + delete on mismatch: "this key does not match the committed public key"), then `mv` to `$UNL`, `chmod 600`. Wrong passphrase → exit 2, nothing left behind. Print: `Unlocked until gen-identity.sh signs (auto-lock) or for at most 2 hours.`
- **lock**: `fyipq__drop_unlocked "$(fyipq__unlocked_path)"`; print `locked` or `already locked`; exit 0.

- [ ] **Step 1: Write the failing test** `tests/pq-identity-tools/test-pq-identity-tools.sh` (same skeleton as Task 1's test, sourcing `tests/lib/pq-test-key.sh` and `fy_pq_prereq_or_skip skip_pass`). Fixture: `WORK=$(mktemp -d)`, `KD=$WORK/keys`, `FR=$WORK/repo` with `public/.well-known`, password file `$WORK/pw` (mode 600, content `test-passphrase-only`), `env FY_PQ_KEY_DIR=$KD REPO_ROOT=$FR FY_PQ_PASSIN=file:$WORK/pw`. Cases:
  - T1 keygen exits 0; `$KD/operator-identity-mldsa65.enc.pem`'s first line is the encrypted-PKCS#8 PEM header (build the expected string at runtime from fragments, e.g. `hdr="-----BEG""IN ENC""RYPTED PRI""VATE KEY-----"` — see Global Constraints); `openssl asn1parse` of it contains `scrypt` (mutation: replace `-scrypt` with nothing → T1 must fail since PBKDF2 appears).
  - T2 the published `.pub` is `ML-DSA-65` (`fyipq__pub_algorithm`).
  - T3 keygen a second time exits 3 and the encrypted file's sha256 is unchanged.
  - T4 unlock exits 0; unlocked file mode is `600` (`stat -f %Lp` / `stat -c %a`); signing a message with it verifies against the published `.pub`.
  - T5 unlock with wrong passphrase (`file:` of a different file) exits 2 and no `*.unlocked.pem*` exists in `$KD`.
  - T6 unlock with a different committed `.pub` (replace with another key's public key) exits 5 and leaves no unlocked file.
  - T7 unlock without `FY_PQ_PASSIN` and stdin from `/dev/null` exits 4.
  - T8 lock deletes the unlocked file; second lock prints `already locked`, exit 0.
  - T9 no output of any command contains the base64 body of `master`/unlocked key (grep the captured stdout+stderr of T1–T8 for the second line of the unlocked PEM).

- [ ] **Step 2:** `chmod +x` and run → FAIL (scripts missing).
- [ ] **Step 3:** Write the three scripts (bash 3.2; header comment with CHAIN/PRIME_DIRECTIVE lines like `gen-identity.sh`; `set -euo pipefail`; source `${SCRIPT_REPO_ROOT}/scripts/lib/identity-pq.sh`; `PASSIN_ARGS`/`PASSOUT_ARGS` arrays built only when `FY_PQ_PASSIN` is set: `-passin "$FY_PQ_PASSIN"` / `-passout "$FY_PQ_PASSIN"`).
- [ ] **Step 4:** `.gitignore` — append after line 18:
  ```
  # operator identity ML-DSA-65 key files (live outside the repo; belt and braces)
  operator-identity-mldsa65.enc.pem
  operator-identity-mldsa65.unlocked.pem
  ```
- [ ] **Step 5:** `scripts/operator-local/README.md` — add a section "ML-DSA-65 identity key (pq-identity-*.sh)" describing the three commands, the key dir, auto-lock by `gen-identity.sh`, the 2-hour limit, and "Dashlane entry: named in the AI's ping, never in this repo".
- [ ] **Step 6:** Run the test → all PASS. Mutation proof: in `unlock`, skip the fingerprint check → T6 must FAIL; restore.
- [ ] **Step 7:** Commit (`feat(identity-pq): operator keygen/unlock/lock for the ML-DSA-65 identity key`).

---

### Task 3: `gen-identity.sh` dual signing + schema v2 + registry

**Files:**
- Modify: `scripts/operator-local/gen-identity.sh`
- Create: `public/api/identity.schema.v2.json`
- Modify: `public/api/identity.example.json`, `deploy/publication.json`, `tests/publication-registry/test-publication-registry.sh` (T20), `tests/anchor-history/test-ten-mandatory.sh` (T4 path), `tests/test-gen-identity-ordering-guard.sh`, `tests/identity-kind-discipline/test-gen-identity-kind-discipline.sh`, `scripts/operator-local/test-gen-identity.sh`
- Test: `tests/gen-identity-pq/test-gen-identity-pq.sh`

**Interfaces:**
- Consumes: Task 1 library; `tests/lib/pq-test-key.sh`.
- Produces: `identity.json` with `schema_version: 2` and
  ```json
  "verification_pq": {
    "algorithm": "ML-DSA-65",
    "standard": "FIPS 204",
    "context_string": "freedom-yield/validator-identity",
    "pubkey_url": "https://metal.freedom-yield.com/.well-known/operator-identity-mldsa65.pub",
    "pubkey_fingerprint": "sha256:<64 hex>",
    "signature_url": "https://metal.freedom-yield.com/api/identity.json.mldsa65.sig",
    "method": "openssl pkeyutl -verify -pubin -inkey operator-identity-mldsa65.pub -rawin -in identity.json -sigfile identity.json.mldsa65.sig -pkeyopt context-string:freedom-yield/validator-identity",
    "minimum_openssl_version": "3.5"
  }
  ```
  placed immediately after `verification`. New env: `OPERATOR_PQ_UNLOCKED_KEY` (default `$(fyipq__unlocked_path)`), `OPERATOR_PQ_PUBKEY` (default `${REPO_ROOT}/${FYIPQ_PUB_REL}`), `FY_OPENSSL`, `FY_PQ_UNLOCK_MAX_AGE_SEC`. New exit codes: **5** = PQ precondition (OpenSSL, public key missing/malformed/not ML-DSA-65, unlocked key missing/stale/misplaced); **11** = PQ signing or PQ self-verify failed. Output file `${REPO_ROOT}/${FYIPQ_SIG_REL}`.

- [ ] **Step 1: Write the failing test** `tests/gen-identity-pq/test-gen-identity-pq.sh`. Copy the harness of `tests/test-gen-identity-ordering-guard.sh` (production-host refusal, curl stub serving a one-leaf docroot, throwaway ed25519 key, `run_genid`) and extend `run_genid` with `OPERATOR_PQ_UNLOCKED_KEY=$KEYDIR/operator-identity-mldsa65.unlocked.pem`, calling `fy_pq_install "$KEYDIR" "$fake_repo"` before each run unless the case says otherwise. Cases:
  - P1 normal run exits 0; `identity.json` has `schema_version == 2`; `.verification_pq.pubkey_fingerprint == fyipq__pub_fingerprint(<fake_repo pub>)`; the PQ sig verifies with `fyipq__verify`; the ed25519 sig still verifies with `ssh-keygen -Y verify` (copy the allowed-signers lines from the ordering-guard test).
  - P2 after P1 the unlocked key no longer exists (auto-lock on success).
  - R1 (Review Focus 1) second run without re-installing the unlocked key → exit 5, stderr contains `pq-identity-unlock.sh`, no `identity.json` written in the fresh fake repo.
  - R2 (Review Focus 3) unlocked key `touch -t 202001010000` → exit 5, and the unlocked file is deleted.
  - R3 (Review Focus 4) replace the fake repo `.pub` with a different key's public key after `fy_pq_install` → exit 11, no `identity.json`, no `.mldsa65.sig`, no `.sig` in `public/api`, and the unlocked file is deleted.
  - P3 `FY_OPENSSL=/usr/bin/false` → exit 5 (OpenSSL), unlocked file deleted.
  - P4 an early non-PQ failure (`FY_EXPECT_CYCLE=99` against a ledger with cycle_n 1 → exit 7) still deletes the unlocked file.
  - P5 a context-string mutation: run with a patched copy of the library in which `FYIPQ_CONTEXT="other"` (copy the script tree into `$WORK/src`, `sed` the constant, run the copy) → the run itself succeeds, but `fyipq__verify` with the real library rejects the produced sig. This proves the published sig is bound to the real context.
  - P6 `identity.json` validates against `public/api/identity.schema.v2.json` with the repo's schema validator (use the same validator call as `tests/anchor-history/test-ten-mandatory.sh` T4).
  - P7 the output (stdout+stderr) of P1 never contains the second line of `master.pem`.
- [ ] **Step 2:** run → FAIL.
- [ ] **Step 3: Implement in `gen-identity.sh`** (cite current line numbers; re-check them first):
  1. Header: document the new env vars and exit codes 5 and 11 in the existing lists (:72-110).
  2. After `PUBLICATION_REGISTRY=…` (≈:186):
     ```bash
     # shellcheck source=../lib/identity-pq.sh
     . "${SCRIPT_REPO_ROOT}/scripts/lib/identity-pq.sh"
     OUT_PQ_SIG="${REPO_ROOT}/${FYIPQ_SIG_REL}"
     PQ_PUB="${OPERATOR_PQ_PUBKEY:-${REPO_ROOT}/${FYIPQ_PUB_REL}}"
     PQ_UNLOCKED="${OPERATOR_PQ_UNLOCKED_KEY:-$(fyipq__unlocked_path)}"
     # Auto-lock: from here on, EVERY exit removes the unlocked ML-DSA key.
     FYID_CLEANUP_FILES=""
     fyid__cleanup() {
         fyipq__drop_unlocked "${PQ_UNLOCKED}"
         [ -n "${FYID_CLEANUP_FILES}" ] && rm -f ${FYID_CLEANUP_FILES}
         return 0
     }
     trap fyid__cleanup EXIT
     ```
  3. After the key-in-repo guard (≈:206), the PQ preconditions (all exit 5):
     ```bash
     PQ_OPENSSL="$(fyipq__resolve_openssl)" || {
         echo "ERROR: need OpenSSL >= ${FYIPQ_MIN_OPENSSL} (not LibreSSL). Install Homebrew openssl@3 or set FY_OPENSSL." >&2; exit 5; }
     [ -f "${PQ_PUB}" ] || { echo "ERROR: ML-DSA public key not found: ${PQ_PUB} — run pq-identity-keygen.sh first." >&2; exit 5; }
     PQ_FP="$(fyipq__pub_fingerprint "${PQ_PUB}")" || { echo "ERROR: ${PQ_PUB} is not a single PEM PUBLIC KEY block." >&2; exit 5; }
     [ "$(fyipq__pub_algorithm "${PQ_OPENSSL}" "${PQ_PUB}")" = "${FYIPQ_ALGORITHM}" ] || {
         echo "ERROR: ${PQ_PUB} is not an ${FYIPQ_ALGORITHM} public key." >&2; exit 5; }
     fyipq__check_unlocked "${PQ_UNLOCKED}" "${REPO_ROOT}" "${SCRIPT_REPO_ROOT}" || exit 5
     ```
  4. Replace the §4 trap line (`trap 'rm -f "${TMP_JSON}" "${TMP_JSON}.sig"' EXIT`) with `TMP_PQ_SIG="${TMP_JSON}.mldsa65.sig"` and `FYID_CLEANUP_FILES="${TMP_JSON} ${TMP_JSON}.sig ${TMP_PQ_SIG}"`. Replace the §6 trap line with `FYID_CLEANUP_FILES="${FYID_CLEANUP_FILES} ${ALLOWED}"`. In §7 replace `trap - EXIT` with nothing (the EXIT trap stays; the moved tmp files no longer exist, `rm -f` is harmless) and keep `rm -f "${ALLOWED}"`.
  5. `COMMENT_TEXT`: append ` An additional ML-DSA-65 (FIPS 204) signature is at /api/identity.json.mldsa65.sig; verify with OpenSSL 3.5+ (see verification_pq).`
  6. jq: add `--arg pq_alg "${FYIPQ_ALGORITHM}" --arg pq_std "${FYIPQ_STANDARD}" --arg pq_ctx "${FYIPQ_CONTEXT}" --arg pq_pub_url "${FYIPQ_PUB_URL}" --arg pq_fp "${PQ_FP}" --arg pq_sig_url "${FYIPQ_SIG_URL}" --arg pq_min "${FYIPQ_MIN_OPENSSL}"`; `schema_version: 2`; after the `verification` object add the `verification_pq` object exactly as in **Produces**, with `method: ("openssl pkeyutl -verify -pubin -inkey operator-identity-mldsa65.pub -rawin -in identity.json -sigfile identity.json.mldsa65.sig -pkeyopt context-string:" + $pq_ctx)`. Leave the identity-HISTORY bootstrap's `schema_version: 1` (:724) untouched.
  7. §5, after the ssh-keygen sign and its `.sig` existence check:
     ```bash
     if ! fyipq__sign "${PQ_OPENSSL}" "${PQ_UNLOCKED}" "${TMP_JSON}" "${TMP_PQ_SIG}"; then
         fyipq__drop_unlocked "${PQ_UNLOCKED}"
         echo "ERROR: ML-DSA signing failed — refusing to publish." >&2; exit 11
     fi
     # Auto-lock: the key's only use is done.
     fyipq__drop_unlocked "${PQ_UNLOCKED}"
     ```
  8. §6, after the ssh-keygen self-verify:
     ```bash
     if ! fyipq__verify "${PQ_OPENSSL}" "${PQ_PUB}" "${TMP_JSON}" "${TMP_PQ_SIG}"; then
         echo "ERROR: ML-DSA self-verify failed against ${PQ_PUB} — refusing to publish." >&2; exit 11
     fi
     ```
  9. §7: `mv "${TMP_PQ_SIG}" "${OUT_PQ_SIG}"` after the two existing `mv`s; add `"${OUT_PQ_SIG}"` to the `chmod 644`; add `✓ wrote ${OUT_PQ_SIG}` and `  ML-DSA-65 fingerprint: ${PQ_FP}` and `  ML-DSA key:          auto-locked (unlocked file removed)` to the summary; add `public/api/identity.json.mldsa65.sig` and `public/.well-known/operator-identity-mldsa65.pub` to the "Next steps" `git add` list.
- [ ] **Step 4: Schema** — `public/api/identity.schema.v2.json` = copy of v1 with `$id` → `…/api/identity.schema.v2.json`, title/description mention v2, `schema_version` `const: 2`, `verification_pq` added to top-level `required`, and a `verification_pq` property: object, `additionalProperties: true`, required all eight keys; `algorithm` const `"ML-DSA-65"`; `standard` const `"FIPS 204"`; `context_string` const `"freedom-yield/validator-identity"`; `pubkey_url`/`signature_url` `format: uri`; `pubkey_fingerprint` `pattern: "^sha256:[0-9a-f]{64}$"`; `method` string; `minimum_openssl_version` const `"3.5"`. The artifact_manifest kind description keeps the record clause verbatim (T20).
- [ ] **Step 5: Example** — `public/api/identity.example.json`: `schema_version: 2`, `_comment` names v2, add `verification_pq` with `pubkey_fingerprint: "sha256:" + 64 zeros`. Keep `pin_policy` byte-identical (kind-discipline c1 compares it).
- [ ] **Step 6: Tests that hard-code v1** — `tests/anchor-history/test-ten-mandatory.sh` T4 (:135) → v2 path; `scripts/operator-local/test-gen-identity.sh` LOCAL_SCHEMA (:32) → v2, and make it install a PQ key (source `tests/lib/pq-test-key.sh`, `fy_pq_install` before each run, pass `OPERATOR_PQ_UNLOCKED_KEY`) and assert the `.mldsa65.sig` exists next to `.sig` (:110-116) and is NOT created in the retired-env case (step 8, :330-370); `tests/test-gen-identity-ordering-guard.sh` and `tests/identity-kind-discipline/test-gen-identity-kind-discipline.sh`: in `run_genid` add the `fy_pq_install` call and `OPERATOR_PQ_UNLOCKED_KEY`, and call `fy_pq_prereq_or_skip skip_pass` next to the existing ssh-keygen prerequisite checks.
- [ ] **Step 7: Registry** — `deploy/publication.json`: add a row for `api/identity.schema.v2.json` modelled on the v1 row at :480. **Do NOT add rows for the `.pub` / `.mldsa65.sig` yet** (they are not tracked until Task 8; T13 would fail). Fix the stale `producer_evidence` line numbers on the three gen-identity rows (:456-458) to the post-change line numbers of `OUT_JSON`, `OUT_SIG`, `ID_HISTORY_FILE`. `tests/publication-registry/test-publication-registry.sh`: T20 checks the record clause in the v2 schema as well as v1 (add the v2 path next to `IDENTITY_SCHEMA` at :73 and loop over both).
- [ ] **Step 8:** Run `bash tests/gen-identity-pq/test-gen-identity-pq.sh`, then `bash tests/run-all-tests.sh` → all PASS (the full suite must be green on the Mac with Homebrew OpenSSL).
- [ ] **Step 9: Mutation proof** — (a) delete the step-7 `fyipq__drop_unlocked` line → P2 must FAIL; (b) delete the step-8 verify block → R3 must FAIL (sig published); (c) set `schema_version: 1` in the jq → P6 must FAIL. Restore each.
- [ ] **Step 10:** Commit (`feat(identity): sign identity.json with ML-DSA-65 as well as ed25519 (schema v2)`).

---

### Task 4: `check-identity-pq.sh` + CI on `ubuntu-26.04`

**Files:**
- Create: `scripts/check-identity-pq.sh`
- Modify: `.github/workflows/verify-identity.yml`, `.github/workflows/validate.yml` (tests job :151-160), `.github/workflows/ci-main.yml` (tests job :46-55)
- Test: `tests/identity-pq-check/test-check-identity-pq.sh`

**Interfaces:**
- Consumes: Task 1 library. Task 3's manifest shape (via fixtures only — this task must not depend on Task 3's code).
- Produces: `bash scripts/check-identity-pq.sh [--require-sig-verify]`, env `FYD_REPO_ROOT` (default repo root). Exit **0**: manifest v1 (prints `schema_version 1: no ML-DSA signature expected`) or v2 fully valid. **2**: cannot run (jq missing, manifest unreadable/invalid JSON). **3**: v2 but any of — `.pub` or `.mldsa65.sig` missing; `verification_pq` fields not equal to the library constants (`algorithm`, `standard`, `context_string`, `pubkey_url`, `signature_url`, `minimum_openssl_version`); fingerprint ≠ `fyipq__pub_fingerprint`; signature fails `fyipq__verify` (when OpenSSL available). **4**: `--require-sig-verify` given and no OpenSSL ≥ 3.5. Without `--require-sig-verify` and without OpenSSL, the fingerprint/field checks still run and it prints `signature not verified (no OpenSSL >= 3.5)`.

- [ ] **Step 1: Write the failing test** with fixtures built in a temp repo (`$WORK/repo/public/api`, `$WORK/repo/public/.well-known`): a v2 `identity.json` made with jq from `public/api/identity.example.json` (if Task 3 has not landed in this worktree, build the `verification_pq` object inline from the library constants), a key from `fy_pq_make_master`, pub via `fy_pq_install`, sig via `fyipq__sign` over the fixture bytes. Cases:
  - C1 v1 manifest (schema_version 1, no PQ files) → exit 0 and the "no ML-DSA signature expected" line (Review Focus 5).
  - C2 valid v2 → exit 0.
  - C3 v2 with the `.mldsa65.sig` deleted → exit 3.
  - C4 v2 with one sig byte flipped (`printf '\x00' | dd of=… bs=1 seek=100 conv=notrunc`) → exit 3 (Review Focus 5).
  - C5 v2 with `pubkey_fingerprint` changed by one hex char → exit 3.
  - C6 v2 with `context_string` changed → exit 3.
  - C7 `FY_OPENSSL=/usr/bin/false bash … --require-sig-verify` → exit 4; same without the flag → exit 0 plus the "signature not verified" line.
- [ ] **Step 2:** run → FAIL.
- [ ] **Step 3:** Write `scripts/check-identity-pq.sh` (header with CHAIN/PRIME_DIRECTIVE lines, usage, exit codes; `set -u`; source the library; read `schema_version` with jq; implement the checks above in order; print one `FAIL:` line per failed check and exit 3 if any).
- [ ] **Step 4:** `verify-identity.yml`: `runs-on: ubuntu-26.04`; add `public/api/identity.json.mldsa65.sig`, `public/.well-known/operator-identity-mldsa65.pub`, `scripts/check-identity-pq.sh`, `scripts/lib/identity-pq.sh` to both `paths` lists; add steps after the ssh verify:
  ```yaml
      - name: openssl version
        run: openssl version
      - name: verify ML-DSA-65 signature (schema v2 manifests)
        run: bash scripts/check-identity-pq.sh --require-sig-verify
  ```
  Update the header comment: the ssh step's skip-if-missing applies to the ed25519 trio only; the ML-DSA step never skips for a v2 manifest.
- [ ] **Step 5:** `validate.yml` and `ci-main.yml` tests jobs: `runs-on: ubuntu-26.04`, and add `env: FY_REQUIRE_PQ: "1"` at job level. Add a step `bash scripts/check-identity-pq.sh` after the identity-pins step in both.
- [ ] **Step 6: Prove the suite on Ubuntu 26.04 locally.** Start Docker Desktop, run `docker run --rm -v "$PWD":/w -w /w ubuntu:26.04 bash -c 'apt-get update -qq && apt-get install -y -qq git jq openssl openssh-client xxd curl python3 python3-jsonschema >/dev/null && git config --global --add safe.directory /w && FY_REQUIRE_PQ=1 bash tests/run-all-tests.sh'`. Record the summary line. Any failure that is not caused by this branch is reported to the coordinator, not fixed here. **Stop the container and quit Docker Desktop when done** (CLAUDE.md: no long-running Docker). If the port or Docker is unavailable, say so in the report instead of skipping silently.
- [ ] **Step 7:** Mutation proof: make `check-identity-pq.sh` skip the fingerprint comparison → C5 must FAIL; restore.
- [ ] **Step 8:** Commit (`ci(identity): verify the ML-DSA-65 identity signature on ubuntu-26.04`).

---

### Task 5: Transition-day flow (stop 2 unlock, unit 4b, status) + preflight

**Files:**
- Modify: `scripts/cycle-transition.sh`, `docs/CYCLE_GATE.md` (step 4/4b ≈:841-880), `docs/cycle-transition-steps.json` (:31 area), `docs/VALIDATOR_RENEWAL.md` (:391-393), `docs/REHEARSAL_2026-09-01.md` (:230 line-number citation only), `tests/cycle-transition/test-cycle-transition.sh`, `scripts/install-rehearsal-preflight.sh` (check 5 ≈:678-696), and that installer's test file (find with `grep -rl install-rehearsal-preflight tests/`).

**Interfaces:**
- Consumes: command names from Tasks 2/3 (`scripts/operator-local/pq-identity-unlock.sh`, `scripts/operator-local/pq-identity-lock.sh`, output `public/api/identity.json.mldsa65.sig`).
- Produces: plan/runbook text only; no new script interfaces.

Required changes in `cycle-transition.sh` (re-locate each by grep; line numbers drift):
  1. Phase row 2 (`fyct__phase_rows`, ≈:421): the operator line becomes `ssh-add ~/.ssh/freedom-yield-operator-identity && bash scripts/operator-local/pq-identity-unlock.sh`. Text: the second command asks for the ML-DSA passphrase (Dashlane entry named in the AI's ping); `gen-identity.sh` deletes the unlocked key itself right after signing (auto-lock), so there is no lock keystroke; if unit 4 does not reach signing, the AI asks the operator to run `bash scripts/operator-local/pq-identity-lock.sh` (no passphrase — the AI may run it itself); a re-run of unit 4 needs a fresh unlock.
  2. Keystroke count (≈:848): FIVE → SIX, inserting "(2) the ML-DSA unlock at stop 2" and renumbering.
  3. Unit 4b (≈:692-694): `git add public/api/identity.json public/api/identity.json.sig public/api/identity.json.mldsa65.sig deploy/identity-pin-baseline.json deploy/publication.json`; "Expect exactly those FIVE entries"; the MUST-STAY sentence names both signatures.
  4. Status phase (≈:1392-1475): additionally read `api/identity.json.mldsa65.sig`; only when the fetched manifest's `schema_version` is 2, a missing PQ sig makes v2=INCOMPLETE with `d2="the manifest is fresh but api/identity.json.mldsa65.sig did not publish with it"`.
  5. Caveat 5 (≈:1639): names both signatures; cryptographic checks are CI's `verify-identity` workflow (ML-DSA) and unit 9's Phase 1 (ed25519).
  Mirror 1–3 in `docs/CYCLE_GATE.md`, `docs/cycle-transition-steps.json`, `docs/VALIDATOR_RENEWAL.md`; update the `gen-identity.sh:<line>` citations in `docs/CYCLE_GATE.md` (:859) and `docs/REHEARSAL_2026-09-01.md` (:230) to the post-Task-3 line of the `ssh-keygen -Y sign` call (coordinate: read it from the integration branch after Task 3 merges; if Task 3 is not merged yet, leave these two citations and report them as pending).

Preflight (`install-rehearsal-preflight.sh` check 5): after the ed25519 pair check, add: the encrypted key `$(fyipq__enc_path)` exists with mode 600 in a 700 dir outside the repo; the committed `public/.well-known/operator-identity-mldsa65.pub` exists and `fyipq__pub_fingerprint` succeeds; no unlocked file is lying around (if one exists, FAIL with "run pq-identity-lock.sh"). Never print the Dashlane entry name.

- [ ] **Step 1: Failing tests** in `tests/cycle-transition/test-cycle-transition.sh`: extend the C1 regression (:495-505) to require `public/api/identity.json.mldsa65.sig` in the `git add` line; extend the stop-2 assertions to require `pq-identity-unlock.sh`; status fixture (:977) also writes `api/identity.json.mldsa65.sig` and a v2 manifest; add `mut_drop_pq_sig() { rm -f "${1}/pub/api/identity.json.mldsa65.sig"; }` and `mutate_case "identity.json.mldsa65.sig did not publish" 2 INCOMPLETE mut_drop_pq_sig`; add a case where the manifest is v1 and the PQ sig is absent → COMPLETE. Preflight test: encrypted key missing → FAIL line; unlocked file present → FAIL line naming `pq-identity-lock.sh`.
- [ ] **Step 2:** run → FAIL. **Step 3:** implement. **Step 4:** run the two test files and the docs drift gate (:300-325) → PASS. **Step 5:** mutation proof — revert change 4 only → the `mut_drop_pq_sig` case must FAIL; restore. **Step 6:** commit (`feat(cycle-transition): unlock the ML-DSA identity key at stop 2 and carry its signature`).

---

### Task 6: Verification docs, public pages, evidence

**Files:**
- Modify: `docs/IDENTITY_VERIFICATION.md`, `docs/OPERATOR_IDENTITY_SETUP.md`, `docs/DEPLOY_OWNERSHIP_MATRIX.md`, `docs/IDENTITY_SCHEMA_CHANGELOG.md`, `docs/EVIDENCE_MANIFEST.md`, `public/.well-known/README.md`, `public/verify/index.html`, `public/ja/verify/index.html`, `public/data/index.html`, `public/ja/data/index.html`, `scripts/gen-evidence.sh`, `public/api/evidence.example.json`, `tests/gen-evidence/test-gen-evidence.sh`, `TOOLKIT.md`
- Test: `tests/identity-pq-docs/test-documented-pq-command.sh`

**Interfaces:**
- Consumes: constants from Task 1; file names from Tasks 2–4.
- Produces: documentation only, plus two evidence keys: `live_artifacts.identity_manifest.pq_signature_url` = `FYIPQ_SIG_URL`, `pq_pubkey_url` = `FYIPQ_PUB_URL`, and `formal_schema_url` → `…/api/identity.schema.v2.json`.

Content requirements:
- `IDENTITY_VERIFICATION.md`: "Key model" names both keys (ed25519 primary; ML-DSA-65 additive, FIPS 204, context string). New **Step 2b — verify the ML-DSA-65 signature (OpenSSL 3.5+)** with this exact block, fenced and wrapped in markers the test reads:
  ````
  <!-- pq-verify:begin -->
  ```sh
  curl -sSfO https://metal.freedom-yield.com/api/identity.json
  curl -sSfO https://metal.freedom-yield.com/api/identity.json.mldsa65.sig
  curl -sSfO https://metal.freedom-yield.com/.well-known/operator-identity-mldsa65.pub
  openssl pkeyutl -verify -pubin -inkey operator-identity-mldsa65.pub -rawin -in identity.json -sigfile identity.json.mldsa65.sig -pkeyopt context-string:freedom-yield/validator-identity
  ```
  <!-- pq-verify:end -->
  ````
  Expected output `Signature Verified Successfully`; note that macOS `/usr/bin/openssl` is LibreSSL and cannot do this (use Homebrew `openssl@3`), and that Ubuntu 26.04's stock `openssl` can. Step 1's URL list and "a 404 on any of the five URLs" count gain the two new URLs (seven). Rotation section: the PQ key rotates like the ed25519 key, and its algorithm follows Metallicus' basic choice (spec §3.1).
- `OPERATOR_IDENTITY_SETUP.md`: scope Step 4's "no BEGIN header" rule to the ed25519 `.pub`; add a "ML-DSA-65 key" section: `pq-identity-keygen.sh`, backup to the Dashlane entry named in the AI's ping, unlock at stop 2, auto-lock, `pq-identity-lock.sh`; add the two files to Step 5/6 git-add lists.
- `DEPLOY_OWNERSHIP_MATRIX.md`: split the fused row at :94 into two rows; add rows for the two new files modelled on :95/:96.
- `IDENTITY_SCHEMA_CHANGELOG.md`: newest-first entry `## 2026-10-15 — schema v2: additive ML-DSA-65 signature` with `### Summary` / `### Why` / `### Compatibility` (v1 consumers ignore `verification_pq`; v1 schema stays published) / `### What changed`.
- `public/.well-known/README.md`: list both public keys; replace the stale "not yet published" status with the current state.
- Public pages (EN; JA mirrors in Japanese): in the verification `dl`/cmd-box add the ML-DSA-65 lines (the four-line block above) and one sentence: "identity.json also carries an ML-DSA-65 (FIPS 204) signature. Verify it with OpenSSL 3.5 or later." No other claim. Schema link → v2. No inline styles.
- `TOOLKIT.md`: a row for `scripts/check-identity-pq.sh`.

- [ ] **Step 1: Failing test** `tests/identity-pq-docs/test-documented-pq-command.sh`: extract the lines between `<!-- pq-verify:begin -->` and `<!-- pq-verify:end -->` from `docs/IDENTITY_VERIFICATION.md`, require exactly three `curl` lines and one `openssl` line, and require the curl URLs to equal `FYIPQ_SIG_URL`, `FYIPQ_PUB_URL` and the identity.json URL. Build fixtures named `identity.json`, `identity.json.mldsa65.sig`, `operator-identity-mldsa65.pub` in a temp dir (Task 1 helpers), then **run the documented `openssl` line verbatim** there with the resolved OpenSSL first on `PATH` (`PATH="$(dirname "$(fyipq__resolve_openssl)"):$PATH"`) → must print `Signature Verified Successfully`. Also grep the EN and JA public pages for that exact openssl line. Mutation: change the context string in the doc copy → the run must FAIL.
- [ ] **Step 2:** run → FAIL. **Step 3:** edit docs/pages/evidence. **Step 4:** `bash tests/identity-pq-docs/test-documented-pq-command.sh` and `bash tests/gen-evidence/test-gen-evidence.sh` → PASS; run the repo's link/attr checker step from `ci-main.yml` locally if it exists as a script. **Step 5:** commit (`docs(identity): document and publish the ML-DSA-65 verification path`).

---

### Task 7: Watch the ML-DSA parameter Metallicus uses

**Files:**
- Modify: `scripts/check-pulsevm-upstream.sh`, `tests/pulsevm-upstream/test-pulsevm-upstream.sh`

**Interfaces:**
- Consumes: nothing from Tasks 1–6.
- Produces: two new observations in the existing state file (schema_version 2): `pr116_state` (GitHub `state` + `merged` of `MetalBlockchain/pulsevm` PR 116; baseline `open`) and `mldsa_example_param` (the `MLDSA44|MLDSA65|MLDSA87` token(s) used after `--key-type` in `docs/ml-dsa.md` on the PR head branch while open, on `main` once merged; baseline `MLDSA65`). A change from baseline raises the script's existing notification at its existing "change" severity, with text naming spec §3.1 ("identity PQ key follows Metallicus' basic choice — review rotation").

- [ ] **Step 1:** Read the whole script first; follow its existing observation pattern (fetch, read-only, polite caching, `observations` object, dedup) exactly — no new transport, no new cron. **Step 2:** Failing tests in `test-pulsevm-upstream.sh` using its existing stub mechanism: baseline → no alert; `MLDSA87` in the stubbed doc → alert; PR merged → alert; fetch failure → existing failure path (not a parameter alert). **Step 3:** implement. **Step 4:** PASS + mutation (compare against a wrong baseline constant → the "no alert" case must FAIL). **Step 5:** commit (`feat(pulsevm-watch): watch PR #116 and the ML-DSA parameter Metallicus uses`).

---

### Task 8: Operator delivery (coordinator + operator; not an implementer task)

Runs only after Tasks 1–7 are merged into the integration branch, the whole-branch review passes, and the full suite is green on the Mac and in the Task-4 Ubuntu 26.04 container.

- [ ] Operator (TTY): `bash scripts/operator-local/pq-identity-keygen.sh` (passphrase from the Dashlane entry named in the AI's ping, twice). AI verifies: encrypted file exists, mode 600, scrypt in `asn1parse`; `.pub` is ML-DSA-65.
- [ ] Operator backs up the encrypted key file and passphrase to Dashlane.
- [ ] Operator (TTY): `ssh-add ~/.ssh/freedom-yield-operator-identity && bash scripts/operator-local/pq-identity-unlock.sh`.
- [ ] AI: `bash scripts/operator-local/gen-identity.sh` (non-transition run, no `FY_EXPECT_CYCLE`) → exit 0; unlocked key gone; `ssh-add -d` the ed25519 key.
- [ ] AI: add `deploy/publication.json` rows for `.well-known/operator-identity-mldsa65.pub` and `api/identity.json.mldsa65.sig` (model: :457/:462), fix the `.well-known/README.md` row's "exactly this file and operator-identity.pub" text; run `bash scripts/check-identity-pq.sh --require-sig-verify` and `bash tests/run-all-tests.sh` → green.
- [ ] AI: commit `public/api/identity.json`, `.sig`, `.mldsa65.sig`, `.well-known/operator-identity-mldsa65.pub`, `deploy/publication.json` only (explicit `git add <file>`), final audit team (memory: push only after it), then **ask the operator to approve the push**.
- [ ] After deploy: curl the three URLs from the Mac and run the documented openssl line → `Signature Verified Successfully`; confirm `verify-identity` workflow green.
- [ ] This setup day (a weekday before 2026-11-06, separate from the transition day so a first-time step never shares a day with the irreversible anchor) doubles as the rehearsal of the stop-2 unlock: its `ssh-add && pq-identity-unlock.sh` → `gen-identity.sh` → auto-lock sequence is exactly the transition-day sequence. No separate rehearsal day.
