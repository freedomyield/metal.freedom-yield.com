# Public-Site Probe Path Classification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop short validator-host→web-host path blips from paging the operator, while still paging real public-site outages with a priority chosen by where the request died, and keep enough evidence (diagnostics, incident log, 90-day retention) to settle the cause afterwards.

**Architecture:** `scripts/check-anomalies.sh` keeps its single Cloudflare probe (`P_cf`) and 30 s re-probe, adds a direct-to-origin probe (`P_direct`, `curl --resolve` to `WEB_ORIGIN_IP` from the cron env) only on the failure path, classifies the failure (`cf_path` / `origin_or_path` / `unknown`), and tracks an optional `web_incident` state object so the outage push fires only on the second consecutive failed run. All measuring, classifying and text rendering lives in a new side-effect-free library `scripts/lib/web-probe.sh`; every state change and write stays in `check-anomalies.sh` under the existing K-3 `notify_or_keep` / `candidate_set` / `fyd_live_write` discipline. Two small root-run installers deliver the host-side pieces: 90-day logrotate + log provisioning, and the `WEB_ORIGIN_IP` cron env line (value supplied at install time, never committed).

**Tech Stack:** bash (must also run under macOS `/bin/bash` 3.2 for the test suites), jq, curl, mtr (optional at run time), GNU date (`gdate` on macOS), logrotate, cron.d.

**Spec:** `docs/superpowers/specs/2026-09-24-web-probe-path-classification-design.md` (approved, "案 1"). Read it with this plan.

## Global Constraints

- **Prime Directive:** no task broadcasts anything; no `proton …`, no RPC `push_transaction`. Nothing here needs one. (`docs/CONSTITUTION.md` PRIME DIRECTIVE.)
- **Scope:** validator host only. No change to the web host, Cloudflare config, `.github/workflows/uptime.yml`, or the other anomaly checks. `api_freshness` keeps its gate: it runs only when `OBS_WEB_STATUS` is `200` in this run.
- **Push titles (verbatim, Japanese):** `公開サイトが応答しない (5 分以上継続)` (high, classes `origin_or_path` / `unknown`), `公開サイト: Cloudflare 経路で失敗継続 (origin は正常)` (default, class `cf_path`), `公開サイト復旧` (default).
- **Class labels (verbatim):** `cf_path` → `Cloudflare 経路 (origin は正常)`, `origin_or_path` → `origin 停止 または シンガポール経路 (未判別)`, `unknown` → `判別不能 (origin 直接確認なし)`.
- **Duration wording (verbatim):** `約 N 分 (5 分刻みの観測)`.
- **State:** `web_incident` is OPTIONAL: absent or `null` = no incident. Shape `{started_at:number, last_class:"cf_path"|"origin_or_path"|"unknown", classes:[string], runs:number, pushed:boolean}`. A malformed one is a K-3.5 schema mismatch and is quarantined. `.web` stays a string with values `ok`/`warn`; `warn` means "outage push delivered".
- **K-3 invariant:** `pushed` and `.web` advance only after a successful `notify_or_keep`. `started_at` / `runs` / `classes` / `last_class` are observations and advance every run.
- **Logs:** production paths `/var/log/anomalies-web-diag.log` (one block per failed observation, header `=== web-diag <UTC ISO> class=<c> ===`) and `/var/log/anomalies-web-blips.log` (one line per closed incident: `<start UTC> <end UTC> duration_s=<n> classes=<a,b> pushed=<bool>`). logrotate: `daily`, `rotate 90`, `compress`, `create 644 deploy deploy`, for these two plus `/var/log/anomalies.log`.
- **Host identifiers:** no real IP or hostname literal is committed anywhere. Tests use RFC 5737 addresses only (`192.0.2.10`, `198.51.100.7`, `203.0.113.9`, `203.0.113.10`), `127.0.0.1`, and the `example.invalid` host. `scripts/publish-guard.sh` allows RFC 5737 and loopback (verified).
- **No person names** in any file, comment, or commit message.
- **Side effects:** every durable write goes through `scripts/lib/side-effects.sh` (`fyd_live_write --append`), never a raw `>>` into a durable path (`tests/side-effects-callers/` G4 gate).
- **bash 3.2:** no empty-array expansion under `set -u`, no associative arrays, no `${x,,}`, no `mapfile`.
- **Every property test is mutation-proven:** break the property, run the suite, see it FAIL, restore, see it PASS. The plan gives the exact mutation for each property.
- **Commits:** one purpose per commit, message explains *why*, ends with the trailer `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`. Do NOT push. A push to `main` is a production monitoring change (the deploy advances the validator host) and needs operator approval.

---

## File Structure

| File | Task | Responsibility |
|---|---|---|
| `scripts/lib/web-probe.sh` (create) | 1 | Side-effect-free helpers: one probe (`web_probe`), `--resolve` spec, IPv4 check, classification + labels, duration rounding, cf-ray colo, mtr capture, diagnostics block and blip line rendering. |
| `scripts/check-anomalies.sh` (modify) | 1 | Sources the lib; new web observation + transition blocks; `web_incident` schema clause in K-3.5; scratch cleanup; header docs. |
| `scripts/anomaly-state-init.sh` (modify) | 1 | Baseline state writes `"web_incident": null`. This makes the key part of the writer's vocabulary, which `scripts/check-field-contracts.py` requires once K-3.5 reads it (the checker reports HIGH otherwise; verified). |
| `tests/anomalies/test-web-probe-lib.sh` (create) | 1 | Unit tests for the lib (sourced directly, curl/mtr/timeout stubs). |
| `tests/anomalies/test-web-incident.sh` (create) | 1 | Multi-run, end-to-end tests of the real `check-anomalies.sh` in a sandbox (spec §5 cases 1–8 + legacy state + class change + diagnostics content). |
| `tests/anomalies/integration-linux.sh` (modify) | 1 | Case I9 (python `/health` stub down for 2 runs, then up); mirror all of `scripts/lib/`; production-path guard also covers the two new logs. |
| `tests/anomalies/test-delegation-notify-body.sh` (modify) | 1 | Sandbox mirrors all of `scripts/lib/` (it now needs `web-probe.sh`). |
| `tests/cycle-gate/run-tests.sh` (modify) | 1 | T23 sandbox links all of `scripts/lib/`. |
| `tests/cycle-gate/scenario-test-endtime.sh` (modify) | 1 | Same sandbox fix. |
| `tests/side-effects-callers/test-monitoring-side-effects.sh` (modify) | 1 | `WEB_DIAG_LOG` / `WEB_BLIP_LOG` join the G4 durable-path list; two mutation cases. |
| `scripts/install-anomalies-logrotate.sh` (create) | 2 | Root installer: `/etc/logrotate.d/anomalies` (90 days, 3 logs) + provisioning of the 2 new logs as deploy:deploy 0644. |
| `tests/install-anomalies-logrotate/test-install-anomalies-logrotate.sh` (create) | 2 | Installer suite. |
| `scripts/vps-bootstrap.sh` (modify) | 2 | `step_anomaly_cron` calls the installer instead of its own 7-day heredoc (single source). |
| `scripts/install-anomalies-web-origin-env.sh` (create) | 3 | Root installer: one `WEB_ORIGIN_IP=` line in `/etc/cron.d/metal-anomalies`, value from `--origin-ip=` or the environment, lint-gated, never echoed. |
| `tests/install-anomalies-web-origin-env/test-install-anomalies-web-origin-env.sh` (create) | 3 | Installer suite (spec §5 case 9). |
| `tests/cron-generators-lint/test-cron-generators-lint.sh` (modify) | 3 | Lints bootstrap's `metal-anomalies` with the installer applied. |
| `docs/MONITORING_OPS.md`, `docs/MONITORING_NOTIFY_CALLERS.md`, `TOOLKIT.md` (modify) | 4 | Probe section, optional schema field, logs, runbook lines, new push titles, installer catalog rows. |

**Why a separate `scripts/lib/web-probe.sh`.** The measuring and rendering code (~235 lines with comments) has no business touching state or notifying. Keeping it out of `check-anomalies.sh` (1,119 lines) means that file grows only by its transition block (+~150 lines), the K-3 invariants stay readable in one place, and the helpers are unit-tested by sourcing them instead of sed-extracting code. The cost is that four test sandboxes that copied `side-effects.sh` by name must now mirror `scripts/lib/` as a whole. `tests/side-effects-callers/test-monitoring-side-effects.sh` (`mk_repo`) already records that as the correct pattern, and Task 1 applies it. The library is sourced at the top next to `side-effects.sh` and is fatal if missing, so a missing dependency fails the run loudly instead of silently skipping the probe.

## Parallelism

```
Task 1 (core)  ─┐
Task 2 (logrotate) ├──► merge all three ──► Task 4 (docs)
Task 3 (env)   ─┘
```

- **Tasks 1, 2 and 3 run in parallel** in separate worktrees. Their file sets are disjoint (table above). No task reads a file another task creates. Task 3's lint test renders the `metal-anomalies` heredoc in `vps-bootstrap.sh`, which Task 2 does not touch (Task 2 edits only the logrotate lines below it).
- **Task 4 runs after Tasks 1–3 are merged.** It documents names and behaviour from all three.
- The coordinator merges 1, 2 and 3 in any order (no textual overlap), then runs the **Integration verification** section, then dispatches Task 4.

## Test-running notes (all tasks)

- Suites are plain bash and print `Total: PASS=<n> FAIL=0` or `…summary: PASS=<n>  FAIL=0` plus `RESULT: PASS`. Any `FAIL` line means red.
- macOS needs `gdate` (Homebrew coreutils) for the GNU-date suites; without it they print `SKIP:` and exit 0. Do not treat SKIP as green for Task 1: install coreutils or run in the Linux container below.
- Linux-only suite (`tests/anomalies/integration-linux.sh`) runs on a Mac through Docker (verified):

```bash
docker run --rm -v "$PWD":/repo:ro -w /repo ubuntu:24.04 bash -c \
  'apt-get update -qq >/dev/null 2>&1 && apt-get install -y -qq jq curl python3 >/dev/null 2>&1 && bash tests/anomalies/integration-linux.sh 2>/dev/null | grep -E "FAIL|Total"'
```

---

### Task 1: Probe library, classification, persistence gate, diagnostics and `web_incident` state

**Files:**
- Create: `scripts/lib/web-probe.sh`
- Create: `tests/anomalies/test-web-probe-lib.sh`
- Create: `tests/anomalies/test-web-incident.sh`
- Modify: `scripts/check-anomalies.sh` (header comment lines 15-17 and ~26; after the `. "$FYD_LIB"` line ~62; K-3.5 schema check ~399-417; `cleanup_k3` ~450; web blocks ~631-656)
- Modify: `scripts/anomaly-state-init.sh:190-204` (baseline heredoc)
- Modify: `tests/anomalies/integration-linux.sh`
- Modify: `tests/anomalies/test-delegation-notify-body.sh:169`
- Modify: `tests/cycle-gate/run-tests.sh:574`
- Modify: `tests/cycle-gate/scenario-test-endtime.sh:96`
- Modify: `tests/side-effects-callers/test-monitoring-side-effects.sh` (`DURABLE=` ~593, Part 4 mutations ~677)

**Interfaces:**
- Consumes: `orig_get`, `candidate_set`, `notify_or_keep`, `STATE_DIR` (already in `check-anomalies.sh`); `fyd_live_write --append <desc> <path>` and `FYD_STATE_DIR_DEFAULT` from `scripts/lib/side-effects.sh`.
- Produces (Task 4 documents these; Tasks 2 and 3 depend only on the names and paths):
  - Library functions: `web_probe <outprefix> <url> [<host:port:ip>]` → prints a 3-digit code; `web_timing_line <outprefix>`; `web_cf_colo <headers-file>`; `web_is_ipv4 <addr>` (rc 0/1); `web_resolve_spec <url> <ipv4>` → `host:port:ip`; `web_classify <cf_code> <direct_code|skipped>` → `""|cf_path|origin_or_path|unknown`; `web_class_label <class>`; `web_class_labels_csv <a,b>`; `web_duration_min <seconds>`; `web_mtr_capture <ipv4|""> <outfile>`; `web_render_diag <dir> <class> <iso> <direct_code|skipped>`; `web_render_blip_line <start> <end> <a,b> <true|false>`.
  - Env read by `check-anomalies.sh`: `WEB_URL` (unchanged), `WEB_ORIGIN_IP` (new, from the cron env; unset or invalid → P_direct skipped), `WEB_REPROBE_SLEEP` (default `30`), `WEB_PROBE_MAX_TIME` (default `10`), `WEB_DIAG_TIMEOUT` (default `25`), `WEB_DIAG_LOG` / `WEB_BLIP_LOG` (defaults: `/var/log/anomalies-web-{diag,blips}.log` when the resolved state dir is the production default, otherwise `<state dir>/anomalies-web-{diag,blips}.log`).
  - State field `web_incident` (shape in Global Constraints).

- [ ] **Step 1: Write the failing library test**

Create `tests/anomalies/test-web-probe-lib.sh` and make it executable (`tests/run-all-tests.sh` discovers executable `test-*.sh`):

```bash
#!/usr/bin/env bash
# tests/anomalies/test-web-probe-lib.sh
#
# Unit tests for scripts/lib/web-probe.sh — the measurement, classification
# and text-rendering helpers behind check-anomalies.sh's public-site probe
# (docs/superpowers/specs/2026-09-24-web-probe-path-classification-design.md
# §3.1, §3.2, §3.5). The library is sourced directly; curl / mtr / timeout
# are PATH stubs that record their argv, so nothing leaves the machine.
#
# CHAIN: none. PRIME_DIRECTIVE: TESTNET-FIRST — safe (no broadcast, no network).

set -uo pipefail
exec </dev/null

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="${REPO}/scripts/lib/web-probe.sh"

TMP="$(mktemp -d -t fy-web-probe-lib.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
FAILURES=()
assert_eq() {
	local label="$1" expected="$2" actual="$3"
	if [ "$expected" = "$actual" ]; then
		PASS=$((PASS + 1))
		printf '  PASS  %s\n' "$label"
	else
		FAIL=$((FAIL + 1))
		FAILURES+=("$label (expected='$expected', actual='$actual')")
		printf '  FAIL  %s expected=[%s] actual=[%s]\n' "$label" "$expected" "$actual"
	fi
}
assert_rc() {    # <label> <expected rc> <cmd...>
	local label="$1" expected="$2" rc
	shift 2
	"$@" >/dev/null 2>&1
	rc=$?
	assert_eq "$label" "$expected" "$rc"
}
assert_re() {    # <label> <ERE> <text>
	if grep -qE -- "$2" <<<"$3"; then
		PASS=$((PASS + 1))
		printf '  PASS  %s\n' "$1"
	else
		FAIL=$((FAIL + 1))
		FAILURES+=("$1 (no line matches /$2/)")
		printf '  FAIL  %s — no line matches /%s/\n' "$1" "$2"
	fi
}

if [ "$(uname)" = "Linux" ]; then
	DATE_REAL="$(command -v date)"
elif command -v gdate >/dev/null 2>&1; then
	DATE_REAL="$(command -v gdate)"
else
	echo "SKIP: test-web-probe-lib.sh requires GNU date (Linux 'date' or macOS 'gdate' via Homebrew coreutils)"
	exit 0
fi

BIN="${TMP}/bin"
mkdir -p "$BIN" "${TMP}/empty"
printf '#!/usr/bin/env bash\nexec "%s" "$@"\n' "$DATE_REAL" >"${BIN}/date"
cat >"${BIN}/curl" <<'EOF'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >>"$STUB_ARGV_LOG"
hdr=""; prev=""
for a in "$@"; do
	[ "$prev" = "-D" ] && hdr="$a"
	prev="$a"
done
case "$STUB_MODE" in
	ok)
		[ -n "$hdr" ] && printf 'HTTP/2 200\r\ncf-ray: 8c1f00dd1a2b3c4d-SIN\r\n\r\n' >"$hdr"
		printf 'http_code=200 t_dns=0.001 t_connect=0.010 t_tls=0.020 t_ttfb=0.030 t_total=0.031 remote_ip=192.0.2.10'
		exit 0
		;;
	timeout)
		echo 'curl: (28) Operation timed out after 10001 milliseconds' >&2
		printf 'http_code=000 t_dns=0.001 t_connect=0.000 t_tls=0.000 t_ttfb=0.000 t_total=10.001 remote_ip='
		exit 28
		;;
	silent)
		exit 7
		;;
esac
EOF
cat >"${BIN}/mtr" <<'EOF'
#!/usr/bin/env bash
printf 'mtr %s\n' "$*" >>"$STUB_ARGV_LOG"
echo 'HOST: stub   Loss%   Snt   Last   Avg  Best  Wrst StDev'
EOF
cat >"${BIN}/timeout" <<'EOF'
#!/usr/bin/env bash
printf 'timeout %s\n' "$*" >>"$STUB_ARGV_LOG"
shift
exec "$@"
EOF
chmod +x "${BIN}"/*
export PATH="${BIN}:${PATH}"
export STUB_ARGV_LOG="${TMP}/argv.log"
export STUB_MODE=ok
: >"$STUB_ARGV_LOG"

# shellcheck source=scripts/lib/web-probe.sh
. "$LIB"

echo "=== web_is_ipv4 ==="
for ip in 192.0.2.10 198.51.100.255 203.0.113.0 127.0.0.1 0.0.0.0; do
	assert_rc "accepts [$ip]" 0 web_is_ipv4 "$ip"
done
for ip in "" 256.1.1.1 1.2.3 1.2.3.4. .1.2.3.4 1..2.3 a.b.c.d 1.2.3.4.5 \
	2001:db8::1 "192.0.2.10 " "192.0.2.10;x" 1234.1.1.1 010.0.0.1; do
	assert_rc "rejects [$ip]" 1 web_is_ipv4 "$ip"
done

echo "=== web_resolve_spec ==="
assert_eq "https → port 443" "example.invalid:443:192.0.2.10" "$(web_resolve_spec https://example.invalid 192.0.2.10)"
assert_eq "http → port 80" "example.invalid:80:192.0.2.10" "$(web_resolve_spec http://example.invalid/x 192.0.2.10)"
assert_eq "explicit port kept" "127.0.0.1:19123:127.0.0.1" "$(web_resolve_spec http://127.0.0.1:19123 127.0.0.1)"
assert_rc "non-IPv4 origin refused" 1 web_resolve_spec https://example.invalid not-an-ip

echo "=== web_classify (spec §3.2) ==="
assert_eq "P_cf 200 → no class" "" "$(web_classify 200 skipped)"
assert_eq "P_cf fail + P_direct 200 → cf_path" cf_path "$(web_classify 000 200)"
assert_eq "P_cf 522 + P_direct 200 → cf_path" cf_path "$(web_classify 522 200)"
assert_eq "P_cf fail + P_direct fail → origin_or_path" origin_or_path "$(web_classify 000 000)"
assert_eq "P_cf fail + P_direct 503 → origin_or_path" origin_or_path "$(web_classify 000 503)"
assert_eq "P_cf fail + P_direct skipped → unknown" unknown "$(web_classify 000 skipped)"

echo "=== labels ==="
assert_eq "cf_path label" 'Cloudflare 経路 (origin は正常)' "$(web_class_label cf_path)"
assert_eq "origin_or_path label" 'origin 停止 または シンガポール経路 (未判別)' "$(web_class_label origin_or_path)"
assert_eq "unknown label" '判別不能 (origin 直接確認なし)' "$(web_class_label unknown)"
assert_eq "labels for a class history" \
	'Cloudflare 経路 (origin は正常) → origin 停止 または シンガポール経路 (未判別)' \
	"$(web_class_labels_csv cf_path,origin_or_path)"
assert_eq "labels for an empty history" '-' "$(web_class_labels_csv '')"

echo "=== web_duration_min (rounded up, at least 1) ==="
for pair in 0:1 1:1 60:1 61:2 570:10 600:10 601:11 -5:1 abc:1; do
	assert_eq "duration ${pair%%:*}s → ${pair#*:} min" "${pair#*:}" "$(web_duration_min "${pair%%:*}")"
done

echo "=== web_cf_colo ==="
printf 'HTTP/2 522\r\nCF-RAY: 8c1f00dd1a2b3c4d-NRT\r\n' >"${TMP}/h1"
printf 'HTTP/2 200\r\ncf-ray: 8c1f00dd1a2b3c4d-SIN\r\n' >"${TMP}/h2"
printf 'HTTP/1.1 200 OK\r\nserver: nginx\r\n' >"${TMP}/h3"
assert_eq "colo from CF-RAY (any case)" NRT "$(web_cf_colo "${TMP}/h1")"
assert_eq "colo from cf-ray" SIN "$(web_cf_colo "${TMP}/h2")"
assert_eq "no cf-ray → -" - "$(web_cf_colo "${TMP}/h3")"
assert_eq "missing file → -" - "$(web_cf_colo "${TMP}/nope")"

echo "=== web_probe ==="
: >"$STUB_ARGV_LOG"
STUB_MODE=ok
assert_eq "200 → prints 200" 200 "$(web_probe "${TMP}/p1" https://example.invalid/health)"
assert_re "200 → timing line kept with curl rc" '^http_code=200 t_dns=.* remote_ip=192\.0\.2\.10 curl_rc=0$' "$(cat "${TMP}/p1.w")"
assert_re "200 → headers kept" '^cf-ray: 8c1f00dd1a2b3c4d-SIN' "$(tr -d '\r' <"${TMP}/p1.h")"
ARGV="$(tail -1 "$STUB_ARGV_LOG")"
assert_re "argv: 10 s cap" '--max-time 10 ' "$ARGV"
assert_re "argv: headers dumped to the scratch file" "-D ${TMP}/p1\.h " "$ARGV"
assert_eq "argv: no --resolve for P_cf" 0 "$(grep -c -- '--resolve' <<<"$ARGV")"
STUB_MODE=timeout
assert_eq "timeout → 000" 000 "$(web_probe "${TMP}/p2" https://example.invalid/health)"
assert_re "timeout → curl rc 28 recorded" 'curl_rc=28$' "$(cat "${TMP}/p2.w")"
assert_re "timeout → curl error kept" '\(28\)' "$(cat "${TMP}/p2.err")"
STUB_MODE=silent
assert_eq "no output at all → 000" 000 "$(web_probe "${TMP}/p3" https://example.invalid/health)"
assert_eq "no output → minimal timing line" 'http_code=000 curl_rc=7' "$(cat "${TMP}/p3.w")"
STUB_MODE=ok
web_probe "${TMP}/p4" https://example.invalid/health example.invalid:443:192.0.2.10 >/dev/null
assert_re "P_direct passes --resolve" '--resolve example\.invalid:443:192\.0\.2\.10 ' "$(tail -1 "$STUB_ARGV_LOG")"
assert_eq "unwritable scratch never degrades the verdict" 200 "$(web_probe /dev/null/nope https://example.invalid/health)"

echo "=== web_mtr_capture ==="
: >"$STUB_ARGV_LOG"
web_mtr_capture 192.0.2.10 "${TMP}/mtr1"
assert_eq "mtr under timeout 25 with the spec's flags" 'timeout 25 mtr -r -n -c 5 -w 192.0.2.10' "$(head -1 "$STUB_ARGV_LOG")"
assert_re "mtr report captured" '^HOST: stub' "$(cat "${TMP}/mtr1")"
: >"$STUB_ARGV_LOG"
web_mtr_capture "" "${TMP}/mtr2"
assert_eq "no IP → skipped" 'skipped (no valid WEB_ORIGIN_IP)' "$(cat "${TMP}/mtr2")"
assert_eq "no IP → mtr not invoked" 0 "$(grep -c . "$STUB_ARGV_LOG")"
(PATH="${TMP}/empty"; web_mtr_capture 192.0.2.10 "${TMP}/mtr3")
assert_eq "mtr absent → skipped, not an error" 'skipped (mtr not installed)' "$(cat "${TMP}/mtr3")"

echo "=== web_render_diag ==="
D="${TMP}/diag"
mkdir -p "$D"
printf 'http_code=000 t_dns=0.001 t_connect=0.000 t_tls=0.000 t_ttfb=0.000 t_total=10.001 remote_ip= curl_rc=28\n' >"${D}/cf1.w"
: >"${D}/cf1.h"
echo 'curl: (28) Operation timed out' >"${D}/cf1.err"
printf 'http_code=522 t_dns=0.001 t_connect=0.010 t_tls=0.020 t_ttfb=5.000 t_total=5.001 remote_ip=192.0.2.10 curl_rc=0\n' >"${D}/cf2.w"
printf 'HTTP/2 522\r\ncf-ray: 8c1f00dd1a2b3c4d-SIN\r\n\r\n' >"${D}/cf2.h"
: >"${D}/cf2.err"
echo 'HOST: stub' >"${D}/mtr"
OUT="$(web_render_diag "$D" unknown 2026-09-21T09:00:00Z skipped)"
assert_eq "header line" '=== web-diag 2026-09-21T09:00:00Z class=unknown ===' "$(head -1 <<<"$OUT")"
assert_re "cf#1 timing" '^\[cf#1\] http_code=000 .*curl_rc=28$' "$OUT"
assert_re "cf#1 stderr" '^\[cf#1 stderr\]$' "$OUT"
assert_re "cf#2 headers, CR stripped, indented" '^  cf-ray: 8c1f00dd1a2b3c4d-SIN$' "$OUT"
assert_re "direct skipped" '^\[direct\] skipped' "$OUT"
assert_re "mtr section" '^  HOST: stub$' "$OUT"
OUT2="$(web_render_diag "$D" cf_path 2026-09-21T09:00:00Z 200)"
assert_re "direct expected but absent → not run" '^\[direct\] not run$' "$OUT2"

echo "=== web_render_blip_line ==="
assert_eq "blip line" \
	'2026-09-21T09:00:00Z 2026-09-21T09:10:00Z duration_s=600 classes=cf_path,origin_or_path pushed=true' \
	"$(web_render_blip_line 1789981200 1789981800 cf_path,origin_or_path true)"
assert_eq "blip line, no classes" \
	'2026-09-21T09:00:00Z 2026-09-21T09:10:00Z duration_s=600 classes=- pushed=false' \
	"$(web_render_blip_line 1789981200 1789981800 '' false)"

echo "=== purity: the library performs no side effect of its own ==="
CODE_ONLY="$(grep -vE '^[[:space:]]*#' "$LIB")"
for pat in fyd_ notify candidate_set STATE_FILE /var/log /var/lib; do
	assert_eq "no '${pat}' in library code" 0 "$(grep -cF -- "$pat" <<<"$CODE_ONLY")"
done

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
	printf '\nFailures:\n'
	for f in "${FAILURES[@]}"; do printf '  - %s\n' "$f"; done
	exit 1
fi
exit 0
```

