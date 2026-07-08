#!/usr/bin/env bash
# tests/apply-external-link-attrs/test-apply-external-link-attrs.sh — unit
# test for scripts/apply-external-link-attrs.sh.
#
# WHY: apply-external-link-attrs.sh is a MINIMAL-DIFF tool by design — it
# rewrites only the rel/target attribute bytes of <a ...> start tags it
# classifies as external, and every other byte of the file must survive a
# run untouched. This test proves the classification rules, the rel-union
# + canonical-order + allowlist logic, the --check contract, idempotency,
# and — most load-bearing of all — that non-anchor tags and non-rel/target
# bytes never move.
#
# CHAIN: none — pure local file edits, no broadcast. PRIME_DIRECTIVE: safe.
#
# Usage:
#   bash tests/apply-external-link-attrs/test-apply-external-link-attrs.sh
#
# Exit codes:
#   0  all cases PASS
#   1  any case FAILED

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="${REPO_ROOT}/scripts/apply-external-link-attrs.sh"

if [ ! -x "$SCRIPT" ]; then
	echo "FATAL: script not executable at $SCRIPT" >&2
	exit 1
fi

PASS=0
FAIL=0
pass() { printf 'PASS  %-70s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL  %-70s\n' "$1" >&2; FAIL=$((FAIL + 1)); }
check_eq() {
	local label="$1" expected="$2" actual="$3"
	if [ "$expected" = "$actual" ]; then
		pass "$label"
	else
		fail "$label (expected='$expected' actual='$actual')"
	fi
}

TMP="$(mktemp -d -t apply-external-link-attrs-test.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# tid_line <file> <data-tid value> — print the single line of <file>
# containing data-tid="<value>" (there is always exactly one per fixture).
tid_line() {
	grep -F "data-tid=\"$2\"" "$1" | head -1
}

# ============================================================================
# Main fixture: one file exercising every classification + rel/allowlist
# rule. Each <a> carries a unique data-tid so assertions are robust to
# attribute-order changes elsewhere in the tag.
# ============================================================================
MAIN_FIXTURE="$TMP/main.html"
cat > "$MAIN_FIXTURE" <<'EOF'
<!doctype html>
<html>
<head>
	<link rel="preconnect" href="https://www.googletagmanager.com/gtag/js">
</head>
<body>
	<article data-tid="article-tag">Not a link at all.</article>
	<a data-tid="no-attrs">bare anchor, no href</a>
	<a data-tid="frag" href="#main">fragment only</a>
	<a data-tid="relative" href="/about-metal/">relative path</a>
	<a data-tid="mailto" href="mailto:info@metal.freedom-yield.com">mail</a>
	<a data-tid="tel" href="tel:+81312345678">tel</a>
	<a data-tid="ownhost" href="https://metal.freedom-yield.com/about-metal/">own host absolute</a>
	<a data-tid="ext-bare" href="https://example.com/report">bare external</a>
	<a data-tid="allow-exact" href="https://github.com/freedomyield/metal-validator">github exact allowlist</a>
	<a data-tid="allow-subdomain" href="https://explorer.metalblockchain.org/" rel="noopener">allowlisted subdomain, existing rel</a>
	<a data-tid="allow-lookalike" href="https://evilmetalblockchain.org/">substring lookalike must NOT be exempt</a>
	<a data-tid="ext-existing-rel" href="https://example.org/" rel="noopener noreferrer">existing rel union</a>
	<a data-tid="protocol-relative-allow" href="//explorer.metalblockchain.org/x">protocol-relative allowlisted</a>
	<a data-tid="custom-tokens" href="https://example.net/" rel="me sponsored">custom tokens preserved</a>
</body>
</html>
EOF
cp "$MAIN_FIXTURE" "$TMP/main.html.orig"

RUN1_OUT="$("$SCRIPT" "$TMP" 2>&1)"
RUN1_RC=$?
check_eq "apply run: exit 0" "0" "$RUN1_RC"

# ---- classification: internal -> UNTOUCHED (exact byte match) -------------
for tid in no-attrs frag relative mailto tel ownhost; do
	before="$(tid_line "$TMP/main.html.orig" "$tid")"
	after="$(tid_line "$TMP/main.html" "$tid")"
	check_eq "internal untouched: data-tid=$tid" "$before" "$after"
done

# ---- non-anchor tag with an external URL -> UNTOUCHED ----------------------
LINK_BEFORE="$(grep -F '<link' "$TMP/main.html.orig")"
LINK_AFTER="$(grep -F '<link' "$TMP/main.html")"
check_eq "non-anchor <link> with external URL untouched" "$LINK_BEFORE" "$LINK_AFTER"
ARTICLE_BEFORE="$(tid_line "$TMP/main.html.orig" "article-tag")"
ARTICLE_AFTER="$(tid_line "$TMP/main.html" "article-tag")"
check_eq "non-anchor <article> untouched" "$ARTICLE_BEFORE" "$ARTICLE_AFTER"

