#!/usr/bin/env bash
# publish-guard.sh — prevent forbidden host identifiers AND operator PII from
# being published (committed / pushed / written into a tracked file).
#
# WHY: on 2026-07-03 a real validator host IP + the operator handle were
# committed into a public-tracked file (docs/audits/constitution-
# 2026-07-03T16-33-audit.md documents the leak). gitleaks did not catch it
# (it scans key/token secrets, not host IPs, handles, names, phones, emails).
# This guard is the missing host-identifier + PII layer, wired at three points
# (Claude PreToolUse, git pre-commit, git pre-push) for defense in depth.
#
# WHAT IT BLOCKS:
#   A.  real public IPv4 literal (RFC5737 doc / RFC1918 / loopback / link-local
#       / CGNAT / multicast are ALLOWED).
#   A2. real public IPv6 literal (2001:db8::/32 doc / fc00::/7 unique-local /
#       fe80::/10 link-local / ::1 loopback / :: unspecified / ff00::/8
#       multicast are ALLOWED — analogous to the IPv4 exclusions above).
#   A3. Japanese phone-number literal (mobile 070/080/090, ± separators).
#   A4. personal email literal (any domain NOT in the allowlist below).
#   B.  forbidden ASCII word-literals (operator handle, surname, company slug,
#       validator SSH key name) matched by sha256(lowercased token).
#   C.  forbidden non-ASCII (CJK) literals (operator real name, company name in
#       kana) matched by sha256(raw UTF-8 bytes).
#   D.  optional local .publish-denylist (gitignored) of exact substrings —
#       the robust layer for values embedded in longer prose (CJK especially).
#
# The raw forbidden words / name / emails / phone / IP are INTENTIONALLY ABSENT
# from this tracked file — only sha256 hashes and generic patterns appear — so
# this guard does not itself leak what it protects.
#
# MODES:
#   1. Claude Code PreToolUse hook (default; stdin = tool JSON):
#        Write/Edit/MultiEdit -> scan content bound for a PUBLISHABLE
#          (in-repo, non-gitignored) file; ignored/out-of-repo paths skipped.
#        Bash -> refuse `git commit|push --no-verify|-n` (hook-bypass); else allow.
#        other tools -> allow.
#   2. git hook:  publish-guard.sh --diff   (stdin = git diff; scans + lines)
#   3. raw text:  publish-guard.sh --text    (stdin = text; scans everything)
#
# EXIT: 0 = allow/clean. Block is MODE-AWARE (fail-closed, stderr shown):
#   hook mode          -> exit 2 (Claude Code PreToolUse blocks ONLY on 2;
#                         any other non-zero is a non-blocking warning)
#   --diff / --text    -> exit 1 (git hook convention)
#
# Refs: memory/feedback_no_literal_host_identifier.md,
#       memory/feedback_no_operator_name.md, memory/feedback_no_personal_finance.md,
#       docs/CONSTITUTION.md §4.1 S8.

set -u

# sha256(lowercased) of forbidden ASCII word-literals. Raw words NOT present.
# Overridable for tests via FYD_PUBLISH_WORD_HASHES.
WORD_HASHES="${FYD_PUBLISH_WORD_HASHES:-f2af0a6dbe5973c0a15cbcabb9d71b020a5065d2910c107bc07200fd57bedfd8,6b63988f732f4ac10ef4c0595464238abc3b61db8fe9621eee9564d0d19750eb,ec81007f8a9941a1bfcd0718c93e5d95042483a064abfe4fddbee870d5d1c7f4,afc9728fa107a6bfd5a850aa925c1eceeb6d10ef6c53b84dd765eb24ffec621f,294aa8d75483b8331e3ba6a7f24aea15202747f36de65197e7bc6194880b2558}"
# sha256(raw UTF-8 bytes) of forbidden non-ASCII (CJK) literals. Overridable via FYD_PUBLISH_CJK_HASHES.
CJK_HASHES="${FYD_PUBLISH_CJK_HASHES:-00bb0a1ec63ccbc0348e1afd6c70153b9a5c531fe2341019addbe46b186acb9c,008dbb256d8722dbe73317ddf8c5a5b910d64d3709fa13f48c482505e42e6601}"

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
DENYLIST_FILE="${FYD_PUBLISH_DENYLIST:-$REPO_ROOT/.publish-denylist}"

