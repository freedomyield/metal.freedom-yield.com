#!/usr/bin/env bash
# scripts/lib/side-effects.sh — the single opt-in gate for production side effects.
#
# CHAIN: none — this file defines shell functions only. It never invokes a
#        broadcast-capable command and deliberately offers no route to one:
#        broadcast stays behind bin/safe-broadcast and the Prime Directive's
#        four gates (docs/CONSTITUTION.md). Do not add one here.
#
# ---------------------------------------------------------------------------
# WHY THIS EXISTS
# ---------------------------------------------------------------------------
# The 2026-08-06 design analysis (docs/superpowers/specs/
# 2026-08-06-single-source-of-truth-design.md, component C3) measured the
# cause of four production-side-effect accidents in two days: a test that
# deleted a production data file, eight real ntfy pushes, a real testnet RPC
# POST, and a near-miss ssh to the validator host.
#
# The common cause was not carelessness. It was that production side effects
# were OPT-OUT: the default value of every knob pointed at production, and a
# test only stayed hermetic if its author found and set the right variable.
# Three clusters were already opt-in because the Constitution forces them to
# be (broadcast §Prime Directive, host ssh, proton keystore §3.5) and none of
# them produced an accident. The three that were opt-out — notify, file
# writes, state dir — produced all four.
#
# Finding the right variable was itself the trap. Six spellings existed for
# "stop this script from notifying" (NOTIFY, FYD_NOTIFY, ANCHOR_NOTIFY,
# WATCH_NOTIFY, plus hardcoded paths in daily-status.sh and
# install-anchor-watch-alert-only.sh) and four for the state directory
# (ANOMALY_STATE_DIR, FY_STATE_DIR, WATCH_STATE_DIR, UPTIME_STATE_DIR) — all
# four resolving to the same /var/lib/freedom-yield.
#
# This library inverts the default and collapses the spellings:
#
#   * Nothing here performs a side effect unless FY_LIVE is exactly "1".
#   * Not-live is a LOUD no-op: every suppressed side effect prints one
#     "DRY: would …" line to stderr and returns 0. Silence is the failure
#     mode the C3 rollout is most afraid of ("the cron went quiet and nobody
#     noticed"), so a dry cron tick must be distinguishable from a broken one
#     by reading the log, not by diffing artifacts.
#   * Only the cron env headers carry FY_LIVE=1 (enforced separately by the
#     check-cron-file.sh lint), so a test that forgets to stub is inert
#     instead of destructive.
#
# ---------------------------------------------------------------------------
# CONTRACT
# ---------------------------------------------------------------------------
# FY_LIVE
#   Exactly the one-character string "1" means live. Everything else —
#   unset, "", "0", "yes", "true", "TRUE", " 1" — means dry. The comparison
#   happens in exactly one place (fyd_is_live) and every other function in
#   this file asks that function rather than re-reading FY_LIVE; the mutation
#   cases in tests/side-effects/ fail if any path grows its own copy.
#
# Exit codes
#   64            usage / argument error raised BY THIS LIBRARY (also exposed
#                 as $FYD_USAGE_RC). 64 is chosen to sit outside every exit
#                 code the delegated scripts use (notify.sh 0-5,
#                 push-to-web-host.sh 0-1) and outside this repo's 1-9
#                 script conventions, so a caller can always tell "I called
#                 it wrong" apart from "the side effect failed".
#   0             dry mode, after validation passed.
#   anything else the delegate's own exit code, VERBATIM. This library never
#                 renumbers or translates it. notify.sh's 2/3/4/5 encode the
#                 retry classification that retryable_notify_rc() consumes in
#                 three callers; remapping them would silently turn a
#                 retryable 429 into a permanent failure. Translation, if
#                 ever wanted, belongs in the orchestrator (design doc §6).
#
# Validation runs in BOTH modes, before the live/dry branch, so that a dry
# run can never accept a call that a live run would reject. The one gap that
# cannot be closed this way is documented at fyd_push().
#
# ---------------------------------------------------------------------------
# USAGE (source once near the top of a script)
# ---------------------------------------------------------------------------
#   REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
#   # shellcheck source=scripts/lib/side-effects.sh
#   . "${REPO_ROOT}/scripts/lib/side-effects.sh"
#
#   fyd_notify high "Validator renewal" "7 days left"
#   fyd_notify --strict --tags=tada high "Delegation up" "$body"
#   fyd_push validator.json
#   STATE_DIR="$(fyd_state_dir anomaly)"
#   fyd_live_run "remove the stale sign output" rm -f "$SIGN_OUT"
#
# The library is self-locating: it resolves its sibling scripts from its own
# path, so a caller does not have to hand it a repo root.
#
# See tests/side-effects/test-side-effects.sh for the executable statement of
# every rule above, including the mutation cases that prove the dry path is
# actually exercised.