# ---- external, bare -> gets target + rel union (with nofollow) ------------
EXT_BARE="$(tid_line "$TMP/main.html" "ext-bare")"
check_eq "external bare: target+rel applied" \
	'	<a data-tid="ext-bare" href="https://example.com/report" target="_blank" rel="nofollow noopener noreferrer">bare external</a>' \
	"$EXT_BARE"

# ---- allowlisted exact host (github.com) -> NO auto nofollow --------------
ALLOW_EXACT="$(tid_line "$TMP/main.html" "allow-exact")"
check_eq "allowlisted exact host: no nofollow" \
	'	<a data-tid="allow-exact" href="https://github.com/freedomyield/metal-validator" target="_blank" rel="noopener noreferrer">github exact allowlist</a>' \
	"$ALLOW_EXACT"

# ---- allowlisted subdomain (*.metalblockchain.org), existing rel ----------
ALLOW_SUB="$(tid_line "$TMP/main.html" "allow-subdomain")"
check_eq "allowlisted subdomain: existing rel unioned, no nofollow" \
	'	<a data-tid="allow-subdomain" href="https://explorer.metalblockchain.org/" rel="noopener noreferrer" target="_blank">allowlisted subdomain, existing rel</a>' \
	"$ALLOW_SUB"

# ---- substring lookalike (evilmetalblockchain.org) must NOT match the
# suffix allowlist entry for metalblockchain.org -> DOES get nofollow -------
ALLOW_LOOKALIKE="$(tid_line "$TMP/main.html" "allow-lookalike")"
check_eq "substring lookalike host is NOT exempt (gets nofollow)" \
	'	<a data-tid="allow-lookalike" href="https://evilmetalblockchain.org/" target="_blank" rel="nofollow noopener noreferrer">substring lookalike must NOT be exempt</a>' \
	"$ALLOW_LOOKALIKE"

# ---- existing rel="noopener noreferrer" non-allowlisted -> union adds
# nofollow, canonical order, no duplicates -----------------------------------
EXT_EXISTING="$(tid_line "$TMP/main.html" "ext-existing-rel")"
check_eq "non-allowlisted existing rel gains nofollow, canonical order" \
	'	<a data-tid="ext-existing-rel" href="https://example.org/" rel="nofollow noopener noreferrer" target="_blank">existing rel union</a>' \
	"$EXT_EXISTING"

# ---- protocol-relative href classified by host -----------------------------
PROTO_REL="$(tid_line "$TMP/main.html" "protocol-relative-allow")"
check_eq "protocol-relative href classified by host (allowlisted)" \
	'	<a data-tid="protocol-relative-allow" href="//explorer.metalblockchain.org/x" target="_blank" rel="noopener noreferrer">protocol-relative allowlisted</a>' \
	"$PROTO_REL"

# ---- author's custom rel tokens are NEVER dropped --------------------------
CUSTOM_TOKENS="$(tid_line "$TMP/main.html" "custom-tokens")"
check_eq "custom pre-existing rel tokens preserved after required ones" \
	'	<a data-tid="custom-tokens" href="https://example.net/" rel="nofollow noopener noreferrer me sponsored" target="_blank">custom tokens preserved</a>' \
	"$CUSTOM_TOKENS"

# ---- regression: an unquoted href ending in '/' right before the tag's
# closing '>' must NOT have its trailing '/' stolen as a false self-close
# marker (the naive "2nd-to-last char is '/'" check would truncate the
# href value here). This shape is not used anywhere in this repo's real
# public/ HTML (everything is double-quoted), but the tool must still get
# it right rather than silently corrupt a URL.
UNQUOTED_FIXTURE="$TMP/unquoted.html"
cat > "$UNQUOTED_FIXTURE" <<'EOF'
<a data-tid="unquoted-trailing-slash" href=https://example.com/>bare unquoted href</a>
EOF
"$SCRIPT" "$UNQUOTED_FIXTURE" >/dev/null 2>&1
UNQUOTED_RESULT="$(tid_line "$UNQUOTED_FIXTURE" "unquoted-trailing-slash")"
if echo "$UNQUOTED_RESULT" | grep -qF 'href=https://example.com/'; then
	pass "unquoted href trailing slash preserved (not stolen as self-close)"
else
	fail "unquoted href trailing slash was corrupted (got: $UNQUOTED_RESULT)"
fi
echo "$UNQUOTED_RESULT" | grep -q 'target="_blank"' \
	&& pass "unquoted-href tag still gets target=_blank applied" \
	|| fail "unquoted-href tag missing target=_blank (got: $UNQUOTED_RESULT)"

