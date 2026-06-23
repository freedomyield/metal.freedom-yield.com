#!/usr/bin/env bash
# post-anchor-event.sh — Phase α anchor event processor (C2 T-11).
#
# Idempotent driver that:
#   1. Reads the current /api/cycles-history.json (live web URL).
#   2. Extracts dag_root_hash.
#   3. Compares to /var/lib/freedom-yield/last-anchored-root.
#   4. If unchanged, exits 2 (no-op).
#   5. If changed, invokes scripts/sign-anchor-event.sh with the new root.
#   6. Composes /api/anchor-receipt.json from the receipt fragment +
#      ambient URL metadata.
#   7. AJV-validates the composed receipt against the public schema.
#   8. Pushes to the web host via push-to-web-host.sh.
#   9. Updates last-anchored-root state file.
#
# Invoked by either:
#   - scripts/watch-anchor-events.sh (T-12, cron-driven) when a cycle
#     transition is detected by metalgo RPC observation
#   - the operator directly, with --force, for an --event-type=idrotate
#     after an operator identity-key rotation
#   - the operator directly, for emergency manual re-broadcast
#
# Constitution alignment:
#   - §2 #1 validator health: this script does NOT poll metalgo. It
#     reads only the static cycles-history.json URL and triggers
#     sign-anchor-event.sh; neither touches the metalgo data dir.
#   - §3.3: no key material is read by this script directly; the
#     anchor key is held by sign-anchor-event.sh's proton-cli keystore
#     under the deploy user.
#   - §4.1: no SECRET item is logged or echoed; the dag_root_hash and
#     tx_id are PUBLIC.
#   - §5: validator-host change; deployment is operator-approved.
#
# Exit codes:
#   0  success — anchor broadcast and receipt published
#   1  usage error
#   2  no-op (= dag_root_hash unchanged since last anchor)
#   3  cycles-history.json missing or invalid
#   4  sign-anchor-event.sh failed
#   5  receipt assembly or schema validation failed
#   6  push to web host failed
#   7  state-file update failed
#
# Usage:
#   post-anchor-event.sh --event-type <cyclestart|cycleend|idrotate>
#                        [--cycle-n N] [--key-seq K]
#                        [--force] [--dry-run]
#
# Canonical sources for the optional trigger_reference fields
# (= M-1 fix per audit 2026-06-21):
#
#   --cycle-n N   integer >= 1, the canonical cycle number this event
#                 pertains to. Used for cyclestart and cycleend events.
#                 If absent, the receipt OMITS cycle_n entirely — the
#                 driver does NOT derive cycle_n from any branch summary
#                 (branches.cycles.leaf_count is "closed cycles", not
#                 "current target cycle", and using it would publish
#                 incorrect metadata under any race condition between
#                 gen-cycle-history's append and this driver's run).
#   --key-seq K   integer >= 1, the canonical operator-identity key_seq
#                 this event pertains to. Used for idrotate events.
#                 If absent, the receipt OMITS key_seq entirely.
#
#   For the four event types the canonical source is:
#     cyclestart : caller passes --cycle-n explicitly. There is no
#                  on-chain or in-artifact source available at start
#                  time because the new cycle is not yet recorded in
#                  cycle-history.jsonl (= it only logs CLOSED cycles).
#     cycleend   : caller passes --cycle-n explicitly. After
#                  gen-cycle-history has appended the closing entry,
#                  the new last line of cycle-history.jsonl carries the
#                  cycle_n; the operator MAY read it manually and pass
#                  it via --cycle-n. The driver does not race against
#                  gen-cycle-history by reading the file itself.
#     idrotate   : caller passes --key-seq explicitly. cycle_n does not
#                  apply.
#     manual / recovery : neither --cycle-n nor --key-seq is set;
#                  trigger_reference is omitted entirely.
#
# Config (in /etc/freedom-yield/, same family as sign-anchor-event.sh):
#   anchor-sink, xpr-chain, xpr-quantity (consumed by sign-anchor-event.sh)
#
# State file (= no SECRET, just the last-anchored 64-hex):
#   /var/lib/freedom-yield/last-anchored-root
#     One line containing the dag_root_hash most recently anchored on
#     chain. Used for the idempotency check at step 3.
#
# Test-time env overrides (= keep production paths unchanged):
#   ANCHOR_SIGNER    path to the signer script. Default:
#                    $(dirname $0)/sign-anchor-event.sh. Test harnesses
#                    set this to a stub that emits a synthetic receipt
#                    fragment without invoking proton-cli.
#   PUBLIC_BASE      base URL for fetching cycles-history.json. Default
#                    https://metal.freedom-yield.com. Tests may use a
#                    file:// URL pointing at a fixture directory.
#   FY_STATE_DIR     directory holding last-anchored-root. Default
#                    /var/lib/freedom-yield. Tests use a temp dir.
#
# Log: /home/deploy/metal.freedom-yield.com/logs/post-anchor-event.log
#   per docs/CRON_CONVENTIONS.md. The caller (cron / watcher) is expected
#   to append-redirect this script's stdout/stderr to that path.

