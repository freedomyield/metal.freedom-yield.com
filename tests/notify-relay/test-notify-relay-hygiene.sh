#!/usr/bin/env bash
# tests/notify-relay/test-notify-relay-hygiene.sh — mechanical gates for the notify-relay bundle (P5).
# Gates: no AI-call stage / no token literal / path strings only on definition lines / diff is new files only.
# CHAIN: none.
# PRIME_DIRECTIVE: TESTNET-FIRST — safe. Read-only on the repo; mutation runs on a temp copy.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
PATTERNS_REL="tests/notify-relay/fixtures/no-ai.patterns.json"
PATTERNS_PATH="${HYGIENE_PATTERNS_OVERRIDE:-$REPO_ROOT/$PATTERNS_REL}"
PATTERNS_SHA256="8c03079e6752b816149b467257dd527c34aa0022a235eaf6e385846937a3c53f"
BASE_REF="main"
# The four bundle files (single definition point).
BUNDLE_FILES="scripts/notify-relay-put.sh scripts/lib/notify-text.sh scripts/install-notify-relay.sh scripts/operator-local/make-notify-relay-token.sh"
MUTATION_TARGET_REL="scripts/notify-relay-put.sh"
# Files the bundle may touch (diff gate). Exact paths or directory prefixes ending in "/".
ALLOWED_PATHS="docs/superpowers/plans/2026-11-24-notify-relay-put.md docs/superpowers/specs/2026-11-24-notify-signal-relay-design.md $BUNDLE_FILES tests/notify-relay/"
TOKEN_RE='[A-Za-z0-9_-]{43}'
TOKEN_EXEMPT_REL="$PATTERNS_REL"
PATH_RE="['\"](/|\./|\.\./)[A-Za-z]"

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); echo "ok   - $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL - $1"; }
skip() { echo "SKIP - $1"; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else fail "$1 (expected [$2] got [$3])"; fi; }

TMP_ROOT="$(mktemp -d "$REPO_ROOT/.hygiene-test.XXXXXX")"
trap 'rm -rf "${TMP_ROOT:?}"' EXIT

escape_ere() { printf '%s' "$1" | sed 's/[][\.*^$+?(){}|/-]/\\&/g'; }

# stdin matches (ASCII case-insensitive substring; boundary "word" needs non-word neighbours)
text_hits_stdin() {
  local text=$1 boundary=$2 esc
  esc="$(escape_ere "$text")"
  if [ "$boundary" = "word" ]; then
    LC_ALL=C grep -qiE "(^|[^A-Za-z0-9_])${esc}([^A-Za-z0-9_]|\$)"
  else
    LC_ALL=C grep -qiE -- "$esc"
  fi
}

# prints "id" for each pattern that hits file $1; returns 0 always
scan_file_for_ai() {
  local file=$1 id text boundary
  while IFS=$'\t' read -r id text boundary; do
    if text_hits_stdin "$text" "$boundary" < "$file"; then echo "$id"; fi
  done < <(jq -r '.patterns[] | [.id, .text, .boundary] | @tsv' "$PATTERNS_PATH")
}

# 1. fixture identity
actual_sha="$(shasum -a 256 "$PATTERNS_PATH" | cut -d' ' -f1)"
eq "patterns fixture sha256 matches the shared copy" "$PATTERNS_SHA256" "$actual_sha"

# 3. the matcher itself: each hit matches, each miss does not
bad=0
while IFS=$'\t' read -r id text boundary hit miss; do
  printf '%s\n' "$hit" | text_hits_stdin "$text" "$boundary" || { echo "  hit not matched: $id"; bad=$((bad + 1)); }
  if printf '%s\n' "$miss" | text_hits_stdin "$text" "$boundary"; then echo "  miss matched: $id"; bad=$((bad + 1)); fi
done < <(jq -r '.patterns[] | [.id, .text, .boundary, .hit, .miss] | @tsv' "$PATTERNS_PATH")
n_pat="$(jq '.patterns | length' "$PATTERNS_PATH")"
eq "matcher agrees with every pattern's hit/miss ($n_pat patterns)" "0" "$bad"

