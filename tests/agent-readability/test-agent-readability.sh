#!/usr/bin/env bash
# tests/agent-readability/test-agent-readability.sh
#
# Invariant: the public site is readable by AI agents that act on a person's
# request and by AI search crawlers, and by nobody else; the machine-readable
# guides (llms.txt, openapi.json) agree with the files that are really
# published; CORS is scoped to the public data only.
#
# What it covers (every check function is also run against a mutant that
# breaks the property, and must fail on it — teeth are shown on every run):
#   R1  robots.txt, interpreted as RFC 9309 (group chosen case-insensitively,
#       `*` only when no group matches, longest match wins, Allow on a tie):
#       the six allowed bots may read the public paths and not the operator-only
#       paths; training crawlers, general search engines and unknown bots may
#       read nothing
#   R2  no User-agent appears twice (case-insensitive)
#   L1  llms.txt has the llmstxt.org shape
#   L2  every llms.txt URL maps to a tracked public/ file, a pushed feed, or a
#       directory page
#   L3  llms.txt does not list operator-only paths
#   O1  openapi.json is OpenAPI 3.1 and declares GET / HEAD only
#   O2  every relative $ref points at a tracked public/api/ file
#   O3  openapi.json paths == llms.txt "Data feeds" + "Verifying" URLs
#   C1  CORS: one Access-Control-Allow-Origin, scoped to /api/* and /llms.txt,
#       operator-only path excluded, GET / HEAD only
#   C2  X-Robots-Tag value unchanged
#   T1  no separation term (list kept outside the repo) in public/ or caddy/
#   P1  no IPv4 address and no e-mail address in llms.txt / openapi.json
#
# CHAIN: none. PRIME_DIRECTIVE: TESTNET-FIRST — safe.

set -uo pipefail
exec </dev/null

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
ROBOTS="$REPO/public/robots.txt"
LLMS="$REPO/public/llms.txt"
OPENAPI="$REPO/public/api/openapi.json"
CADDYFILE="$REPO/caddy/Caddyfile"
EXCLUDES="$REPO/deploy/feed-excludes.txt"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0; FAILURES=()
ok() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); FAILURES+=("$1 ($2)"); printf '  FAIL  %s  (%s)\n' "$1" "$2"; }

finish() {
  echo
  echo "PASS=$PASS FAIL=$FAIL"
  if [ "$FAIL" -ne 0 ]; then printf '  - %s\n' "${FAILURES[@]}"; exit 1; fi
  exit 0
}
report() {
  if [ -z "$2" ]; then ok "$1"
  else while IFS= read -r l; do bad "$1" "$l"; done <<<"$2"; fi
}
expect_caught() {
  if [ -n "$2" ]; then ok "mutant caught: $1"
  else bad "mutant NOT caught: $1" "check printed nothing"; fi
}

cd "$REPO" || exit 1
TRACKED="$TMP/tracked.txt"
git ls-files --cached --others --exclude-standard public caddy >"$TRACKED"

# --- R1: robots.txt as RFC 9309 ------------------------------------------------
check_robots_policy() {
  python3 -I - "$1" <<'PY'
import sys
groups = []          # list of (set(agents lowercase), [(allow_bool, path)])
cur_agents, cur_rules, in_rules = [], [], False
for raw in open(sys.argv[1], encoding='utf-8'):
    line = raw.split('#', 1)[0].strip()
    if not line:
        continue
    k, _, v = line.partition(':')
    k, v = k.strip().lower(), v.strip()
    if k == 'user-agent':
        if in_rules:
            groups.append((set(cur_agents), cur_rules)); cur_agents, cur_rules, in_rules = [], [], False
        cur_agents.append(v.lower())
    elif k in ('allow', 'disallow'):
        in_rules = True
        if v:
            cur_rules.append((k == 'allow', v))
if cur_agents:
    groups.append((set(cur_agents), cur_rules))

def allowed(ua, path):
    ua = ua.lower()
    rules = []
    for agents, r in groups:
        if ua in agents:
            rules += r
    if not rules:
        for agents, r in groups:
            if '*' in agents:
                rules += r
    best = None
    for a, p in rules:
        if path.startswith(p):
            key = (len(p), a)
            if best is None or key > best:
                best = key
    return True if best is None else best[1]

readers = ['ChatGPT-User', 'Claude-User', 'Perplexity-User', 'OAI-SearchBot', 'Claude-SearchBot', 'PerplexityBot']
ok_paths = ['/', '/api/validator.json', '/llms.txt']
no_paths = ['/status/', '/calendar/x.ics', '/api/server-status.json']
closed = ['GPTBot', 'ClaudeBot', 'CCBot', 'Google-Extended', 'Googlebot', 'Bingbot', 'SomeUnknownBot']
for b in readers:
    for ua in (b, b.lower()):
        for p in ok_paths:
            if not allowed(ua, p): print('%s must be allowed %s' % (ua, p))
        for p in no_paths:
            if allowed(ua, p): print('%s must be refused %s' % (ua, p))
for b in closed:
    if allowed(b, '/'): print('%s must be refused /' % b)
PY
}
echo "R1: robots.txt policy (RFC 9309 reading)"
report "R1 robots.txt: readers allowed (public paths only), everyone else closed" "$(check_robots_policy "$ROBOTS")"