set -euo pipefail

# -------- args --------
EVENT_TYPE=""
FORCE=0
DRY_RUN=0
CYCLE_N=""
KEY_SEQ=""
while [ "$#" -gt 0 ]; do
	case "$1" in
		--event-type)
			[ "$#" -ge 2 ] || { echo "ERROR: --event-type requires a value" >&2; exit 1; }
			EVENT_TYPE="$2"; shift 2 ;;
		--event-type=*) EVENT_TYPE="${1#*=}"; shift ;;
		--cycle-n)
			[ "$#" -ge 2 ] || { echo "ERROR: --cycle-n requires a value" >&2; exit 1; }
			CYCLE_N="$2"; shift 2 ;;
		--cycle-n=*) CYCLE_N="${1#*=}"; shift ;;
		--key-seq)
			[ "$#" -ge 2 ] || { echo "ERROR: --key-seq requires a value" >&2; exit 1; }
			KEY_SEQ="$2"; shift 2 ;;
		--key-seq=*) KEY_SEQ="${1#*=}"; shift ;;
		--force)        FORCE=1; shift ;;
		--dry-run)      DRY_RUN=1; shift ;;
		--help|-h)
			sed -n '1,/^set -euo pipefail$/p' "$0" >&2
			exit 0
			;;
		*) echo "ERROR: unknown arg $1" >&2; exit 1 ;;
	esac
done

case "${EVENT_TYPE}" in
	cyclestart|cycleend|idrotate) ;;
	"") echo "ERROR: --event-type is required (cyclestart|cycleend|idrotate)" >&2; exit 1 ;;
	*)  echo "ERROR: invalid --event-type '${EVENT_TYPE}'" >&2; exit 1 ;;
esac

# Validate CYCLE_N if provided: must be a positive integer.
if [ -n "${CYCLE_N}" ]; then
	case "${CYCLE_N}" in
		*[!0-9]*|"") echo "ERROR: --cycle-n must be a non-negative integer (got '${CYCLE_N}')" >&2; exit 1 ;;
		0|0*)         echo "ERROR: --cycle-n must be >= 1 (got '${CYCLE_N}')" >&2; exit 1 ;;
	esac
fi

# Validate KEY_SEQ if provided: must be a positive integer.
if [ -n "${KEY_SEQ}" ]; then
	case "${KEY_SEQ}" in
		*[!0-9]*|"") echo "ERROR: --key-seq must be a non-negative integer (got '${KEY_SEQ}')" >&2; exit 1 ;;
		0|0*)         echo "ERROR: --key-seq must be >= 1 (got '${KEY_SEQ}')" >&2; exit 1 ;;
	esac
fi

# --cycle-n applies only to cyclestart / cycleend; --key-seq applies only
# to idrotate. Reject mismatch loudly rather than silently dropping the
# input (= caller mental-model check).
case "${EVENT_TYPE}" in
	cyclestart|cycleend)
		if [ -n "${KEY_SEQ}" ]; then
			echo "ERROR: --key-seq is not valid for event_type '${EVENT_TYPE}' (use --cycle-n)" >&2; exit 1
		fi ;;
	idrotate)
		if [ -n "${CYCLE_N}" ]; then
			echo "ERROR: --cycle-n is not valid for event_type 'idrotate' (use --key-seq)" >&2; exit 1
		fi ;;
esac

# -------- paths --------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
SIGNER="${ANCHOR_SIGNER:-${SCRIPT_DIR}/sign-anchor-event.sh}"
PUSHER="${SCRIPT_DIR}/push-to-web-host.sh"
STATE_DIR="${FY_STATE_DIR:-/var/lib/freedom-yield}"
STATE_FILE="${STATE_DIR}/last-anchored-root"