- [ ] **Step 2: Run it to verify it fails**

Run: `chmod +x tests/anomalies/test-web-probe-lib.sh && bash tests/anomalies/test-web-probe-lib.sh`
Expected: it exits non-zero before any PASS line, with `…/scripts/lib/web-probe.sh: No such file or directory` (the library does not exist yet).

- [ ] **Step 3: Write the library**

Create `scripts/lib/web-probe.sh` (mode 0644 like the other `scripts/lib/*.sh`; it is sourced, not executed):

```bash
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
```

- [ ] **Step 4: Run the library test to verify it passes**

Run: `bash tests/anomalies/test-web-probe-lib.sh | tail -1`
Expected: `Total: PASS=79 FAIL=0`

- [ ] **Step 5: Mutation-prove the library test (break → FAIL → restore → PASS)**

Each command breaks exactly one property. The suite must print at least one `  FAIL ` line for it. Restore from the backup after each one.

```bash
MUT="$(mktemp -d)"; cp scripts/lib/web-probe.sh "$MUT/wp"
restore() { cp "$MUT/wp" scripts/lib/web-probe.sh; }
# L1 duration rounds UP (the spec presents it as an upper bound)
perl -pi -e 's/echo \$\(\(\(s \+ 59\) \/ 60\)\)/echo \$((s \/ 60))/' scripts/lib/web-probe.sh
bash tests/anomalies/test-web-probe-lib.sh | grep -c '  FAIL '; restore      # expect 7
# L2 classification table (P_direct 200 → cf_path)
perl -pi -e 's/^\t\t200\) echo cf_path ;;/\t\t200) echo origin_or_path ;;/' scripts/lib/web-probe.sh
bash tests/anomalies/test-web-probe-lib.sh | grep -c '  FAIL '; restore      # expect 2
# L3 leading-zero octets are refused
perl -pi -e 's/^\t\t\t0\?\*\) return 1 ;;/\t\t\t0?*) : ;;/' scripts/lib/web-probe.sh
bash tests/anomalies/test-web-probe-lib.sh | grep -c '  FAIL '; restore      # expect 1
# L4 the verdict never depends on the scratch file
perl -pi -e 's/^\tcode=\$\(printf .*$/\tcode=\$(sed -n "s\/^http_code=\\([0-9][0-9][0-9]\\).*\/\\1\/p" "\${prefix}.w" 2>\/dev\/null)/' scripts/lib/web-probe.sh
bash tests/anomalies/test-web-probe-lib.sh | grep -c '  FAIL '; restore      # expect 2
cmp scripts/lib/web-probe.sh "$MUT/wp" && rm -rf "$MUT" && bash tests/anomalies/test-web-probe-lib.sh | tail -1
```

Expected: `7`, `2`, `1`, `2`, then `Total: PASS=79 FAIL=0`. Any non-zero count proves the property; these counts were measured on the reference implementation.

- [ ] **Step 6: Write the failing end-to-end test**

Create `tests/anomalies/test-web-incident.sh` and make it executable:

```bash
#!/usr/bin/env bash
# tests/anomalies/test-web-incident.sh
#
# Public-site probe: path classification, persistence gate, diagnostics and
# the optional web_incident state field — spec
# docs/superpowers/specs/2026-09-24-web-probe-path-classification-design.md
# §5 cases 1-8 (case 9 lives in tests/install-anomalies-web-origin-env/).
#
# Strategy: runs the REAL scripts/check-anomalies.sh end to end, several
# times against one sandbox state file, the way cron does — the same shape
# as tests/anomalies/test-delegation-notify-body.sh. The properties under
# test span runs ("no push on run 1, one push on run 2, none on run 3"), so
# they can only be observed across real candidate-state commits; a
# sed-extracted block would have to re-implement the commit it is meant to
# test. The real K-3.5 schema check, notify_or_keep retry path and commit
# are exercised, not stubbed.
#
# PATH stand-ins (test-local; nothing on this machine is modified):
#   curl     /health: P_cf answers from a per-sandbox queue (one code per
#            call, the last one repeats); P_direct (recognised by --resolve)
#            answers a fixed code. /api/validator.json answers a fresh
#            observedAt. The P-chain RPC fails, so the validator/period
#            transitions are skipped (as in the delegation suite).
#   sleep    no-op, logged (the 30 s re-probe and notify's 5 s retry)
#   timeout  logged, then runs the rest of its argv
#   mtr      logged, prints one line
#   flock    no-op where util-linux is absent (macOS)
#   date     GNU date (gdate on macOS); the suite SKIPs when neither exists
# The sandbox's scripts/notify.sh records prio / title / body per call and
# exits with the code in notify.rc.
#
# CHAIN: none. PRIME_DIRECTIVE: TESTNET-FIRST — safe (no broadcast, no
# network: every curl is the stub).

set -uo pipefail
exec </dev/null

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="${REPO}/scripts/check-anomalies.sh"

PASS=0
FAIL=0
FAILURES=()
assert_eq() {
	local label="$1" expected="$2" actual="$3"
	if [ "$expected" = "$actual" ]; then
		PASS=$((PASS + 1))
		printf '  PASS  %s\n' "$label"
	else
		FAIL=$((FAIL + 1))
		FAILURES+=("$label (expected='$expected', actual='$actual')")
		printf '  FAIL  %s expected=[%s] actual=[%s]\n' "$label" "$expected" "$actual"
	fi
}
assert_has() {   # <label> <fixed string> <text>
	if grep -qF -- "$2" <<<"$3"; then
		PASS=$((PASS + 1))
		printf '  PASS  %s\n' "$1"
	else
		FAIL=$((FAIL + 1))
		FAILURES+=("$1 (missing '$2')")
		printf '  FAIL  %s — missing [%s]\n' "$1" "$2"
	fi
}
assert_re() {    # <label> <ERE> <text>
	if grep -qE -- "$2" <<<"$3"; then
		PASS=$((PASS + 1))
		printf '  PASS  %s\n' "$1"
	else
		FAIL=$((FAIL + 1))
		FAILURES+=("$1 (no line matches /$2/)")
		printf '  FAIL  %s — no line matches /%s/\n' "$1" "$2"
	fi
}

TMP="$(mktemp -d -t fy-web-incident.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
BIN="${TMP}/bin"
mkdir -p "$BIN"

if date -u -d '@0' +%s >/dev/null 2>&1; then
	:
elif command -v gdate >/dev/null 2>&1; then
	printf '#!/usr/bin/env bash\nexec %s "$@"\n' "$(command -v gdate)" >"${BIN}/date"
else
	echo "SKIP: test-web-incident.sh requires GNU date (Linux 'date' or macOS 'gdate' via Homebrew coreutils)"
	exit 0
fi
if ! command -v flock >/dev/null 2>&1; then
	printf '#!/usr/bin/env bash\nexit 0\n' >"${BIN}/flock"
fi
cat >"${BIN}/sleep" <<'EOF'
#!/usr/bin/env bash
printf 'sleep %s\n' "$*" >>"$STUB_LOG"
exit 0
EOF
cat >"${BIN}/timeout" <<'EOF'
#!/usr/bin/env bash
printf 'timeout %s\n' "$*" >>"$STUB_LOG"
shift
exec "$@"
EOF
cat >"${BIN}/mtr" <<'EOF'
#!/usr/bin/env bash
printf 'mtr %s\n' "$*" >>"$STUB_LOG"
echo 'HOST: stub   Loss%   Snt   Last   Avg  Best  Wrst StDev'
EOF
cat >"${BIN}/curl" <<'EOF'
#!/usr/bin/env bash
url=""; out=""; hdr=""; resolve=""
while [ "$#" -gt 0 ]; do
	case "$1" in
		-o) out="$2"; shift 2 ;;
		-D) hdr="$2"; shift 2 ;;
		--resolve) resolve="$2"; shift 2 ;;
		-w | --max-time | -X | -H | --data) shift 2 ;;
		-*) shift ;;
		*) url="$1"; shift ;;
	esac
done
printf 'curl url=%s resolve=%s\n' "$url" "${resolve:-none}" >>"$STUB_LOG"
case "$url" in
	*/ext/bc/P) exit 7 ;;
	*/api/validator.json)
		printf '{"observedAt":"%s"}' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$out"
		printf '200'
		exit 0
		;;
	*/health)
		if [ -n "$resolve" ]; then
			code=$(cat "$DIRECT_CODE_FILE")
		else
			code=$(head -1 "$CF_QUEUE")
			if [ "$(wc -l <"$CF_QUEUE" | tr -d ' ')" -gt 1 ]; then
				tail -n +2 "$CF_QUEUE" >"${CF_QUEUE}.next" && mv "${CF_QUEUE}.next" "$CF_QUEUE"
			fi
			if [ -n "$hdr" ] && [ "$code" != "000" ]; then
				printf 'HTTP/2 %s\r\ncf-ray: 8c1f00dd1a2b3c4d-SIN\r\n\r\n' "$code" >"$hdr"
			fi
		fi
		if [ "$code" = "000" ]; then
			echo 'curl: (28) Operation timed out after 10001 milliseconds' >&2
			printf 'http_code=000 t_dns=0.004 t_connect=0.000 t_tls=0.000 t_ttfb=0.000 t_total=10.001 remote_ip='
			exit 28
		fi
		printf 'http_code=%s t_dns=0.004 t_connect=0.012 t_tls=0.030 t_ttfb=0.050 t_total=0.051 remote_ip=192.0.2.10' "$code"
		exit 0
		;;
esac
exit 7
EOF
chmod +x "${BIN}"/*

# new_sandbox <name> [web] — fresh repo copy + baseline state (web ok, no
# web_incident). Sets S and the per-sandbox stub control files.
new_sandbox() {
	S="${TMP}/$1"
	local web="${2:-ok}"
	rm -rf "$S"
	mkdir -p "${S}/scripts/lib" "${S}/public/api" "${S}/state/locks" "${S}/notify"
	cp "$SCRIPT" "${S}/scripts/check-anomalies.sh"
	cp -R "${REPO}/scripts/lib/." "${S}/scripts/lib/"
	cat >"${S}/scripts/notify.sh" <<'SHIM'
#!/usr/bin/env bash
n=$(( $(cat "${NOTIFY_DIR}/count" 2>/dev/null || echo 0) + 1 ))
printf '%s' "$n" >"${NOTIFY_DIR}/count"
printf '%s|%s|%s\n' "$n" "$1" "$2" >>"${NOTIFY_DIR}/index"
printf '%s' "$3" >"${NOTIFY_DIR}/body.${n}"
exit "$(cat "$NOTIFY_RC_FILE" 2>/dev/null || echo 0)"
SHIM
	chmod +x "${S}/scripts/notify.sh"
	cat >"${S}/public/api/server-status.json" <<JSON
{
  "observedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "metalgo": { "containerStatus": "running", "peerCount": 120 },
  "caddy":   { "containerStatus": "running" },
  "host": {
    "cpu":    { "usedPercent": 15 },
    "memory": { "usedPercent": 30, "totalKB": 16000000, "usedKB":  4800000 },
    "disk":   { "usedPercent": 40, "totalKB": 500000000, "usedKB": 200000000 }
  }
}
JSON
	printf '{ "nodeId": "NodeID-sandbox", "uptime": { "network": "99.0000" }, "stake": { "self": 12600 } }\n' \
		>"${S}/public/api/validator.json"
	cat >"${S}/state/anomaly-state.json" <<JSON
{
  "metalgo": "running", "caddy": "running", "disk": "ok", "memory": "ok",
  "peers": "ok", "web": "${web}", "api_freshness": "ok",
  "validator_present": "yes", "last_known_end_time": null,
  "delegator_count": null, "delegator_total_nmetal": null,
  "period_alert_sent": { "7": false, "1": false, "0": false, "10min": false }
}
JSON
	STATE="${S}/state/anomaly-state.json"
	STUB_LOG="${S}/stub.log"
	CF_QUEUE="${S}/cf.queue"
	DIRECT_CODE_FILE="${S}/direct.code"
	NOTIFY_RC_FILE="${S}/notify.rc"
	NOTIFY_DIR="${S}/notify"
	DIAG_LOG="${S}/state/anomalies-web-diag.log"
	BLIP_LOG="${S}/state/anomalies-web-blips.log"
	echo 200 >"$CF_QUEUE"
	echo 200 >"$DIRECT_CODE_FILE"
	echo 0 >"$NOTIFY_RC_FILE"
	: >"$STUB_LOG"
}

# run_check [VAR=value ...] — one cron tick. Later assignments override the
# defaults (env applies them left to right). Returns the script's rc.
run_check() {
	: >"$STUB_LOG"
	rm -f "${NOTIFY_DIR}/index" "${NOTIFY_DIR}/count" "${NOTIFY_DIR}"/body.*
	env PATH="${BIN}:${PATH}" FY_LIVE=1 NTFY_TAGS= \
		NOTIFY= FYD_NOTIFY= ANCHOR_NOTIFY= WATCH_NOTIFY= FY_STATE_DIR= \
		ANOMALY_STATE_DIR="${S}/state" METALGO_API="http://127.0.0.1:1" \
		WEB_URL="https://example.invalid" WEB_ORIGIN_IP="192.0.2.10" \
		WEB_DIAG_LOG= WEB_BLIP_LOG= FRESH_REPROBE_SLEEP=0 \
		STUB_LOG="$STUB_LOG" CF_QUEUE="$CF_QUEUE" DIRECT_CODE_FILE="$DIRECT_CODE_FILE" \
		NOTIFY_RC_FILE="$NOTIFY_RC_FILE" NOTIFY_DIR="$NOTIFY_DIR" \
		"$@" bash "${S}/scripts/check-anomalies.sh" >"${S}/run.out" 2>"${S}/run.err"
}

set_cf()        { printf '%s\n' "$@" >"$CF_QUEUE"; }
set_direct()    { echo "$1" >"$DIRECT_CODE_FILE"; }
set_notify_rc() { echo "$1" >"$NOTIFY_RC_FILE"; }
st()            { jq -c "$1" "$STATE"; }
backdate()      { jq ".web_incident.started_at -= $1" "$STATE" >"${STATE}.tmp" && mv "${STATE}.tmp" "$STATE"; }
count_in()      { [ -f "$2" ] || { echo 0; return; }; grep -c -- "$1" "$2" || true; }
pushes()        { count_in '|' "${NOTIFY_DIR}/index"; }
push_prio()     { sed -n "${1}p" "${NOTIFY_DIR}/index" | cut -d'|' -f2; }
push_title()    { sed -n "${1}p" "${NOTIFY_DIR}/index" | cut -d'|' -f3-; }
push_body()     { cat "${NOTIFY_DIR}/body.${1}" 2>/dev/null; }
cf_probes()     { count_in 'url=https://example.invalid/health resolve=none' "$STUB_LOG"; }
direct_probes() { count_in 'resolve=example.invalid:443:192.0.2.10' "$STUB_LOG"; }
sleeps()        { count_in '^sleep ' "$STUB_LOG"; }
mtr_calls()     { count_in '^mtr ' "$STUB_LOG"; }
diag_blocks()   { count_in '^=== web-diag ' "$DIAG_LOG"; }
blip_lines()    { count_in 'duration_s=' "$BLIP_LOG"; }

OUTAGE_TITLE='公開サイトが応答しない (5 分以上継続)'
CF_TITLE='公開サイト: Cloudflare 経路で失敗継続 (origin は正常)'
RECOVERY_TITLE='公開サイト復旧'

echo "=== healthy steady state: one request, nothing else ==="
new_sandbox steady
set_cf 200
run_check; rc=$?
assert_eq "steady: rc=0" 0 "$rc"
assert_eq "steady: exactly one P_cf request" 1 "$(cf_probes)"
assert_eq "steady: no P_direct" 0 "$(direct_probes)"
assert_eq "steady: no sleep" 0 "$(sleeps)"
assert_eq "steady: no mtr" 0 "$(mtr_calls)"
assert_eq "steady: no push" 0 "$(pushes)"
assert_eq "steady: web_incident absent" null "$(st '.web_incident')"
assert_eq "steady: no diagnostics file" no "$([ -e "$DIAG_LOG" ] && echo yes || echo no)"

echo "=== case 1: blip that recovers inside the 30 s re-probe ==="
new_sandbox c1
set_cf 000 200
run_check; rc=$?
assert_eq "c1: rc=0" 0 "$rc"
assert_eq "c1: re-probed (2 P_cf)" 2 "$(cf_probes)"
assert_eq "c1: re-probe slept WEB_REPROBE_SLEEP default 30" 1 "$(count_in '^sleep 30$' "$STUB_LOG")"
assert_eq "c1: no P_direct" 0 "$(direct_probes)"
assert_eq "c1: no push" 0 "$(pushes)"
assert_eq "c1: no incident" null "$(st '.web_incident')"
assert_eq "c1: .web stays ok" '"ok"' "$(st '.web')"
assert_eq "c1: no diagnostics block" 0 "$(diag_blocks)"

echo "=== case 2: fails the re-probe, recovers next run → no push, one blip line ==="
new_sandbox c2
set_cf 000 000; set_direct 200
run_check; rc=$?
assert_eq "c2 run1: rc=0" 0 "$rc"
assert_eq "c2 run1: no push" 0 "$(pushes)"
assert_eq "c2 run1: incident opened" '{"runs":1,"pushed":false,"last_class":"cf_path","classes":["cf_path"]}' \
	"$(st '.web_incident | {runs, pushed, last_class, classes}')"
assert_eq "c2 run1: started_at is an epoch" number "$(jq -r '.web_incident.started_at | type' "$STATE")"
assert_eq "c2 run1: one diagnostics block" 1 "$(diag_blocks)"
assert_re "c2 run1: diag header names the class" '^=== web-diag [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z class=cf_path ===$' "$(cat "$DIAG_LOG")"
set_cf 200
run_check; rc=$?
assert_eq "c2 run2: rc=0" 0 "$rc"
assert_eq "c2 run2: no push" 0 "$(pushes)"
assert_eq "c2 run2: incident cleared" null "$(st '.web_incident')"
assert_eq "c2 run2: .web ok" '"ok"' "$(st '.web')"
assert_eq "c2 run2: one blip line" 1 "$(blip_lines)"
assert_re "c2 run2: blip line shape, pushed=false" \
	'^[0-9T:-]+Z [0-9T:-]+Z duration_s=[0-9]+ classes=cf_path pushed=false$' "$(cat "$BLIP_LOG")"

echo "=== case 3: origin_or_path persists → one high push on run 2, none on run 3 ==="
new_sandbox c3
set_cf 000 000; set_direct 000
run_check
assert_eq "c3 run1: no push" 0 "$(pushes)"
set_cf 000
run_check; rc=$?
assert_eq "c3 run2: rc=0" 0 "$rc"
assert_eq "c3 run2: no re-probe while an incident is open (1 P_cf)" 1 "$(cf_probes)"
assert_eq "c3 run2: exactly one push" 1 "$(pushes)"
assert_eq "c3 run2: priority high" high "$(push_prio 1)"
assert_eq "c3 run2: outage title" "$OUTAGE_TITLE" "$(push_title 1)"
B="$(push_body 1)"
assert_has "c3 run2: body names the class" '分類: origin 停止 または シンガポール経路 (未判別)' "$B"
assert_has "c3 run2: body carries the duration" '継続: 約 ' "$B"
assert_has "c3 run2: body quotes the P_cf timing" 'Cloudflare 経由: http_code=000' "$B"
assert_has "c3 run2: body quotes the P_direct timing" 'origin 直接: http_code=000' "$B"
assert_has "c3 run2: body points at the diagnostics file" "診断: ${DIAG_LOG}" "$B"
assert_eq "c3 run2: .web=warn" '"warn"' "$(st '.web')"
assert_eq "c3 run2: pushed=true runs=2" '{"pushed":true,"runs":2}' "$(st '.web_incident | {pushed, runs}')"
run_check; rc=$?
assert_eq "c3 run3: rc=0" 0 "$rc"
assert_eq "c3 run3: no further push" 0 "$(pushes)"
assert_eq "c3 run3: runs=3" 3 "$(st '.web_incident.runs')"

echo "=== case 5: recovery after a push → default push with duration + classes ==="
backdate 570
set_cf 200
run_check; rc=$?
assert_eq "c5: rc=0" 0 "$rc"
assert_eq "c5: exactly one push" 1 "$(pushes)"
assert_eq "c5: priority default" default "$(push_prio 1)"
assert_eq "c5: recovery title" "$RECOVERY_TITLE" "$(push_title 1)"
B="$(push_body 1)"
assert_has "c5: body carries the duration as an observation bound" '継続: 約 10 分 (5 分刻みの観測)' "$B"
assert_has "c5: body carries the classes seen" '観測した分類: origin 停止 または シンガポール経路 (未判別)' "$B"
assert_eq "c5: .web back to ok" '"ok"' "$(st '.web')"
assert_eq "c5: incident cleared" null "$(st '.web_incident')"
assert_eq "c5: one blip line" 1 "$(blip_lines)"
assert_re "c5: blip line pushed=true" 'duration_s=(57[0-9]|58[0-9]|59[0-9]|600) classes=origin_or_path pushed=true$' "$(cat "$BLIP_LOG")"

echo "=== case 4: cf_path persists → default push with the Cloudflare title ==="
new_sandbox c4
set_cf 522 522; set_direct 200
run_check
set_cf 522
run_check; rc=$?
assert_eq "c4 run2: rc=0" 0 "$rc"
assert_eq "c4 run2: exactly one push" 1 "$(pushes)"
assert_eq "c4 run2: priority default" default "$(push_prio 1)"
assert_eq "c4 run2: Cloudflare title" "$CF_TITLE" "$(push_title 1)"
B="$(push_body 1)"
assert_has "c4 run2: body names the class" '分類: Cloudflare 経路 (origin は正常)' "$B"
assert_has "c4 run2: body carries the cf-ray colo" 'cf-ray colo: SIN' "$B"
assert_eq "c4 run2: .web=warn" '"warn"' "$(st '.web')"

echo "=== case 6: outage push fails → pushed stays false, next run pushes ==="
new_sandbox c6
set_cf 000 000; set_direct 000
run_check
set_cf 000; set_notify_rc 2
run_check; rc=$?
assert_eq "c6 run2: rc=6 (notify permanently failed)" 6 "$rc"
assert_eq "c6 run2: two attempts (rc 2 is retried once)" 2 "$(pushes)"
assert_eq "c6 run2: pushed stays false" false "$(st '.web_incident.pushed')"
assert_eq "c6 run2: .web stays ok" '"ok"' "$(st '.web')"
assert_eq "c6 run2: runs still advances (observation)" 2 "$(st '.web_incident.runs')"
set_notify_rc 0
run_check; rc=$?
assert_eq "c6 run3: rc=0" 0 "$rc"
assert_eq "c6 run3: the push goes out" 1 "$(pushes)"
assert_eq "c6 run3: outage title" "$OUTAGE_TITLE" "$(push_title 1)"
assert_eq "c6 run3: pushed=true" true "$(st '.web_incident.pushed')"
assert_eq "c6 run3: .web=warn" '"warn"' "$(st '.web')"

echo "=== case 7: WEB_ORIGIN_IP unset → P_direct skipped, class unknown, high push ==="
new_sandbox c7
set_cf 000 000
run_check WEB_ORIGIN_IP=
assert_eq "c7 run1: no P_direct request" 0 "$(count_in 'resolve=[^n]' "$STUB_LOG")"
assert_eq "c7 run1: no mtr (nothing to trace)" 0 "$(mtr_calls)"
assert_eq "c7 run1: class unknown" '"unknown"' "$(st '.web_incident.last_class')"
assert_has "c7 run1: diagnostics say P_direct was skipped" '[direct] skipped' "$(cat "$DIAG_LOG")"
set_cf 000
run_check WEB_ORIGIN_IP=; rc=$?
assert_eq "c7 run2: rc=0" 0 "$rc"
assert_eq "c7 run2: priority high" high "$(push_prio 1)"
assert_eq "c7 run2: outage title" "$OUTAGE_TITLE" "$(push_title 1)"
assert_has "c7 run2: body names the class" '分類: 判別不能 (origin 直接確認なし)' "$(push_body 1)"

echo "=== case 7b: a malformed WEB_ORIGIN_IP is refused, not used ==="
new_sandbox c7b
set_cf 000 000
run_check WEB_ORIGIN_IP='192.0.2.10;x'
assert_eq "c7b: no P_direct request" 0 "$(count_in 'resolve=[^n]' "$STUB_LOG")"
assert_eq "c7b: class unknown" '"unknown"' "$(st '.web_incident.last_class')"
assert_has "c7b: refusal is logged" 'not a dotted-quad IPv4 address' "$(cat "${S}/run.err")"

echo "=== class change within one incident ==="
new_sandbox cx
set_cf 000 000; set_direct 200
run_check
set_cf 000; set_direct 000
run_check
assert_eq "cx run2: push by the LATEST class (high)" high "$(push_prio 1)"
assert_eq "cx run2: classes keep the history" '["cf_path","origin_or_path"]' "$(st '.web_incident.classes')"
assert_eq "cx run2: last_class is the latest" '"origin_or_path"' "$(st '.web_incident.last_class')"

echo "=== diagnostics block content ==="
new_sandbox diag
set_cf 522 000; set_direct 000
run_check
D="$(cat "$DIAG_LOG")"
assert_re "diag: P_cf #1 timing line" '^\[cf#1\] http_code=522 .* curl_rc=0$' "$D"
assert_re "diag: P_cf #1 headers kept (cf-ray)" '^  cf-ray: 8c1f00dd1a2b3c4d-SIN$' "$D"
assert_re "diag: P_cf #2 timing line" '^\[cf#2\] http_code=000 .* curl_rc=28$' "$D"
assert_re "diag: P_cf #2 curl error kept" '^  curl: \(28\) Operation timed out' "$D"
assert_re "diag: P_direct timing line" '^\[direct\] http_code=000 ' "$D"
assert_re "diag: mtr section" '^\[mtr\]$' "$D"
assert_eq "diag: mtr ran under timeout 25 with the spec's flags" 1 \
	"$(count_in '^timeout 25 mtr -r -n -c 5 -w 192.0.2.10$' "$STUB_LOG")"
assert_eq "diag: log written beside the sandbox state, not /var/log" yes \
	"$([ -s "${S}/state/anomalies-web-diag.log" ] && echo yes || echo no)"

echo "=== legacy state: .web=warn without web_incident ==="
new_sandbox legacy warn
set_cf 000
run_check; rc=$?
assert_eq "legacy fail: rc=0" 0 "$rc"
assert_eq "legacy fail: no re-probe" 1 "$(cf_probes)"
assert_eq "legacy fail: no second outage push" 0 "$(pushes)"
assert_eq "legacy fail: state not converted" null "$(st '.web_incident')"
set_cf 200
run_check
assert_eq "legacy recover: one push" 1 "$(pushes)"
assert_eq "legacy recover: recovery title" "$RECOVERY_TITLE" "$(push_title 1)"
assert_has "legacy recover: duration honestly unknown" '継続: 不明' "$(push_body 1)"
assert_eq "legacy recover: .web ok" '"ok"' "$(st '.web')"
assert_eq "legacy recover: no blip line (start unknown)" 0 "$(blip_lines)"

echo "=== case 8: K-3.5 schema — web_incident optional, validated when present ==="
new_sandbox s_absent
run_check; rc=$?
assert_eq "schema: absent web_incident passes (rc=0)" 0 "$rc"
new_sandbox s_null
jq '.web_incident = null' "$STATE" >"${STATE}.tmp" && mv "${STATE}.tmp" "$STATE"
run_check; rc=$?
assert_eq "schema: null web_incident passes (rc=0)" 0 "$rc"
for bad in \
	'{"started_at":"x","last_class":"cf_path","classes":["cf_path"],"runs":1,"pushed":false}' \
	'{"started_at":1,"last_class":"bogus","classes":["cf_path"],"runs":1,"pushed":false}' \
	'{"started_at":1,"last_class":"cf_path","classes":[1],"runs":1,"pushed":false}' \
	'{"started_at":1,"last_class":"cf_path","classes":["cf_path"],"runs":1,"pushed":"no"}' \
	'false'; do
	new_sandbox s_bad
	jq --argjson wi "$bad" '.web_incident = $wi' "$STATE" >"${STATE}.tmp" && mv "${STATE}.tmp" "$STATE"
	run_check; rc=$?
	assert_eq "schema: malformed web_incident $bad → exit 4" 4 "$rc"
	assert_eq "schema: …and is quarantined" 1 "$(find "${S}/state/quarantine" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"
done

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
	printf '\nFailures:\n'
	for f in "${FAILURES[@]}"; do printf '  - %s\n' "$f"; done
	exit 1
fi
exit 0
```

- [ ] **Step 7: Run it to verify it fails**

Run: `chmod +x tests/anomalies/test-web-incident.sh && bash tests/anomalies/test-web-incident.sh | grep -E '  FAIL ' | head -3`
Expected:

```
  FAIL  steady: exactly one P_cf request expected=[1] actual=[2]
  FAIL  steady: no sleep expected=[0] actual=[1]
  FAIL  steady: no push expected=[0] actual=[1]
```

The "steady" failures come from the stub printing the new `-w` format, which the old parser does not read. The later cases fail for the real reasons: for example `c1: no push expected=[0] actual=[1]` (the current script pages on the first failed run) and `c2 run1: incident opened …` (it never writes `web_incident`).

- [ ] **Step 8: Source the library in `check-anomalies.sh`**

In `scripts/check-anomalies.sh`, directly after these existing lines (~61-62):

```bash
# shellcheck source=scripts/lib/side-effects.sh
. "$FYD_LIB"
```

insert:

```bash
WEB_PROBE_LIB="${ROOT}/scripts/lib/web-probe.sh"
if [ ! -r "$WEB_PROBE_LIB" ]; then
  echo "[check-anomalies] FATAL: web-probe library not readable at $WEB_PROBE_LIB" >&2
  exit 1
fi
# shellcheck source=scripts/lib/web-probe.sh
. "$WEB_PROBE_LIB"
```

- [ ] **Step 9: Update the header comment in `check-anomalies.sh`**

Replace lines 15-17:

```bash
#   - public web URL (web host, behind edge CDN) returns non-200 — 1 回目で fail したら
#     30 秒後に即再確認、2 回連続で fail なら alert(transient blip は ~50 秒で
#     黙ってミュート、本物の障害は ~50 秒で検知)
```

with:

```bash
#   - public web URL (web host, behind edge CDN) /health non-200 — 1 回目で fail
#     したら 30 秒後に再確認。再確認でも fail なら web_incident を開き (push なし)、
#     origin 直接 probe (WEB_ORIGIN_IP) で cf_path / origin_or_path / unknown に
#     分類して診断を /var/log/anomalies-web-diag.log に残す。次の cron run でも
#     fail なら分類別の priority で push (≈5 分の持続 gate)、復旧 push は継続時間と
#     分類を載せる。docs/superpowers/specs/2026-09-24-web-probe-path-classification-design.md
```

and replace the state-file doc line (~26):

```bash
#     "web":     "ok",        ← web host(web 配信) の公開到達性
```

with:

```bash
#     "web":     "ok",        ← web host(web 配信) の公開到達性 (warn = outage push 済)
#     "web_incident": null,   ← optional; open public-site incident
#                               {started_at, last_class, classes, runs, pushed}
```

- [ ] **Step 10: Add the optional `web_incident` clause to the K-3.5 schema check**

In the `# Schema check:` jq program (~399-417), replace the last program line and the closing quote:

```bash
    (.period_alert_sent|has("10min"))
  ' "$STATE_FILE" >/dev/null 2>&1; then
```

with:

```bash
    (.period_alert_sent|has("10min")) and
    ((if has("web_incident") then .web_incident else null end) as $wi |
      ($wi == null) or (
        ($wi|type=="object") and
        ($wi.started_at|type=="number") and
        ($wi.last_class as $c | ["cf_path","origin_or_path","unknown"] | any(.[]; . == $c)) and
        ($wi.classes|type=="array") and
        ($wi.classes|all(.[]; type=="string")) and
        ($wi.runs|type=="number") and
        ($wi.pushed|type=="boolean")))
  ' "$STATE_FILE" >/dev/null 2>&1; then
```

Verified with jq 1.8: `{}` and `{"web_incident":null}` pass. `false`, a string `started_at`, an unknown `last_class`, a non-string class and a string `pushed` all fail.

- [ ] **Step 11: Clean up the probe scratch dir on exit**

Replace `cleanup_k3` (~450):

```bash
cleanup_k3() {
  rm -f "$ORIGINAL_STATE" "$CANDIDATE_STATE" "${CANDIDATE_STATE}.swp" 2>/dev/null || true
}
```

with:

```bash
cleanup_k3() {
  rm -f "$ORIGINAL_STATE" "$CANDIDATE_STATE" "${CANDIDATE_STATE}.swp" 2>/dev/null || true
  # Web-probe scratch (mktemp -d under TMPDIR, not the state dir; see the
  # web observation block). /dev/null is the "mktemp failed" sentinel.
  if [ -n "${WEB_PROBE_DIR:-}" ] && [ "${WEB_PROBE_DIR}" != /dev/null ] && [ -d "${WEB_PROBE_DIR}" ]; then
    rm -rf "${WEB_PROBE_DIR}" 2>/dev/null || true
  fi
}
```

- [ ] **Step 12: Replace the web observation and transition blocks**

Delete everything from the line `# === observation: web URL availability (with blip-mitigation re-check) ==` down to, but not including, the line `# === transition: api_freshness (= push pipeline health, web-gated) ======`. That removes the old inline `web_probe()` (the library now defines `web_probe` with a different signature), the old re-probe and the old `# === transition: web (notify-gated)` block. Insert this in its place:

```bash
# === observation: web URL availability (probe + path classification) ===
# Design: docs/superpowers/specs/2026-09-24-web-probe-path-classification-design.md
# P_cf is what a visitor sees (through Cloudflare). If it fails while no web
# incident is open and .web is ok, it is re-probed once after
# WEB_REPROBE_SLEEP (30 s). If it is still failing, P_direct probes the
# origin directly (curl --resolve to WEB_ORIGIN_IP, supplied by the cron env
# and never committed) and the failure is classified (spec §3.2). A healthy
# run makes exactly one request. Probing, classification and text rendering
# live in scripts/lib/web-probe.sh; every side effect and every state change
# stays in this file.
WEB_URL="${WEB_URL:-https://metal.freedom-yield.com}"
WEB_ORIGIN_IP="${WEB_ORIGIN_IP:-}"
# Log defaults follow the RESOLVED state dir, like LOCK_FILE above: with the
# production state dir they are the /var/log files logrotate keeps 90 days
# (scripts/install-anomalies-logrotate.sh); with any other state dir — every
# test sandbox — they land beside that state instead of reaching into
# /var/log.
if [ "$STATE_DIR" = "$FYD_STATE_DIR_DEFAULT" ]; then
  WEB_LOG_DIR_DEFAULT=/var/log
else
  WEB_LOG_DIR_DEFAULT="$STATE_DIR"
fi
WEB_DIAG_LOG="${WEB_DIAG_LOG:-${WEB_LOG_DIR_DEFAULT}/anomalies-web-diag.log}"
WEB_BLIP_LOG="${WEB_BLIP_LOG:-${WEB_LOG_DIR_DEFAULT}/anomalies-web-blips.log}"
WEB_NOW=$(date +%s)
WEB_NOW_ISO=$(date -u -d "@${WEB_NOW}" +%Y-%m-%dT%H:%M:%SZ)

ORIG_WEB=$(orig_get '.web'); [ "$ORIG_WEB" = "null" ] && ORIG_WEB="ok"
ORIG_WI=$(orig_get '(.web_incident // empty) | tojson')
WI_OPEN=0; WI_STARTED=""; WI_RUNS=0; WI_PUSHED=false; WI_CLASSES='[]'; WI_LEGACY=0
if [ -n "$ORIG_WI" ]; then
  WI_OPEN=1
  WI_STARTED=$(printf '%s' "$ORIG_WI" | jq -r '.started_at')
  WI_RUNS=$(printf '%s' "$ORIG_WI" | jq -r '.runs')
  WI_PUSHED=$(printf '%s' "$ORIG_WI" | jq -r '.pushed')
  WI_CLASSES=$(printf '%s' "$ORIG_WI" | jq -c '.classes')
elif [ "$ORIG_WEB" = "warn" ]; then
  # .web=warn written before web_incident existed: an outage push already
  # went out, but its start is unknown. Treated as open + pushed (no second
  # outage push, no re-probe); see the transition block.
  WI_OPEN=1; WI_PUSHED=true; WI_LEGACY=1
fi

WEB_PROBE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fy-web-probe.XXXXXX" 2>/dev/null) || WEB_PROBE_DIR=/dev/null
OBS_WEB_STATUS=$(web_probe "${WEB_PROBE_DIR}/cf1" "${WEB_URL}/health")
if [ "$OBS_WEB_STATUS" != "200" ] && [ "$WI_OPEN" = "0" ] && [ "$ORIG_WEB" = "ok" ]; then
  sleep "${WEB_REPROBE_SLEEP:-30}"
  OBS_WEB_STATUS=$(web_probe "${WEB_PROBE_DIR}/cf2" "${WEB_URL}/health")
fi

OBS_WEB_DIRECT=""
OBS_WEB_CLASS=""
if [ "$OBS_WEB_STATUS" != "200" ]; then
  OBS_WEB_DIRECT=skipped
  WEB_TRACE_IP=""
  if [ -n "$WEB_ORIGIN_IP" ]; then
    if WEB_RESOLVE=$(web_resolve_spec "$WEB_URL" "$WEB_ORIGIN_IP"); then
      WEB_TRACE_IP="$WEB_ORIGIN_IP"
      OBS_WEB_DIRECT=$(web_probe "${WEB_PROBE_DIR}/direct" "${WEB_URL}/health" "$WEB_RESOLVE")
    else
      echo "[web] WEB_ORIGIN_IP is not a dotted-quad IPv4 address; P_direct skipped" >&2
    fi
  fi
  OBS_WEB_CLASS=$(web_classify "$OBS_WEB_STATUS" "$OBS_WEB_DIRECT")
  web_mtr_capture "$WEB_TRACE_IP" "${WEB_PROBE_DIR}/mtr"

  WEB_CF_LAST="${WEB_PROBE_DIR}/cf1"
  [ -f "${WEB_PROBE_DIR}/cf2.w" ] && WEB_CF_LAST="${WEB_PROBE_DIR}/cf2"
  WEB_CF_LINE=$(web_timing_line "$WEB_CF_LAST")
  WEB_COLO=$(web_cf_colo "${WEB_CF_LAST}.h")
  if [ "$OBS_WEB_DIRECT" = "skipped" ]; then
    WEB_DIRECT_LINE='skipped (WEB_ORIGIN_IP 未設定 または IPv4 でない)'
  else
    WEB_DIRECT_LINE=$(web_timing_line "${WEB_PROBE_DIR}/direct")
  fi

  # Diagnostics (spec §3.5): one block per failed observation. A write
  # failure is reported and never blocks the transition below.
  web_render_diag "$WEB_PROBE_DIR" "$OBS_WEB_CLASS" "$WEB_NOW_ISO" "$OBS_WEB_DIRECT" \
    | fyd_live_write --append "the web-probe diagnostics block" "$WEB_DIAG_LOG" \
    || echo "[web] diagnostics append to ${WEB_DIAG_LOG} failed; transition continues" >&2
fi

# === transition: web (notify-gated, persistence-gated) ==================
# Spec §3.4. The outage push fires on the SECOND consecutive failed run,
# never the first, so a path blip shorter than one cron interval is logged
# (blip log + diagnostics) but never pages. .web keeps its meaning — "warn"
# only once an outage push was delivered — and, like .web, the incident's
# `pushed` flag advances only on a successful notify (K-3). started_at /
# runs / classes / last_class are observations and advance unconditionally.
WEB_CLASSES_CSV=$(printf '%s' "$WI_CLASSES" | jq -r 'join(",")' 2>/dev/null)
web_append_blip() {  # <pushed: true|false>
  web_render_blip_line "$WI_STARTED" "$WEB_NOW" "$WEB_CLASSES_CSV" "$1" \
    | fyd_live_write --append "the web incident blip-log line" "$WEB_BLIP_LOG" \
    || echo "[web] blip-log append to ${WEB_BLIP_LOG} failed; transition continues" >&2
}
if [ "$OBS_WEB_STATUS" = "200" ]; then
  if [ "$WI_OPEN" = "1" ] && [ "$WI_PUSHED" = "true" ]; then
    if [ "$WI_LEGACY" = "1" ]; then
      WEB_DUR_TXT='不明 (旧形式の state から継続)'
      WEB_CLASS_TXT='-'
    else
      WEB_DUR_TXT="約 $(web_duration_min $((WEB_NOW - WI_STARTED))) 分 (5 分刻みの観測)"
      WEB_CLASS_TXT=$(web_class_labels_csv "$WEB_CLASSES_CSV")
    fi
    body=$(printf 'GET %s/health -> 200 OK\n継続: %s\n観測した分類: %s\n診断: %s' \
      "$WEB_URL" "$WEB_DUR_TXT" "$WEB_CLASS_TXT" "$WEB_DIAG_LOG")
    if notify_or_keep default "公開サイト復旧" "$body"; then
      candidate_set '.web' '"ok"'
      if [ "$WI_LEGACY" = "0" ]; then
        # Blip line only after the recovery push is delivered: a failed push
        # keeps the incident open and the next run retries, and writing the
        # line now would duplicate it then.
        web_append_blip true
        candidate_set '.web_incident' 'null'
      fi
    fi
  elif [ "$WI_OPEN" = "1" ]; then
    # Outlived the 30 s re-probe but not a whole cron interval: log, no push.
    web_append_blip false
    candidate_set '.web_incident' 'null'
  fi
elif [ "$WI_LEGACY" = "1" ]; then
  # Legacy .web=warn: the outage push already went out; stay silent, as the
  # old code did for "already warn". Diagnostics above are still captured.
  :
elif [ "$WI_OPEN" = "0" ]; then
  # First failed run (after the re-probe): open the incident, no push.
  candidate_set '.web_incident' "$(jq -cn --argjson s "$WEB_NOW" --arg c "$OBS_WEB_CLASS" \
    '{started_at: $s, last_class: $c, classes: [$c], runs: 1, pushed: false}')"
else
  WEB_PUSHED_NEXT="$WI_PUSHED"
  if [ "$WI_PUSHED" != "true" ]; then
    case "$OBS_WEB_CLASS" in
      cf_path)
        WEB_PRIO=default
        WEB_TITLE='公開サイト: Cloudflare 経路で失敗継続 (origin は正常)'
        WEB_ACTION=$'対処:\n1) Cloudflare の status page で SIN colo の障害有無を確認\n2) origin は直接確認で 200 のため web host 側の作業は不要\n影響: Cloudflare 経由の閲覧者が到達できない可能性、validator は無事'
        ;;
      *)
        WEB_PRIO=high
        WEB_TITLE='公開サイトが応答しない (5 分以上継続)'
        WEB_ACTION=$'対処:\n1) web host に SSH してログ確認\n2) docker ps | grep caddy-static\n3) systemctl status nginx\n4) tail /var/log/nginx/error.log\n影響: 閲覧者がサイトに到達不能な可能性、validator は無事'
        ;;
    esac
    body=$(printf '分類: %s\n継続: 約 %s 分 (5 分刻みの観測)\nCloudflare 経由: %s\ncf-ray colo: %s\norigin 直接: %s\n診断: %s の "=== web-diag %s" ブロック\n%s' \
      "$(web_class_label "$OBS_WEB_CLASS")" "$(web_duration_min $((WEB_NOW - WI_STARTED)))" \
      "$WEB_CF_LINE" "$WEB_COLO" "$WEB_DIRECT_LINE" "$WEB_DIAG_LOG" "$WEB_NOW_ISO" "$WEB_ACTION")
    if notify_or_keep "$WEB_PRIO" "$WEB_TITLE" "$body"; then
      WEB_PUSHED_NEXT=true
      candidate_set '.web' '"warn"'
    fi
  fi
  candidate_set '.web_incident' "$(jq -cn --argjson s "$WI_STARTED" --arg c "$OBS_WEB_CLASS" \
    --argjson cl "$WI_CLASSES" --argjson r "$((WI_RUNS + 1))" --argjson p "$WEB_PUSHED_NEXT" \
    '{started_at: $s, last_class: $c, classes: (if any($cl[]; . == $c) then $cl else $cl + [$c] end), runs: $r, pushed: $p}')"
fi
```

Notes for the implementer (the code comments carry the same reasoning):
- `OBS_WEB_STATUS` keeps its name and meaning, so the `api_freshness` block below it is unchanged and still gated on `200`.
- A legacy state (`.web == "warn"` written before `web_incident` existed) is treated as "open and already pushed": no re-probe and no second outage push. On recovery it sends `公開サイト復旧` with `継続: 不明 (旧形式の state から継続)` and writes no blip line, because its start is unknown. This path is never converted into a `web_incident`, so no duration is ever made up.
- The blip line for a pushed incident is written only after the recovery push succeeds. A failed recovery push keeps the incident open, and the next run retries without duplicating the line.
- The `mktemp -d` scratch lives under `TMPDIR`, not the state dir, so it is not a durable write (G4). `cleanup_k3` removes it.

- [ ] **Step 13: Write `web_incident: null` in the baseline state**

In `scripts/anomaly-state-init.sh`, in the baseline heredoc (~190-204), replace:

```json
  "api_freshness": "ok",
  "validator_present": "yes",
```

with:

```json
  "api_freshness": "ok",
  "web_incident": null,
  "validator_present": "yes",
```

Why: `scripts/check-field-contracts.py` treats the new K-3.5 clause (a single-quoted jq read of `.web_incident` bound to `$STATE_FILE`) as a read of the `anomaly-state.json` artifact. It reports HIGH `unguarded read of a key no writer emits` unless some writer of that artifact spells the key. `candidate_set '.web_incident' …` is a path assignment, which the checker does not harvest. Writing `null` in the baseline states the "no incident" value the spec defines and closes the finding. Measured: `HIGH=1` without this line, `HIGH=0` with it.

- [ ] **Step 14: Make the four sandboxes mirror all of `scripts/lib/`**

`check-anomalies.sh` now refuses to run without `scripts/lib/web-probe.sh`, so every test sandbox that copied `side-effects.sh` by name must carry the whole directory.

In `tests/anomalies/test-delegation-notify-body.sh` (~169), replace:

```bash
	cp "${REPO}/scripts/lib/side-effects.sh" "${S}/scripts/lib/side-effects.sh"
```

with:

```bash
	# scripts/lib/ is mirrored as a WHOLE DIRECTORY: check-anomalies.sh sources
	# side-effects.sh AND web-probe.sh, and naming files one by one is the bug
	# tests/side-effects-callers/test-monitoring-side-effects.sh mk_repo records.
	cp -R "${REPO}/scripts/lib/." "${S}/scripts/lib/"
```

In `tests/cycle-gate/run-tests.sh` (~574) and in `tests/cycle-gate/scenario-test-endtime.sh` (~96), replace:

```bash
ln -s "${REPO_ROOT}/scripts/lib/side-effects.sh" "${TMP_REPO_BASE}/scripts/lib/side-effects.sh"
```

with:

```bash
# All of scripts/lib/, not a hand-picked file: check-anomalies.sh also
# sources scripts/lib/web-probe.sh (2026-09-24).
for lib in "${REPO_ROOT}"/scripts/lib/*.sh; do
	ln -s "$lib" "${TMP_REPO_BASE}/scripts/lib/$(basename "$lib")"
done
```

In `tests/anomalies/integration-linux.sh`, replace:

```bash
# Both scripts source scripts/lib/side-effects.sh relative to their own repo
# root (C3 rollout, 2026-08-06) and refuse to run without it, so the sandbox
# repo has to carry it too.
```

with:

```bash
# Both scripts source scripts/lib/side-effects.sh relative to their own repo
# root (C3 rollout, 2026-08-06) and refuse to run without it, so the sandbox
# repo has to carry it too — and check-anomalies.sh also sources
# scripts/lib/web-probe.sh (2026-09-24), so the whole directory is mirrored.
```

and replace:

```bash
cp "$REPO/scripts/lib/side-effects.sh" "$SBX_REPO/scripts/lib/side-effects.sh"
```

with:

```bash
cp -R "$REPO/scripts/lib/." "$SBX_REPO/scripts/lib/"
```

- [ ] **Step 15: Run the end-to-end test and the suites next to it**

Run:

```bash
bash tests/anomalies/test-web-incident.sh | tail -1
bash tests/anomalies/test-web-probe-lib.sh | tail -1
bash tests/anomalies/test-delegation-notify-body.sh | tail -2
bash tests/anomalies/test-api-freshness-broken.sh | tail -1
bash tests/anomalies/test-candidate-state.sh | tail -1
bash tests/anomalies/test-state-init.sh | tail -1
bash tests/cycle-gate/run-tests.sh | tail -2
python3 scripts/check-field-contracts.py | tail -1
bash tests/field-contracts/test-field-contracts.sh | tail -2
bash -n tests/cycle-gate/scenario-test-endtime.sh && echo scenario-syntax-ok
```

Expected (macOS reference run):

```
Total: PASS=114 FAIL=0
Total: PASS=79 FAIL=0
test-delegation-notify-body.sh summary: PASS=68  FAIL=0  SKIP=0
RESULT: PASS
Total: PASS=22 FAIL=0
Total: PASS=42 FAIL=0
Total: PASS=11 FAIL=0 SKIP=10
RESULTS: 23 PASS / 0 FAIL (total 23)
================================================================
field-contracts: artifacts=35  read-sites-analyzed=152  findings: CRITICAL=0 HIGH=0 LOW=0
test-field-contracts.sh summary: PASS=23  FAIL=0
scenario-syntax-ok
```

`test-state-init.sh` skips its flock cases on macOS. The container run in Step 19 covers them.

`tests/cycle-gate/scenario-test-endtime.sh` is a real-time manual scenario and is NOT in `run-all-tests.sh`, so only its syntax is checked here. If it is run for real (`bash tests/cycle-gate/scenario-test-endtime.sh $(( $(date +%s) + 15 ))`, about 50 s), its Phase B already fails on current `main` on macOS for `gen-cycle-history.sh uptime-history.sh gen-evidence.sh gen-renewal-ics.sh node-info.sh`. That failure is pre-existing and does not involve `check-anomalies.sh`: the missing list is identical before and after this change (measured).

- [ ] **Step 16: Mutation-prove the end-to-end test (break → FAIL → restore → PASS)**

```bash
MUT="$(mktemp -d)"; cp scripts/check-anomalies.sh "$MUT/ca"; cp scripts/lib/web-probe.sh "$MUT/wp"
restore() { cp "$MUT/ca" scripts/check-anomalies.sh; cp "$MUT/wp" scripts/lib/web-probe.sh; }
T=tests/anomalies/test-web-incident.sh
# M1 G1 persistence gate: treat the first failed run as an already-open incident
perl -pi -e 's/^WI_OPEN=0; WI_STARTED=""; WI_RUNS=0;/WI_OPEN=1; WI_STARTED="\$WEB_NOW"; WI_RUNS=0;/' scripts/check-anomalies.sh
bash $T | grep -c '  FAIL '; restore                                           # expect 36
# M2 priority and title follow the class (cf_path must not page high)
perl -pi -e 's/^\t\t200\) echo cf_path ;;/\t\t200) echo origin_or_path ;;/' scripts/lib/web-probe.sh
bash $T | grep -c '  FAIL '; restore                                           # expect 7
# M3 K-3: pushed and .web advance only on a delivered push
perl -pi -e 's/^    if notify_or_keep "\$WEB_PRIO" "\$WEB_TITLE" "\$body"; then/    notify_or_keep "\$WEB_PRIO" "\$WEB_TITLE" "\$body"; if true; then/' scripts/check-anomalies.sh
bash $T | grep -c '  FAIL '; restore                                           # expect 4
# M4 K-3.5 validates web_incident when present
perl -pi -e 's/^\s+\(\$wi\.pushed\|type=="boolean"\)\)\)/        true))/' scripts/check-anomalies.sh
bash $T | grep -c '  FAIL '; restore                                           # expect 2
# M5 recovery resets .web to ok
perl -pi -e 's/^      candidate_set \x27\.web\x27 \x27"ok"\x27$/      :/' scripts/check-anomalies.sh
bash $T | grep -c '  FAIL '; restore                                           # expect 2
# M6 re-probe only when no incident is open
perl -pi -e 's/ && \[ "\$WI_OPEN" = "0" \] && \[ "\$ORIG_WEB" = "ok" \]; then/ && [ "\$ORIG_WEB" = "ok" ]; then/' scripts/check-anomalies.sh
bash $T | grep -c '  FAIL '; restore                                           # expect 1
# M7 every closed pushed incident reaches the blip log
perl -pi -e 's/^        web_append_blip true$/        :/' scripts/check-anomalies.sh
bash $T | grep -c '  FAIL '; restore                                           # expect 2
cmp scripts/check-anomalies.sh "$MUT/ca" && cmp scripts/lib/web-probe.sh "$MUT/wp" && rm -rf "$MUT"
bash $T | tail -1
```

Expected: the seven counts `36 7 4 2 2 1 2` (all non-zero), then `Total: PASS=114 FAIL=0`.

Then prove the Step 13 baseline line is load-bearing. Copy `scripts/anomaly-state-init.sh` to a temp file, delete its `"web_incident": null,` line, and run `python3 scripts/check-field-contracts.py | tail -1`. Expected: `… HIGH=1 …`. Copy the file back (do NOT use `git checkout`, which would also drop Step 13 if it is uncommitted) and rerun. Expected: `HIGH=0`.

- [ ] **Step 17: Guard the two new durable logs in the side-effects gate**

In `tests/side-effects-callers/test-monitoring-side-effects.sh`, replace (~593):

```bash
DURABLE='STATE_FILE|PREV_FILE|HIST_JSONL|MISSING_MARKER|OUT_PUBLIC|COUNTER_FILE|CONTENTION_COUNTER|DELEGATOR_EVENTS_LOG|quar_target|REWARDS_HISTORY|TRACKER_STATE|DIGEST_FILE'
```

with:

```bash
# WEB_DIAG_LOG|WEB_BLIP_LOG added 2026-09-24 for check-anomalies.sh's public-site
# probe logs: both are appended through fyd_live_write today, and the Part 4
# mutation below proves a raw redirect into either would be caught.
DURABLE='STATE_FILE|PREV_FILE|HIST_JSONL|MISSING_MARKER|OUT_PUBLIC|COUNTER_FILE|CONTENTION_COUNTER|DELEGATOR_EVENTS_LOG|quar_target|REWARDS_HISTORY|TRACKER_STATE|DIGEST_FILE|WEB_DIAG_LOG|WEB_BLIP_LOG'
```

Then insert this directly before the existing line `mutate "G4/G5 — the hard-refusal marker is removed from anomaly-state-init" \`:

```bash
mutate "G4 — the web-probe diagnostics append reverts to a raw redirect" \
	"${SCRIPTS}/check-anomalies.sh" \
	's@^    | fyd_live_write --append "the web-probe diagnostics block" "\$WEB_DIAG_LOG"@    >> "$WEB_DIAG_LOG"@'

mutate "G4 — the web blip-log append reverts to a raw redirect" \
	"${SCRIPTS}/check-anomalies.sh" \
	's@^    | fyd_live_write --append "the web incident blip-log line" "\$WEB_BLIP_LOG"@    >> "$WEB_BLIP_LOG"@'