MODE="hook"
case "${1:-}" in
	--diff) MODE="diff" ;;
	--text) MODE="text" ;;
esac

SCAN_TEXT=""
CTX=""

# Claude Code PreToolUse blocks ONLY on exit 2 (any other non-zero exit is a
# non-blocking warning and the tool call proceeds). git hooks conventionally
# treat exit 1 as failure. Pick the blocking exit per mode.
if [ "$MODE" = "hook" ]; then BLOCK_EXIT=2; else BLOCK_EXIT=1; fi

if [ "$MODE" = "diff" ]; then
	SCAN_TEXT="$(grep -E '^\+' | grep -vE '^\+\+\+' | sed 's/^+//' || true)"
	CTX="git diff (added lines)"
elif [ "$MODE" = "text" ]; then
	SCAN_TEXT="$(cat)"
	CTX="text"
else
	INPUT="$(cat)"
	if ! command -v jq >/dev/null 2>&1; then
		printf 'publish-guard: jq not found; cannot parse tool input; failing closed.\n' >&2
		exit "$BLOCK_EXIT"
	fi
	TOOL="$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)"
	FP=""
	case "$TOOL" in
		Write)
			FP="$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)"
			SCAN_TEXT="$(printf '%s' "$INPUT" | jq -r '.tool_input.content // empty' 2>/dev/null)"
			CTX="Write $FP" ;;
		Edit)
			FP="$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)"
			SCAN_TEXT="$(printf '%s' "$INPUT" | jq -r '.tool_input.new_string // empty' 2>/dev/null)"
			CTX="Edit $FP" ;;
		MultiEdit)
			FP="$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)"
			SCAN_TEXT="$(printf '%s' "$INPUT" | jq -r '[.tool_input.edits[]?.new_string] | join("\n")' 2>/dev/null)"
			CTX="MultiEdit $FP" ;;
		Bash)
			CMD="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)"
			# Detect `git commit|push --no-verify` / `-n` as an ACTUAL flag on the
			# command line (a hook-bypass attempt).
			#
			# DESIGN (round 4, 2026-08-06). Three previous attempts failed the same
			# way, so the MECHANISM that produced the failures is removed rather
			# than tuned once more:
			#
			#   r1  tokenized the command (Text::ParseWords) and scanned the TOKENS
			#       INSTEAD of the raw text. Six real bypasses opened, because a
			#       static tokenizer does not perform shell EXPANSION:
			#       $'--no-verify' (ANSI-C quoting), F=--no-verify; ... $F,
			#       $(echo --no-verify), `echo --no-verify`, ${Q:---no-verify}, and a
			#       backslash-newline continuation. A real shell turns each into the
			#       literal flag at execution time; the tokenizer resolved none.
			#   r2  went back to a substring scan but first DELETED the value spans
			#       of message-carrying options. Deleting text can delete the
			#       payload: the value branch ate the NEXT, genuine token
			#       (`git commit -m x file-c --no-verify`) as a bogus "value".
			#   r3  refined the deletion rules. Two more deletion-shaped bypasses
			#       appeared (`git commit '-sm' x --no-verify 'y'`,
			#       `git commit -nm --no-verify`).
			#
			# Root cause: SPAN DELETION combined with FLAG-OWNERSHIP INFERENCE. Any
			# rule that decides "these bytes are option X's value, drop them" can be
			# steered into dropping a real flag instead, so every new rule creates a
			# new way to hide the payload -- the reason three rounds did not
			# converge. Round 4 removes both. Nothing is deleted and no option
			# ownership is inferred; the checks below are pure ORs, so each one can
			# only ever turn ALLOW into BLOCK, never the reverse.
			#
			#   G.  Is this a `git commit` / `git push` invocation at all? Decided on
			#       the RAW text, never on a transformed copy -- deciding it on a
			#       masked/stripped copy would let `eval "git commit --no-verify"`
			#       hide the subcommand and skip the entire check. Global options
			#       (-C <dir>, -c k=v, --no-pager) are allowed between `git` and the
			#       subcommand: without that, `git -C /path commit --no-verify` was
			#       never even examined (a hole present since the original version).
			#   P1. Literal "--no-verify" anywhere in the RAW text. This is the
			#       original pre-r1 check, byte for byte, and it alone covers all six
			#       r1 forms: every one of them still carries the literal characters
			#       in the unexecuted command text. It is never masked, so no
			#       transformation can lose it. A commit message that merely mentions
			#       "--no-verify" therefore still blocks; that is deliberate and
			#       unchanged (use `git commit -F <file>`), and it is NOT the false
			#       positive this work was asked to fix.
			#   P2. A short-option cluster containing "n" (-n, -an, -nm, -nam) in the
			#       QUOTE-MASKED text. Masking is purely lexical: scan left to right
			#       and replace the CONTENTS of each CLOSED quoted region with a
			#       placeholder. This is the whole fix for the reported false
			#       positive (a commit message mentioning "bash -n"), and unlike
			#       deletion it cannot lose a payload: each quoted region is decided
			#       by the quoting itself, not by guessing which option it belongs
			#       to, and text outside quotes is never touched. Contents that are
			#       EXACTLY a flag are kept (so a deliberately quoted '-n' is still
			#       caught); an unbalanced quote falls back to the raw text.
			#   P3. Exact-token match over Text::ParseWords::shellwords. ADDITIVE --
			#       never a replacement for P1/P2. The tokenizer is the only one of
			#       the three that resolves split-quote concatenation (--no-ver"ify",
			#       -'n', --no-ver\ify); P1/P2 are the only ones that survive shell
			#       expansion. Neither is complete alone, so both run. Because it is
			#       OR-ed in (r1 REPLACED the substring scan with it), it cannot
			#       reintroduce the r1 regression.
			#
			# Fail-closed on tool failure. The trust signal is the EXACT literal
			# stdout text "BLOCK" or "ALLOW" printed by the perl script below --
			# not its exit code. An exit code alone is NOT a safe signal here: a
			# broken/absent perl (or any other malfunction) could easily exit 0
			# or 1 by coincidence with no real detection logic having run at
			# all, and 0/1 are exactly the two codes this check would otherwise
			# treat as legitimate decisions -- silently swallowing a real
			# bypass. Requiring the precise marker string means any malfunction
			# (missing perl -> no output at all, a crash, a truncated run, a
			# stray warning polluting stdout) fails the exact-match and falls
			# through to the ORIGINAL raw substring scan below, i.e. it
			# degrades to exactly the pre-existing (already safe) behavior,
			# never to "allow".
			BASH_BLOCK=0
			if [ -n "$CMD" ]; then
				DECISION="$(printf '%s' "$CMD" | perl -0777 -ne '
					my $cmd = $_;
					# A short-option cluster containing "n": a bare -n, or -n
					# bundled with other boolean short options (-an, -nm, -nam).
					my $NC = qr/-[A-Za-z]*n[A-Za-z]*/;
					# G. RAW text only (see header). No left word-boundary on
					# "git" -- deliberately, because the original check had none
					# either and adding one made a quoted
					# `eval "git commit --no-verify"` stop matching (round-4
					# self-test X1: a regression this file must not ship).
					my $has_gitcmd = ($cmd =~ /git(?:\s+-\S*(?:\s+[^-\s]\S*)?){0,5}\s+(?:commit|push)(?![\w-])/) ? 1 : 0;
					# P1. Raw literal long flag. Never masked, never stripped.
					my $flag = ($cmd =~ /--no-verify/) ? 1 : 0;
					# P2. Quote-masked short-option cluster.
					if (!$flag) {
						my $s = $cmd; my $out = q{}; my $balanced = 1;
						pos($s) = 0;
						while (pos($s) < length($s)) {
							# Runs of ordinary characters pass through untouched.
							if ($s =~ /\G([^\x27"\\]+)/gcs) { $out .= $1; next; }
							# A backslash escape outside quotes takes its next
							# character with it (covers \\ and line continuations).
							if ($s =~ /\G(\\.?)/gcs)        { $out .= $1; next; }
							my $c;
							if    ($s =~ /\G\x27([^\x27]*)\x27/gcs)  { $c = $1; }
							elsif ($s =~ /\G"((?:[^"\\]|\\.)*)"/gcs) { $c = $1; }
							else  { $balanced = 0; last; }
							# Space-padded so masking can neither create nor destroy
							# a word boundary for the scan below.
							$out .= ($c eq q{--no-verify} || $c =~ /\A$NC\z/) ? qq{ $c } : qq{ \x01 };
						}
						my $scan = $balanced ? $out : $cmd;
						# Left boundary: start / whitespace / backslash (so an
						# escaped \-n is not read as mid-word). Right boundary: not
						# alphanumeric, so a bundled -nm"msg" is caught while an
						# attached numeric argument (-n1, `tail -n20`) is not.
						$flag = 1 if $scan =~ /(?<![^\s\\])$NC(?![A-Za-z0-9])/;
					}
					# P3. Additive exact-token check (split-quote concatenation).
					if (!$flag) {
						my @w = eval {
							local $SIG{__WARN__} = sub {};
							require Text::ParseWords;
							Text::ParseWords::shellwords($cmd);
						};
						if (!$@) {
							for my $t (@w) {
								next unless defined $t;
								if ($t eq q{--no-verify} || $t =~ /\A$NC\z/) { $flag = 1; last; }
							}
						}
					}
					print(($has_gitcmd && $flag) ? "BLOCK" : "ALLOW");
				' 2>/dev/null)"
				case "$DECISION" in
					BLOCK) BASH_BLOCK=1 ;;
					ALLOW) : ;;
					*)
						if printf '%s' "$CMD" | grep -qE 'git[[:space:]]+(commit|push)([[:space:]]|$)' \
							&& printf '%s' "$CMD" | grep -qE '(--no-verify|[[:space:]]-n([[:space:]]|$))'; then
							BASH_BLOCK=1
						fi
						;;
				esac
			fi
			if [ "$BASH_BLOCK" -eq 1 ]; then
				cat >&2 <<'EOF'
