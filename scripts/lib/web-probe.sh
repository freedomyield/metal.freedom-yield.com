#!/usr/bin/env bash
# scripts/lib/web-probe.sh — public-site probe helpers for check-anomalies.sh.
#
# CHAIN: none — HTTP GETs against the public site's /health and an optional
#        mtr trace toward the web host. No broadcast pathway exists here.
# PRIME_DIRECTIVE: TESTNET-FIRST — safe (no broadcast).
#
# Design: docs/superpowers/specs/2026-09-24-web-probe-path-classification-design.md
#
# Why a separate file: everything here MEASURES, CLASSIFIES or RENDERS TEXT.
# Nothing here notifies, reads or writes the anomaly state, or writes any
# file other than the caller-supplied scratch paths. check-anomalies.sh keeps
# every side effect (through scripts/lib/side-effects.sh) and every state
# transition, so the K-3 invariants stay in one file while the ~1,100-line
# transition script grows only by its transition block. The helpers are
# unit-tested by sourcing this file directly
# (tests/anomalies/test-web-probe-lib.sh) instead of sed-extracting code.
#
# bash 3.2 compatible (the macOS test host's /bin/bash): no empty-array
# expansion under `set -u`, no associative arrays, no ${x,,}.

# curl -w format shared by every probe: one line of key=value pairs, so the
# diagnostics block and the push body can quote it verbatim.
WEB_PROBE_WFMT='http_code=%{http_code} t_dns=%{time_namelookup} t_connect=%{time_connect} t_tls=%{time_appconnect} t_ttfb=%{time_starttransfer} t_total=%{time_total} remote_ip=%{remote_ip}'

# web_probe <outprefix> <url> [<resolve-spec>]
#   One GET capped at WEB_PROBE_MAX_TIME (default 10) seconds. Writes
#   <outprefix>.w (the timing line + " curl_rc=N"), <outprefix>.h (response
#   headers, so cf-ray survives) and <outprefix>.err (curl's stderr). A
#   non-empty <resolve-spec> ("host:port:ip") is passed as --resolve: that is
#   P_direct, which reaches the origin without going through Cloudflare.
#   Prints the 3-digit HTTP code ("000" = no HTTP response) and always
#   returns 0 — a failed probe is an observation, not an error. The code comes
#   from curl's stdout, never from re-reading the scratch file, so an
#   unwritable scratch dir degrades the diagnostics, never the verdict.
web_probe() {
	local prefix="$1" url="$2" resolve="${3:-}" hdr err out code rc=0
	hdr="${prefix}.h"
	err="${prefix}.err"
	if ! { : >"$hdr"; } 2>/dev/null; then
		hdr=/dev/null
		err=/dev/null
	fi
	if [ -n "$resolve" ]; then
		out=$(curl -sS -o /dev/null -D "$hdr" --resolve "$resolve" -w "$WEB_PROBE_WFMT" \
			--max-time "${WEB_PROBE_MAX_TIME:-10}" "$url" 2>"$err") || rc=$?
	else
		out=$(curl -sS -o /dev/null -D "$hdr" -w "$WEB_PROBE_WFMT" \
			--max-time "${WEB_PROBE_MAX_TIME:-10}" "$url" 2>"$err") || rc=$?
	fi
	code=$(printf '%s\n' "$out" | sed -n 's/^http_code=\([0-9][0-9][0-9]\).*/\1/p' | head -1)
	[ -n "$code" ] || code="000"
	if [ "$hdr" != /dev/null ]; then
		printf '%s curl_rc=%s\n' "${out:-http_code=000}" "$rc" >"${prefix}.w" 2>/dev/null || true
	fi
	printf '%s\n' "$code"
}

# web_timing_line <outprefix> — the probe's timing line, or a placeholder.
web_timing_line() {
	if [ -s "${1}.w" ]; then
		head -1 "${1}.w"
	else
		echo "(no timing captured)"
	fi
}

# web_cf_colo <headers-file> — the Cloudflare colo from `cf-ray: <id>-<COLO>`,
#   or "-" when there is none (no response, or not served through Cloudflare).
web_cf_colo() {
	local c=""
	if [ -r "$1" ]; then
		c=$(tr -d '\r' <"$1" | sed -n 's/^[Cc][Ff]-[Rr][Aa][Yy]:[[:space:]]*[^-]*-\([A-Za-z][A-Za-z]*\).*/\1/p' | tail -1)
	fi
	printf '%s\n' "${c:--}"
}

# web_is_ipv4 <addr> — dotted-quad IPv4, each octet 0-255 without leading
#   zeros (curl would read "010" as octal). IPv6 is deliberately not accepted:
#   --resolve needs it bracketed and the origin in use is IPv4.
web_is_ipv4() {
	local ip="$1" o IFS=.
	case "$ip" in
		"" | *[!0-9.]* | .* | *. | *..*) return 1 ;;
	esac
	set -- $ip
	[ "$#" -eq 4 ] || return 1
	for o in "$@"; do
		case "$o" in
			0?*) return 1 ;;
		esac
		[ "${#o}" -le 3 ] || return 1
		[ "$o" -le 255 ] 2>/dev/null || return 1
	done
	return 0
}