```

Run: `bash tests/side-effects-callers/test-monitoring-side-effects.sh | grep -E 'G4 — the web|summary'`
Expected:

```
PASS  4 mutation caught: G4 — the web-probe diagnostics append reverts to a raw redirect
PASS  4 mutation caught: G4 — the web blip-log append reverts to a raw redirect
test-monitoring-side-effects.sh summary: PASS=65  FAIL=0  SKIP=0
```

Mutation proof that the `DURABLE` addition is what catches them: remove `|WEB_DIAG_LOG|WEB_BLIP_LOG` from the `DURABLE=` line and rerun. Expected: both lines become `FAIL … gate stayed green against a deliberately broken file` and the summary shows `FAIL=2`. Put the names back, rerun, and expect `FAIL=0`.

- [ ] **Step 18: Add integration case I9 (Linux)**

In `tests/anomalies/integration-linux.sh`:

(a) In the case-list comment, after the line `#   I8  post-test verification: production paths NOT touched`, add:

```bash
#   I9  public-site outage across runs: no push on run 1, one high push on
#       run 2 (P_direct also fails → origin_or_path), recovery push on run 3
#       (web-probe design spec 2026-09-24 §5)
```

(b) Extend `PROD_PATHS`. Replace:

```bash
  /var/log/anomalies.log
)
```

with:

```bash
  /var/log/anomalies.log
  /var/log/anomalies-web-diag.log
  /var/log/anomalies-web-blips.log
)
```

(c) After the line `PROD_TOPIC_HASH=$(sha256sum "$PROD_TOPIC" 2>/dev/null | awk '{print $1}' || echo "missing")`, add:

```bash
PROD_WEB_DIAG=/var/log/anomalies-web-diag.log
PROD_WEB_BLIP=/var/log/anomalies-web-blips.log
PROD_WEB_DIAG_HASH=$(sha256sum "$PROD_WEB_DIAG" 2>/dev/null | awk '{print $1}' || echo "missing")
PROD_WEB_BLIP_HASH=$(sha256sum "$PROD_WEB_BLIP" 2>/dev/null | awk '{print $1}' || echo "missing")
```

(d) Make the python stub's `/health` switchable. Replace:

```bash
python3 -u -c "
import http.server, socketserver, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/health':
            self.send_response(200); self.end_headers(); self.wfile.write(b'')
```

with:

```bash
# /health answers 503 while $TMP/health-down exists (I9 toggles it).
python3 -u -c "
import http.server, socketserver, sys, os
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/health':
            if os.path.exists('$TMP/health-down'):
                self.send_response(503); self.end_headers(); return
            self.send_response(200); self.end_headers(); self.wfile.write(b'')
```

(e) Insert the I9 block directly before the `# ===…` banner that introduces `# I8  post-test verification: production paths NOT touched.`:

```bash
# ===========================================================================
# I9  public-site outage across runs (persistence gate + direct probe +
#     recovery). The mini server's /health goes down for two runs; P_direct
#     reaches the SAME server via --resolve to 127.0.0.1, so it fails too and
#     the class is origin_or_path.
# ===========================================================================
echo ""
echo "=== I9: public-site outage across runs ==="
bootstrap_baseline
: > "$SBX_NOTIFY_LOG"
cat > "$SBX_NOTIFY" <<'BASH'
#!/usr/bin/env bash
echo "title=$2 prio=$1" >> "${STUB_NOTIFY_LOG:-/dev/null}"
exit 0
BASH
chmod +x "$SBX_NOTIFY"
export WEB_REPROBE_SLEEP=0 WEB_ORIGIN_IP=127.0.0.1
touch "$TMP/health-down"
run_check; rc=$?
assert "I9 run 1 (outage opens) rc=0"                           0 "$rc"
assert "I9 run 1: no public-site push"                          0 "$(grep -c 'title=公開サイト' "$SBX_NOTIFY_LOG" || true)"
assert "I9 run 1: incident open, runs=1, pushed=false"          "1 false" "$(jq -r '"\(.web_incident.runs) \(.web_incident.pushed)"' "$SBX_STATE/anomaly-state.json")"
run_check; rc=$?
assert "I9 run 2 rc=0"                                          0 "$rc"
assert "I9 run 2: one high outage push"                         1 "$(grep -c 'title=公開サイトが応答しない (5 分以上継続) prio=high' "$SBX_NOTIFY_LOG" || true)"
assert "I9 run 2: class origin_or_path (P_direct failed too)"   origin_or_path "$(jq -r '.web_incident.last_class' "$SBX_STATE/anomaly-state.json")"
assert "I9 run 2: .web=warn"                                    warn "$(jq -r '.web' "$SBX_STATE/anomaly-state.json")"
rm -f "$TMP/health-down"
run_check; rc=$?
assert "I9 run 3 rc=0"                                          0 "$rc"
assert "I9 run 3: one recovery push"                            1 "$(grep -c 'title=公開サイト復旧 prio=default' "$SBX_NOTIFY_LOG" || true)"
assert "I9 run 3: .web=ok"                                      ok "$(jq -r '.web' "$SBX_STATE/anomaly-state.json")"
assert "I9 run 3: incident cleared"                             null "$(jq -r '.web_incident' "$SBX_STATE/anomaly-state.json")"
assert "I9: two diagnostics blocks in the sandbox log"          2 "$(grep -c '^=== web-diag ' "$SBX_STATE/anomalies-web-diag.log" 2>/dev/null || true)"
assert "I9: one blip line, pushed=true"                         1 "$(grep -c 'classes=origin_or_path pushed=true$' "$SBX_STATE/anomalies-web-blips.log" 2>/dev/null || true)"
unset WEB_REPROBE_SLEEP WEB_ORIGIN_IP

```

(f) In the I8 assertions, after `assert "I8 production topic file SHA unchanged"      "$PROD_TOPIC_HASH"   "$PROD_TOPIC_HASH_AFTER"`, add:

```bash
assert "I8 production web-diag log SHA unchanged"    "$PROD_WEB_DIAG_HASH" "$(sha256sum "$PROD_WEB_DIAG" 2>/dev/null | awk '{print $1}' || echo "missing")"
assert "I8 production web-blip log SHA unchanged"    "$PROD_WEB_BLIP_HASH" "$(sha256sum "$PROD_WEB_BLIP" 2>/dev/null | awk '{print $1}' || echo "missing")"
```

- [ ] **Step 19: Run the Linux suites in a container, and mutation-prove I9**

Run from the repo root:

```bash
bash -n tests/anomalies/integration-linux.sh && echo syntax-ok
docker run --rm -v "$PWD":/repo:ro -w /repo ubuntu:24.04 bash -c \
  'apt-get update -qq >/dev/null 2>&1 && apt-get install -y -qq jq curl python3 >/dev/null 2>&1;
   bash tests/anomalies/integration-linux.sh 2>/dev/null | grep -E "FAIL|Total";
   bash tests/anomalies/test-web-incident.sh | tail -1; bash tests/anomalies/test-web-probe-lib.sh | tail -1;
   useradd -m t; su t -c "bash tests/anomalies/test-state-init.sh" | tail -1'
```

Expected:

```
syntax-ok
Total: PASS=47 FAIL=0
Total: PASS=114 FAIL=0
Total: PASS=79 FAIL=0
Total: PASS=28 FAIL=0 SKIP=2
```

Mutation (the container works on a copy, so the checkout stays untouched):

```bash
docker run --rm -v "$PWD":/src:ro ubuntu:24.04 bash -c \
  'apt-get update -qq >/dev/null 2>&1 && apt-get install -y -qq jq curl python3 perl >/dev/null 2>&1; cp -R /src /repo && cd /repo &&
   perl -pi -e "s/^WI_OPEN=0; WI_STARTED=\"\"; WI_RUNS=0;/WI_OPEN=1; WI_STARTED=\"\\\$WEB_NOW\"; WI_RUNS=0;/" scripts/check-anomalies.sh &&
   bash tests/anomalies/integration-linux.sh 2>/dev/null | grep -E "FAIL|Total"'
```

Expected:

```
  FAIL  I9 run 1: no public-site push                                expected=0 actual=1
  FAIL  I9 run 1: incident open, runs=1, pushed=false                expected=1 false actual=1 true
Total: PASS=45 FAIL=2
```

- [ ] **Step 20: Guards and full suite**

Run:

```bash
for f in scripts/lib/web-probe.sh scripts/check-anomalies.sh tests/anomalies/test-web-incident.sh tests/anomalies/test-web-probe-lib.sh tests/anomalies/integration-linux.sh; do
  bash scripts/publish-guard.sh --text <"$f" >/dev/null 2>&1; echo "$? $f"; done
gitleaks dir --no-banner -c .gitleaks.toml scripts/lib/web-probe.sh tests/anomalies 2>&1 | tail -1
grep -nE '([0-9]{1,3}\.){3}[0-9]{1,3}' scripts/lib/web-probe.sh scripts/check-anomalies.sh \
  | grep -vE '192\.0\.2\.|198\.51\.100\.|203\.0\.113\.|127\.0\.0\.1|0\.0\.0\.0' || echo "no host IP literal"
bash tests/run-all-tests.sh | tail -4
```

Expected: every publish-guard line starts with `0 `, gitleaks prints `no leaks found`, the grep prints `no host IP literal`, and the runner ends with `RESULT: ALL PASS` with a balanced `ROSTER:` line.

- [ ] **Step 21: Commit**

Stage exactly these files: `scripts/lib/web-probe.sh scripts/check-anomalies.sh scripts/anomaly-state-init.sh tests/anomalies/test-web-probe-lib.sh tests/anomalies/test-web-incident.sh tests/anomalies/integration-linux.sh tests/anomalies/test-delegation-notify-body.sh tests/cycle-gate/run-tests.sh tests/cycle-gate/scenario-test-endtime.sh tests/side-effects-callers/test-monitoring-side-effects.sh`. Commit with this message (let the pre-commit hooks run):

```text
feat(anomalies): classify public-site probe failures by path and page only when they persist

Three 'site not responding' pushes on 09-21/09-23 were 30-50 s path outages
between the validator host and the web host while the origin stayed healthy.
The probe had one vantage, paged on a blip that happened to span the 30 s
re-probe, and kept no evidence, so the cause could not be settled.

A failure that survives the re-probe now opens an optional web_incident (no
push), probes the origin directly with curl --resolve to WEB_ORIGIN_IP from
the cron env (never committed), classifies the failure as cf_path /
origin_or_path / unknown, and appends a diagnostics block. The outage push
fires only when the next run still fails, with priority by class; recovery
pushes carry duration and classes, and every closed incident gets one blip
line. pushed and .web advance only on a delivered push (K-3); K-3.5 accepts
a state without web_incident and quarantines a malformed one.

Measuring and rendering live in the side-effect-free scripts/lib/web-probe.sh,
so check-anomalies.sh grows only by its transition block; test sandboxes now
mirror scripts/lib/ as a whole. The init baseline writes web_incident: null so
the field-contract checker sees a writer for the key K-3.5 reads.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
```

Verify it landed: `git log -1 --format=%H` and `git cat-file -t <that hash>` prints `commit`. Then `git show --stat HEAD` lists exactly the ten files above.
---

### Task 2: 90-day log retention installer (and single-source bootstrap)

**Files:**
- Create: `scripts/install-anomalies-logrotate.sh`
- Create: `tests/install-anomalies-logrotate/test-install-anomalies-logrotate.sh`
- Modify: `scripts/vps-bootstrap.sh:245-254` (the `/etc/logrotate.d/anomalies` heredoc in `step_anomaly_cron`)

**Interfaces:**
- Consumes: nothing from other tasks. The three log paths are fixed by the spec: `/var/log/anomalies.log`, `/var/log/anomalies-web-diag.log`, `/var/log/anomalies-web-blips.log` (Task 1 writes the latter two in production).
- Produces: `sudo bash scripts/install-anomalies-logrotate.sh` (exit 0 installed or no-op / 2 not root / 3 log dir missing / 4 `logrotate -d` refused). Test-harness env: `FYD_LOGROTATE_TARGET`, `FYD_LOG_DIR`, `FYD_DEPLOY_USER`, `FYD_BACKUP_DIR`. Task 4 documents it.

- [ ] **Step 1: Write the failing test**

Create `tests/install-anomalies-logrotate/test-install-anomalies-logrotate.sh` and make it executable:

```bash
#!/usr/bin/env bash
# tests/install-anomalies-logrotate/test-install-anomalies-logrotate.sh —
# suite for scripts/install-anomalies-logrotate.sh (web-probe design spec
# 2026-09-24 §3.5, G5: 90-day retention for anomalies.log and the two
# public-site probe logs).
#
# CHAIN: none — the installer runs in test-harness mode against a tempdir
#        (FYD_LOGROTATE_TARGET / FYD_LOG_DIR / FYD_BACKUP_DIR); /etc and
#        /var/log are never touched.
# PRIME_DIRECTIVE: TESTNET-FIRST — safe.
#
# Usage:
#   bash tests/install-anomalies-logrotate/test-install-anomalies-logrotate.sh

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
INSTALLER="${REPO_ROOT}/scripts/install-anomalies-logrotate.sh"
BOOTSTRAP="${REPO_ROOT}/scripts/vps-bootstrap.sh"

PASS=0
FAIL=0
SKIP=0
ok()   { PASS=$((PASS + 1)); echo "PASS  $1"; }
bad()  { FAIL=$((FAIL + 1)); echo "FAIL  $1${2:+ — $2}"; }
skip() { SKIP=$((SKIP + 1)); echo "SKIP  $1${2:+ — $2}"; }
mode_of() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }

WORK="$(mktemp -d -t anomalies-logrotate-test.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/logrotate.d" "$WORK/log"
TARGET="$WORK/logrotate.d/anomalies"
LOGD="$WORK/log"

run_inst() {
	FYD_LOGROTATE_TARGET="$TARGET" FYD_LOG_DIR="$LOGD" FYD_DEPLOY_USER=deploy \
		FYD_BACKUP_DIR="$WORK/backups" bash "$INSTALLER"
}

# The expected config, written out independently of the installer: this is
# the spec's retention contract, not a copy of the installer's heredoc.
EXPECTED="$(cat <<CONF
# Managed by scripts/install-anomalies-logrotate.sh — edit the installer, not this file.
# 90-day retention: web-probe design spec 2026-09-24 §3.5 (G5).
${LOGD}/anomalies.log ${LOGD}/anomalies-web-diag.log ${LOGD}/anomalies-web-blips.log {
  daily
  rotate 90
  compress
  missingok
  notifempty
  create 644 deploy deploy
}
CONF
)"

printf 'existing line\n' >"$LOGD/anomalies.log"

# --- T1 fresh install ---------------------------------------------------------
OUT="$(run_inst 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && ok "T1 fresh install exits 0" || bad "T1 fresh install exits 0" "rc=$RC $OUT"
[ "$(cat "$TARGET" 2>/dev/null)" = "$EXPECTED" ] \
	&& ok "T1 config is exactly the 90-day contract (daily / rotate 90 / compress / create 644 deploy deploy)" \
	|| bad "T1 config is exactly the 90-day contract" "$(diff <(printf '%s\n' "$EXPECTED") "$TARGET" 2>&1 | head -5)"
[ "$(mode_of "$TARGET")" = "644" ] && ok "T1 config mode 0644" || bad "T1 config mode 0644" "$(mode_of "$TARGET")"

# --- T2 provisioning --------------------------------------------------------------
for name in anomalies-web-diag.log anomalies-web-blips.log; do
	[ -f "$LOGD/$name" ] && [ ! -s "$LOGD/$name" ] \
		&& ok "T2 ${name} provisioned (empty)" \
		|| bad "T2 ${name} provisioned (empty)"
	[ "$(mode_of "$LOGD/$name")" = "644" ] && ok "T2 ${name} mode 0644" || bad "T2 ${name} mode 0644"
done
[ "$(cat "$LOGD/anomalies.log")" = "existing line" ] \
	&& ok "T2 an existing log is never truncated" \
	|| bad "T2 an existing log is never truncated" "$(cat "$LOGD/anomalies.log")"

# --- T3 idempotent ----------------------------------------------------------------
OUT="$(run_inst 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && grep -q 'already up to date' <<<"$OUT" \
	&& ok "T3 re-run is a no-op" || bad "T3 re-run is a no-op" "rc=$RC $OUT"
[ ! -d "$WORK/backups" ] || [ -z "$(ls -A "$WORK/backups")" ] \
	&& ok "T3 no backup on a no-op" || bad "T3 no backup on a no-op" "$(ls "$WORK/backups")"

# --- T4 differing prior config (the old 7-day stanza) is backed up and replaced ----
printf '/var/log/anomalies.log {\n  daily\n  rotate 7\n}\n' >"$TARGET"
OUT="$(run_inst 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && [ "$(cat "$TARGET")" = "$EXPECTED" ] \
	&& ok "T4 old 7-day config replaced" || bad "T4 old 7-day config replaced" "rc=$RC"
[ "$(ls "$WORK/backups" 2>/dev/null | grep -c '^logrotate-anomalies\.bak-')" = "1" ] \
	&& ok "T4 prior config backed up once" || bad "T4 prior config backed up once" "$(ls "$WORK/backups" 2>&1)"
[ "$(ls "$WORK/logrotate.d")" = "anomalies" ] \
	&& ok "T4 no sidecar left in the logrotate dir (logrotate would load it)" \
	|| bad "T4 no sidecar left in the logrotate dir" "$(ls "$WORK/logrotate.d")"

# --- T5 root gate ---------------------------------------------------------------------
if [ "$(id -u)" -ne 0 ]; then
	env -u FYD_LOGROTATE_TARGET bash "$INSTALLER" >/dev/null 2>&1; RC=$?
	[ "$RC" -eq 2 ] && ok "T5 production target without root → exit 2" || bad "T5 production target without root → exit 2" "rc=$RC"
else
	skip "T5 root gate" "running as root"
fi

# --- T6 missing log dir -------------------------------------------------------------
FYD_LOGROTATE_TARGET="$WORK/other" FYD_LOG_DIR="$WORK/no-such-dir" bash "$INSTALLER" >/dev/null 2>&1; RC=$?
[ "$RC" -eq 3 ] && [ ! -e "$WORK/other" ] && ok "T6 missing log dir → exit 3, nothing written" || bad "T6 missing log dir → exit 3" "rc=$RC"

# --- T7 vps-bootstrap.sh delegates to the installer (single source) ----------------
[ "$(grep -c 'cat > /etc/logrotate.d/anomalies' "$BOOTSTRAP")" = "0" ] \
	&& ok "T7 vps-bootstrap.sh no longer carries its own anomalies logrotate heredoc" \
	|| bad "T7 vps-bootstrap.sh no longer carries its own anomalies logrotate heredoc"
STEP="$(awk '/^step_anomaly_cron\(\) \{/{f=1} f{print} f && /^\}/{exit}' "$BOOTSTRAP")"
grep -qF 'FYD_DEPLOY_USER="$DEPLOY_USER" bash "$DEPLOY_DIR/scripts/install-anomalies-logrotate.sh"' <<<"$STEP" \
	&& ok "T7 step_anomaly_cron runs the installer with the bootstrap's deploy user" \
	|| bad "T7 step_anomaly_cron runs the installer with the bootstrap's deploy user"

# --- T8 logrotate itself parses the generated config (where logrotate exists) ------
# Rendered for the CURRENT user so `create` resolves on any machine; the
# retention stanza is otherwise identical to T1's.
if command -v logrotate >/dev/null 2>&1; then
	mkdir -p "$WORK/t8"
	FYD_LOGROTATE_TARGET="$WORK/t8/anomalies" FYD_LOG_DIR="$LOGD" FYD_DEPLOY_USER="$(id -un)" \
		FYD_BACKUP_DIR="$WORK/t8-backups" bash "$INSTALLER" >/dev/null 2>&1
	LR_OUT="$(logrotate -d -s "$WORK/lr.state" "$WORK/t8/anomalies" 2>&1)"; RC=$?
	[ "$RC" -eq 0 ] && ok "T8 logrotate -d accepts the config" || bad "T8 logrotate -d accepts the config" "$(tail -3 <<<"$LR_OUT")"
else
	skip "T8 logrotate -d" "logrotate not installed here (verified on the validator host at rollout)"
fi

echo "test-install-anomalies-logrotate.sh summary: PASS=$PASS  FAIL=$FAIL  SKIP=$SKIP"
if [ "$FAIL" -eq 0 ]; then
	echo "RESULT: PASS"
	exit 0
fi
echo "RESULT: FAIL"
exit 1
```

- [ ] **Step 2: Run it to verify it fails**

Run: `chmod +x tests/install-anomalies-logrotate/test-install-anomalies-logrotate.sh && bash tests/install-anomalies-logrotate/test-install-anomalies-logrotate.sh | grep -E '^FAIL' | head -3`
Expected: `FAIL  T1 fresh install exits 0 — rc=127 …No such file or directory` (followed by more FAIL lines; T7 also fails because `vps-bootstrap.sh` still carries its own heredoc).

- [ ] **Step 3: Write the installer**

Create `scripts/install-anomalies-logrotate.sh` (mode 0755, like the other `scripts/install-*.sh`):