if [ ! -x "${SIGNER}" ]; then
	echo "ERROR: signer not executable: ${SIGNER}" >&2; exit 1
fi
if [ ! -x "${PUSHER}" ]; then
	echo "ERROR: pusher not executable: ${PUSHER}" >&2; exit 1
fi
[ -d "${STATE_DIR}" ] || mkdir -p "${STATE_DIR}"

# -------- fetch cycles-history.json --------
PUBLIC_BASE="${PUBLIC_BASE:-https://metal.freedom-yield.com}"
CYCLES_URL="${PUBLIC_BASE}/api/cycles-history.json"

CYCLES_TMP="$(mktemp -t cycles.XXXXXX)"
trap 'rm -f "${CYCLES_TMP}" "${RECEIPT_TMP:-}" "${FRAG_TMP:-}"' EXIT

if ! curl -sSLf -o "${CYCLES_TMP}" "${CYCLES_URL}"; then
	echo "ERROR: failed to fetch ${CYCLES_URL}" >&2; exit 3
fi
if ! jq empty "${CYCLES_TMP}" >/dev/null 2>&1; then
	echo "ERROR: ${CYCLES_URL} is not valid JSON" >&2; exit 3
fi

DAG_ROOT_HASH="$(jq -r '.dag_root_hash // empty' "${CYCLES_TMP}")"
case "${DAG_ROOT_HASH}" in
	*[!a-f0-9]*|"")
		echo "ERROR: cycles-history.json has no usable dag_root_hash field" >&2; exit 3 ;;
esac
if [ "${#DAG_ROOT_HASH}" -ne 64 ]; then
	echo "ERROR: dag_root_hash is not 64 chars: ${DAG_ROOT_HASH}" >&2; exit 3
fi

# -------- idempotency check --------
LAST_ANCHORED=""
[ -r "${STATE_FILE}" ] && LAST_ANCHORED="$(tr -d '\n\r\t ' < "${STATE_FILE}" || true)"

if [ "${FORCE}" -eq 0 ] && [ "${LAST_ANCHORED}" = "${DAG_ROOT_HASH}" ]; then
	echo "no-op: dag_root_hash unchanged since last anchor (${DAG_ROOT_HASH:0:12}…)" >&2
	exit 2
fi

echo "anchoring event_type=${EVENT_TYPE} dag_root_hash=${DAG_ROOT_HASH}" >&2

# -------- invoke signer --------
FRAG_TMP="$(mktemp -t anchor-frag.XXXXXX)"
SIGNER_ARGS=("${EVENT_TYPE}" "${DAG_ROOT_HASH}")
[ "${DRY_RUN}" -eq 1 ] && SIGNER_ARGS+=(--dry-run)

if ! "${SIGNER}" "${SIGNER_ARGS[@]}" > "${FRAG_TMP}"; then
	echo "ERROR: sign-anchor-event.sh failed" >&2; exit 4
fi

if ! jq empty "${FRAG_TMP}" >/dev/null 2>&1; then
	echo "ERROR: signer emitted non-JSON output" >&2; exit 5
fi

# -------- compose anchor-receipt.json --------
NOW_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
TX_ID="$(jq -r .tx_id "${FRAG_TMP}")"
EXPLORER_URL=""

# Network is in the fragment; build the explorer URL accordingly.
NETWORK_TAG="$(jq -r .network "${FRAG_TMP}")"
case "${NETWORK_TAG}" in
	xpr-mainnet)  EXPLORER_BASE="${EXPLORER_BASE_MAIN:-https://explorer.xprnetwork.org}" ;;
	xpr-testnet)  EXPLORER_BASE="${EXPLORER_BASE_TEST:-https://explorer.xprnetwork-test.metallicus.com}" ;;
	*) EXPLORER_BASE="${EXPLORER_BASE_MAIN:-https://explorer.xprnetwork.org}" ;;
esac
EXPLORER_URL="${EXPLORER_BASE}/transaction/${TX_ID}"