# 2. no AI-call stage in the bundle files
missing=0; ai_hits=""
for rel in $BUNDLE_FILES; do
  if [ ! -f "$REPO_ROOT/$rel" ]; then echo "  missing: $rel"; missing=$((missing + 1)); continue; fi
  h="$(scan_file_for_ai "$REPO_ROOT/$rel" | tr '\n' ' ')"
  [ -n "$h" ] && ai_hits="$ai_hits $rel:[$h]"
done
eq "all bundle files exist" "0" "$missing"
eq "no AI-call pattern in bundle files" "" "${ai_hits# }"

# 4. break to prove: a key-read line added to a temp copy of P1 must be caught
cp "$REPO_ROOT/$MUTATION_TARGET_REL" "$TMP_ROOT/mutant.sh"
# shellcheck disable=SC2016
printf 'k=${ANTHROPIC_API_KEY:-}\n' >> "$TMP_ROOT/mutant.sh"
mut_hits="$(scan_file_for_ai "$TMP_ROOT/mutant.sh" | tr '\n' ' ')"
if [ -n "$mut_hits" ]; then ok "mutant (API key read added to a copy of P1) is caught: $mut_hits"; else fail "mutant not caught"; fi

# 5. no 43-char token-shaped run in bundle files or tests/notify-relay (fixture exempt)
tok_files=""
for rel in $BUNDLE_FILES; do
  [ -f "$REPO_ROOT/$rel" ] || continue
  LC_ALL=C grep -qE "(^|[^A-Za-z0-9_-])${TOKEN_RE}([^A-Za-z0-9_-]|\$)" "$REPO_ROOT/$rel" && tok_files="$tok_files $rel"
done
while IFS= read -r f; do
  [ "$f" = "$REPO_ROOT/$TOKEN_EXEMPT_REL" ] && continue
  LC_ALL=C grep -qE "(^|[^A-Za-z0-9_-])${TOKEN_RE}([^A-Za-z0-9_-]|\$)" "$f" && tok_files="$tok_files ${f#"$REPO_ROOT"/}"
done < <(find "$REPO_ROOT/tests/notify-relay" -type f)
eq "no 43-char token-shaped literal" "" "${tok_files# }"

# 6. path strings only on definition lines (^[A-Z_]+=)
path_bad=""
for rel in $BUNDLE_FILES; do
  [ -f "$REPO_ROOT/$rel" ] || continue
  n="$(LC_ALL=C grep -nE "$PATH_RE" "$REPO_ROOT/$rel" | grep -cvE '^[0-9]+:[A-Z_]+=')"
  [ "$n" != "0" ] && path_bad="$path_bad $rel($n)"
done
eq "path strings appear only on definition lines" "" "${path_bad# }"

# 7. diff gate: only added (A) or modified (M) files, only allowed paths
if git -C "$REPO_ROOT" rev-parse --verify -q "$BASE_REF" >/dev/null \
   && base="$(git -C "$REPO_ROOT" merge-base "$BASE_REF" HEAD 2>/dev/null)" && [ -n "$base" ]; then
  diff_bad=""
  while IFS=$'\t' read -r status path rest; do
    [ -z "$status" ] && continue
    allowed=0
    for a in $ALLOWED_PATHS; do
      case "$a" in */) case "$path" in "$a"*) allowed=1 ;; esac ;; *) [ "$path" = "$a" ] && allowed=1 ;; esac
    done
    if { [ "$status" != "A" ] && [ "$status" != "M" ]; } || [ "$allowed" != "1" ] || [ -n "$rest" ]; then diff_bad="$diff_bad $status:$path"; fi
  done < <(git -C "$REPO_ROOT" diff --name-status "$base" HEAD)
  eq "diff vs $BASE_REF touches only allowed bundle paths (A or M)" "" "${diff_bad# }"
else
  skip "diff gate: $BASE_REF or merge-base unavailable"
fi

echo "---"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