=== PUBLISH_GUARD_BLOCK ===
`git commit|push --no-verify` (or -n) is refused: it would skip the
pre-commit/pre-push hooks that block host IP / handle / name / phone / email
from being published. Re-run WITHOUT --no-verify.
EOF
				exit "$BLOCK_EXIT"
			fi
			exit 0 ;;
		*)
			exit 0 ;;
	esac

	if [ -n "$FP" ]; then
		case "$FP" in
			"$REPO_ROOT"/*) : ;;
			/*) exit 0 ;;
		esac
		if git -C "$REPO_ROOT" check-ignore -q "$FP" 2>/dev/null; then exit 0; fi
		if [ "$FP" = "$DENYLIST_FILE" ]; then exit 0; fi
	fi
fi

[ -z "$SCAN_TEXT" ] && exit 0

# ---- core scan (A: IPv4, A2: IPv6, A3: phone, A4: email, B: word hash, C: CJK hash) ----
FINDINGS="$(
	printf '%s' "$SCAN_TEXT" | WORDH="$WORD_HASHES" CJKH="$CJK_HASHES" \
	perl -MDigest::SHA=sha256_hex -0777 -ne '
		my %wh = map { $_ => 1 } grep { length } split /,/, ($ENV{WORDH} // "");
		my %ch = map { $_ => 1 } grep { length } split /,/, ($ENV{CJKH}  // "");
		my @hits;
		# A. public IPv4 literals
		while (/(?<![\d.])(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})(?![\d.])/g) {
			my @o = ($1,$2,$3,$4); next if grep { $_ > 255 } @o;
			my ($a,$b,$c) = @o;
			next if $a==0 || $a==10 || $a==127;
			next if $a==172 && $b>=16 && $b<=31;
			next if $a==192 && $b==168;
			next if $a==169 && $b==254;
			next if $a==100 && $b>=64 && $b<=127;
			next if $a==192 && $b==0 && $c==2;
			next if $a==198 && $b==51 && $c==100;
			next if $a==203 && $b==0 && $c==113;
			next if $a>=224;
			push @hits, "public-IPv4 literal ($a.$b.x.x)";
		}
		# A2. public IPv6 literals. Candidate shapes are the standard compressed
		# and uncompressed forms (adapted from the widely-used RFC4291 regex);
		# excluded ranges mirror the IPv4 exclusions above:
		#   ::1        loopback         (cf. IPv4 127.0.0.0/8)
		#   ::         unspecified      (cf. IPv4 0.0.0.0)
		#   fc00::/7   unique-local     (cf. IPv4 RFC1918 private)
		#   fe80::/10  link-local       (cf. IPv4 169.254.0.0/16)
		#   2001:db8::/32 documentation (cf. IPv4 RFC5737 doc)
		#   ff00::/8   multicast        (cf. IPv4 >=224 multicast)
		while (/(?<![0-9A-Fa-f:])((?:[0-9A-Fa-f]{1,4}:){7}[0-9A-Fa-f]{1,4}|(?:[0-9A-Fa-f]{1,4}:){1,7}:|(?:[0-9A-Fa-f]{1,4}:){1,6}:[0-9A-Fa-f]{1,4}|(?:[0-9A-Fa-f]{1,4}:){1,5}(?::[0-9A-Fa-f]{1,4}){1,2}|(?:[0-9A-Fa-f]{1,4}:){1,4}(?::[0-9A-Fa-f]{1,4}){1,3}|(?:[0-9A-Fa-f]{1,4}:){1,3}(?::[0-9A-Fa-f]{1,4}){1,4}|(?:[0-9A-Fa-f]{1,4}:){1,2}(?::[0-9A-Fa-f]{1,4}){1,5}|[0-9A-Fa-f]{1,4}:(?::[0-9A-Fa-f]{1,4}){1,6}|:(?::[0-9A-Fa-f]{1,4}){1,7})(?![0-9A-Fa-f:])/g) {
			my $addr = lc $1;
			next if $addr eq "::1" || $addr eq "::";
			# Minimum-specificity gate: a real routable/assigned IPv6 literal
			# is written with at least one FULL 16-bit hextet (4 hex digits in
			# one unbroken colon-delimited segment) -- global-unicast prefixes
			# (2xxx/3xxx) are always written that way. Below that, the "::"-
			# compressed shape matches ubiquitous non-IP syntax too eagerly:
			# CSS pseudo-elements/classes (`::before`, `pre::-webkit-
			# scrollbar`), C++/Rust/Ruby namespace separators (`std::vector`,
			# `Foo::Bar`), and generic `a::b` code all parse as syntactically-
			# valid (if absurdly minimal) IPv6 shorthand.
			#
			# A same-total-digit-count gate (">=4 digits summed across all
			# segments") is NOT enough here: `h3::before` / `.status-
			# badge::before` / `.commitment-card::before` (real selectors)
			# each combine one short leading hex fragment (e.g. the "3" off
			# "h3", or the "e" off "badge") with the "bef" that "before"
			# happens to start with (b/e/f are all valid hex letters) and land
			# at EXACTLY 4 total digits split across two short segments,
			# passing a total-count gate while still not being an address.
			# Requiring one segment to independently reach the full 4 digits
			# closes that: no real host address is written any other way, and
			# no incidental code/CSS collision plausibly produces one unbroken
			# 4-hex-char run immediately adjacent to "::".
			my @hx = grep { length } split /:/, $addr;
			next unless grep { length($_) == 4 } @hx;
			my ($first) = $addr =~ /^([0-9a-f]{1,4})/;
			my $f = defined($first) ? hex($first) : 0;
			next if ($f & 0xffc0) == 0xfe80;   # fe80::/10 link-local
			next if ($f & 0xfe00) == 0xfc00;   # fc00::/7 unique-local
			next if ($f & 0xff00) == 0xff00;   # ff00::/8 multicast
			if ($f == 0x2001) {
				my ($second) = $addr =~ /^[0-9a-f]{1,4}:([0-9a-f]{1,4})/;
				next if defined($second) && hex($second) == 0x0db8;  # 2001:db8::/32 doc
			}
			push @hits, "public-IPv6 literal (redacted)";
		}
		# A3. Japanese mobile phone (070/080/090, optional separators). Boundaries
		# exclude adjacent alphanumerics so an 11-digit run inside a hex string
		# (e.g. a git SHA or a sha256 literal) is not mistaken for a phone.
		while (/(?<![0-9A-Za-z])0[789]0[-\s]?\d{4}[-\s]?\d{4}(?![0-9A-Za-z])/g) {
			push @hits, "phone-number literal (redacted)";
		}
		# A4. personal email (any domain NOT allowlisted)
		while (/[A-Za-z0-9._%+\-]+\@([A-Za-z0-9.\-]+\.[A-Za-z]{2,})/g) {
			my $dom = lc $1;
			next if $dom =~ /(?:^|\.)(?:metal\.freedom-yield\.com|freedom-yield\.com|anthropic\.com|(?:users\.)?noreply\.github\.com|example\.(?:com|org|net))$/;
			next if $dom =~ /\.(?:invalid|test|example|localhost|local)$/;   # RFC 6761/6762 reserved (placeholder), never real
			push @hits, "personal-email literal (redacted)";
		}
		# B. forbidden ASCII word-literals by hash
		while (/([A-Za-z0-9_]{3,})/g) {
			push @hits, "forbidden handle/identifier (redacted)" if $wh{ sha256_hex(lc $1) };
		}
		# C. forbidden non-ASCII (CJK) literals by hash of raw bytes
		while (/([^\x00-\x7F]{3,})/g) {
			push @hits, "forbidden name/word (redacted)" if $ch{ sha256_hex($1) };
		}
		if (@hits) { my %s; print join("\n", grep { !$s{$_}++ } @hits), "\n"; }
	'
)"

# ---- D: optional local denylist (exact substrings, gitignored) ----
DENY_HIT=""
if [ -f "$DENYLIST_FILE" ]; then
	while IFS= read -r line || [ -n "$line" ]; do
		[ -z "$line" ] && continue
		case "$line" in \#*) continue ;; esac
		# Pure-ASCII-word entries -> whole-word match, so a company/handle slug
		# does not false-positive as a substring of an unrelated word (a short
		# slug appearing inside e.g. "inspiring" / "aspiring"). Entries with
		# @ . digits, or non-ASCII (emails / phone / IP / CJK names) -> substring
		# match: they are unique enough and this catches prose embedding.
		if printf '%s' "$line" | LC_ALL=C grep -qE '^[A-Za-z0-9_]+$'; then
			gflags="-wqF"
		else
			gflags="-qF"
		fi
		if printf '%s' "$SCAN_TEXT" | grep $gflags -- "$line"; then
			DENY_HIT="local denylist entry matched (redacted)"
			break
		fi
	done < "$DENYLIST_FILE"
fi

if [ -n "$FINDINGS" ] || [ -n "$DENY_HIT" ]; then
	{
		echo "=== PUBLISH_GUARD_BLOCK ==="
		echo "Context: ${CTX:-$MODE}"
		echo "Forbidden host identifier / operator PII would be published. Blocked (fail-closed)."
		[ -n "$FINDINGS" ] && printf '%s\n' "$FINDINGS"
		[ -n "$DENY_HIT" ] && printf '%s\n' "$DENY_HIT"
		echo
		echo "Fix: use an RFC5737 doc IP (192.0.2/198.51.100/203.0.113.x) or a 2001:db8::/32 doc"
		echo "     IPv6 not a real host IP;"
		echo "     never commit the operator handle / real name / company name / phone / personal email"
		echo "     / validator SSH key name. Keep genuinely local files gitignored."
	} >&2
	exit "$BLOCK_EXIT"
fi

exit 0
