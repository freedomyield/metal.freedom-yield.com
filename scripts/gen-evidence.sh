#!/usr/bin/env bash
# gen-evidence.sh — build a machine-readable evidence manifest for institutional readers.
#
# Purpose:
#   Combine the live validator state (NodeID / self-stake / delegation fee / status) with
#   the project's static commitments (non-custodial, renewal transparency, decommission
#   notice window, incident disclosure SLA) and the public-page URL set into a single
#   self-describing JSON file. Designed to be consumed by automated due-diligence tooling
#   on the reviewer side — one fetch, one parse, the whole evidence index.
#
# Schema:
#   See public/api/evidence.example.json for the committed schema example.
#   schema_version is incremented when the field shape changes.
#
# Dependencies:
#   jq only. No curl, no python. No new runtime dependencies.
#
# Inputs:
#   public/api/validator.json — live state, written every 5 minutes by scripts/node-info.sh.
#
# Output:
#   public/api/evidence.json — gitignored runtime artefact.
#   Atomic write: same-directory tmp file + jq round-trip validation + mv.
#   On any failure, the existing evidence.json is left untouched.
#
# Cron cadence:
#   Daily. Most live state changes propagate via /api/validator.json (5-min cadence);
#   this manifest is a slow-moving evidence index, not real-time telemetry.
#
# Staleness handling:
#   - If validator.json has no observed timestamp, or it cannot be parsed,
#     validator_status is reported as "unknown" + stale_input_warning: true.
#   - If now - observed_at > 3600s (1 hour), same: "unknown" + stale_input_warning: true.
#   - Only when input is fresh do we report "active" / "inactive".
#
# Constraints (Constitution v0.1):
#   §4.2 C1   — No provider/region names in inputs or outputs.
#   §4.1      — No SSH paths, no host paths, no IPs, no credentials.
#   feedback_validator_operation_first — NO direct metalgo queries here.
#               We only re-read validator.json, the canonical local artefact.
#   feedback_polite_external_access    — NO external API calls. Everything is local.
set -euo pipefail

REPO_BASE="${REPO_BASE:-$(cd "$(dirname "$0")/.." && pwd)}"

# -------- cycle-gate (= cycle-affecting write 制御、 fail-closed) --------
# Skip regeneration of evidence.json when the gate is deferred or missing.
# evidence.json is a leaf in identity.json's artifact_manifest (= part of
# artifact_root); rewriting during a transition window would invalidate
# the most recent operator-signed identity manifest until re-signed.
CYCLE_GATE_SCRIPT="${REPO_BASE}/scripts/cycle-gate.sh"
if [ ! -x "${CYCLE_GATE_SCRIPT}" ]; then
	echo "[gen-evidence] cycle-gate.sh missing or non-executable → skip (fail-closed)" >&2
	exit 0
fi
if ! "${CYCLE_GATE_SCRIPT}" --side-effect=cycle-artifact-write; then
	echo "[gen-evidence] deferred by cycle-gate → skip evidence.json regeneration" >&2
	exit 0
fi

VALIDATOR_JSON="${REPO_BASE}/public/api/validator.json"
OUT="${REPO_BASE}/public/api/evidence.json"
STALE_THRESHOLD_SEC=3600

if [[ ! -r "${VALIDATOR_JSON}" ]]; then
	echo "ERROR: ${VALIDATOR_JSON} not readable. Run scripts/node-info.sh first." >&2
	exit 1
fi

# Validate that validator.json is parseable before we trust any field.
if ! jq -e . "${VALIDATOR_JSON}" >/dev/null 2>&1; then
	echo "ERROR: ${VALIDATOR_JSON} is not valid JSON; refusing to generate evidence.json." >&2
	exit 1
fi

# Extract dynamic fields. Empty string means "absent" downstream.
NODE_ID=$(jq -r '.nodeId // empty' "${VALIDATOR_JSON}")
SELF_STAKE=$(jq -r '.stake.self // empty' "${VALIDATOR_JSON}")
FEE_PCT=$(jq -r '.delegationFee.percent // empty' "${VALIDATOR_JSON}")
P_BOOT=$(jq -r '.bootstrap.pChain // false' "${VALIDATOR_JSON}")
X_BOOT=$(jq -r '.bootstrap.xChain // false' "${VALIDATOR_JSON}")
C_BOOT=$(jq -r '.bootstrap.cChain // false' "${VALIDATOR_JSON}")
OBSERVED_AT=$(jq -r '.observedAt // empty' "${VALIDATOR_JSON}")

# Staleness determination.
#   - observed_at missing or unparseable → unknown + stale_input_warning.
#   - now - observed_at > STALE_THRESHOLD_SEC → unknown + stale_input_warning.
#   - otherwise → use the active/inactive derivation.
STALE_WARNING="false"
VALIDATOR_STATUS="unknown"