sed '/^User-agent: Claude-User$/,/^$/ s|^Allow: /$|Disallow: /|' "$ROBOTS" >"$TMP/r1-m1.txt"
expect_caught "a request-time group turned back to Disallow: /" "$(check_robots_policy "$TMP/r1-m1.txt")"
sed '/^User-agent: GPTBot$/,/^$/ s|^Disallow: /$|Allow: /|' "$ROBOTS" >"$TMP/r1-m2.txt"
expect_caught "GPTBot (training) allowed" "$(check_robots_policy "$TMP/r1-m2.txt")"
sed '/^User-agent: \*$/,$ s|^Disallow: /$|Allow: /|' "$ROBOTS" >"$TMP/r1-m3.txt"
expect_caught "wildcard allowed" "$(check_robots_policy "$TMP/r1-m3.txt")"
sed '/^User-agent: PerplexityBot$/,/^$/ {/^Disallow: \/status\/$/d;}' "$ROBOTS" >"$TMP/r1-m4.txt"
expect_caught "/status/ exclusion dropped from one allowed group" "$(check_robots_policy "$TMP/r1-m4.txt")"

# --- R2: no duplicate User-agent -----------------------------------------------
check_robots_dups() {
  grep -i '^User-agent:' "$1" | sed -E 's/^[^:]*:[[:space:]]*//' | tr 'A-Z' 'a-z' | sort | uniq -d | sed 's/^/User-agent appears twice: /'
}
echo "R2: robots.txt has no duplicate User-agent"
report "R2 no duplicate User-agent (case-insensitive)" "$(check_robots_dups "$ROBOTS")"
{ cat "$ROBOTS"; printf '\nUser-agent: claude-user\nDisallow: /\n'; } >"$TMP/r2-m.txt"
expect_caught "duplicate group added (different case)" "$(check_robots_dups "$TMP/r2-m.txt")"

# --- L1: llms.txt shape ----------------------------------------------------------
check_llms_shape() {
  local f="$1" first second
  first="$(head -n 1 "$f")"
  second="$(grep -v '^[[:space:]]*$' "$f" | sed -n 2p)"
  case "$first" in '# '*) ;; *) echo "line 1 is not an H1";; esac
  case "$second" in '> '*) ;; *) echo "the first non-empty line after the H1 is not a blockquote summary";; esac
  grep -q '^## ' "$f" || echo "no ## section"
  grep -q '^## Optional$' "$f" || echo "no ## Optional section"
  grep -E '^- \[' "$f" | grep -v -E '^- \[[^]]+\]\(https://metal\.freedom-yield\.com/[^)]*\)(: .*)?$' | sed 's/^/malformed list item: /'
}
echo "L1: llms.txt shape"
report "L1 llms.txt has H1, summary, sections, well-formed links" "$(check_llms_shape "$LLMS")"
sed '1d' "$LLMS" >"$TMP/l1-m.txt"
expect_caught "H1 removed" "$(check_llms_shape "$TMP/l1-m.txt")"