```bash
#!/usr/bin/env bash
# install-anomalies-logrotate.sh — install /etc/logrotate.d/anomalies: 90-day
# retention for the anomaly detector's cron log and the public-site probe's
# diagnostics + blip logs, and provision those two logs deploy-writable.
#
# CHAIN: none — writes one logrotate config and touches log files.
# PRIME_DIRECTIVE: TESTNET-FIRST — no broadcast pathway here or downstream.
#
# Why (docs/superpowers/specs/2026-09-24-web-probe-path-classification-design.md
# §3.5, goal G5): the 2026-09-21/23 public-site alerts could not be explained
# after the fact, partly because /var/log/anomalies.log kept only 7 days. The
# new diagnostics log (anomalies-web-diag.log) and incident log
# (anomalies-web-blips.log) are what a later digest or a hosting-provider
# support inquiry reads, so all three are kept 90 days.
#
# Single source: scripts/vps-bootstrap.sh calls this installer instead of
# carrying its own heredoc, so a fresh host and a remediated host cannot
# drift apart.
#
# Why this installer also provisions the two new logs: check-anomalies.sh runs
# as `deploy` and /var/log is root-owned, so `deploy` cannot create a file
# there (the 2026-06-19 metal-evidence failure, docs/CRON_CONVENTIONS.md
# Rule 1). They are created once here as root, owned by the deploy user,
# 0644 — the same pre-provisioning vps-bootstrap.sh does for anomalies.log.
# An existing log is never truncated.
#
# Backups of a differing prior config go to FYD_BACKUP_DIR, never next to the
# target: logrotate reads every file in /etc/logrotate.d, and a
# "*.bak-<stamp>" sidecar is not on its taboo-extension list, so it would be
# loaded as a second config for the same logs.
#
# Usage (validator host, as root):
#   sudo bash scripts/install-anomalies-logrotate.sh
#
# Env overrides (test harness):
#   FYD_LOGROTATE_TARGET  config file to write (default /etc/logrotate.d/anomalies).
#                         When overridden, the root requirement is waived and
#                         no ownership is enforced.
#   FYD_LOG_DIR           directory holding the three logs (default /var/log)
#   FYD_DEPLOY_USER       owner of the logs and of logrotate's `create`
#                         (default deploy)
#   FYD_BACKUP_DIR        backup destination (default /var/backups)
#
# Exit codes:
#   0  installed or already up to date
#   2  not root (and FYD_LOGROTATE_TARGET not overridden)
#   3  log directory missing
#   4  generated config failed `logrotate -d` (nothing changed)
#
# Operator-gated: committed so the host action is one command; running it on
# the host follows operator approval (Constitution §5 / Operating Model W7).

set -euo pipefail

PROD_TARGET="/etc/logrotate.d/anomalies"
TARGET="${FYD_LOGROTATE_TARGET:-$PROD_TARGET}"
LOG_DIR="${FYD_LOG_DIR:-/var/log}"
DEPLOY_USER="${FYD_DEPLOY_USER:-deploy}"
BACKUP_DIR="${FYD_BACKUP_DIR:-/var/backups}"

if [ "$TARGET" = "$PROD_TARGET" ] && [ "$(id -u)" -ne 0 ]; then
	echo "ERROR: this installer must run as root (writes /etc/logrotate.d/ and provisions /var/log files)" >&2
	echo "       usage: sudo bash scripts/install-anomalies-logrotate.sh" >&2
	exit 2
fi
if [ ! -d "$LOG_DIR" ]; then
	echo "ERROR: log directory missing: ${LOG_DIR}" >&2
	exit 3
fi

read -r -d '' EXPECTED <<CONF || true
# Managed by scripts/install-anomalies-logrotate.sh — edit the installer, not this file.
# 90-day retention: web-probe design spec 2026-09-24 §3.5 (G5).
${LOG_DIR}/anomalies.log ${LOG_DIR}/anomalies-web-diag.log ${LOG_DIR}/anomalies-web-blips.log {
  daily
  rotate 90
  compress
  missingok
  notifempty
  create 644 ${DEPLOY_USER} ${DEPLOY_USER}
}
CONF

TMP="$(mktemp)"
trap 'rm -f "$TMP" "${TMP}.state"' EXIT
printf '%s\n' "$EXPECTED" >"$TMP"

# Parse check with logrotate itself (debug mode changes nothing; a scratch
# state file keeps /var/lib/logrotate/status untouched). Only for the real
# target: that is where the `create` owner is guaranteed to exist and where
# the config will actually be read; test harnesses have neither.
if [ "$TARGET" = "$PROD_TARGET" ] && command -v logrotate >/dev/null 2>&1; then
	if ! logrotate -d -s "${TMP}.state" "$TMP" >/dev/null 2>&1; then
		echo "ERROR: generated config failed 'logrotate -d' — nothing changed" >&2
		logrotate -d -s "${TMP}.state" "$TMP" 2>&1 | tail -5 >&2 || true
		exit 4
	fi
fi

for name in anomalies.log anomalies-web-diag.log anomalies-web-blips.log; do
	f="${LOG_DIR}/${name}"
	if [ ! -e "$f" ]; then
		: >"$f"
		echo "provisioned: ${f}"
	fi
	if [ "$TARGET" = "$PROD_TARGET" ]; then
		chown "${DEPLOY_USER}:${DEPLOY_USER}" "$f"
	fi
	chmod 0644 "$f"
done

if [ -f "$TARGET" ] && [ "$(cat "$TARGET")" = "$EXPECTED" ]; then
	echo "ok: ${TARGET} already up to date (no change)"
	exit 0
fi

if [ -f "$TARGET" ]; then
	STAMP="$(date -u +%Y%m%d-%H%M%S)"
	mkdir -p "$BACKUP_DIR"
	cp -p "$TARGET" "${BACKUP_DIR}/logrotate-$(basename "$TARGET").bak-${STAMP}"
	echo "backed up prior target to ${BACKUP_DIR}/logrotate-$(basename "$TARGET").bak-${STAMP}"
fi

if [ "$TARGET" = "$PROD_TARGET" ]; then
	install -m 0644 -o root -g root "$TMP" "$TARGET"
else
	install -m 0644 "$TMP" "$TARGET"
fi
echo "installed: ${TARGET} (daily, rotate 90, compress; create 644 ${DEPLOY_USER} ${DEPLOY_USER})"
echo "logs:      ${LOG_DIR}/anomalies.log ${LOG_DIR}/anomalies-web-diag.log ${LOG_DIR}/anomalies-web-blips.log"
```

- [ ] **Step 4: Make `vps-bootstrap.sh` call the installer**

In `scripts/vps-bootstrap.sh`, `step_anomaly_cron`, replace:

```bash
  cat > /etc/logrotate.d/anomalies <<EOF
/var/log/anomalies.log {
  daily
  rotate 7
  compress
  missingok
  notifempty
  create 644 $DEPLOY_USER $DEPLOY_USER
}
EOF
```

with:

```bash
  # 90-day retention for anomalies.log plus the public-site probe's
  # diagnostics / blip logs (web-probe design spec 2026-09-24 §3.5). Single
  # source: the installer also provisions the two web-probe logs
  # deploy-writable, as the touch/chown above does for anomalies.log.
  FYD_DEPLOY_USER="$DEPLOY_USER" bash "$DEPLOY_DIR/scripts/install-anomalies-logrotate.sh"
```

`step_repo` runs before `step_anomaly_cron` in `main()`, so `$DEPLOY_DIR/scripts/` exists at that point. Leave the `metal-anomalies` cron heredoc above it untouched: `tests/cron-generators-lint/` renders it, and Task 3 lints it too.

- [ ] **Step 5: Run the test to verify it passes, plus the bootstrap lint**

Run:

```bash
bash tests/install-anomalies-logrotate/test-install-anomalies-logrotate.sh | tail -3
bash -n scripts/vps-bootstrap.sh && echo bootstrap-syntax-ok
bash tests/cron-generators-lint/test-cron-generators-lint.sh | tail -2
```

Expected (macOS, non-root, no logrotate):

```
SKIP  T8 logrotate -d — logrotate not installed here (verified on the validator host at rollout)
test-install-anomalies-logrotate.sh summary: PASS=17  FAIL=0  SKIP=1
RESULT: PASS
bootstrap-syntax-ok
test-cron-generators-lint.sh summary: PASS=36  FAIL=0
RESULT: PASS
```

Then run it on Linux with real logrotate, as root and as a normal user:

```bash
docker run --rm -v "$PWD":/repo:ro -w /repo ubuntu:24.04 bash -c \
  'apt-get update -qq >/dev/null 2>&1 && apt-get install -y -qq logrotate >/dev/null 2>&1;
   bash tests/install-anomalies-logrotate/test-install-anomalies-logrotate.sh | tail -3;
   useradd -m t; su t -c "bash tests/install-anomalies-logrotate/test-install-anomalies-logrotate.sh" | tail -3'
```

Expected: as root `PASS  T8 logrotate -d accepts the config` / `summary: PASS=17  FAIL=0  SKIP=1` (T5 root gate skipped); as `t` `summary: PASS=18  FAIL=0  SKIP=0`; `RESULT: PASS` both times.

- [ ] **Step 6: Mutation-prove the test (break → FAIL → restore → PASS)**

```bash
MUT="$(mktemp -d)"; cp scripts/install-anomalies-logrotate.sh "$MUT/lr"; cp scripts/vps-bootstrap.sh "$MUT/vb"
restore() { cp "$MUT/lr" scripts/install-anomalies-logrotate.sh; cp "$MUT/vb" scripts/vps-bootstrap.sh; }
T=tests/install-anomalies-logrotate/test-install-anomalies-logrotate.sh
# R1 retention is 90 days
perl -pi -e 's/^  rotate 90$/  rotate 7/' scripts/install-anomalies-logrotate.sh
bash $T | grep -c '^FAIL '; restore                                            # expect 2
# R2 backups never land next to the config (logrotate would load them)
perl -pi -e 's/^\tmkdir -p "\$BACKUP_DIR"$/\tBACKUP_DIR="\$(dirname "\$TARGET")"/' scripts/install-anomalies-logrotate.sh
bash $T | grep -c '^FAIL '; restore                                            # expect 2
# R3 an existing log is never truncated
perl -pi -e 's/^\tif \[ ! -e "\$f" \]; then$/\tif true; then/' scripts/install-anomalies-logrotate.sh
bash $T | grep -c '^FAIL '; restore                                            # expect 1
# R4 bootstrap keeps a single source
perl -pi -e 's/^  FYD_DEPLOY_USER="\$DEPLOY_USER" bash .*$/  cat > \/etc\/logrotate.d\/anomalies <<EOF\n\/var\/log\/anomalies.log {\n}\nEOF/' scripts/vps-bootstrap.sh
bash $T | grep -c '^FAIL '; restore                                            # expect 2
cmp scripts/install-anomalies-logrotate.sh "$MUT/lr" && cmp scripts/vps-bootstrap.sh "$MUT/vb" && rm -rf "$MUT"
bash $T | tail -1
```

Expected: `2 2 1 2`, then `RESULT: PASS`.

- [ ] **Step 7: Guards and full suite**

Run:

```bash
for f in scripts/install-anomalies-logrotate.sh tests/install-anomalies-logrotate/test-install-anomalies-logrotate.sh scripts/vps-bootstrap.sh; do
  bash scripts/publish-guard.sh --text <"$f" >/dev/null 2>&1; echo "$? $f"; done
bash tests/run-all-tests.sh | tail -4
```

Expected: every line starts with `0 `, and the runner ends with `RESULT: ALL PASS`.

- [ ] **Step 8: Commit**

Stage exactly `scripts/install-anomalies-logrotate.sh scripts/vps-bootstrap.sh tests/install-anomalies-logrotate/test-install-anomalies-logrotate.sh` and commit with:

```text
feat(ops): keep anomaly and public-site probe logs for 90 days from one installer

The 09-21/09-23 public-site alerts could not be explained afterwards partly
because /var/log/anomalies.log kept only 7 days. The probe's new diagnostics
and blip logs are what a later digest or a hosting support inquiry reads, so
all three logs rotate daily and are kept 90 days.

install-anomalies-logrotate.sh is the single source: vps-bootstrap.sh now
calls it instead of carrying its own 7-day heredoc. It also creates the two
new logs as deploy:deploy 0644, because the cron runs as deploy and cannot
create files under /var/log. Backups go to /var/backups, never next to the
config, where logrotate would load them as a second config.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
```

Verify with `git cat-file -t "$(git log -1 --format=%H)"` → `commit`, and `git show --stat HEAD` lists the three files.

---

### Task 3: `WEB_ORIGIN_IP` cron-env installer

**Files:**
- Create: `scripts/install-anomalies-web-origin-env.sh`
- Create: `tests/install-anomalies-web-origin-env/test-install-anomalies-web-origin-env.sh`
- Modify: `tests/cron-generators-lint/test-cron-generators-lint.sh` (Group B, before the `# Group C:` banner)