if [[ -n "${OBSERVED_AT}" ]]; then
	# date -d works on GNU date (Linux); fall back to BSD date (-j -f) if needed.
	OBS_EPOCH=$(date -d "${OBSERVED_AT}" +%s 2>/dev/null \
		|| date -j -f "%Y-%m-%dT%H:%M:%SZ" "${OBSERVED_AT}" +%s 2>/dev/null \
		|| echo "")
	if [[ -n "${OBS_EPOCH}" ]]; then
		NOW_EPOCH=$(date -u +%s)
		AGE_SEC=$((NOW_EPOCH - OBS_EPOCH))
		if (( AGE_SEC > STALE_THRESHOLD_SEC )) || (( AGE_SEC < -STALE_THRESHOLD_SEC )); then
			STALE_WARNING="true"
			VALIDATOR_STATUS="unknown"
		else
			# Fresh input — derive active/inactive.
			VALIDATOR_STATUS="inactive"
			if [[ -n "${NODE_ID}" && -n "${SELF_STAKE}" && "${SELF_STAKE}" != "null" \
				&& "${P_BOOT}" == "true" && "${X_BOOT}" == "true" && "${C_BOOT}" == "true" ]]; then
				if awk -v v="${SELF_STAKE}" 'BEGIN { exit !(v + 0 > 0) }'; then
					VALIDATOR_STATUS="active"
				fi
			fi
		fi
	else
		# observed_at could not be parsed.
		STALE_WARNING="true"
		VALIDATOR_STATUS="unknown"
	fi
else
	# observed_at missing entirely.
	STALE_WARNING="true"
	VALIDATOR_STATUS="unknown"
fi

GENERATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Atomic write: same-directory tmp + jq validation + mv.
TMP="$(dirname "${OUT}")/.evidence.json.tmp.$$"
trap 'rm -f "${TMP}"' EXIT

