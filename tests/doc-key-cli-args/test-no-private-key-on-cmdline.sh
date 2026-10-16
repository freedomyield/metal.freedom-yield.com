#!/usr/bin/env bash
# test-no-private-key-on-cmdline.sh — in every tracked file, `proton key:add`
# and `proton key:remove` must take NO argument (only an optional trailing
# `# comment`, or a closing Markdown backtick right after the command name).
# Any argument — a key, a placeholder, $(...), backticks, a variable, even a
# public key — fails: an argument lands in shell history and in `ps`.
# proton-cli 0.1.98 prompts with hidden input when the argument is omitted
# (lib/commands/key/add.js:21-22, lib/commands/key/remove.js:13-14), and
# key:remove only accepts the private key itself (passwordManager.js:100-103,
# remove.js:24), so the argument-less form is always the one to document.
# CHAIN: none. PRIME_DIRECTIVE: TESTNET-FIRST — safe, no broadcast pathway.
set -u
REPO_SRC="$(cd "$(dirname "$0")/../.." && pwd)"
SELF_REL="tests/doc-key-cli-args/test-no-private-key-on-cmdline.sh"
PASS=0; FAIL=0
pass() { printf 'PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf 'FAIL  %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }

# Whitespace after the command name followed by anything but `#` is an
# argument. A backtick directly after the name (no space) closes inline code.
RE='proton[[:space:]]+key:(add|remove)[[:space:]]+[^[:space:]#]'

# Key-shaped fixtures are built at run time so no key-looking literal is
# committed (secret scanners would rightly flag one).
FAKE_PVT="PVT_K1_$(printf 'x%.0s' $(seq 1 50))"
FAKE_WIF="5K$(printf '1%.0s' $(seq 1 49))"
BT='`'

# --- self-check: every argument shape is caught, every no-argument form passes ---
P='HOME=~/.metal-fy-proton proton'
for line in \
	"HOME=~/.metal-fy-proton-test proton key:add <frdomyieltst active/owner PVT>" \
	"$P key:remove <old PVT>" \
	"$P key:add ${FAKE_PVT}" \
	"$P key:add ${FAKE_WIF}" \
	"$P key:add \$(cat f)" \
	"$P key:add \\\$(sudo cat /etc/freedom-yield/anchor.k1.key)" \
	"$P key:add ${BT}cat f${BT}" \
	"$P key:add \"\$KEY\"" \
	"$P  key:add \${PRIVATE_KEY}" \
	"$P key:remove PUB_K1_x" \
	"# 5. Re-execute B4 (HOME=~/.metal-fy-proton proton key:add for the new key)."; do
	printf '%s\n' "$line" | grep -qE -- "$RE" && pass "S1 caught: $line" || bad "MUTATION NOT CAUGHT: $line"
done
for line in \
	"$P key:add" \
	"$P key:add   # prompt に NEW active PVT を貼る" \
	"$P key:remove" \
	"$P key:list" \
	"When ${BT}proton key:add${BT} (B4) runs for the first time" \
	"  HOME=~/.metal-fy-proton proton key:add   " ; do
	printf '%s\n' "$line" | grep -qE -- "$RE" && bad "FALSE POSITIVE: $line" || pass "S2 allowed: $line"
done

# --- the repo: every tracked file except this one ---
cd "$REPO_SRC" || { bad "cd $REPO_SRC"; echo "RESULT: FAIL"; exit 1; }
FILES="$(git ls-files 2>/dev/null)"
[ -n "$FILES" ] || { bad "git ls-files returned nothing"; echo "RESULT: FAIL"; exit 1; }
hits="$(printf '%s\n' "$FILES" | grep -vxF "$SELF_REL" | tr '\n' '\0' |
	xargs -0 grep -InE -- "$RE" 2>/dev/null)"
if [ -z "$hits" ]; then
	pass "R1 no tracked file passes an argument to proton key:add/key:remove"
else
	bad "R1 argument to proton key:add/key:remove (omit it; paste at the hidden prompt):"
	printf '%s\n' "$hits" >&2
fi

echo "test-no-private-key-on-cmdline summary: passed=$PASS failed=$FAIL"
if [ "$FAIL" -eq 0 ]; then echo "RESULT: PASS"; else echo "RESULT: FAIL"; exit 1; fi