# --- L2: every llms.txt URL is a real published thing ----------------------------
check_llms_urls() {
  local f="$1" u p
  grep -o -E '\]\(https://metal\.freedom-yield\.com/[^)]*\)' "$f" | sed -E 's/^\]\(https:\/\/metal\.freedom-yield\.com//; s/\)$//' | sort -u |
  while IFS= read -r u; do
    p="${u#/}"
    case "$u" in
      */) grep -qxF "public/${p}index.html" "$TRACKED" || echo "directory URL has no page: $u" ;;
      *) if grep -qxF "public/$p" "$TRACKED"; then :
         elif grep -qxF "$p" "$EXCLUDES"; then :
         else echo "URL maps to no tracked file and no pushed feed: $u"; fi ;;
    esac
  done
}
echo "L2: llms.txt URLs exist"
report "L2 every llms.txt URL is a tracked file, a pushed feed, or a directory page" "$(check_llms_urls "$LLMS")"
{ cat "$LLMS"; printf -- '- [nope](https://metal.freedom-yield.com/api/does-not-exist.json): x\n'; } >"$TMP/l2-m.txt"
expect_caught "non-existent file listed" "$(check_llms_urls "$TMP/l2-m.txt")"

# --- L3: no operator-only paths --------------------------------------------------
check_llms_private() {
  grep -n -E '/status/|/calendar/|server-status\.json|watch-status\.json' "$1" | sed 's/^/operator-only path listed: /'
}
echo "L3: llms.txt lists no operator-only path"
report "L3 no /status/, /calendar/, server-status.json, watch-status.json" "$(check_llms_private "$LLMS")"
{ cat "$LLMS"; printf -- '- [s](https://metal.freedom-yield.com/status/): x\n'; } >"$TMP/l3-m.txt"
expect_caught "/status/ added" "$(check_llms_private "$TMP/l3-m.txt")"

# --- O1: OpenAPI 3.1, GET / HEAD only --------------------------------------------
check_openapi_shape() {
  local f="$1"
  jq -e . "$f" >/dev/null 2>&1 || { echo "not valid JSON"; return 0; }
  jq -e '.openapi | startswith("3.1.")' "$f" >/dev/null 2>&1 || echo "openapi is not 3.1.x"
  jq -r '.paths | to_entries[] | .key as $p | .value | keys[] | select(. != "get" and . != "head") | "\($p): operation/key not allowed: \(.)"' "$f"
  jq -e '[.paths[] | has("get")] | all' "$f" >/dev/null 2>&1 || echo "a path has no get"
  jq -e 'has("security") | not' "$f" >/dev/null 2>&1 || echo "top-level security declared (the data needs no authentication)"
}
echo "O1: openapi.json shape"
report "O1 OpenAPI 3.1, GET / HEAD only" "$(check_openapi_shape "$OPENAPI")"
jq '.paths["/api/validator.json"].post = {"responses": {"200": {"description": "x"}}}' "$OPENAPI" >"$TMP/o1-m.json"
expect_caught "post operation added" "$(check_openapi_shape "$TMP/o1-m.json")"