FYD_SIDE_EFFECTS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FYD_SCRIPTS_DIR="$(cd "${FYD_SIDE_EFFECTS_LIB_DIR}/.." && pwd)"

# Exit code for "this library was called incorrectly" (see CONTRACT above).
FYD_USAGE_RC=64

# The single production state directory. Every one of the four legacy env
# names resolved to this path, so collapsing them changes no behaviour.
FYD_STATE_DIR_DEFAULT="/var/lib/freedom-yield"

# Filename shape accepted by fyd_push before it will delegate. This
# expression is a copy of the one in scripts/push-to-web-host.sh and MUST
# stay byte-identical to it — tests/side-effects/ greps both files for this
# literal and fails if they drift. Duplicating a REJECTION is safe (the dry
# run refuses exactly what the live run refuses); loosening one side without
# the other is what the lock-step test prevents.
FYD_PUSH_FILENAME_RE='^[A-Za-z0-9][A-Za-z0-9._-]*(/[A-Za-z0-9][A-Za-z0-9._-]*)?$'

# ---------------------------------------------------------------------------
# Internal helpers (fyd__ prefix — not part of the contract)
# ---------------------------------------------------------------------------

# fyd__resolve_env <var-name>...
#   Prints the value of the first NAMED variable that is set and non-empty;
#   argument order is precedence order. Returns 1 (printing nothing) when
#   none are set.
#
#   When a later (lower-precedence) name is also set to a DIFFERENT value,
#   the conflict is announced on stderr rather than swallowed. Precedence is
#   always canonical-first: the canonical name is the lever a test uses to
#   sandbox an entire run, so an ambient legacy variable must not be able to
#   drag that run back onto a production path. Callers that set only a legacy
#   name — every current caller and every current cron env header — observe
#   no change and no message.
fyd__resolve_env() {
	local winner_name="" winner_val="" n v
	for n in "$@"; do
		eval "v=\${${n}:-}"
		[ -n "$v" ] || continue
		if [ -z "$winner_name" ]; then
			winner_name="$n"
			winner_val="$v"
		elif [ "$v" != "$winner_val" ]; then
			echo "side-effects: WARNING: ${n}=${v} ignored — ${winner_name}=${winner_val} takes precedence." >&2
		fi
	done
	[ -n "$winner_name" ] || return 1
	printf '%s\n' "$winner_val"
	return 0
}

# fyd__usage <message...>  — print a usage error, return $FYD_USAGE_RC.
fyd__usage() {
	echo "side-effects: ERROR: $*" >&2
	return "$FYD_USAGE_RC"
}

# ---------------------------------------------------------------------------
# The decision (exactly one place)
# ---------------------------------------------------------------------------

# fyd_is_live
#   Returns 0 iff FY_LIVE is exactly "1". No trimming, no truthiness, no
#   case folding: a knob that accepts "true" also accepts "trueish" typos,
#   and this one guards production. The strictness is deliberate and tested.
fyd_is_live() {
	[ "${FY_LIVE:-}" = "1" ]
}

# fyd_dry_note <text...>
#   The single writer of the "DRY:" marker. Emits one greppable line naming
#   the suppressed action and the FY_LIVE value that suppressed it, so a cron
#   log answers "is this tick dry, and why" without any other tooling.
#   Always returns 0 — a suppressed side effect is a success, not a failure.
fyd_dry_note() {
	echo "DRY: would $* (FY_LIVE=${FY_LIVE:-<unset>})" >&2
	return 0
}

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

# fyd_live_run <description> <command> [args...]
#   The generic gate, for side effects that are neither notify nor push:
#   file writes, rm, ssh, systemctl, git push. Exists so those callers do not
#   each invent a seventh spelling of "don't do it for real".
#     dry  → prints "DRY: would <description>", does not run, returns 0.
#     live → runs the command, returns its exit code verbatim.
#   <description> is prose for the log, not a command; the command starts at
#   $2. Both are required.
fyd_live_run() {
	if [ "$#" -lt 2 ]; then
		fyd__usage "fyd_live_run: usage: fyd_live_run <description> <command> [args...]"
		return "$FYD_USAGE_RC"
	fi
	if [ -z "${1:-}" ]; then
		fyd__usage "fyd_live_run: description must not be empty"
		return "$FYD_USAGE_RC"
	fi
	local desc="$1"
	shift
	if ! fyd_is_live; then
		fyd_dry_note "$desc"
		return 0
	fi
	local rc=0
	"$@" || rc=$?
	return "$rc"
}

