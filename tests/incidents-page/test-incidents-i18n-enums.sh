#!/usr/bin/env bash
# test-incidents-i18n-enums.sh — the incidents page must be able to render
# every value the incidents feed is allowed to contain.
#
# CHAIN: none — reads two repo files and compares them. No network, no host.
# PRIME_DIRECTIVE: TESTNET-FIRST — safe.
#
# This is the VALUE-domain counterpart to the field-name contract checked by
# tests/field-contracts/. Getting the field name right only guarantees the page
# reads the right property; it says nothing about whether the page understands
# the values that property may hold.
#
# 2026-08-06: incidents.schema.v1.json declares severity as the capitalized
# enum ["Critical","Major","Minor","Info"] and status as
# ["open","under_remediation","resolved"], while incidents.js keyed its I18N
# tables in lowercase and compared `sev === "critical"`. Every lookup missed.
# Two consequences, neither of which produced an error anywhere:
#
#   * the JA page fell through to the raw English enum value (a locale leak);
#   * `sev === "critical"` never matched, so a Critical or Major incident was
#     rendered with badge-ok — GREEN. The page actively signalled "all fine"
#     for the most serious class of event it exists to report.
#
# scripts/check-field-contracts.py cannot see this class: `severity` IS a real
# field, read under its real name. Only the value domain was wrong. Hence this
# targeted check — narrow enough to have no false positives, which a general
# case-mismatch heuristic would not be (see docs/FIELD_CONTRACTS.md).
#
# Usage:
#   bash tests/incidents-page/test-incidents-i18n-enums.sh
#
# Exit codes:
#   0  every enum value in every locale resolves to a label
#   1  some enum value would render unlabelled (or the inputs are unreadable)

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCHEMA="${REPO_ROOT}/public/api/incidents.schema.v1.json"
PAGE_JS="${REPO_ROOT}/public/assets/incidents.js"

for f in "$SCHEMA" "$PAGE_JS"; do
	if [ ! -r "$f" ]; then
		echo "FATAL: not readable: $f" >&2
		exit 1
	fi
done
if ! command -v jq >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
	echo "FATAL: jq and python3 required" >&2
	exit 1
fi

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "PASS  $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL  $1"; }

# Enum values straight out of the schema — never a copy kept in this test, so
# adding a severity or status level to the schema makes this suite demand a
# label for it rather than silently passing.
SEVERITIES="$(jq -r '.. | objects | select(.properties.severity?) | .properties.severity.enum[]?' "$SCHEMA")"
STATUSES="$(jq -r '.. | objects | select(.properties.status?) | .properties.status.enum[]?' "$SCHEMA")"

if [ -z "$SEVERITIES" ] || [ -z "$STATUSES" ]; then
	echo "FATAL: could not extract severity/status enums from $SCHEMA" >&2
	exit 1
fi

# Extract the lookup-table keys the page actually defines, per locale.
table_keys() {           # table_keys <locale> <table-name>
	python3 - "$PAGE_JS" "$1" "$2" <<'PY'
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
locale, table = sys.argv[2], sys.argv[3]
m = re.search(r"\b%s\s*:\s*\{" % re.escape(locale), src)
if not m:
    sys.exit(0)
# Brace-match the locale block, then find the named table inside it.
i = src.index("{", m.end() - 1)
depth, j = 0, i
while j < len(src):
    if src[j] == "{":
        depth += 1
    elif src[j] == "}":
        depth -= 1
        if depth == 0:
            break
    j += 1
block = src[i:j + 1]
t = re.search(r"\b%s\s*:\s*\{([^}]*)\}" % re.escape(table), block)
if not t:
    sys.exit(0)
for k in re.findall(r"([A-Za-z_$][\w$]*)\s*:", t.group(1)):
    print(k)
PY
}

LOCALES="en ja"

for loc in $LOCALES; do
	KEYS="$(table_keys "$loc" severity)"
	if [ -z "$KEYS" ]; then
		bad "$loc: no severity label table found in incidents.js"
		continue
	fi
	MISSING=""
	for v in $SEVERITIES; do
		# The page lowercases before lookup; the invariant is that the
		# lowercased enum value is present as a key.
		low="$(printf '%s' "$v" | tr '[:upper:]' '[:lower:]')"
		printf '%s\n' "$KEYS" | grep -qx "$low" || MISSING="$MISSING $v"
	done
	[ -z "$MISSING" ] \
		&& ok "$loc: every severity enum value has a label" \
		|| bad "$loc: severity values would render unlabelled:$MISSING"
done

for loc in $LOCALES; do
	KEYS="$(table_keys "$loc" statusValue)"
	if [ -z "$KEYS" ]; then
		bad "$loc: no statusValue label table found in incidents.js"
		continue
	fi
	MISSING=""
	for v in $STATUSES; do
		low="$(printf '%s' "$v" | tr '[:upper:]' '[:lower:]')"
		printf '%s\n' "$KEYS" | grep -qx "$low" || MISSING="$MISSING $v"
	done
	[ -z "$MISSING" ] \
		&& ok "$loc: every status enum value has a label" \
		|| bad "$loc: status values would render unlabelled:$MISSING"
done

# The severity->badge decision must also be case-insensitive. A bare
# `sev === "critical"` against a "Critical" feed value is the exact bug that
# painted a Critical incident green.
#
# Scoped to severityBadge's own body, deliberately: a file-wide grep for
# toLowerCase() passes as soon as ANY other function normalizes (statusLabel
# does), so the file-wide form silently stopped detecting the very bug it was
# written for. Verified by mutation.
BODY="$(python3 - "$PAGE_JS" <<'PY'
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r"function\s+severityBadge\s*\([^)]*\)\s*\{", src)
if not m:
    sys.exit(0)
i = src.index("{", m.end() - 1)
depth, j = 0, i
while j < len(src):
    if src[j] == "{":
        depth += 1
    elif src[j] == "}":
        depth -= 1
        if depth == 0:
            break
    j += 1
print(src[i:j + 1])
PY
)"
if [ -z "$BODY" ]; then
	bad "severityBadge() not found in incidents.js"
elif printf '%s' "$BODY" | grep -qE "toLowerCase\(\)|toUpperCase\(\)"; then
	ok "severity comparison is case-normalized before matching the enum"
else
	bad "severityBadge() matches severity without normalizing case — a 'Critical' feed value would miss every lowercase branch (badge-ok green)"
fi

# Guard the direction that actually shipped: a raw enum value must never be
# interpolated straight into the rendered card.
if grep -qE 'escapeHtml\(\s*inc\.status\s*\)' "$PAGE_JS"; then
	bad "inc.status is rendered raw — visitors would see 'under_remediation'"
else
	ok "status is rendered through its label table, not raw"
fi

echo
echo "test-incidents-i18n-enums.sh summary: PASS=$PASS  FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