# web_resolve_spec <url> <ipv4> — "host:port:ip" for curl --resolve, the port
#   taken from the URL or its scheme's default. In production the URL is
#   https://<site> (port 443), exactly the spec's command shape; deriving it
#   lets the Linux integration suite point P_direct at a local server.
#   Returns 1 when the address is not IPv4 or the URL has no host.
web_resolve_spec() {
	local url="$1" ip="$2" scheme rest hostport host port
	web_is_ipv4 "$ip" || return 1
	scheme="${url%%://*}"
	rest="${url#*://}"
	hostport="${rest%%/*}"
	host="${hostport%%:*}"
	[ -n "$host" ] || return 1
	if [ "$hostport" != "$host" ]; then
		port="${hostport#*:}"
	else
		case "$scheme" in
			http) port=80 ;;
			*) port=443 ;;
		esac
	fi
	printf '%s:%s:%s\n' "$host" "$port" "$ip"
}

# web_classify <P_cf code> <P_direct code|skipped> — spec §3.2. Prints nothing
#   for a healthy P_cf; otherwise cf_path | origin_or_path | unknown.
web_classify() {
	[ "$1" = "200" ] && return 0
	case "$2" in
		skipped) echo unknown ;;
		200) echo cf_path ;;
		*) echo origin_or_path ;;
	esac
}

# web_class_label <class> — the Japanese label used in pushes (spec §3.2).
web_class_label() {
	case "$1" in
		cf_path) echo 'Cloudflare 経路 (origin は正常)' ;;
		origin_or_path) echo 'origin 停止 または シンガポール経路 (未判別)' ;;
		unknown) echo '判別不能 (origin 直接確認なし)' ;;
		*) echo "$1" ;;
	esac
}

# web_class_labels_csv <a,b,...> — labels of a class history joined by " → ",
#   or "-" for an empty history.
web_class_labels_csv() {
	local csv="$1" c out="" IFS=,
	for c in $csv; do
		out="${out:+${out} → }$(web_class_label "$c")"
	done
	printf '%s\n' "${out:--}"
}

# web_duration_min <seconds> — whole minutes, rounded UP, at least 1. The
#   observation grid is 5 minutes, so the value is an upper bound of the
#   first-to-last-observation span, never a precise outage length.
web_duration_min() {
	local s="${1:-0}"
	case "$s" in
		"" | *[!0-9]*) s=0 ;;
	esac
	[ "$s" -ge 1 ] || s=1
	echo $(((s + 59) / 60))
}

# web_mtr_capture <ipv4|""> <outfile> — `timeout 25 mtr -r -n -c 5 -w <ip>`
#   into <outfile>, or one "skipped (…)" line when there is no valid address
#   or the tools are missing. Never fails (spec §4).
web_mtr_capture() {
	local ip="$1" out="$2" rc=0
	{
		if [ -z "$ip" ]; then
			echo "skipped (no valid WEB_ORIGIN_IP)"
		elif ! command -v mtr >/dev/null 2>&1; then
			echo "skipped (mtr not installed)"
		elif ! command -v timeout >/dev/null 2>&1; then
			echo "skipped (timeout not installed)"
		else
			timeout "${WEB_DIAG_TIMEOUT:-25}" mtr -r -n -c 5 -w "$ip" 2>&1 || rc=$?
			[ "$rc" -eq 0 ] || echo "(mtr exited rc=${rc}; 124 = cut off by timeout ${WEB_DIAG_TIMEOUT:-25}s)"
		fi
	} >"$out" 2>/dev/null || true
	return 0
}

# web_render_diag <scratch-dir> <class> <UTC ISO> <P_direct code|skipped>
#   One diagnostics block (spec §3.5), starting with
#   "=== web-diag <UTC ISO> class=<class> ===": both P_cf runs, P_direct and
#   the mtr report, each with its timing line, headers and curl error.
web_render_diag() {
	local dir="$1" class="$2" iso="$3" direct="$4" p label
	printf '=== web-diag %s class=%s ===\n' "$iso" "$class"
	for p in cf1 cf2 direct; do
		case "$p" in
			cf1) label='cf#1' ;;
			cf2) label='cf#2' ;;
			*) label='direct' ;;
		esac
		if [ "$p" = "direct" ] && [ "$direct" = "skipped" ]; then
			printf '[%s] skipped (WEB_ORIGIN_IP unset or not IPv4)\n' "$label"
			continue
		fi
		if [ ! -f "${dir}/${p}.w" ]; then
			printf '[%s] not run\n' "$label"
			continue
		fi
		printf '[%s] %s\n' "$label" "$(head -1 "${dir}/${p}.w")"
		if [ -s "${dir}/${p}.h" ]; then
			printf '[%s headers]\n' "$label"
			tr -d '\r' <"${dir}/${p}.h" | sed '/^$/d; s/^/  /'
		fi
		if [ -s "${dir}/${p}.err" ]; then
			printf '[%s stderr]\n' "$label"
			sed 's/^/  /' "${dir}/${p}.err"
		fi
	done
	printf '[mtr]\n'
	if [ -s "${dir}/mtr" ]; then
		sed 's/^/  /' "${dir}/mtr"
	else
		echo '  not run'
	fi
}

# web_render_blip_line <start epoch> <end epoch> <a,b,...> <true|false>
#   "<start UTC> <end UTC> duration_s=<n> classes=<a,b> pushed=<bool>"
#   (spec §3.5). Uses GNU date -d @N (the validator host's date).
web_render_blip_line() {
	local start="$1" end="$2" classes="${3:-}" pushed="$4" dur
	dur=$((end - start))
	[ "$dur" -ge 0 ] || dur=0
	printf '%s %s duration_s=%s classes=%s pushed=%s\n' \
		"$(date -u -d "@${start}" +%Y-%m-%dT%H:%M:%SZ)" \
		"$(date -u -d "@${end}" +%Y-%m-%dT%H:%M:%SZ)" \
		"$dur" "${classes:--}" "$pushed"
}