# fyd_notify [--strict] [--tags=<tag>] [--] <priority> <title> [message...]
#   The single entry point for ntfy delivery. Delegates to notify.sh, whose
#   argv shape (priority, title, message words joined by notify.sh itself)
#   and env inputs are preserved exactly, so migrating a caller is textual.
#
#   Options exist instead of env prefixes because `NTFY_TAGS=x fyd_notify …`
#   is a bash trap: an assignment prefixed to a FUNCTION call persists in the
#   caller's shell afterwards, so the tag would leak into the next
#   notification. An ambient NTFY_TAGS / NOTIFY_STRICT_EXIT is still honoured
#   (back-compat with existing callers and cron headers); an explicit flag
#   wins over it.
#
#   Rejected in both modes (rc $FYD_USAGE_RC): an unrecognized --option (a
#   `--tag=` typo would otherwise be silently taken as the priority), fewer
#   than two positional arguments, and an unreadable delegate.
#
#   NOT rejected: an unknown priority or an empty message. notify.sh coerces
#   an unknown priority to "default" and still delivers; refusing here would
#   drop an alert entirely, and a lost alert is worse than a mis-prioritized
#   one. The caller gets a WARNING line instead.
fyd_notify() {
	local tags_flag="" strict_flag="" have_tags=0 have_strict=0
	while [ "$#" -gt 0 ]; do
		case "$1" in
			--)
				shift
				break
				;;
			--strict)
				strict_flag=1
				have_strict=1
				shift
				;;
			--tags=*)
				tags_flag="${1#--tags=}"
				have_tags=1
				shift
				;;
			--*)
				fyd__usage "fyd_notify: unknown option: $1"
				return "$FYD_USAGE_RC"
				;;
			*)
				break
				;;
		esac
	done

	if [ "$#" -lt 2 ]; then
		fyd__usage "fyd_notify: usage: fyd_notify [--strict] [--tags=<tag>] <priority> <title> [message...]"
		return "$FYD_USAGE_RC"
	fi
	local prio="$1" title="$2"
	shift 2

	local notify_bin
	notify_bin="$(fyd__resolve_env FYD_NOTIFY ANCHOR_NOTIFY WATCH_NOTIFY NOTIFY || true)"
	[ -n "$notify_bin" ] || notify_bin="${FYD_SCRIPTS_DIR}/notify.sh"
	if [ ! -r "$notify_bin" ]; then
		fyd__usage "fyd_notify: delegate not readable: ${notify_bin}"
		return "$FYD_USAGE_RC"
	fi

	case "$prio" in
		urgent | high | default | low | min) ;;
		*)
			echo "side-effects: WARNING: fyd_notify: unknown priority '${prio}' — notify.sh will send it as 'default'." >&2
			;;
	esac

	local tags strict
	if [ "$have_tags" -eq 1 ]; then tags="$tags_flag"; else tags="${NTFY_TAGS:-}"; fi
	if [ "$have_strict" -eq 1 ]; then strict="$strict_flag"; else strict="${NOTIFY_STRICT_EXIT:-}"; fi

	if ! fyd_is_live; then
		local msg="$*"
		fyd_dry_note "notify prio=${prio} tags=${tags} strict=${strict} title=[${title}] msg_bytes=${#msg} via ${notify_bin}"
		return 0
	fi

	# Four explicit branches instead of an env array: bash 3.2 (the macOS
	# system bash this repo's tests run under) errors on ${#arr[@]} for an
	# empty array while `set -u` is in effect. An assignment prefixed to an
	# EXTERNAL command does not leak into this shell, unlike the function
	# case described above.
	local rc=0
	if [ -n "$tags" ] && [ -n "$strict" ]; then
		NTFY_TAGS="$tags" NOTIFY_STRICT_EXIT="$strict" bash "$notify_bin" "$prio" "$title" "$@" || rc=$?
	elif [ -n "$tags" ]; then
		NTFY_TAGS="$tags" bash "$notify_bin" "$prio" "$title" "$@" || rc=$?
	elif [ -n "$strict" ]; then
		NOTIFY_STRICT_EXIT="$strict" bash "$notify_bin" "$prio" "$title" "$@" || rc=$?
	else
		bash "$notify_bin" "$prio" "$title" "$@" || rc=$?
	fi
	return "$rc"
}

