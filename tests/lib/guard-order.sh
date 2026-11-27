# shellcheck shell=bash
# tests/lib/guard-order.sh — source-text check that a script's §3.5 keystore
# guard runs before its first keystore use (sourced, not executed).
#
# CHAIN: none. PRIME_DIRECTIVE: TESTNET-FIRST — safe. Reads the script's TEXT
# only; never runs it.
#
# Why (2026-11-27, L7c): bin/safe-broadcast and scripts/sign-anchor-event.sh
# use jq before their guard, so a "HOME = login home is refused" run cannot go
# through tests/lib/real-home-fence.sh (its jq trap stops them first), and
# scripts/run-testnet-rehearsal.sh reads a login-home place that has no
# override. Their cases are this order check instead; the guard function's
# own refusal is run inside the fence by tests/keystore-guard.
#
# guard_order_lines <script> [extra use ERE]
#   Prints "<guard line> <first use line>" and returns 0, or prints the reason
#   and returns 1 (no top-level guard call, or no use found at all — both
#   fail the caller, never pass it).
#   The guard line is the first top-level `require_project_keystore_home ...`.
#   A "use" is a line that
#     (1) runs proton as a command;
#     (2) names a place UNDER a home: `$HOME/`, `${HOME}/`, `$LOGIN_HOME/`, or
#         `<var>/` for a var assigned from fyd_login_home / `eval echo ~` /
#         `id -un` (a "home root");
#     (3) names a "home path" var: one assigned (at the start of a line) from
#         (2) or from another home path var — the assignment itself only
#         builds the string and is not a use, unless it runs a command `$(`;
#     (4) matches the extra ERE (e.g. the call of the wrapper that runs proton).
#   A use inside a function counts at the first TOP-LEVEL line that calls that
#   function (directly or through other functions), because that is where it
#   runs. Comment lines and heredoc bodies are skipped.

GUARD_ORDER_CALL_RE='^require_project_keystore_home[[:space:]]'
GUARD_ORDER_PROTON_RE='(^|[;&|]|\$\()[[:space:]]*proton([[:space:]]|$)'
GUARD_ORDER_ASSIGN_RE='^[[:space:]]*((local|export|readonly|declare)[[:space:]]+(-[A-Za-z]+[[:space:]]+)*)?[A-Za-z_][A-Za-z0-9_]*='
GUARD_ORDER_ROOT_SRC_RE='fyd_login_home|eval[[:space:]]+echo[[:space:]]+"?~|id[[:space:]]+-un'

guard_order_lines() {
	local script="$1" extra_re="${2:-}"
	[ -r "$script" ] || { echo "guard-order: cannot read $script"; return 1; }
	# The patterns go in through the environment: `awk -v` would eat their backslashes.
	GO_GUARD_RE="$GUARD_ORDER_CALL_RE" GO_PROTON_RE="$GUARD_ORDER_PROTON_RE" \
	GO_ASSIGN_RE="$GUARD_ORDER_ASSIGN_RE" GO_ROOT_SRC_RE="$GUARD_ORDER_ROOT_SRC_RE" \
	GO_EXTRA_RE="$extra_re" awk '
	BEGIN {
		guard_re = ENVIRON["GO_GUARD_RE"]; proton_re = ENVIRON["GO_PROTON_RE"]
		assign_re = ENVIRON["GO_ASSIGN_RE"]; root_src_re = ENVIRON["GO_ROOT_SRC_RE"]
		extra_re = ENVIRON["GO_EXTRA_RE"]
		root["HOME"] = 1; root["LOGIN_HOME"] = 1
	}
	# assigned_name(line) — the name a line assigns at its start, or "".
	function assigned_name(line,    n) {
		if (line !~ assign_re) return ""
		n = line; sub(/=.*/, "", n); sub(/^.*[[:space:]]/, "", n)
		return n
	}
	function rhs_of(line) { sub(/^[^=]*=/, "", line); return line }
	# refs(text, set, slash) — 1 if text references "$name" / "${name" for a
	# name in set: followed by "/" (slash = 1) or by a non-name char (slash = 0).
	function refs(text, set, slash,    k, re) {
		for (k in set) {
			re = "(^|[^\\\\])\\$\\{?" k (slash ? "\\}?/" : "([^A-Za-z0-9_]|$)")
			if (text ~ re) return 1
		}
		return 0
	}
	function is_home_ref(text) { return refs(text, root, 1) || refs(text, hpath, 0) }
	function is_use(line,    n) {
		if (line ~ proton_re) return 1
		if (extra_re != "" && line ~ extra_re) return 1
		n = assigned_name(line)
		if (n != "" && rhs_of(line) !~ /\$\(/) return 0
		return is_home_ref(line)
	}
	function note_calls(line, owner,    n, i, words) {
		n = split(line, words, /[^A-Za-z0-9_]+/)
		for (i = 1; i <= n; i++)
			if ((words[i] in fn_name) && words[i] != owner) calls[owner] = calls[owner] " " words[i]
	}
	# heredoc_starts(line) — the terminator word of a heredoc the line opens, or "".
	function heredoc_starts(line,    h) {
		if (!match(line, /(^|[^<])<<-?[[:space:]]*\\?["\047]?[A-Za-z_][A-Za-z0-9_]*/)) return ""
		h = substr(line, RSTART, RLENGTH); sub(/^[^<]*<<-?[[:space:]]*\\?["\047]?/, "", h)
		return h
	}
	function heredoc_ends(line) { sub(/^\t+/, "", line); return line == heredoc }
	# pass 1: function names and assignments (heredoc bodies and comments skipped)
	NR == FNR && heredoc != "" { if (heredoc_ends($0)) heredoc = ""; next }
	NR == FNR {
		if ($0 ~ /^[[:space:]]*#/) next
		heredoc = heredoc_starts($0)
		if (match($0, /^[A-Za-z_][A-Za-z0-9_]*\(\)[[:space:]]*\{/)) { n = $0; sub(/\(\).*/, "", n); fn_name[n] = 1 }
		n = assigned_name($0)
		if (n != "") { na++; a_name[na] = n; a_rhs[na] = rhs_of($0) }
		next
	}
	# between the passes: home roots, then home path vars to a fixed point
	FNR == 1 {
		heredoc = ""
		for (i = 1; i <= na; i++) if (a_rhs[i] ~ root_src_re) root[a_name[i]] = 1
		do {
			changed = 0
			for (i = 1; i <= na; i++)
				if (!(a_name[i] in hpath) && !(a_name[i] in root) && is_home_ref(a_rhs[i])) { hpath[a_name[i]] = 1; changed = 1 }
		} while (changed)
	}
	# pass 2
	heredoc != "" { if (heredoc_ends($0)) heredoc = ""; next }
	/^[[:space:]]*#/ { next }
	{
		line = $0
		heredoc_next = heredoc_starts(line)
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
		if (use == "") { print "guard-order: no keystore use found (proton command, a place under a home, or the extra pattern)"; exit 1 }
		print guard, use
	}' "$script" "$script"
}