# Build trigger_reference ONLY from canonical caller input (--cycle-n or
# --key-seq). We do NOT derive cycle_n from branches.cycles.leaf_count or
# any other branch summary; leaf_count is "closed cycles" not "current
# target cycle", and any derivation rule (e.g. leaf_count+1) would publish
# incorrect metadata under any race condition between gen-cycle-history's
# append and this driver's run. See M-1 audit fix 2026-06-21.
TRIGGER_REF_JSON="null"
case "${EVENT_TYPE}" in
	cyclestart|cycleend)
		if [ -n "${CYCLE_N}" ]; then
			TRIGGER_REF_JSON="$(jq -n --argjson c "${CYCLE_N}" '{cycle_n: $c}')"
		fi ;;
	idrotate)
		if [ -n "${KEY_SEQ}" ]; then
			TRIGGER_REF_JSON="$(jq -n --argjson k "${KEY_SEQ}" '{key_seq: $k}')"
		fi ;;
esac

# AJV CLI selects its parser by file extension; the temp file MUST end in
# `.json` or AJV treats the bytes as not-JSON and reports "Unexpected token".
RECEIPT_TMP_BASE="$(mktemp -t anchor-receipt.XXXXXX)"
RECEIPT_TMP="${RECEIPT_TMP_BASE}.json"
mv "${RECEIPT_TMP_BASE}" "${RECEIPT_TMP}"
# Signing actor/permission denormalized at receipt-build time per the
# 2026-06-23 anchor-script triad refactor (= consistency invariant with
# anchor.inscribe_action.permission is enforced by schema allOf).
SIGNING_ACTOR_FRAG="$(jq -r '(.inscribe_action.permission.actor // empty)' "${FRAG_TMP}")"
SIGNING_PERMISSION_FRAG="$(jq -r '(.inscribe_action.permission.permission // empty)' "${FRAG_TMP}")"
SIGNING_ACTOR="${SIGNING_ACTOR_FRAG:-metalfreedom}"
SIGNING_PERMISSION="${SIGNING_PERMISSION_FRAG:-anchor}"