**Interfaces:**
- Consumes: nothing from other tasks. The env name `WEB_ORIGIN_IP` is fixed by the spec (§3.1) and read by Task 1's `check-anomalies.sh`. It must be a dotted-quad IPv4 without leading zeros, the same rule as Task 1's `web_is_ipv4`.
- Produces: `sudo bash scripts/install-anomalies-web-origin-env.sh --origin-ip=<IPv4>` (or `WEB_ORIGIN_IP` in a root shell's environment). Exit 0 installed or no-op / 1 usage or bad address / 2 not root / 3 target missing / 4 lint refused / 5 post-verify failed (restored). Test-harness env: `FYD_CRON_TARGET`, `FYD_BACKUP_DIR`, `FYD_REPO_PATH`. Task 4 documents it.

- [ ] **Step 1: Write the failing test**

Create `tests/install-anomalies-web-origin-env/test-install-anomalies-web-origin-env.sh` and make it executable:

```bash
#!/usr/bin/env bash
# tests/install-anomalies-web-origin-env/test-install-anomalies-web-origin-env.sh
# — suite for scripts/install-anomalies-web-origin-env.sh (web-probe design
# spec 2026-09-24 §3.6 / §5 case 9: the WEB_ORIGIN_IP env line, supplied at
# install time and never committed).
#
# The fixture is the metal-anomalies file scripts/vps-bootstrap.sh generates
# (its heredoc rendered with the bootstrap's own variables), i.e. the shape
# the live host carries. Addresses are RFC 5737 documentation addresses.
#
# CHAIN: none — test-harness mode only (FYD_CRON_TARGET / FYD_BACKUP_DIR point
#        into a tempdir); /etc/cron.d is never touched.
# PRIME_DIRECTIVE: TESTNET-FIRST — safe.
#
# Usage:
#   bash tests/install-anomalies-web-origin-env/test-install-anomalies-web-origin-env.sh

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
INSTALLER="${REPO_ROOT}/scripts/install-anomalies-web-origin-env.sh"
CHECKER="${REPO_ROOT}/scripts/check-cron-file.sh"
BOOTSTRAP="${REPO_ROOT}/scripts/vps-bootstrap.sh"

PASS=0
FAIL=0
SKIP=0
ok()   { PASS=$((PASS + 1)); echo "PASS  $1"; }
bad()  { FAIL=$((FAIL + 1)); echo "FAIL  $1${2:+ — $2}"; }
skip() { SKIP=$((SKIP + 1)); echo "SKIP  $1${2:+ — $2}"; }
mode_of() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }

WORK="$(mktemp -d -t web-origin-env-test.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
CRON_DIR="$WORK/cron.d"
F="$CRON_DIR/metal-anomalies"
mkdir -p "$CRON_DIR"

render_fixture() {   # <out> — vps-bootstrap.sh's metal-anomalies heredoc, rendered
	local body
	body="$(awk -v pat='cat > /etc/cron.d/metal-anomalies <<EOF' \
		'index($0, pat){flag=1; next} flag && /^EOF$/{exit} flag{print}' "$BOOTSTRAP")"
	printf 'DEPLOY_USER="deploy"\nDEPLOY_DIR="/home/deploy/metal.freedom-yield.com"\ncat <<EOF\n%s\nEOF\n' "$body" \
		| bash >"$1"
}
run_inst() {   # [args...] — against $F
	FYD_CRON_TARGET="$F" FYD_BACKUP_DIR="$WORK/backups" bash "$INSTALLER" "$@"
}
backups() { ls "$WORK/backups" 2>/dev/null | grep -c '^metal-anomalies\.bak-' || true; }
first_cmd_line() { grep -nvE '^[[:space:]]*(#|$)|^[A-Z_]+=' "$1" | head -1 | cut -d: -f1; }

render_fixture "$F"
[ -s "$F" ] && grep -q 'check-anomalies.sh' "$F" \
	&& ok "fixture: rendered vps-bootstrap.sh's metal-anomalies" \
	|| { bad "fixture: rendered vps-bootstrap.sh's metal-anomalies"; exit 1; }
cp "$F" "$WORK/orig"

# --- T1 insert --------------------------------------------------------------------
OUT="$(run_inst --origin-ip=192.0.2.10 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && ok "T1 insert exits 0" || bad "T1 insert exits 0" "rc=$RC $OUT"
[ "$(grep -c '^WEB_ORIGIN_IP=' "$F")" = "1" ] && grep -qxF 'WEB_ORIGIN_IP=192.0.2.10' "$F" \
	&& ok "T1 exactly one WEB_ORIGIN_IP line with the given value" \
	|| bad "T1 exactly one WEB_ORIGIN_IP line with the given value" "$(grep -n WEB_ORIGIN_IP "$F")"
WO_LINE="$(grep -n '^WEB_ORIGIN_IP=' "$F" | cut -d: -f1)"
[ "$WO_LINE" = "$(( $(first_cmd_line "$F") - 1 ))" ] \
	&& ok "T1 placed directly above the first command line (end of the env header block)" \
	|| bad "T1 placed directly above the first command line" "line=$WO_LINE first_cmd=$(first_cmd_line "$F")"
diff <(grep -v '^WEB_ORIGIN_IP=' "$F") "$WORK/orig" >/dev/null \
	&& ok "T1 every other line preserved" || bad "T1 every other line preserved"
bash "$CHECKER" "$F" >/dev/null 2>&1 \
	&& ok "T1 result passes check-cron-file.sh" || bad "T1 result passes check-cron-file.sh"
grep -qF '192.0.2.10' <<<"$OUT" \
	&& bad "T1 the value is never echoed" "$OUT" || ok "T1 the value is never echoed"
[ "$(mode_of "$F")" = "644" ] && ok "T1 mode 0644" || bad "T1 mode 0644" "$(mode_of "$F")"
[ "$(backups)" = "1" ] && ok "T1 prior file backed up once" || bad "T1 prior file backed up once" "$(backups)"

# --- T2 idempotent ------------------------------------------------------------------
cp "$F" "$WORK/after-t1"
OUT="$(run_inst --origin-ip=192.0.2.10 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && grep -q 'no change' <<<"$OUT" && cmp -s "$F" "$WORK/after-t1" \
	&& ok "T2 same value again is a byte-for-byte no-op" || bad "T2 same value again is a no-op" "rc=$RC $OUT"
[ "$(backups)" = "1" ] && ok "T2 no extra backup on a no-op" || bad "T2 no extra backup on a no-op" "$(backups)"

# --- T3 change value --------------------------------------------------------------------
run_inst --origin-ip=198.51.100.7 >/dev/null 2>&1; RC=$?
[ "$RC" -eq 0 ] && [ "$(grep -c '^WEB_ORIGIN_IP=' "$F")" = "1" ] && grep -qxF 'WEB_ORIGIN_IP=198.51.100.7' "$F" \
	&& ok "T3 a new value replaces the old one (still one line)" \
	|| bad "T3 a new value replaces the old one" "$(grep -n WEB_ORIGIN_IP "$F")"
grep -qF '192.0.2.10' "$F" && bad "T3 old value gone" || ok "T3 old value gone"
[ "$(ls "$CRON_DIR")" = "metal-anomalies" ] \
	&& ok "T3 no sidecar left in the cron dir" || bad "T3 no sidecar left in the cron dir" "$(ls "$CRON_DIR")"

# --- T4 value from the environment ------------------------------------------------------
render_fixture "$F"
WEB_ORIGIN_IP=192.0.2.10 FYD_CRON_TARGET="$F" FYD_BACKUP_DIR="$WORK/backups" bash "$INSTALLER" >/dev/null 2>&1; RC=$?
[ "$RC" -eq 0 ] && grep -qxF 'WEB_ORIGIN_IP=192.0.2.10' "$F" \
	&& ok "T4 WEB_ORIGIN_IP from the environment is accepted" || bad "T4 WEB_ORIGIN_IP from the environment" "rc=$RC"

# --- T5 duplicates collapse to one ----------------------------------------------------------
render_fixture "$F"
awk 'NR==1{print "WEB_ORIGIN_IP=203.0.113.9"} {print} END{print "WEB_ORIGIN_IP=203.0.113.10"}' "$F" >"$WORK/dup" && cp "$WORK/dup" "$F"
run_inst --origin-ip=192.0.2.10 >/dev/null 2>&1
[ "$(grep -c '^WEB_ORIGIN_IP=' "$F")" = "1" ] && grep -qxF 'WEB_ORIGIN_IP=192.0.2.10' "$F" \
	&& ok "T5 stray WEB_ORIGIN_IP lines are removed, one remains" \
	|| bad "T5 stray WEB_ORIGIN_IP lines are removed" "$(grep -n WEB_ORIGIN_IP "$F")"

# --- T6 invalid addresses are refused and change nothing ------------------------------------
render_fixture "$F"; cp "$F" "$WORK/pre-t6"
for badip in "" 256.1.1.1 1.2.3 010.0.0.1 2001:db8::1 '192.0.2.10;touch /tmp/x' '192.0.2.10 '; do
	WEB_ORIGIN_IP= FYD_CRON_TARGET="$F" FYD_BACKUP_DIR="$WORK/backups" bash "$INSTALLER" "--origin-ip=${badip}" >/dev/null 2>&1; RC=$?
	[ "$RC" -eq 1 ] && cmp -s "$F" "$WORK/pre-t6" \
		&& ok "T6 [${badip}] refused (exit 1), file untouched" \
		|| bad "T6 [${badip}] refused (exit 1), file untouched" "rc=$RC"
done

# --- T7 missing target ----------------------------------------------------------------------
FYD_CRON_TARGET="$CRON_DIR/nope" bash "$INSTALLER" --origin-ip=192.0.2.10 >/dev/null 2>&1; RC=$?
[ "$RC" -eq 3 ] && [ ! -e "$CRON_DIR/nope" ] \
	&& ok "T7 missing target → exit 3, nothing created" || bad "T7 missing target → exit 3" "rc=$RC"

# --- T8 lint failure changes nothing ----------------------------------------------------------
render_fixture "$F"
grep -v '^SHELL=' "$F" >"$WORK/noshell" && cp "$WORK/noshell" "$F"
cp "$F" "$WORK/pre-t8"
run_inst --origin-ip=192.0.2.10 >/dev/null 2>&1; RC=$?
[ "$RC" -eq 4 ] && cmp -s "$F" "$WORK/pre-t8" \
	&& ok "T8 a candidate that fails check-cron-file.sh → exit 4, file untouched" \
	|| bad "T8 lint failure → exit 4, file untouched" "rc=$RC"

# --- T9 root gate ------------------------------------------------------------------------------
if [ "$(id -u)" -ne 0 ]; then
	env -u FYD_CRON_TARGET bash "$INSTALLER" --origin-ip=192.0.2.10 >/dev/null 2>&1; RC=$?
	[ "$RC" -eq 2 ] && ok "T9 production target without root → exit 2" || bad "T9 production target without root → exit 2" "rc=$RC"
else
	skip "T9 root gate" "running as root"
fi

echo "test-install-anomalies-web-origin-env.sh summary: PASS=$PASS  FAIL=$FAIL  SKIP=$SKIP"
if [ "$FAIL" -eq 0 ]; then
	echo "RESULT: PASS"
	exit 0
fi
echo "RESULT: FAIL"
exit 1
```

- [ ] **Step 2: Run it to verify it fails**

Run: `chmod +x tests/install-anomalies-web-origin-env/test-install-anomalies-web-origin-env.sh && bash tests/install-anomalies-web-origin-env/test-install-anomalies-web-origin-env.sh | grep -E '^(PASS|FAIL)' | head -3`
Expected: `PASS  fixture: rendered vps-bootstrap.sh's metal-anomalies`, then `FAIL  T1 insert exits 0 — rc=127 …No such file or directory`.

- [ ] **Step 3: Write the installer**

Create `scripts/install-anomalies-web-origin-env.sh` (mode 0755):

```bash
#!/usr/bin/env bash
# install-anomalies-web-origin-env.sh — set the WEB_ORIGIN_IP env line in
# /etc/cron.d/metal-anomalies, so check-anomalies.sh can probe the web host's
# origin directly (P_direct) when the Cloudflare probe fails.
#
# CHAIN: none — edits one env line of one cron file. No broadcast pathway.
# PRIME_DIRECTIVE: TESTNET-FIRST — safe.
#
# Why (docs/superpowers/specs/2026-09-24-web-probe-path-classification-design.md
# §3.1, §3.6): a direct-to-origin probe is what tells a Cloudflare-path failure
# apart from an origin or network-path failure. The origin address is a host
# identifier, so it is NEVER committed: it is supplied when this installer is
# run and exists only in the host's cron file. This installer never echoes it.
#
# Behaviour:
#   - Edits an EXISTING cron file; it never creates metal-anomalies
#     (scripts/vps-bootstrap.sh does).
#   - Drops every existing WEB_ORIGIN_IP= line and inserts exactly one
#     immediately before the first command line (after the env header block),
#     so the position is deterministic and a re-run with the same value is a
#     byte-for-byte no-op. Every other line is preserved.
#   - The candidate is linted with scripts/check-cron-file.sh before install;
#     a lint failure changes nothing.
#   - A differing prior file is backed up to FYD_BACKUP_DIR — never into
#     /etc/cron.d, where cron would ignore it but a reader could mistake it.
#
# Usage (validator host, as root):
#   sudo bash scripts/install-anomalies-web-origin-env.sh --origin-ip=<IPv4>
#   (or with WEB_ORIGIN_IP=<IPv4> set in a root shell's environment)
#
# Env overrides (test harness):
#   FYD_CRON_TARGET   cron file to edit (default /etc/cron.d/metal-anomalies).
#                     When overridden, the root requirement is waived and root
#                     ownership is not enforced.
#   FYD_BACKUP_DIR    backup destination (default /var/backups)
#   FYD_REPO_PATH     repo whose scripts/check-cron-file.sh lints the
#                     candidate (default: the repo this script lives in)
#
# Exit codes:
#   0  installed, or already up to date
#   1  usage error, or the origin address is missing / not a dotted-quad IPv4
#   2  not root (and FYD_CRON_TARGET not overridden)
#   3  target cron file missing
#   4  candidate failed check-cron-file.sh (target untouched)
#   5  post-install verification failed (prior file restored)
#
# Operator-gated: committed so the host action is one command; running it on
# the host follows operator approval (Constitution §5 / Operating Model W7).

set -euo pipefail

PROD_TARGET="/etc/cron.d/metal-anomalies"
CRON_TARGET="${FYD_CRON_TARGET:-$PROD_TARGET}"
BACKUP_DIR="${FYD_BACKUP_DIR:-/var/backups}"
REPO_PATH="${FYD_REPO_PATH:-$(cd "$(dirname "$0")/.." && pwd)}"
ORIGIN_IP="${WEB_ORIGIN_IP:-}"

for arg in "$@"; do
	case "$arg" in
		--origin-ip=*) ORIGIN_IP="${arg#*=}" ;;
		-h | --help) sed -n '2,49p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*) echo "ERROR: unknown arg: $arg" >&2; exit 1 ;;
	esac
done

if [ "$CRON_TARGET" = "$PROD_TARGET" ] && [ "$(id -u)" -ne 0 ]; then
	echo "ERROR: this installer must run as root (edits /etc/cron.d/metal-anomalies)" >&2
	echo "       usage: sudo bash scripts/install-anomalies-web-origin-env.sh --origin-ip=<IPv4>" >&2
	exit 2
fi

# Dotted-quad IPv4 only, no leading zeros (curl reads 010 as octal). Same
# rule as web_is_ipv4 in scripts/lib/web-probe.sh, which re-checks the value
# at run time and skips P_direct if it is malformed.
is_ipv4() {
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
if ! is_ipv4 "$ORIGIN_IP"; then
	echo "ERROR: origin address missing or not a dotted-quad IPv4 address (pass --origin-ip=<IPv4>)" >&2
	exit 1
fi

if [ ! -f "$CRON_TARGET" ]; then
	echo "ERROR: ${CRON_TARGET} missing — this installer edits it, it does not create it (see scripts/vps-bootstrap.sh)" >&2
	exit 3
fi

TMP="$(mktemp)"
trap 'rm -f "$TMP" "${TMP}.lint"' EXIT
awk -v line="WEB_ORIGIN_IP=${ORIGIN_IP}" '
	/^WEB_ORIGIN_IP=/ { next }
	!done && $0 !~ /^[[:space:]]*(#|$)/ && $0 !~ /^[A-Z_]+=/ { print line; done = 1 }
	{ print }
	END { if (!done) print line }
' "$CRON_TARGET" >"$TMP"

if cmp -s "$TMP" "$CRON_TARGET"; then
	echo "ok: ${CRON_TARGET} already carries this WEB_ORIGIN_IP (no change)"
	exit 0
fi

if ! FYD_CRON_SCRIPTS_DIR="${REPO_PATH}/scripts" bash "${REPO_PATH}/scripts/check-cron-file.sh" "$TMP" >"${TMP}.lint" 2>&1; then
	echo "ERROR: candidate cron file failed check-cron-file.sh — nothing changed" >&2
	grep -F 'FAIL' "${TMP}.lint" >&2 || true
	exit 4
fi

STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP="${BACKUP_DIR}/$(basename "$CRON_TARGET").bak-${STAMP}"
mkdir -p "$BACKUP_DIR"
cp -p "$CRON_TARGET" "$BACKUP"
echo "backed up prior target to ${BACKUP}"

if [ "$CRON_TARGET" = "$PROD_TARGET" ]; then
	install -m 0644 -o root -g root "$TMP" "$CRON_TARGET"
else
	install -m 0644 "$TMP" "$CRON_TARGET"
fi

if [ "$(grep -c '^WEB_ORIGIN_IP=' "$CRON_TARGET")" != "1" ] \
	|| ! grep -qxF "WEB_ORIGIN_IP=${ORIGIN_IP}" "$CRON_TARGET"; then
	echo "ERROR: post-install verification failed — restoring ${BACKUP}" >&2
	cp -p "$BACKUP" "$CRON_TARGET"
	exit 5
fi
echo "installed: WEB_ORIGIN_IP set in ${CRON_TARGET} (value not echoed)"
echo "effect:    the next check-anomalies.sh run probes the origin directly when the Cloudflare probe fails"
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash tests/install-anomalies-web-origin-env/test-install-anomalies-web-origin-env.sh | tail -2`
Expected:

```
test-install-anomalies-web-origin-env.sh summary: PASS=26  FAIL=0  SKIP=0
RESULT: PASS
```

(As root, T9 is a SKIP: `PASS=25  FAIL=0  SKIP=1`.)

- [ ] **Step 5: Mutation-prove the test (break → FAIL → restore → PASS)**

```bash
MUT="$(mktemp -d)"; cp scripts/install-anomalies-web-origin-env.sh "$MUT/wo"
restore() { cp "$MUT/wo" scripts/install-anomalies-web-origin-env.sh; }
T=tests/install-anomalies-web-origin-env/test-install-anomalies-web-origin-env.sh
# W1 exactly one WEB_ORIGIN_IP line (old/stray lines are dropped)
perl -pi -e 's/^\t\/\^WEB_ORIGIN_IP=\/ \{ next \}$/\t# (mutated)/' scripts/install-anomalies-web-origin-env.sh
bash $T | grep -c '^FAIL '; restore                                            # expect 4
# W2 only dotted-quad IPv4 is accepted
perl -pi -e 's/^if ! is_ipv4 "\$ORIGIN_IP"; then$/if false; then/' scripts/install-anomalies-web-origin-env.sh
bash $T | grep -c '^FAIL '; restore                                            # expect 7
# W3 lint-gated: a candidate failing check-cron-file.sh changes nothing
perl -pi -e 's/^if ! FYD_CRON_SCRIPTS_DIR=.*then$/if false; then/' scripts/install-anomalies-web-origin-env.sh
bash $T | grep -c '^FAIL '; restore                                            # expect 1
# W4 the value is never echoed
perl -pi -e 's/^echo "installed: WEB_ORIGIN_IP set in \$\{CRON_TARGET\} \(value not echoed\)"$/echo "installed: WEB_ORIGIN_IP=\${ORIGIN_IP} in \${CRON_TARGET}"/' scripts/install-anomalies-web-origin-env.sh
bash $T | grep -c '^FAIL '; restore                                            # expect 1
# W5 same value twice is a byte-for-byte no-op
perl -pi -e 's/^if cmp -s "\$TMP" "\$CRON_TARGET"; then$/if false; then/' scripts/install-anomalies-web-origin-env.sh
bash $T | grep -c '^FAIL '; restore                                            # expect 1
cmp scripts/install-anomalies-web-origin-env.sh "$MUT/wo" && rm -rf "$MUT"
bash $T | tail -1
```

Expected: `4 7 1 1 1`, then `RESULT: PASS`.

- [ ] **Step 6: Register the composition in the cron-generators lint**

In `tests/cron-generators-lint/test-cron-generators-lint.sh`, insert this block directly before the `# =============…` banner line that precedes `# Group C: install-metal-anchor-publish-health-cron.sh …` (i.e. after the `install-reward-tracker-cron.sh` idempotency check):

```bash
# ---- install-anomalies-web-origin-env.sh -------------------------------------
# Not a whole-file generator: it edits the metal-anomalies file that
# vps-bootstrap.sh generates, adding the WEB_ORIGIN_IP env line (web-probe
# design spec 2026-09-24 §3.6). So lint the COMPOSITION — bootstrap's rendered
# metal-anomalies with the installer applied — which is exactly the file the
# validator host ends up carrying. 192.0.2.10 is an RFC 5737 doc address.
WO_OUT="$WORK/web-origin-env-cron-file"
render_bootstrap_cron metal-anomalies > "$WO_OUT"
FYD_CRON_TARGET="$WO_OUT" FYD_BACKUP_DIR="$WORK/wo-backups" \
	bash "${REPO_ROOT}/scripts/install-anomalies-web-origin-env.sh" --origin-ip=192.0.2.10 >/dev/null 2>&1
RC=$?
[ "$RC" -eq 0 ] && grep -qxF 'WEB_ORIGIN_IP=192.0.2.10' "$WO_OUT" \
	&& ok "generate: install-anomalies-web-origin-env.sh adds WEB_ORIGIN_IP to bootstrap's metal-anomalies" \
	|| bad "generate: install-anomalies-web-origin-env.sh adds WEB_ORIGIN_IP to bootstrap's metal-anomalies (rc=$RC)"
lint_file_is_clean "install-anomalies-web-origin-env.sh (on vps-bootstrap.sh:metal-anomalies)" "$WO_OUT"
WO_REPEAT_OUT="$(FYD_CRON_TARGET="$WO_OUT" FYD_BACKUP_DIR="$WORK/wo-backups" \
	bash "${REPO_ROOT}/scripts/install-anomalies-web-origin-env.sh" --origin-ip=192.0.2.10 2>&1)"
printf '%s' "$WO_REPEAT_OUT" | grep -q 'no change' \
	&& ok "install-anomalies-web-origin-env.sh: re-running with the same value is idempotent (no-op)" \
	|| bad "install-anomalies-web-origin-env.sh: re-run did not report idempotent no-op"

```

Run: `bash tests/cron-generators-lint/test-cron-generators-lint.sh | grep -E 'web-origin|summary'`
Expected:

```
PASS  generate: install-anomalies-web-origin-env.sh adds WEB_ORIGIN_IP to bootstrap's metal-anomalies
PASS  lint: install-anomalies-web-origin-env.sh (on vps-bootstrap.sh:metal-anomalies) passes check-cron-file.sh (exit 0)
PASS  install-anomalies-web-origin-env.sh: re-running with the same value is idempotent (no-op)
test-cron-generators-lint.sh summary: PASS=39  FAIL=0
```

Mutation proof for the lint registration: temporarily delete the `SHELL=/bin/bash` line from the rendered file between the installer call and `lint_file_is_clean` (add `sed -i.bak '/^SHELL=/d' "$WO_OUT"` after `RC=$?`) and rerun. Expected: the `lint: install-anomalies-web-origin-env.sh …` line turns `FAIL`. Remove the inserted line again and rerun → `FAIL=0`.

- [ ] **Step 7: Guards and full suite**

Run:

```bash
for f in scripts/install-anomalies-web-origin-env.sh tests/install-anomalies-web-origin-env/test-install-anomalies-web-origin-env.sh tests/cron-generators-lint/test-cron-generators-lint.sh; do
  bash scripts/publish-guard.sh --text <"$f" >/dev/null 2>&1; echo "$? $f"; done
grep -nE '([0-9]{1,3}\.){3}[0-9]{1,3}' scripts/install-anomalies-web-origin-env.sh \
  tests/install-anomalies-web-origin-env/test-install-anomalies-web-origin-env.sh tests/cron-generators-lint/test-cron-generators-lint.sh \
  | grep -vE '192\.0\.2\.|198\.51\.100\.|203\.0\.113\.' || echo "only RFC 5737 addresses"
bash tests/run-all-tests.sh | tail -4
```

Expected: every publish-guard line starts with `0 `, `only RFC 5737 addresses`, and the runner ends with `RESULT: ALL PASS`.

- [ ] **Step 8: Commit**

Stage exactly `scripts/install-anomalies-web-origin-env.sh tests/install-anomalies-web-origin-env/test-install-anomalies-web-origin-env.sh tests/cron-generators-lint/test-cron-generators-lint.sh` and commit with:

```text
feat(ops): install the web origin address into the anomaly cron env without committing it

The public-site probe tells a Cloudflare-path failure apart from an origin
or network-path failure by probing the origin directly, which needs the
origin address. That address is a host identifier, so it must never be in
the repo. This installer writes exactly one WEB_ORIGIN_IP line into
/etc/cron.d/metal-anomalies from --origin-ip (or the environment) at install
time. It accepts only dotted-quad IPv4, lint-gates the candidate with
check-cron-file.sh, keeps every other line, is a byte-for-byte no-op on
re-run, and never echoes the value.

cron-generators-lint now lints bootstrap's metal-anomalies with the
installer applied, which is the file the host actually carries.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
```

Verify with `git cat-file -t "$(git log -1 --format=%H)"` → `commit`, and `git show --stat HEAD` lists the three files.
---

### Integration verification (coordinator, after merging Tasks 1–3, before Task 4)

Not a subagent task. Run on the merged `main` working tree:

```bash
git log --oneline -4                       # the three task commits are present
for h in $(git log -3 --format=%H); do git cat-file -t "$h"; done   # commit ×3
bash tests/run-all-tests.sh | tail -4      # RESULT: ALL PASS, ROSTER balanced
grep -c 'WEB_ORIGIN_IP' scripts/check-anomalies.sh scripts/install-anomalies-web-origin-env.sh   # both non-zero: the env name the installer writes is the one the script reads
grep -c 'anomalies-web-diag.log\|anomalies-web-blips.log' scripts/check-anomalies.sh scripts/install-anomalies-logrotate.sh   # both non-zero: the paths logrotate keeps are the ones the script writes
docker run --rm -v "$PWD":/repo:ro -w /repo ubuntu:24.04 bash -c \
  'apt-get update -qq >/dev/null 2>&1 && apt-get install -y -qq jq curl python3 logrotate >/dev/null 2>&1;
   bash tests/anomalies/integration-linux.sh 2>/dev/null | tail -1;
   bash tests/install-anomalies-logrotate/test-install-anomalies-logrotate.sh | tail -1'
```

Expected: three `commit` lines, `RESULT: ALL PASS`, four non-zero grep counts, `Total: PASS=47 FAIL=0`, `RESULT: PASS`.

---

### Task 4: Documentation (after Tasks 1–3 are merged)

**Files:**
- Modify: `docs/MONITORING_OPS.md` (§1 out-of-scope bullet ~18; §5.4 ~162-184; new §6.7 after §6.6 ~282; §9 ~357-365; §10 runbook ~367-400)
- Modify: `docs/MONITORING_NOTIFY_CALLERS.md` (append an addendum at the end)
- Modify: `TOOLKIT.md` (`scripts/check-anomalies.sh` entry ~126-128; installer table rows after the `install-reward-tracker-cron.sh` row ~200)

**Interfaces:**
- Consumes: the names from Tasks 1–3 exactly as merged: `scripts/lib/web-probe.sh`, `web_incident`, `WEB_ORIGIN_IP`, `WEB_REPROBE_SLEEP`, `WEB_PROBE_MAX_TIME`, `WEB_DIAG_TIMEOUT`, `WEB_DIAG_LOG`, `WEB_BLIP_LOG`, `scripts/install-anomalies-logrotate.sh`, `scripts/install-anomalies-web-origin-env.sh`, the three push titles.
- Produces: nothing code depends on.

Doc rule for this task: refer to code by file and block marker (for example "the `# === transition: web` block of `scripts/check-anomalies.sh`"), not by line number, so the docs do not go stale on the next edit. Never write a real IP address or hostname. The runbook uses `<origin IPv4>`, which is an operator input shown in angle brackets, not a value to fill into the repo.

- [ ] **Step 1: `docs/MONITORING_OPS.md` §1**

Replace the bullet:

```markdown
- The site / web host / Caddy / nginx layer.
```

with:

```markdown
- The site / web host / Caddy / nginx layer itself. (Probing it from the validator host *is* in scope — see §6.7.)
```

- [ ] **Step 2: `docs/MONITORING_OPS.md` §5.4**

In the jsonc block, after the line `  "api_freshness": "ok|warn",` add:

```jsonc
  "web_incident": null,            // OPTIONAL — see below and §6.7
```

After the paragraph that starts `K-3.5 validation: top-level fields present with the expected types.`, add:

```markdown
`web_incident` (added 2026-09-24, §6.7) is the one **optional** field. It may be absent or `null`, meaning no public-site incident is open; `anomaly-state-init.sh` writes `null`. When present and not `null` it must be an object with `started_at` (number: epoch of the first failed observation), `last_class` (`cf_path` | `origin_or_path` | `unknown`), `classes` (array of strings, the classes seen in order of first appearance), `runs` (number: consecutive failed runs) and `pushed` (boolean: the outage push was delivered). Any other shape is a schema mismatch and is quarantined like every other mismatch (§5.1). A state file written before the field existed therefore stays valid.
```

- [ ] **Step 3: `docs/MONITORING_OPS.md` new §6.7**

Insert after the end of §6.6 (directly before `## 7. anomaly-state-init.sh (operator-only)`):

````markdown
### 6.7 Public-site probe (`web`): classification, persistence gate, diagnostics

Design: [`docs/superpowers/specs/2026-09-24-web-probe-path-classification-design.md`](superpowers/specs/2026-09-24-web-probe-path-classification-design.md). Measuring, classifying and text rendering live in `scripts/lib/web-probe.sh`, which has no side effects. Every state change and every write stays in the `# === observation: web URL availability` and `# === transition: web` blocks of `scripts/check-anomalies.sh`.

**Probes.**

| Probe | When | What it tells |
|---|---|---|
| `P_cf` — `GET ${WEB_URL}/health`, 10 s cap | every run | what a visitor sees through Cloudflare |
| `P_cf` re-probe after `WEB_REPROBE_SLEEP` (30 s) | first probe failed, no incident open, `.web == ok` | absorbs sub-30 s blips |
| `P_direct` — same URL with `curl --resolve <host>:<port>:${WEB_ORIGIN_IP}` | `P_cf` still failing | whether the origin answers when Cloudflare is bypassed |

A healthy run makes exactly one request. `WEB_ORIGIN_IP` comes only from the cron env (installed by `scripts/install-anomalies-web-origin-env.sh`) and is never committed. When it is unset or not a dotted-quad IPv4, `P_direct` is skipped and logged.

**Classification** (uses the last `P_cf` result and `P_direct`):

| `P_cf` | `P_direct` | class | label in pushes |
|---|---|---|---|
| fail | 200 | `cf_path` | Cloudflare 経路 (origin は正常) |
| fail | fail | `origin_or_path` | origin 停止 または シンガポール経路 (未判別) |
| fail | skipped | `unknown` | 判別不能 (origin 直接確認なし) |

**Transitions** (`web_incident` is described in §5.4):

1. `P_cf` 200, no incident → nothing.
2. `P_cf` 200, incident open, `pushed=false` → no push; one blip-log line; incident cleared.
3. `P_cf` 200, incident open, `pushed=true` → `公開サイト復旧` (default) with `継続: 約 N 分 (5 分刻みの観測)` and the classes seen. On a delivered push: `.web=ok`, one blip-log line, incident cleared.
4. `P_cf` fails, no incident → incident opened (`runs=1`, `pushed=false`), diagnostics appended, **no push**.
5. `P_cf` fails, incident open, `pushed=false` → `runs+1` and a push chosen by the current class: `公開サイトが応答しない (5 分以上継続)` (high) for `origin_or_path` / `unknown`, `公開サイト: Cloudflare 経路で失敗継続 (origin は正常)` (default) for `cf_path`. On a delivered push: `pushed=true`, `.web=warn`.
6. `P_cf` fails, incident open, `pushed=true` → `runs+1`, diagnostics only.

`pushed` and `.web` advance only after `notify_or_keep` succeeds (K-3, §6.1); a failed push is retried by the next run. `started_at`, `runs`, `classes` and `last_class` are observations and advance every run. A legacy state (`.web=warn` without `web_incident`, written before 2026-09-24) is treated as open and already pushed: no re-probe, no second outage push, and a recovery push that says `継続: 不明` with no blip line.

**Logs** (production paths; any other state dir puts them beside that state dir, so a test sandbox never writes `/var/log`):

| File | Content | Written by |
|---|---|---|
| `/var/log/anomalies-web-diag.log` | one block per failed observation, header `=== web-diag <UTC ISO> class=<c> ===`, then both `P_cf` runs, `P_direct` (timing line with `curl_rc`, response headers incl. `cf-ray`, curl error) and `mtr -r -n -c 5 -w ${WEB_ORIGIN_IP}` under `timeout 25` | `fyd_live_write --append` |
| `/var/log/anomalies-web-blips.log` | one line per closed incident: `<start UTC> <end UTC> duration_s=<n> classes=<a,b> pushed=<bool>` | `fyd_live_write --append` |

`scripts/install-anomalies-logrotate.sh` keeps both and `anomalies.log` for 90 days (`daily`, `rotate 90`, `compress`) and creates the two new files as deploy:deploy 0644, because the cron user cannot create files in `/var/log`. A failed append is reported on stderr and never blocks the transition. If `mtr` is not installed, the block records `skipped (mtr not installed)`.

**Env knobs:** `WEB_URL`, `WEB_ORIGIN_IP`, `WEB_REPROBE_SLEEP` (30), `WEB_PROBE_MAX_TIME` (10), `WEB_DIAG_TIMEOUT` (25), `WEB_DIAG_LOG`, `WEB_BLIP_LOG`. Only `WEB_ORIGIN_IP` is set in production; the rest exist for tests.

**Latency and runtime.** A real outage now pages on the second failed run, about 5 minutes after the first instead of about 30 s. This is accepted (spec G2). Worst-case run time is about 85 s (10 + 30 + 10 + 10 + 25), well inside the 5-minute cadence, and K-4 (§4) prevents overlap.

**Tests:** `tests/anomalies/test-web-probe-lib.sh` (library), `tests/anomalies/test-web-incident.sh` (multi-run end-to-end in a sandbox), `tests/anomalies/integration-linux.sh` case I9 (real HTTP server going down for two runs).
````

- [ ] **Step 4: `docs/MONITORING_OPS.md` §9**

After the bullet that starts ``- `${ANOMALY_STATE_DIR}/quarantine/<sha>/diag.txt` `` add:

```markdown
- `/var/log/anomalies-web-diag.log` — public-site diagnostics blocks (§6.7); free-form below the `=== web-diag <UTC ISO> class=<c> ===` header line, which is stable.
- `/var/log/anomalies-web-blips.log` — one line per closed public-site incident (§6.7); the line format `<start UTC> <end UTC> duration_s=<n> classes=<a,b> pushed=<bool>` is stable, because a later digest or a support inquiry reads it.
```

- [ ] **Step 5: `docs/MONITORING_OPS.md` §10 runbook**

In the §10 bash block, after the `ls -la "$STATE_BASE/locks/"` / marker-check lines and before the closing fence, add:

```bash

# Public-site probe (2026-09-24, §6.7). Run as root after the repo is on the
# host. The origin address is typed here and lands only in the cron file; it
# is never committed and the installer does not echo it back.
bash scripts/install-anomalies-logrotate.sh
bash scripts/install-anomalies-web-origin-env.sh --origin-ip=<origin IPv4>
logrotate -d /etc/logrotate.d/anomalies 2>&1 | tail -3
grep -c '^WEB_ORIGIN_IP=' /etc/cron.d/metal-anomalies     # expect 1
bash scripts/check-cron-file.sh /etc/cron.d/metal-anomalies
```

- [ ] **Step 6: `docs/MONITORING_NOTIFY_CALLERS.md` addendum**

Append at the end of the file:

```markdown

## Addendum (2026-09-24) — public-site probe titles in `check-anomalies.sh`

Sections 1–7 above and the 2026-09-07 addendum are left as written. The public-site transition in `scripts/check-anomalies.sh` (the `# === transition: web` block) changed: it no longer pages on the first failed run, and it has three titles instead of two. It is the same caller shape as every other K-3 transition — `notify_or_keep <prio> <title> <body>` → `fyd_notify --strict` → `notify.sh`, with in-run retry on rc 2/4/5 (§6) — so there is no new exit-code handling. Design: `docs/superpowers/specs/2026-09-24-web-probe-path-classification-design.md`; behaviour: `docs/MONITORING_OPS.md` §6.7.

| Title | Priority | When | State advanced only on delivery |
|---|---|---|---|
| `公開サイトが応答しない (5 分以上継続)` | high | 2nd consecutive failed run, class `origin_or_path` or `unknown` | `web_incident.pushed=true`, `.web=warn` |
| `公開サイト: Cloudflare 経路で失敗継続 (origin は正常)` | default | 2nd consecutive failed run, class `cf_path` | `web_incident.pushed=true`, `.web=warn` |
| `公開サイト復旧` | default | first healthy run after a delivered outage push | `.web=ok`, `web_incident` cleared, one blip-log line |

The pre-2026-09-24 title `公開サイトが応答しない` (without the suffix) is no longer sent. A failure that clears before the next run sends nothing; it is recorded in `/var/log/anomalies-web-blips.log` with `pushed=false`. Bodies carry the class label, `継続: 約 N 分 (5 分刻みの観測)`, the key timings of `P_cf` and `P_direct`, the `cf-ray` colo, and the path of the diagnostics log.
```

- [ ] **Step 7: `TOOLKIT.md`**

In the `### \`scripts/check-anomalies.sh\`` entry, replace:

```markdown
**Purpose:** Anomaly detector. Runs frequently via cron. Compares current state vs. a state file to dedup notifications. Detection rules: container status, disk > 85%, memory > 95%, peer count < 10, validator missing from `getCurrentValidators`, period T-7 / T-3 / T-1, stale public `validator.json` push.
**Dependencies:** `notify.sh`, `jq`, `curl`. State file in a configurable path.
```

with:

```markdown
**Purpose:** Anomaly detector. Runs frequently via cron. Compares current state vs. a state file to dedup notifications. Detection rules: container status, disk > 85%, memory > 95%, peer count < 10, validator missing from `getCurrentValidators`, period T-7 / T-3 / T-1, stale public `validator.json` push, and public-site reachability — classified by path (Cloudflare vs. origin, via a direct-to-origin probe) and paged only when a failure lasts into the next run (see `docs/MONITORING_OPS.md` §6.7).
**Dependencies:** `notify.sh`, `jq`, `curl`, `scripts/lib/side-effects.sh`, `scripts/lib/web-probe.sh`; optional `mtr` for diagnostics. State file in a configurable path.
```

After the `| \`scripts/install-reward-tracker-cron.sh\` | … | manual |` row add:

```markdown
| `scripts/install-anomalies-logrotate.sh` | Install `/etc/logrotate.d/anomalies`: `anomalies.log`, `anomalies-web-diag.log` and `anomalies-web-blips.log` rotated daily and kept 90 days; creates the two web-probe logs as deploy:deploy 0644. Single source (`vps-bootstrap.sh` calls it). Root-only unless `FYD_LOGROTATE_TARGET` is overridden; idempotent; backs up a differing prior config to `/var/backups`. | manual |
| `scripts/install-anomalies-web-origin-env.sh` | Write exactly one `WEB_ORIGIN_IP=` line (dotted-quad IPv4 from `--origin-ip=`) into `/etc/cron.d/metal-anomalies` so `check-anomalies.sh` can probe the web origin directly. The value is never committed or echoed. Root-only unless `FYD_CRON_TARGET` is overridden; lint-gated by `check-cron-file.sh`; byte-for-byte no-op on re-run. | manual |
| `scripts/lib/web-probe.sh` | Side-effect-free helpers behind `check-anomalies.sh`'s public-site probe: one probe with timing capture, `--resolve` spec, classification and labels, cf-ray colo, mtr capture, diagnostics block and blip line rendering. | library (sourced) |
```

- [ ] **Step 8: Check the docs**

Run:

```bash
for f in docs/MONITORING_OPS.md docs/MONITORING_NOTIFY_CALLERS.md TOOLKIT.md; do
  bash scripts/publish-guard.sh --text <"$f" >/dev/null 2>&1; echo "$? $f"; done
grep -n '^### 6.7\|^## 7\.' docs/MONITORING_OPS.md
grep -c '公開サイトが応答しない (5 分以上継続)\|公開サイト: Cloudflare 経路で失敗継続 (origin は正常)\|公開サイト復旧' docs/MONITORING_NOTIFY_CALLERS.md
for t in '公開サイトが応答しない (5 分以上継続)' '公開サイト: Cloudflare 経路で失敗継続 (origin は正常)' '公開サイト復旧'; do grep -cF "$t" scripts/check-anomalies.sh; done
bash tests/run-all-tests.sh | tail -2
```

Expected: three lines starting with `0 `; `### 6.7` listed before `## 7.`; `3` (one table row per title); `1`, `1`, `1` (each documented title is spelled exactly as the code sends it); `RESULT: ALL PASS`. Also read the rendered §6.7 tables once to check that the headings keep `h2 → h3` nesting.

- [ ] **Step 9: Commit**

Stage exactly `docs/MONITORING_OPS.md docs/MONITORING_NOTIFY_CALLERS.md TOOLKIT.md` and commit with:

```text
docs(monitoring): document the public-site probe classification, logs and installers

MONITORING_OPS gains §6.7 (probes, classification, the six transitions,
logs, env, accepted latency) and the optional web_incident field in the
§5.4 schema and §9; the §10 runbook gets the two root installers. The
notify caller inventory records the three titles that replace the old
single outage title, and TOOLKIT lists the installers and the new library.
The docs point at code by block marker, not line number, so they do not
drift on the next edit.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
```

Verify with `git cat-file -t "$(git log -1 --format=%H)"` → `commit`.

---

## Rollout (coordinator + operator; not a subagent task)

1. **Ask the operator before any push.** A push to `main` advances the validator host through the deploy's git advance, so it is a production monitoring change (spec §3.6, §7).
2. **Precondition, checked read-only on the host before pushing:** `jq -c '{web, web_incident}' /var/lib/freedom-yield/anomaly-state.json` should show `.web == "ok"` and `web_incident` absent. If `.web` is `warn`, the new code takes the legacy path (silent while failing, `公開サイト復旧` with `継続: 不明` on recovery). That is safe but loses the duration for that one incident, so prefer to deploy after the old code has sent its recovery push.
3. After deploy, as root on the validator host, with operator approval: run `bash scripts/install-anomalies-logrotate.sh`, then `bash scripts/install-anomalies-web-origin-env.sh --origin-ip=<origin IPv4>`. The address comes from the operator or the host-side record. It must not be pasted into the repo, a commit, a memory file or an artifact.
4. Verify on the host: `logrotate -d /etc/logrotate.d/anomalies` (no errors); `grep -c '^WEB_ORIGIN_IP=' /etc/cron.d/metal-anomalies` → `1`; `bash scripts/check-cron-file.sh /etc/cron.d/metal-anomalies` → exit 0; `ls -l /var/log/anomalies-web-*.log` → two files owned by deploy, mode 644; `command -v mtr` (if missing, diagnostics record `skipped (mtr not installed)`; installing `mtr-tiny` is a separate operator decision); after the next tick, `tail -3 /var/log/anomalies.log` shows `=== metal-anomalies end … rc=0 ===`.
5. No live failure test. An outage is never induced on production; the failure paths are covered by the suites above.
6. Memory (not a repo change, spec §6): update the `reference_xserver_topology` memory to name the web container `caddy-static`.

---

## Spec decisions made while planning

These points were open or underspecified in the spec. Each was resolved as below and verified in a scratch prototype (all suites green, every mutation caught).

1. **Log paths in tests.** The spec fixes `/var/log/…`. A test run with `FY_LIVE=1` on the validator host (where the suites are run as deploy) would then append to the production logs, which is the accident class `side-effects.sh` exists to prevent. The defaults therefore follow the resolved state dir, as `LOCK_FILE` already does: `/var/log/…` when the state dir is the production default, otherwise beside the sandbox state. `WEB_DIAG_LOG` / `WEB_BLIP_LOG` can override. Production behaviour is exactly the spec's.
2. **Provisioning the new logs.** The cron runs as deploy, which cannot create files in `/var/log`. The logrotate installer therefore also creates both files (deploy:deploy 0644) and never truncates an existing one.
3. **Legacy state (`.web=warn`, no `web_incident`).** The spec does not cover it. It is treated as open and already pushed: no re-probe, no second outage push, and a recovery push saying `継続: 不明` with no blip line. It is not converted into a `web_incident`, so no duration is made up. The rollout adds a read-only precondition check.
4. **IPv4 only for `WEB_ORIGIN_IP`.** The spec is silent on IPv6. `--resolve` needs brackets for IPv6, and the origin is IPv4. Leading-zero octets are refused (curl reads them as octal). Invalid values are refused by the installer (exit 1) and skipped with a stderr line by the script.
5. **`P_direct` URL.** The spec writes `https://${WEB_HOST}/health` on port 443. The plan derives host and port from `WEB_URL`, which gives exactly that in production and lets integration case I9 aim `P_direct` at a local server.
6. **"timeout 25 bounds the whole capture".** Each curl already has a 10 s cap, so `timeout 25` wraps `mtr`, the only unbounded step. Worst case is about 85 s.
7. **Blip line timing.** For a pushed incident the line is written only after the recovery push is delivered, so a retried recovery does not write a duplicate. If the state commit fails after that, the line may be written twice (at-least-once, like notifications).
8. **Test strategy.** The spec says "extract the real block by its markers". The multi-run properties (no push on run 1, one on run 2, none on run 3; a push that fails and is retried) can only be seen across real candidate-state commits. The end-to-end suite therefore runs the real script in a sandbox, several times per case, as `test-delegation-notify-body.sh` already does, and the library is unit-tested by sourcing it. Nothing is re-implemented in the tests.
9. **Field-contract checker.** The K-3.5 read of `.web_incident` made `scripts/check-field-contracts.py` report HIGH, because no writer spells that key. `anomaly-state-init.sh` now writes `"web_incident": null` (Task 1 Step 13). The spec allows absent or null.
10. **Test-only env knobs** `WEB_REPROBE_SLEEP`, `WEB_PROBE_MAX_TIME`, `WEB_DIAG_TIMEOUT` mirror the existing `FRESH_REPROBE_SLEEP`. Production uses the spec's 30 / 10 / 25.
11. **Push body wording.** No external status-page URL is included, because URLs handed to the operator must be verified first. The body says "Cloudflare の status page".

---

## Self-review

**Spec coverage.** §3.1 probes → Task 1 Steps 3 and 12 (`web_probe`, `web_resolve_spec`, re-probe rule, `-w` timings and `-D` headers). §3.2 classification → `web_classify` / labels (Step 3), used by pushes (Step 12). §3.3 state → Steps 10, 12 and 13. §3.4 transitions 1–3 → Step 12, tested by cases 1–6, class change and legacy. §3.5 diagnostics and blip log → Steps 3 and 12; retention → Task 2. §3.6 configuration delivery → Task 3 (+ Rollout). §4 error handling → `|| true` / stderr on appends, mtr skipped when missing, K-3 retry (case 6), `unknown` pages high (case 7). §5 tests 1–8 → `test-web-incident.sh`; 9 → Task 3 + cron-generators-lint; every property mutation-proven (Task 1 Steps 5, 16, 17, 19; Task 2 Step 6; Task 3 Steps 5–6); Linux integration case I9 → Step 18. §6 docs → Task 4; memory → Rollout step 6. §7 rollout → Rollout section.

**Placeholder scan.** Every code step embeds the complete file or the exact old/new block. The only angle-bracket values are operator inputs in the runbook and rollout text (`<origin IPv4>`), which by design are never committed.

**Name consistency.** Function names and env names are identical across the Task 1 interface list, the library, `check-anomalies.sh`, the tests and the Task 4 docs. Push titles and labels are identical in the code, the tests (`OUTAGE_TITLE`, `CF_TITLE`, `RECOVERY_TITLE`), integration I9, and `MONITORING_NOTIFY_CALLERS.md`; Task 4 Step 8 greps the code for each documented title.