# ---- minimal diff: every byte OUTSIDE the touched <a> tags' rel/target
# attributes is unchanged. Cheapest strong proxy: strip all <a ...> start
# tags from both the pre- and post-run files and diff what remains — if
# that diff is empty, no other byte in the document moved.
strip_a_tags() {
	python3 - "$1" <<'PYEOF'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
# same tag-boundary heuristic as the tool under test, good enough for this
# fixture (no quoted '>' inside any test href).
print(re.sub(r"<a\b[^>]*>", "<A-TAG>", text, flags=re.IGNORECASE))
PYEOF
}
STRIPPED_BEFORE="$(strip_a_tags "$TMP/main.html.orig")"
STRIPPED_AFTER="$(strip_a_tags "$TMP/main.html")"
check_eq "minimal diff: all non-<a>-tag bytes identical" "$STRIPPED_BEFORE" "$STRIPPED_AFTER"

# ============================================================================
# Idempotency: a second run over the already-processed fixture must be a
# byte-identical no-op.
# ============================================================================
cp "$TMP/main.html" "$TMP/main.html.after-run1"
RUN2_OUT="$("$SCRIPT" "$TMP" 2>&1)"
RUN2_RC=$?
check_eq "second apply run: exit 0" "0" "$RUN2_RC"
if diff -q "$TMP/main.html.after-run1" "$TMP/main.html" >/dev/null 2>&1; then
	pass "idempotency: second run byte-identical to first"
else
	fail "idempotency: second run CHANGED bytes (diff below)"
	diff -u "$TMP/main.html.after-run1" "$TMP/main.html" >&2 || true
fi
echo "$RUN2_OUT" | grep -q '^OK: 0 file' \
	&& pass "idempotency: second run reports 0 files changed" \
	|| fail "idempotency: second run did not report 0 files changed (got: $RUN2_OUT)"

# ============================================================================
# --check mode
# ============================================================================

# compliant fixture -> exit 0, no offender output
COMPLIANT="$TMP/compliant.html"
cat > "$COMPLIANT" <<'EOF'
<!doctype html>
<body>
<a href="/internal/">internal</a>
<a href="https://example.com/" target="_blank" rel="nofollow noopener noreferrer">already compliant</a>
<a href="https://github.com/foo/bar" target="_blank" rel="noopener noreferrer">allowlisted compliant</a>
</body>
</html>
EOF
CHECK_COMPLIANT_OUT="$("$SCRIPT" --check "$COMPLIANT" 2>&1)"
CHECK_COMPLIANT_RC=$?
check_eq "--check on compliant fixture: exit 0" "0" "$CHECK_COMPLIANT_RC"
if [ -z "$(echo "$CHECK_COMPLIANT_OUT" | grep -F 'compliant.html:')" ]; then
	pass "--check on compliant fixture: no offender lines printed"
else
	fail "--check on compliant fixture: unexpectedly printed offender(s): $CHECK_COMPLIANT_OUT"
fi

# non-compliant fixture (bare external <a>) -> non-zero, names the offender
NONCOMPLIANT="$TMP/noncompliant.html"
cat > "$NONCOMPLIANT" <<'EOF'
<!doctype html>
<body>
<a href="/internal/">internal, fine</a>
<a href="https://example.com/bare">bare external, offender</a>
</body>
</html>
EOF
CHECK_BAD_OUT="$("$SCRIPT" --check "$NONCOMPLIANT" 2>&1)"
CHECK_BAD_RC=$?
if [ "$CHECK_BAD_RC" -ne 0 ]; then
	pass "--check on non-compliant fixture: exit non-zero (rc=$CHECK_BAD_RC)"
else
	fail "--check on non-compliant fixture: exit 0 (expected non-zero)"
fi
echo "$CHECK_BAD_OUT" | grep -q 'noncompliant.html:.*href="https://example.com/bare"' \
	&& pass "--check names the offending file + tag" \
	|| fail "--check did not name the offender (got: $CHECK_BAD_OUT)"
echo "$CHECK_BAD_OUT" | grep -qF 'href="/internal/"' \
	&& fail "--check must not flag the internal link as an offender" \
	|| pass "--check correctly omits the internal link"

# --check must not have written anything (bad fixture unchanged on disk)
NONCOMPLIANT_AFTER_CHECK="$(cat "$NONCOMPLIANT")"
NONCOMPLIANT_ORIG='<!doctype html>
<body>
<a href="/internal/">internal, fine</a>
<a href="https://example.com/bare">bare external, offender</a>
</body>
</html>'
check_eq "--check mode never writes to disk" "$NONCOMPLIANT_ORIG" "$NONCOMPLIANT_AFTER_CHECK"

# ---- summary ----------------------------------------------------------------
echo
echo "----------------------------------------"
echo "test-apply-external-link-attrs.sh summary: PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
	echo "RESULT: FAIL"
	exit 1
fi
echo "RESULT: PASS"
exit 0