jq -n \
	--argjson frag         "$(cat "${FRAG_TMP}")" \
	--arg dag_root_hash    "${DAG_ROOT_HASH}" \
	--arg expl             "${EXPLORER_URL}" \
	--arg cycles_url       "${PUBLIC_BASE}/api/cycles-history.json" \
	--arg identity_url     "${PUBLIC_BASE}/api/identity.json" \
	--arg event_type       "${EVENT_TYPE}" \
	--argjson trigger_ref  "${TRIGGER_REF_JSON}" \
	--arg signing_actor    "${SIGNING_ACTOR}" \
	--arg signing_permission "${SIGNING_PERMISSION}" \
	--arg verification_status "live" \
	--arg generated_at     "${NOW_UTC}" \
	'({
		_comment: "A-chain anchor receipt — generated by scripts/post-anchor-event.sh per docs/MERKLE_DAG_SPEC.md §6.",
		"$schema": "https://metal.freedom-yield.com/api/anchor-receipt.schema.v1.json",
		schema_version: 1,
		dag_root_hash: $dag_root_hash,
		memo: $frag.memo,
		anchor: ($frag + {explorer_url: $expl, chain_backend: ($frag.chain_backend // "pulsevm")}),
		cycles_history_url: $cycles_url,
		identity_url: $identity_url,
		trigger_event: (
			if   $event_type == "cyclestart" then "cycle_start"
			elif $event_type == "cycleend"   then "cycle_end"
			elif $event_type == "idrotate"   then "identity_rotation"
			else "manual" end
		),
		signing_actor: $signing_actor,
		signing_permission: $signing_permission,
		verification_status: $verification_status,
		generated_at: $generated_at
	})
	+ (if $trigger_ref == null then {} else {trigger_reference: $trigger_ref} end)' \
	> "${RECEIPT_TMP}"

if ! jq empty "${RECEIPT_TMP}" >/dev/null 2>&1; then
	echo "ERROR: composed receipt is not valid JSON" >&2; exit 5
fi

# Optional AJV validation if ajv-cli is available (= present on validator
# host via the existing scripts dependencies). Non-blocking warning if
# AJV is not available.
if command -v npx >/dev/null 2>&1; then
	SCHEMA_LOCAL="${REPO_ROOT}/public/api/anchor-receipt.schema.v1.json"
	if [ -r "${SCHEMA_LOCAL}" ]; then
		AJV_ERR="$(npx --yes -p ajv-cli@5.0.0 -p ajv-formats@3.0.1 ajv validate \
			--strict=false --all-errors -c=ajv-formats --spec=draft2020 \
			-s "${SCHEMA_LOCAL}" -d "${RECEIPT_TMP}" 2>&1)" || AJV_RC=$?
		if [ "${AJV_RC:-0}" -ne 0 ]; then
			echo "ERROR: composed receipt failed AJV validation against ${SCHEMA_LOCAL}" >&2
			echo "ERROR: AJV detail (truncated to 20 lines):" >&2
			printf '%s\n' "${AJV_ERR}" | head -n 20 >&2
			exit 5
		fi
	fi
fi

# -------- atomic local commit + push to web host --------
LOCAL_PUBLISH="${REPO_ROOT}/public/api/anchor-receipt.json"
if [ "${DRY_RUN}" -eq 1 ]; then
	# Emit the composed receipt JSON on stdout (= test harnesses parse it
	# directly). Status messages go to stderr to keep stdout machine-readable.
	echo "DRY-RUN: would atomically install at ${LOCAL_PUBLISH} and push via push-to-web-host.sh" >&2
	cat "${RECEIPT_TMP}"
else
	# Atomic local commit (same dir → POSIX-atomic mv).
	if ! mv "${RECEIPT_TMP}" "${LOCAL_PUBLISH}"; then
		echo "ERROR: failed to install receipt into ${LOCAL_PUBLISH}" >&2
		exit 5
	fi
	chmod 644 "${LOCAL_PUBLISH}"
	RECEIPT_TMP=""  # cleanup trap no longer needs to unlink the published file

	# Push to web host (= push-to-web-host.sh reads from REPO_BASE/public/api/).
	# Requires the web-host forced-command wrapper allowlist to include
	# 'anchor-receipt.json'; see the comment block at the top of
	# scripts/push-to-web-host.sh for the operator-side deployment note.
	if ! "${PUSHER}" anchor-receipt.json; then
		echo "ERROR: push-to-web-host.sh failed for anchor-receipt.json" >&2
		exit 6
	fi

	# -------- append to anchor-history.jsonl ledger --------
	# Triad refactor 2026-06-23: after the live receipt is published, append
	# a new line to /api/anchor-history.jsonl via the dedicated invariant-
	# enforcing append script. Failure here is fatal (exit 6) — without the
	# append step, the live receipt and the public ledger drift out of sync.
	# Requires the web-host forced-command wrapper allowlist to include
	# 'anchor-history.jsonl'; see push-to-web-host.sh.
	HISTORY_APPENDER="${SCRIPT_DIR}/append-anchor-history.sh"
	if [ -x "${HISTORY_APPENDER}" ]; then
		HIST_CYCLE_N_ARGS=()
		if [ -n "${CYCLE_N}" ]; then
			HIST_CYCLE_N_ARGS=(CYCLE_N="${CYCLE_N}")
		fi
		if ! env "${HIST_CYCLE_N_ARGS[@]}" \
				RECEIPT_PATH="${LOCAL_PUBLISH}" \
				HISTORY_PATH="${REPO_ROOT}/public/api/anchor-history.jsonl" \
				"${HISTORY_APPENDER}" >&2; then
			echo "ERROR: append-anchor-history.sh refused to append the new line" >&2
			exit 6
		fi
		if ! "${PUSHER}" anchor-history.jsonl; then
			echo "ERROR: push-to-web-host.sh failed for anchor-history.jsonl" >&2
			exit 6
		fi
	else
		echo "WARN: append-anchor-history.sh not executable at ${HISTORY_APPENDER}; ledger not updated" >&2
	fi
fi

# -------- update state --------
if [ "${DRY_RUN}" -eq 0 ]; then
	# Atomic write — write to .new then mv.
	if ! printf '%s\n' "${DAG_ROOT_HASH}" > "${STATE_FILE}.new"; then
		echo "ERROR: failed to write ${STATE_FILE}.new" >&2; exit 7
	fi
	mv "${STATE_FILE}.new" "${STATE_FILE}"
fi

echo "✓ anchored: tx_id=${TX_ID}" >&2
echo "  network:     ${NETWORK_TAG}" >&2
echo "  explorer:    ${EXPLORER_URL}" >&2
echo "  event_type:  ${EVENT_TYPE}" >&2
echo "  dag_root:    ${DAG_ROOT_HASH}" >&2
echo "  receipt:     ${PUBLIC_BASE}/api/anchor-receipt.json" >&2
