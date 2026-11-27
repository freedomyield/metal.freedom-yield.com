# shellcheck shell=bash
# tests/lib/guard-order.sh — source-text check that a script's §3.5 keystore
# guard runs before its first keystore use (sourced, not executed).
#
# CHAIN: none. PRIME_DIRECTIVE: TESTNET-FIRST — safe. Reads the script's TEXT
# only; never runs it.
#
# Why (2026-11-27, L7c): bin/safe-broadcast and scripts/sign-anchor-event.sh
# use jq before their guard, so a "HOME = login home is refused" run cannot go
# through tests/lib/real-home-fence.sh (its jq trap stops them first). Their
# wrapper-level case is this order check instead; the guard function's own
# refusal is run inside the fence by tests/keystore-guard.
#
# guard_order_lines <script> [extra use ERE]
#   Prints "<guard line> <first use line>" and returns 0, or prints the reason
#   and returns 1 (no top-level guard call, or no use found at all).
#   The guard line is the first top-level `require_project_keystore_home ...`.
#   A "use" is a line that (1) runs proton as a command, (2) names $HOME /
#   ${HOME}, or (3) matches the extra ERE (e.g. the call of the wrapper that
#   runs proton). A use inside a function counts at the first TOP-LEVEL line
#   that calls that function (directly or through other functions), because
#   that is where it runs. Comment lines and heredoc bodies are skipped.

GUARD_ORDER_CALL_RE='^require_project_keystore_home[[:space:]]'
GUARD_ORDER_PROTON_RE='(^|[;&|]|\$\()[[:space:]]*proton([[:space:]]|$)'
GUARD_ORDER_HOME_RE='\$\{?HOME([^A-Za-z0-9_]|$)'

guard_order_lines() {
	local script="$1" extra_re="${2:-}"
	[ -r "$script" ] || { echo "guard-order: cannot read $script"; return 1; }
	# The patterns go in through the environment: `awk -v` would eat their backslashes.
	GO_GUARD_RE="$GUARD_ORDER_CALL_RE" GO_PROTON_RE="$GUARD_ORDER_PROTON_RE" \
	GO_HOME_RE="$GUARD_ORDER_HOME_RE" GO_EXTRA_RE="$extra_re" awk '
	BEGIN {
		guard_re = ENVIRON["GO_GUARD_RE"]; proton_re = ENVIRON["GO_PROTON_RE"]
		home_re = ENVIRON["GO_HOME_RE"]; extra_re = ENVIRON["GO_EXTRA_RE"]
	}
	function is_use(line) {
		return (line ~ proton_re || line ~ home_re || (extra_re != "" && line ~ extra_re))
	}
	function note_calls(line, owner,    n, i, words) {
		n = split(line, words, /[^A-Za-z0-9_]+/)
		for (i = 1; i <= n; i++)
			if ((words[i] in fn_name) && words[i] != owner) calls[owner] = calls[owner] " " words[i]
	}
	# pass 1: function names
	NR == FNR {
		if (match($0, /^[A-Za-z_][A-Za-z0-9_]*\(\)[[:space:]]*\{/)) { n = $0; sub(/\(\).*/, "", n); fn_name[n] = 1 }
		next
	}
	# pass 2
	heredoc != "" { t = $0; sub(/^\t+/, "", t); if (t == heredoc) heredoc = ""; next }
	/^[[:space:]]*#/ { next }
	{
		line = $0
		if (match(line, /(^|[^<])<<-?[[:space:]]*\\?["\047]?[A-Za-z_][A-Za-z0-9_]*/)) {
			h = substr(line, RSTART, RLENGTH); sub(/^[^<]*<<-?[[:space:]]*\\?["\047]?/, "", h); heredoc_next = h
		} else heredoc_next = ""
		if (cur == "" && match(line, /^[A-Za-z_][A-Za-z0-9_]*\(\)[[:space:]]*\{/)) {
			n = line; sub(/\(\).*/, "", n)
			body = line; sub(/^[^{]*\{/, "", body)
			if (is_use(body)) fn_use[n] = 1
			note_calls(body, n)
			if (body !~ /\}[[:space:]]*$/) cur = n
		} else if (cur != "") {
			if (line ~ /^\}/) cur = ""
			else { if (is_use(line)) fn_use[cur] = 1; note_calls(line, cur) }
		} else {
			top_n++; top_line[top_n] = FNR; top_use[top_n] = is_use(line)
			top_calls[top_n] = ""; note_calls(line, "-top-"); top_calls[top_n] = calls["-top-"]; calls["-top-"] = ""
			if (guard == "" && line ~ guard_re) guard = FNR
		}
		heredoc = heredoc_next
	}
	END {
		do {
			changed = 0
			for (f in calls) if (!(f in fn_use)) {
				m = split(calls[f], cs, " ")
				for (i = 1; i <= m; i++) if (cs[i] in fn_use) { fn_use[f] = 1; changed = 1; break }
			}
		} while (changed)
		for (k = 1; k <= top_n && use == ""; k++) {
			if (top_use[k]) { use = top_line[k]; break }
			m = split(top_calls[k], cs, " ")
			for (i = 1; i <= m; i++) if (cs[i] in fn_use) { use = top_line[k]; break }
		}
		if (guard == "") { print "guard-order: no top-level require_project_keystore_home call"; exit 1 }
		if (use == "") { print "guard-order: no keystore use found (proton command, $HOME, or the extra pattern)"; exit 1 }
		print guard, use
	}' "$script" "$script"
}