jq -n \
	--arg node_id "${NODE_ID}" \
	--arg status "${VALIDATOR_STATUS}" \
	--arg self_stake "${SELF_STAKE}" \
	--arg fee_pct "${FEE_PCT}" \
	--arg observed_at "${OBSERVED_AT}" \
	--arg generated_at "${GENERATED_AT}" \
	--argjson stale_warning "${STALE_WARNING}" \
	'{
		_comment: "Machine-readable evidence manifest for Freedom Yield Metal Blockchain validator. Generated by scripts/gen-evidence.sh from validator.json + static project config. The runtime file is gitignored; the committed evidence.example.json documents the schema.",
		schema_version: 1,
		brand: "Freedom Yield",
		network: "metal-mainnet",
		node_id: (if $node_id == "" then null else $node_id end),
		validator_status: $status,
		self_stake_metal: (if $self_stake == "" or $self_stake == "null" then null else ($self_stake | tonumber) end),
		delegation_fee_percent: (if $fee_pct == "" or $fee_pct == "null" then null else ($fee_pct | tonumber) end),
		public_pages: {
			status: "https://metal.freedom-yield.com/",
			journal: "https://metal.freedom-yield.com/journal/",
			incidents: "https://metal.freedom-yield.com/incidents/",
			commitments: "https://metal.freedom-yield.com/commitments/",
			risk_disclosure: "https://metal.freedom-yield.com/risk-disclosure/",
			jurisdiction: "https://metal.freedom-yield.com/jurisdiction/",
			continuity: "https://metal.freedom-yield.com/continuity/",
			network: "https://metal.freedom-yield.com/network/",
			selection_evidence: "https://metal.freedom-yield.com/selection-evidence/",
			subnet_readiness: "https://metal.freedom-yield.com/subnet-readiness/",
			reference_architecture: "https://metal.freedom-yield.com/reference-architecture/",
			subnet_pilot: "https://metal.freedom-yield.com/subnet-pilot/",
			inquiry: "https://metal.freedom-yield.com/inquiry/",
			pledge: "https://metal.freedom-yield.com/pledge/",
			data_catalog: "https://metal.freedom-yield.com/data/"
		},
		operator_commitments: {
			non_custodial: true,
			renewal_transparency: true,
			decommission_notice_days: 90,
			incident_disclosure_sla_hours: 24,
			incident_sla: {
				detect_minutes_max: 30,
				acknowledge_hours_business: 2,
				acknowledge_hours_offhours: 8,
				status_update_cadence_hours: 4,
				resolve_or_escalate_hours: 24
			}
		},
		# MED-6 (2026-08-05): anchor_receipt and anchor_history moved here from
		# in_preparation_artifacts. Both have been live since the cycle 2 -> 3
		# transition (2026-07-04) — see public/api/identity.json, which
		# already carries anchor_receipt_url / audit.anchor_receipt /
		# audit.anchor_history pointing at these same runtime URLs.
		# (NOTE for maintainers: no apostrophes in this comment block — this
		# text sits inside the single-quoted bash string that wraps the jq
		# program below; a stray apostrophe here breaks bash quoting, not
		# just jq parsing.) Leaving these two entries classified as "in
		# preparation" with planned_url misrepresented the live/operational
		# split of this manifest to any automated due-diligence consumer
		# reading this file. anchor_receipt now points its schema_url and
		# formal_schema_url at the v2 (not v1) example and formal schema —
		# the live file is generated by scripts/gen-anchor-receipt.sh, and
		# that script validates against anchor-receipt.schema.v2.json, not
		# v1 (see that script for its own SCHEMA_FILE default). anchor_history
		# schema_url still points at the existing (v1-shaped)
		# anchor-history.example.jsonl — no v2-shaped example file exists in
		# this repo yet — while formal_schema_url correctly names the v2
		# schema that scripts/append-anchor-history.sh actually validates
		# against; authoring a v2-shaped example file is a follow-up, not
		# part of this fix.
		live_artifacts: {
			identity_manifest: {
				url: "https://metal.freedom-yield.com/api/identity.json",
				signature_url: "https://metal.freedom-yield.com/api/identity.json.sig",
				pubkey_url: "https://metal.freedom-yield.com/.well-known/operator-identity.pub",
				schema_url: "https://metal.freedom-yield.com/api/identity.example.json",
				formal_schema_url: "https://metal.freedom-yield.com/api/identity.schema.v1.json",
				format_guide_url: "https://github.com/freedomyield/metal.freedom-yield.com/blob/main/docs/IDENTITY_VERIFICATION.md",
				operator_guide_url: "https://github.com/freedomyield/metal.freedom-yield.com/blob/main/docs/OPERATOR_IDENTITY_SETUP.md",
				cross_reference_url: "https://metal.freedom-yield.com/api/anchor-source.json"
			},
			cycle_history_jsonl: {
				url: "https://metal.freedom-yield.com/api/cycle-history.jsonl",
				schema_url: "https://metal.freedom-yield.com/api/cycle-history.example.jsonl",
				formal_schema_url: "https://metal.freedom-yield.com/api/cycle-history.schema.v1.json",
				format_guide_url: "https://github.com/freedomyield/metal.freedom-yield.com/blob/main/docs/CYCLE_HISTORY.md"
			},
			anchor_receipt: {
				url: "https://metal.freedom-yield.com/api/anchor-receipt.json",
				schema_url: "https://metal.freedom-yield.com/api/anchor-receipt.v2.example.json",
				formal_schema_url: "https://metal.freedom-yield.com/api/anchor-receipt.schema.v2.json",
				format_guide_url: "https://github.com/freedomyield/metal.freedom-yield.com/blob/main/docs/IDENTITY_VERIFICATION.md",
				operator_guide_url: "https://github.com/freedomyield/metal.freedom-yield.com/blob/main/docs/PHASE_ALPHA_AUDIT_HANDOFF.md",
				cross_reference_url: "https://metal.freedom-yield.com/api/anchor-source.json"
			},
			anchor_history: {
				url: "https://metal.freedom-yield.com/api/anchor-history.jsonl",
				schema_url: "https://metal.freedom-yield.com/api/anchor-history.example.jsonl",
				formal_schema_url: "https://metal.freedom-yield.com/api/anchor-history.schema.v2.json",
				format_guide_url: "https://github.com/freedomyield/metal.freedom-yield.com/blob/main/docs/IDENTITY_VERIFICATION.md",
				operator_guide_url: "https://github.com/freedomyield/metal.freedom-yield.com/blob/main/docs/PHASE_ALPHA_AUDIT_HANDOFF.md",
				cross_reference_url: "https://metal.freedom-yield.com/api/anchor-receipt.json"
			}
		},
		in_preparation_artifacts: {},
		explorer_url: "https://explorer.metalblockchain.org/",
		generated_at: $generated_at,
		validator_state_observed_at: (if $observed_at == "" then null else $observed_at end),
		stale_input_warning: $stale_warning
	}' > "${TMP}"

# Round-trip validation: parse the tmp file. If anything is wrong, fail loud and leave the
# existing OUT untouched.
if ! jq -e . "${TMP}" >/dev/null 2>&1; then
	echo "ERROR: generated evidence.json is invalid JSON; refusing to publish." >&2
	exit 2
fi

mv "${TMP}" "${OUT}"
chmod 644 "${OUT}"
trap - EXIT

echo "Wrote ${OUT} (status=${VALIDATOR_STATUS}, stale=${STALE_WARNING}, node_id=${NODE_ID:-<empty>})"