# fyd_push <filename>
#   The single entry point for publishing to the web host. Delegates to
#   push-to-web-host.sh with the filename verbatim; that script keeps sole
#   ownership of the target allowlist and of the ssh itself.
#
#   Validated here, in both modes: exactly one non-empty argument, no "..",
#   not absolute, and $FYD_PUSH_FILENAME_RE (the same shape expression
#   push-to-web-host.sh enforces before it builds the ssh command string).
#
#   Known parity gap: the live run also fails when the target is not in the
#   allowlist or the source file does not exist locally. Neither is knowable
#   in a dry run on a machine that has no such file, so those two remain
#   live-only failures. The shape and traversal checks above are the subset
#   that CAN be verified early, and they are the security-relevant ones.
fyd_push() {
	if [ "$#" -ne 1 ]; then
		fyd__usage "fyd_push: exactly one argument required (got $#): fyd_push <filename>"
		return "$FYD_USAGE_RC"
	fi
	local filename="$1"
	if [ -z "$filename" ]; then
		fyd__usage "fyd_push: filename must not be empty"
		return "$FYD_USAGE_RC"
	fi
	case "$filename" in
		*..*)
			fyd__usage "fyd_push: path traversal rejected (filename contains '..'): ${filename}"
			return "$FYD_USAGE_RC"
			;;
		/*)
			fyd__usage "fyd_push: absolute path rejected (filename must be relative): ${filename}"
			return "$FYD_USAGE_RC"
			;;
	esac
	if ! [[ "$filename" =~ $FYD_PUSH_FILENAME_RE ]]; then
		fyd__usage "fyd_push: illegal characters or shape in filename: ${filename}"
		return "$FYD_USAGE_RC"
	fi

	local push_bin
	push_bin="$(fyd__resolve_env FYD_PUSH_TO_WEB_HOST || true)"
	[ -n "$push_bin" ] || push_bin="${FYD_SCRIPTS_DIR}/push-to-web-host.sh"
	if [ ! -r "$push_bin" ]; then
		fyd__usage "fyd_push: delegate not readable: ${push_bin}"
		return "$FYD_USAGE_RC"
	fi

	if ! fyd_is_live; then
		fyd_dry_note "push ${filename} via ${push_bin}"
		return 0
	fi

	local rc=0
	bash "$push_bin" "$filename" || rc=$?
	return "$rc"
}

# fyd_state_dir [<role>]
#   Prints the state directory to stdout. Collapses the four legacy env names
#   — all of which pointed at the same /var/lib/freedom-yield — behind one
#   canonical FY_STATE_DIR, while still honouring the legacy name that a
#   given role's existing callers and cron headers set:
#
#     (no role)  FY_STATE_DIR
#     cycle      FY_STATE_DIR                      (cycle-gate, resume, watch-anchor-events)
#     anomaly    FY_STATE_DIR → ANOMALY_STATE_DIR  (check-anomalies, anomaly-state-init, gen-anchor-source)
#     watch      FY_STATE_DIR → WATCH_STATE_DIR    (check-watch-validators)
#     uptime     FY_STATE_DIR → UPTIME_STATE_DIR   (uptime-history, node-health-daily, peer-validators)
#
#   A legacy name is honoured only when its role is named, so a caller cannot
#   accidentally inherit another subsystem's directory. An unknown role is
#   refused (rc $FYD_USAGE_RC) rather than quietly falling back to the
#   default — a typo'd role that resolved to /var/lib/freedom-yield would
#   write to production, which is the accident class this file exists to end.
#
#   Resolution is not gated on FY_LIVE: naming a directory is not itself a
#   side effect, and silently rewriting the path in dry mode would create a
#   second hidden source of truth (and break reads of pre-existing state).
#   Handing back the production default while NOT live is announced on
#   stderr instead — legal for read-only use and operator debugging, but
#   visible, because a test resolving a production path is a smell.
fyd_state_dir() {
	if [ "$#" -gt 1 ]; then
		fyd__usage "fyd_state_dir: at most one argument (role): fyd_state_dir [anomaly|watch|uptime|cycle]"
		return "$FYD_USAGE_RC"
	fi
	local role="${1:-}" dir=""
	case "$role" in
		"" | cycle) dir="$(fyd__resolve_env FY_STATE_DIR || true)" ;;
		anomaly) dir="$(fyd__resolve_env FY_STATE_DIR ANOMALY_STATE_DIR || true)" ;;
		watch) dir="$(fyd__resolve_env FY_STATE_DIR WATCH_STATE_DIR || true)" ;;
		uptime) dir="$(fyd__resolve_env FY_STATE_DIR UPTIME_STATE_DIR || true)" ;;
		*)
			fyd__usage "fyd_state_dir: unknown role '${role}' (known: anomaly, watch, uptime, cycle, or none)"
			return "$FYD_USAGE_RC"
			;;
	esac
	if [ -z "$dir" ]; then
		dir="$FYD_STATE_DIR_DEFAULT"
		if ! fyd_is_live; then
			echo "side-effects: WARNING: state dir falls back to the production default ${dir} while FY_LIVE is not \"1\" — set FY_STATE_DIR to a sandbox path for tests." >&2
		fi
	fi
	printf '%s\n' "$dir"
	return 0
}