# --- O2: relative $ref targets are tracked ---------------------------------------
check_openapi_refs() {
  jq -r '.. | objects | select(has("$ref")) | .["$ref"]' "$1" | sort -u |
  while IFS= read -r r; do
    case "$r" in
      ./*) grep -qxF "public/api/${r#./}" "$TRACKED" || echo "\$ref target not tracked: $r" ;;
      *) echo "\$ref is not relative: $r" ;;
    esac
  done
}
echo "O2: openapi.json refs"
report "O2 every \$ref points at a tracked public/api/ file" "$(check_openapi_refs "$OPENAPI")"
sed 's|validator.schema.v1.json|validator.schema.v9.json|' "$OPENAPI" >"$TMP/o2-m.json"
expect_caught "ref to a schema that does not exist" "$(check_openapi_refs "$TMP/o2-m.json")"

# --- O3: openapi paths == llms.txt feed + verify URLs ----------------------------
llms_paths() {
  awk '/^## /{s=($0=="## Data feeds"||$0=="## Verifying the identity manifest")} s' "$1" |
    grep -o -E '\]\(https://metal\.freedom-yield\.com/[^)]*\)' | sed -E 's/^\]\(https:\/\/metal\.freedom-yield\.com//; s/\)$//' | sort -u
}
check_paths_agree() {
  local llms="$1" api="$2"
  jq -r '.paths | keys[]' "$api" | sort -u >"$TMP/api-paths.txt"
  llms_paths "$llms" >"$TMP/llms-paths.txt"
  comm -23 "$TMP/llms-paths.txt" "$TMP/api-paths.txt" | sed 's/^/in llms.txt, missing from openapi.json: /'
  comm -13 "$TMP/llms-paths.txt" "$TMP/api-paths.txt" | sed 's/^/in openapi.json, missing from llms.txt: /'
}
echo "O3: openapi.json and llms.txt list the same files"
report "O3 same set of paths (Data feeds + Verifying)" "$(check_paths_agree "$LLMS" "$OPENAPI")"
jq '.paths["/api/extra.json"] = {"get": {"responses": {"200": {"description": "x"}}}}' "$OPENAPI" >"$TMP/o3-m.json"
expect_caught "path only in openapi.json" "$(check_paths_agree "$LLMS" "$TMP/o3-m.json")"
awk '{print} /^## Data feeds$/ {getline; print; print "- [x](https://metal.freedom-yield.com/api/extra.json): x"}' "$LLMS" >"$TMP/o3-m.txt"
expect_caught "path only in llms.txt" "$(check_paths_agree "$TMP/o3-m.txt" "$OPENAPI")"

# --- C1: CORS scoped ------------------------------------------------------------
check_cors() {
  local f="$1" n block
  n="$(grep -v -E '^[[:space:]]*#' "$f" | grep -i -c 'Access-Control-Allow-Origin')"
  [ "$n" = 1 ] || echo "Access-Control-Allow-Origin appears $n times (expected 1)"
  grep -v -E '^[[:space:]]*#' "$f" | grep -q -E '^[[:space:]]*header @cors_get Access-Control-Allow-Origin "\*"[[:space:]]*$' ||
    echo "no 'header @cors_get Access-Control-Allow-Origin \"*\"' line"
  block="$(awk '/^[[:space:]]*@cors_get \{/{b=1;next} b&&/^[[:space:]]*\}/{exit} b' "$f")"
  printf '%s\n' "$block" | grep -q -E '^[[:space:]]*path /api/\* /llms\.txt[[:space:]]*$' || echo "@cors_get path is not exactly '/api/* /llms.txt'"
  printf '%s\n' "$block" | grep -q -E '^[[:space:]]*not path /api/server-status\.json[[:space:]]*$' || echo "@cors_get lacks 'not path /api/server-status.json'"
  printf '%s\n' "$block" | grep -q -E '^[[:space:]]*method GET HEAD[[:space:]]*$' || echo "@cors_get lacks 'method GET HEAD'"
  n="$(printf '%s\n' "$block" | grep -v -E '^[[:space:]]*(#|$)' | wc -l | tr -d ' ')"
  [ "$n" = 3 ] || echo "@cors_get block has $n directive lines (expected exactly 3)"
  awk '/^[[:space:]]*header \{/{b=1;next} b&&/^[[:space:]]*\}/{b=0} b' "$f" | grep -i -q 'Access-Control' && echo "Access-Control header inside the global header block"
  grep -v -E '^[[:space:]]*#' "$f" | grep -E 'Access-Control-Allow-(Credentials|Methods)' | sed 's/^/must not be set: /'
}
echo "C1: CORS scope"
report "C1 one ACAO, scoped to /api/* and /llms.txt, GET / HEAD, operator path excluded" "$(check_cors "$CADDYFILE")"
awk '{print} /^\theader \{$/ && !d {print "\t\tAccess-Control-Allow-Origin \"*\""; d=1}' "$CADDYFILE" >"$TMP/c1-m1"
expect_caught "ACAO added to the global header block" "$(check_cors "$TMP/c1-m1")"
sed 's|^\t\tpath /api/\* /llms.txt$|\t\tpath /api/* /llms.txt /*|' "$CADDYFILE" >"$TMP/c1-m2"
expect_caught "/* added to the matcher" "$(check_cors "$TMP/c1-m2")"
sed '/^\t\tnot path \/api\/server-status.json$/d' "$CADDYFILE" >"$TMP/c1-m3"
expect_caught "'not path' line removed" "$(check_cors "$TMP/c1-m3")"
awk '{print} /^\theader \{$/ && !d {print "\t\taccess-control-allow-origin \"*\""; d=1}' "$CADDYFILE" >"$TMP/c1-m4"
expect_caught "lower-case ACAO added to the global header block" "$(check_cors "$TMP/c1-m4")"
awk '{print} /^\t@cors_get \{$/ && !d {print "\t\tpath /*"; d=1}' "$CADDYFILE" >"$TMP/c1-m5"
expect_caught "extra 'path /*' line inside @cors_get" "$(check_cors "$TMP/c1-m5")"

# --- C2: X-Robots-Tag unchanged --------------------------------------------------
check_xrobots() {
  grep -v -E '^[[:space:]]*#' "$1" | grep -q -E '^[[:space:]]*X-Robots-Tag "noindex, nofollow, noarchive, nosnippet"[[:space:]]*$' ||
    echo "X-Robots-Tag is not 'noindex, nofollow, noarchive, nosnippet'"
}
echo "C2: X-Robots-Tag"
report "C2 X-Robots-Tag value unchanged" "$(check_xrobots "$CADDYFILE")"
sed 's|X-Robots-Tag "noindex, nofollow, noarchive, nosnippet"|X-Robots-Tag "all"|' "$CADDYFILE" >"$TMP/c2-m"
expect_caught "X-Robots-Tag value changed" "$(check_xrobots "$TMP/c2-m")"

# --- T1: no separation term in public/ or caddy/ ---------------------------------
# The terms live OUTSIDE the repo (the repo is public and must not name them).
# List: $SEPARATION_TERMS_FILE, default $HOME/.config/metal-fy/separation-terms.txt
# (one term per line, '#' lines and blank lines ignored). If the list is
# missing or empty: under CI=true this check and its mutant are SKIPPED (not
# counted); locally it FAILS. The real gate is the full test run before push.
TERMS_FILE="${SEPARATION_TERMS_FILE:-$HOME/.config/metal-fy/separation-terms.txt}"
read_terms() { [ -f "$TERMS_FILE" ] && grep -v -E '^[[:space:]]*(#|$)' "$TERMS_FILE"; }
TERMS="$(read_terms || true)"
check_terms() {
  local list="$1" t f
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    while IFS= read -r f; do
      [ -f "$f" ] && grep -I -i -F -l -e "$t" "$f" | sed 's/^/separation term present in: /'
    done <"$list"
  done <<<"$TERMS"
}
echo "T1: no separation term in public/ or caddy/"
if [ -z "$TERMS" ]; then
  if [ "${CI:-}" = "true" ]; then
    echo "  SKIP  T1 separation-term list not available in CI"
    echo "  SKIP  T1 mutant (no term list)"
  else
    bad "T1 separation-term list missing or empty" "$TERMS_FILE"
  fi
else
  # The scanned set is public/, caddy/ and this test file itself (the terms are
  # read from outside the repo, so the file does not match itself).
  t1_files() { { cat "$TRACKED"; printf '%s\n' "$1"; } >"$2"; }
  t1_files "tests/agent-readability/test-agent-readability.sh" "$TMP/t1-files"
  report "T1 no separation term in public/, caddy/ or this test file" "$(check_terms "$TMP/t1-files")"
  printf 'a line with the first term: %s\n' "$(printf '%s\n' "$TERMS" | head -n 1)" >"$TMP/t1-m.txt"
  printf '%s\n' "$TMP/t1-m.txt" >"$TMP/t1-list"
  expect_caught "separation term present" "$(check_terms "$TMP/t1-list")"
  { cat "$0"; cat "$TMP/t1-m.txt"; } >"$TMP/t1-selfcopy.sh"
  t1_files "$TMP/t1-selfcopy.sh" "$TMP/t1-files-m"
  expect_caught "separation term in a copy of this test file (self is scanned)" "$(check_terms "$TMP/t1-files-m")"
fi

# --- Q1: documented rate limits match the Caddyfile ------------------------------
zone_events() { awk -v z="$2" '$1=="zone" && $2==z {b=1; next} b && $1=="events" {print $2; exit}' "$1"; }
check_ratelimit_docs() {
  local caddy="$1" llms="$2" en="$3" ja="$4" api glob a b c d
  api="$(zone_events "$caddy" api_json)"; glob="$(zone_events "$caddy" global)"
  [ -n "$api" ] && [ -n "$glob" ] || { echo "could not read zone events from the Caddyfile"; return 0; }
  a="$(grep -o -E 'for /api/\*: [0-9]+ requests per minute' "$llms" | grep -o -E '[0-9]+' | head -n 1)"
  b="$(grep -o -E 'site-wide: [0-9]+ per minute' "$llms" | grep -o -E '[0-9]+' | head -n 1)"
  c="$(tr -s ' \t\n' ' ' <"$en" | grep -o -E 'for /api/\*: [0-9]+ requests per minute' | grep -o -E '[0-9]+' | head -n 1)"
  d="$(tr -s ' \t\n' ' ' <"$ja" | grep -o -E '1 分 [0-9]+ 回' | grep -o -E '[0-9]+' | tail -n 1)"
  [ "$a" = "$api" ] || echo "llms.txt /api/* limit '$a' != Caddyfile '$api'"
  [ "$b" = "$glob" ] || echo "llms.txt site-wide limit '$b' != Caddyfile '$glob'"
  [ "$c" = "$api" ] || echo "data/index.html limit '$c' != Caddyfile '$api'"
  [ "$d" = "$api" ] || echo "ja/data/index.html limit '$d' != Caddyfile '$api'"
  grep -i -n -E 'no rate limit|rate limit はかけていません|明示的な rate limit' "$llms" "$en" "$ja" | sed 's/^/claims there is no rate limit: /'
}
echo "Q1: rate-limit statements"
report "Q1 llms.txt and data pages state the Caddyfile's limits; none says 'no rate limit'" \
  "$(check_ratelimit_docs "$CADDYFILE" "$LLMS" "$REPO/public/data/index.html" "$REPO/public/ja/data/index.html")"
awk '$1=="events" && $2==90 {sub(/90/,"91")} {print}' "$CADDYFILE" >"$TMP/q1-m1"
expect_caught "Caddyfile api limit changed" "$(check_ratelimit_docs "$TMP/q1-m1" "$LLMS" "$REPO/public/data/index.html" "$REPO/public/ja/data/index.html")"
{ cat "$LLMS"; printf 'There is no rate limit enforced.\n'; } >"$TMP/q1-m2.txt"
expect_caught "'no rate limit' claim added" "$(check_ratelimit_docs "$CADDYFILE" "$TMP/q1-m2.txt" "$REPO/public/data/index.html" "$REPO/public/ja/data/index.html")"

sed 's|rate limit はクライアントの IP ごとにかけています|明示的な rate limit はかけていません|' "$REPO/public/ja/data/index.html" >"$TMP/q1-m3.html"
expect_caught "old Japanese 'no rate limit' sentence restored in the ja page" "$(check_ratelimit_docs "$CADDYFILE" "$LLMS" "$REPO/public/data/index.html" "$TMP/q1-m3.html")"

# --- M1: .pub media type stated the same way in openapi.json and the data pages --
check_pub_types() {
  local api="$1" en="$2" ja="$3" want f
  want="$(jq -r '.paths["/.well-known/operator-identity.pub"].get.responses["200"].content | keys[0]' "$api")"
  [ -n "$want" ] && [ "$want" != null ] || { echo "openapi.json has no media type for the .pub path"; return 0; }
  for f in "$en" "$ja"; do
    # the two <dd> lines that mention a .pub link must name the same type and no other
    grep -E 'operator-identity(-mldsa87)?\.pub"><code>' "$f" | grep -v -F "$want" | sed "s|^|$(basename "$(dirname "$f")")/index.html: .pub line lacks $want: |" | cut -c1-120
    grep -E 'operator-identity(-mldsa87)?\.pub"><code>' "$f" | grep -E 'text/plain' | sed 's/^/.pub line still says text\/plain: /' | cut -c1-120
  done
}
echo "M1: .pub media type consistency"
report "M1 openapi.json and both data pages name the same .pub media type" \
  "$(check_pub_types "$OPENAPI" "$REPO/public/data/index.html" "$REPO/public/ja/data/index.html")"
sed 's|application/vnd.exstream-package|text/plain|' "$REPO/public/data/index.html" >"$TMP/m1-m.html"
expect_caught "data page copy says text/plain again" "$(check_pub_types "$OPENAPI" "$TMP/m1-m.html" "$REPO/public/ja/data/index.html")"

# --- P1: no IPv4 / e-mail in the new guides --------------------------------------
check_identifiers() {
  local f
  for f in "$@"; do
    grep -n -E '(^|[^0-9.])[0-9]{1,3}(\.[0-9]{1,3}){3}([^0-9.]|$)' "$f" | sed "s|^|IPv4 form in $(basename "$f"): |"
    grep -n -E '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+' "$f" | sed "s|^|e-mail form in $(basename "$f"): |"
  done
}
echo "P1: no host / operator identifiers"
report "P1 no IPv4 and no e-mail in llms.txt / openapi.json" "$(check_identifiers "$LLMS" "$OPENAPI")"
{ cat "$LLMS"; printf 'host 192.0.2.10\n'; } >"$TMP/p1-m1.txt"
expect_caught "IPv4 added" "$(check_identifiers "$TMP/p1-m1.txt")"
{ cat "$LLMS"; printf 'write to someone@example.org\n'; } >"$TMP/p1-m2.txt"
expect_caught "e-mail added" "$(check_identifiers "$TMP/p1-m2.txt")"

finish
