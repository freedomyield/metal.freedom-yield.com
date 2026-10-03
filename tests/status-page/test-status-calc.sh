#!/usr/bin/env bash
# tests/status-page/test-status-calc.sh — operator status page (/status/).
#
# CHAIN: none — pure node evaluation of committed static files. No network,
# no broadcast, no host access.
# PRIME_DIRECTIVE: TESTNET-FIRST — safe.
#
# Pins:
#   C1  verdict order: offline > stale watch > alerting > stale validator >
#       uptime unknown / drop > OK; a stale watch beats every other signal,
#       and missing/unreadable data never yields "正常"
#   C2  alerting: last.alerting non-empty OR any last.* false → 異常あり, p2p
#       alert names the provider-ticket next step
#   C3  history: failures counted; a gap is >7 min between checks, and the
#       newest check → now counts as a gap too
#   C4  expected uptime = 100*(elapsed - overlap)/elapsed; the 2026-10-03
#       reference point (S=1788498830, t=2026-10-03T11:40Z) gives 85.78
#   C5  outage partially outside [S, t] is clipped to [S, t]
#   C6  remaining hours = 0.2*(E-S) - (1-actual/100)*elapsed, floored at 0
#   C7  committed known-outages.json carries the 2026-09-24..28 window
#   C8  service worker never answers /status/*, watch-status, known-outages
#       or a cache:"no-store" request from cache (no respondWith)
#   C9  page hygiene: no inline style/script, noindex, h1→h2→h3, dedicated
#       manifest scoped to /status/, not linked from any other page
#   C10 clock: last.t / generated_at / observedAt > 2 min in the future →
#       時刻が不正 (never 正常); ≤ 2 min ahead is tolerated
#   C11 UNKNOWN (null) is never OK: last.* null → 一部未確認, after alerting,
#       before stale validator; history counts unknowns separately
#   C12 watchdog: no successful render for > 3 min → stale; fetch abort /
#       finally / watchdog are wired in status.js
#
# Mutation check: STATUS_CALC_MUTANT=<path> runs C1–C6 against another copy
# of status-calc.js (used to prove each claim fails when broken).
set -u

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
CALC="${STATUS_CALC_MUTANT:-${REPO}/public/status/status-calc.js}"

if ! command -v node >/dev/null 2>&1; then
	echo "FAIL: node not found (required for status-page tests)" >&2
	exit 1
fi

fail=0

REPO="$REPO" CALC="$CALC" node - <<'JS' || fail=1
"use strict";
const fs = require("fs");
const path = require("path");
const vm = require("vm");
const C = require(process.env.CALC);
const REPO = process.env.REPO;

let failures = 0;
function ok(cond, name) {
	if (cond) { console.log("PASS " + name); }
	else { console.log("FAIL " + name); failures++; }
}
const MIN = 60000, HOUR = 3600000;
const iso = (ms) => new Date(ms).toISOString();

const NOW = Date.parse("2026-10-03T11:40:00Z");
const S = 1788498830;            // unix sec (cycle start)
const E = S + 33 * 24 * 3600;    // unix sec (cycle end, synthetic)
const OUT = [{ start: "2026-09-24T10:56:46Z", end: "2026-09-28T14:51:16Z", note: "x" }];

function goodWatch(now) {
	// last check at now - 1 min, then every 5 min back over 24 h (oldest first)
	const checks = [];
	for (let t = now - 1 * MIN; t > now - 24 * HOUR; t -= 5 * MIN) {
		checks.unshift({ t: iso(t), fresh: true, p2p: true, chain: true });
	}
	const lastT = Date.parse(checks[checks.length - 1].t);
	return { schema: 2, generated_at: iso(now), interval_sec: 300,
		last: { t: iso(lastT), fresh: true, p2p: true, chain: true, alerting: [] },
		counts_24h: { runs: checks.length, fail: 0, unknown: 0, gap: 0 }, checks };
}
function goodValidator(now, network) {
	return { observedAt: iso(now - 2 * MIN), startTime: S, endTime: E,
		uptime: { network: network === undefined ? 85.78 : network } };
}
function v(over) {
	const base = { now: NOW, offline: false, watch: goodWatch(NOW), validator: goodValidator(NOW), outages: OUT };
	return C.verdict(Object.assign(base, over));
}

// ---- C1 verdict order ------------------------------------------------------
ok(v({}).code === "ok" && v({}).title === "✅ 正常", "C1 all good → 正常");
ok(v({ offline: true }).code === "offline", "C1 offline → 通信できません");
const staleW = goodWatch(NOW - 15 * MIN); // last.t = now - 16 min
ok(v({ watch: staleW }).code === "stale_watch", "C1 last.t 16 min old → 見張りの情報が古い");
ok(v({ watch: goodWatch(NOW - 13 * MIN) }).code === "ok", "C1 last.t 14 min old is still current");
const staleAlert = goodWatch(NOW - 30 * MIN);
staleAlert.last.p2p = false; staleAlert.last.alerting = ["p2p"];
ok(v({ watch: staleAlert, validator: null, outages: [] }).code === "stale_watch",
	"C1 stale watch beats alerting + missing validator");
ok(v({ watch: null }).code === "stale_watch", "C1 missing watch-status → stale (never OK)");
ok(v({ watch: { schema: 1, last: { t: "garbage" } } }).code === "stale_watch", "C1 unreadable last.t → stale");
{ const w1 = goodWatch(NOW); w1.schema = 1; ok(v({ watch: w1 }).code === "stale_watch", "C1 old schema 1 (timeline) → stale, not read"); }
{ const w3 = goodWatch(NOW); w3.schema = 3; ok(v({ watch: w3 }).code === "stale_watch", "C1 unknown schema → stale"); }
const alertW = goodWatch(NOW); alertW.last.chain = false;
ok(v({ watch: alertW, validator: null }).code === "alert", "C1 alert beats stale validator");
ok(v({ validator: null }).code === "stale_validator", "C1 missing validator.json → validator の情報が古い");
ok(v({ validator: Object.assign(goodValidator(NOW), { observedAt: iso(NOW - 21 * MIN) }) }).code === "stale_validator",
	"C1 observedAt 21 min old → validator の情報が古い");
ok(v({ validator: Object.assign(goodValidator(NOW), { observedAt: iso(NOW - 21 * MIN) }), outages: [] }).code === "stale_validator",
	"C1 stale validator beats uptime drop");
ok(v({ validator: goodValidator(NOW, 85.0) }).code === "uptime_drop", "C1 actual < expected - 0.5 → 想定外の低下");
ok(v({ validator: goodValidator(NOW, 85.4) }).code === "ok", "C1 actual within 0.5 of expected → OK");
ok(v({ validator: goodValidator(NOW, 88.0) }).code === "ok", "C1 actual above expected is fine");
ok(v({ validator: goodValidator(NOW, null) }).ok === false, "C1 uptime null → not OK");
ok(v({ outages: [] }).code === "uptime_drop", "C1 without known outages the same uptime is a drop");

// ---- C2 alerting -------------------------------------------------------------
const aw = goodWatch(NOW); aw.last.alerting = ["p2p"];
const av = v({ watch: aw });
ok(av.code === "alert" && av.title === "⚠️ 異常あり", "C2 alerting non-empty with all-true checks → 異常あり");
ok(/外から届く/.test(av.detail) && /VPS provider/.test(av.next) && /DISASTER_RECOVERY/.test(av.next),
	"C2 p2p alert names the check and the provider-ticket next step");
const fw = goodWatch(NOW); fw.last.fresh = false;
const fv = v({ watch: fw });
ok(fv.code === "alert" && /データ更新/.test(fv.detail), "C2 fresh=false alone → 異常あり (データ更新)");
ok(v({ watch: goodWatch(NOW) }).next === null, "C2 OK has no next step");
ok(/web host/.test(v({ watch: staleW }).next), "C2 stale watch next step = web host / watcher stopped");

// ---- C3 history ----------------------------------------------------------------
const hw = goodWatch(NOW);
ok(C.historySummary(hw.checks, NOW).gaps === 0 && C.historySummary(hw.checks, NOW).failures === 0, "C3 clean history → 0/0");
const hf = goodWatch(NOW); hf.checks[3].p2p = false; hf.checks[10].chain = false;
ok(C.historySummary(hf.checks, NOW).failures === 2, "C3 two failed checks counted");
const hg = goodWatch(NOW); hg.checks.splice(20, 2); // remove two → one 15-min hole
ok(C.historySummary(hg.checks, NOW).gaps === 1, "C3 one >7 min hole → 1 gap");
const h6 = [{ t: iso(NOW - 13 * MIN), fresh: true, p2p: true, chain: true },
	{ t: iso(NOW - 6 * MIN), fresh: true, p2p: true, chain: true }];
ok(C.historySummary(h6, NOW).gaps === 0, "C3 7-min interval exactly is not a gap");
ok(C.historySummary(goodWatch(NOW - 10 * MIN).checks, NOW).gaps === 1, "C3 last check → now >7 min counts as a gap");

// ---- C10 clock skew ------------------------------------------------------------
const fut = (ms) => { const w = goodWatch(NOW); w.last.t = iso(NOW + ms); return w; };
ok(v({ watch: fut(3 * HOUR) }).code === "clock", "C10 last.t 3 h ahead → 時刻が不正 (was ✅ before the fix)");
ok(v({ watch: fut(3 * HOUR) }).title === "⚠️ 時刻が不正 (端末か見張りの時計)", "C10 title");
ok(v({ watch: fut(2 * MIN + 1000) }).code === "clock", "C10 last.t 2 min 1 s ahead → 時刻が不正");
ok(v({ watch: fut(2 * MIN) }).code === "ok", "C10 last.t exactly 2 min ahead is tolerated");
const gw = goodWatch(NOW); gw.generated_at = iso(NOW + 10 * MIN);
ok(v({ watch: gw }).code === "clock", "C10 generated_at 10 min ahead → 時刻が不正");
ok(v({ validator: Object.assign(goodValidator(NOW), { observedAt: iso(NOW + 3 * HOUR) }) }).code === "clock",
	"C10 validator observedAt 3 h ahead → 時刻が不正");
ok(v({ watch: fut(3 * HOUR), validator: Object.assign(goodValidator(NOW), { observedAt: iso(NOW + 3 * HOUR) }) }).ok === false,
	"C10 both ahead → never OK");

// ---- C11 UNKNOWN (null) ----------------------------------------------------------
const uw = goodWatch(NOW); uw.last.chain = null;
const uv = v({ watch: uw });
ok(uv.code === "unknown" && uv.title === "⚠️ 一部未確認" && uv.ok === false, "C11 last.chain null → 一部未確認 (not ✅)");
ok(/ネットワークに接続/.test(uv.detail), "C11 detail names the unconfirmed check");
const uf = goodWatch(NOW); uf.last.fresh = null; uf.last.p2p = null;
ok(v({ watch: uf }).code === "unknown", "C11 fresh+p2p null → 一部未確認");
const ua = goodWatch(NOW); ua.last.chain = null; ua.last.p2p = false;
ok(v({ watch: ua }).code === "alert", "C11 a false check beats null (異常あり first)");
const ual = goodWatch(NOW); ual.last.chain = null; ual.last.alerting = ["fresh"];
ok(v({ watch: ual }).code === "alert", "C11 alerting beats null");
ok(v({ watch: uw, validator: null }).code === "unknown", "C11 null beats stale validator");
const um = goodWatch(NOW); delete um.last.chain;
ok(v({ watch: um }).code === "alert", "C11 a missing check is still an alert (not unknown, not OK)");
const hu = goodWatch(NOW); hu.checks[2].chain = null; hu.checks[5].fresh = null; hu.checks[5].p2p = false;
const hus = C.historySummary(hu.checks, NOW);
ok(hus.unknowns === 1 && hus.failures === 1, "C11 history: null-only check → 未確認, null+false → 失敗");
ok(C.historySummary(goodWatch(NOW).checks, NOW).unknowns === 0, "C11 history: clean → 0 未確認");

// ---- C13 counts_24h (schema 2: aggregates only) -------------------------------------
{ const w = goodWatch(NOW); w.counts_24h = { runs: 280, fail: 2, unknown: 1, gap: 1 };
  const s = C.countsSummary(w, NOW);
  ok(s && s.failures === 2 && s.unknowns === 1 && s.gaps === 1 && s.total === 280, "C13 counts read as published"); }
ok(C.countsSummary(goodWatch(NOW - 10 * MIN), NOW).gaps === 1, "C13 newest run → now > 7 min adds a gap");
ok(C.countsSummary(goodWatch(NOW), NOW).gaps === 0, "C13 fresh watch adds no gap");
{ const w = goodWatch(NOW); delete w.counts_24h; ok(C.countsSummary(w, NOW) === null, "C13 missing counts → null (not a clean 0)"); }
{ const w = goodWatch(NOW); w.counts_24h.fail = -1; ok(C.countsSummary(w, NOW) === null, "C13 negative count → null"); }
{ const w = goodWatch(NOW); w.counts_24h.gap = "0"; ok(C.countsSummary(w, NOW) === null, "C13 string count → null"); }
{ const w = goodWatch(NOW); w.counts_24h.runs = 1.5; ok(C.countsSummary(w, NOW) === null, "C13 non-integer count → null"); }
{ const w = goodWatch(NOW); delete w.counts_24h; ok(v({ watch: w }).code === "stale_watch", "C13 verdict: missing counts → never ✅ (見張りの情報が読めない)"); }
{ const w = goodWatch(NOW); w.counts_24h.fail = "5"; ok(v({ watch: w }).code === "stale_watch", "C13 verdict: garbled counts → never ✅"); }

// ---- C12 watchdog ------------------------------------------------------------------
ok(C.renderStale(NOW - 3 * MIN - 1000, NOW) === true, "C12 last render 3 min 1 s ago → stale");
ok(C.renderStale(NOW - 2 * MIN, NOW) === false, "C12 last render 2 min ago → fine");
ok(C.renderStale(null, NOW) === true, "C12 never rendered → stale");
ok(C.LIMITS.fetchTimeoutMs > 0 && C.LIMITS.fetchTimeoutMs <= 15000, "C12 fetch timeout set (≤ 15 s)");

// ---- C4 expected uptime ------------------------------------------------------
const e = C.expectedUptime(S * 1000, NOW, OUT);
ok(e !== null && e.toFixed(2) === "85.78", "C4 2026-10-03 point → 85.78 (got " + (e && e.toFixed(4)) + ")");
ok(C.expectedUptime(S * 1000, NOW, []) === 100, "C4 no outages → 100");
const vw = C.uptimeView(Object.assign(goodValidator(NOW), { observedAt: "2026-10-03T11:40:00Z" }), OUT);
ok(vw.expected.toFixed(2) === "85.78" && Math.abs(vw.diff) < 0.01, "C4 uptimeView uses observedAt as t; diff ≈ 0");

// ---- C5 partial overlap --------------------------------------------------------
const s5 = Date.parse("2026-01-10T00:00:00Z");
const t5 = s5 + 10 * HOUR;
const before = [{ start: "2026-01-09T22:00:00Z", end: "2026-01-10T01:00:00Z" }]; // 1 h inside
ok(C.overlapMs(before, s5, t5) === 1 * HOUR, "C5 outage starting before S counts only the part after S");
const after = [{ start: "2026-01-10T09:00:00Z", end: "2026-01-10T12:00:00Z" }]; // 1 h inside
ok(C.overlapMs(after, s5, t5) === 1 * HOUR, "C5 outage ending after t counts only the part before t");
ok(Math.abs(C.expectedUptime(s5, t5, before) - 90) < 1e-9, "C5 expected with clipped outage = 90");
const dup = before.concat(before);
ok(C.overlapMs(dup, s5, t5) === 1 * HOUR, "C5 duplicate outage entries are not double-counted");

// ---- C6 remaining hours --------------------------------------------------------
const sm = 0, em = 100 * HOUR;
ok(Math.abs(C.remainingHours(sm, em, 50 * HOUR, 90) - 15) < 1e-9, "C6 0.2*100h - 0.1*50h = 15 h");
ok(C.remainingHours(sm, em, 50 * HOUR, 50) === 0, "C6 over budget floors at 0");
ok(Math.abs(C.remainingHours(sm, em, 50 * HOUR, 100) - 20) < 1e-9, "C6 no downtime → full 20 h budget");
const low = C.uptimeView({ observedAt: iso(NOW), startTime: S, endTime: E, uptime: { network: 85.78 } }, OUT);
const hoursNow = 0.2 * (E - S) / 3600 - (1 - 0.8578) * (NOW / 1000 - S) / 3600;
ok(Math.abs(low.remainingHours - hoursNow) < 1e-6, "C6 uptimeView remaining hours matches the formula");
ok(C.uptimeView({ observedAt: iso(NOW), startTime: S, endTime: E, uptime: { network: 77 } }, OUT).low === true,
	"C6 < 24 h budget flagged low");
ok(Math.abs(low.expectedAtEnd - C.expectedUptime(S * 1000, E * 1000, OUT)) < 1e-9, "C6 cycle-end expectation uses E");

if (!process.env.STATUS_CALC_MUTANT) {
	// ---- C7 committed known outages -------------------------------------------
	const ko = JSON.parse(fs.readFileSync(path.join(REPO, "public/api/known-outages.json"), "utf8"));
	ok(Array.isArray(ko) && ko.every((o) => /\(likely\)/.test(o.note || "")) && ko.some((o) => o.start === "2026-09-24T10:56:46Z" && o.end === "2026-09-28T14:51:16Z"),
		"C7 known-outages.json has the 2026-09-24..28 window");

	// ---- C8 service worker -------------------------------------------------------
	const swSrc = fs.readFileSync(path.join(REPO, "public/sw.js"), "utf8");
	const handlers = {};
	const ctx = {
		self: { addEventListener: (n, f) => { handlers[n] = f; }, location: { origin: "https://example.invalid" },
			skipWaiting() {}, clients: { claim() {} } },
		caches: { match: () => Promise.resolve(undefined), open: () => Promise.resolve({ put() {}, addAll() {} }), keys: () => Promise.resolve([]) },
		fetch: () => Promise.resolve({ clone() { return {}; } }),
		URL, Promise
	};
	vm.createContext(ctx);
	vm.runInContext(swSrc, ctx);
	function answered(pathname, cache) {
		let used = false;
		handlers.fetch({ request: { method: "GET", url: "https://example.invalid" + pathname, cache: cache || "default" },
			respondWith() { used = true; } });
		return used;
	}
	ok(!answered("/status/"), "C8 SW leaves /status/ to the network");
	ok(!answered("/status/status.js"), "C8 SW leaves /status/* assets to the network");
	ok(!answered("/api/watch-status.json?_=1"), "C8 SW leaves watch-status.json to the network");
	ok(!answered("/api/known-outages.json"), "C8 SW leaves known-outages.json to the network");
	ok(!answered("/api/validator.json", "no-store"), "C8 SW leaves a no-store validator.json fetch to the network");
	ok(answered("/api/validator.json") && answered("/styles.css"), "C8 SW still handles the rest of the site");

	// ---- C9 page hygiene -----------------------------------------------------------
	const dir = path.join(REPO, "public/status");
	const html = fs.readFileSync(path.join(dir, "index.html"), "utf8");
	ok(!/style=/.test(html) && !/<style/i.test(html), "C9 no inline style");
	ok(!/<script(?![^>]*\bsrc=)[^>]*>/i.test(html), "C9 no inline script");
	ok(!/https?:\/\/(?!metal\.freedom-yield\.com\/status\/")[^"]*"/.test(html.replace(/<link rel="canonical"[^>]*>/, "")), "C9 no third-party URLs");
	ok(/<meta name="robots" content="noindex,nofollow">/.test(html), "C9 robots noindex,nofollow");
	const hs = (html.match(/<h[1-6]\b/g) || []).map((h) => Number(h[2]));
	let order = hs[0] === 1 && hs.filter((h) => h === 1).length === 1;
	for (let i = 1; i < hs.length; i++) if (hs[i] > hs[i - 1] + 1) order = false;
	ok(order, "C9 headings h1→h2→h3 without skipping");
	const js = fs.readFileSync(path.join(dir, "status.js"), "utf8") + fs.readFileSync(path.join(dir, "status-calc.js"), "utf8");
	ok(!/innerHTML|\.style\.|setAttribute\(\s*["']style/.test(js), "C9 no innerHTML / inline style from JS");
	ok((js.match(/fetch\(/g) || []).length === 1 && /cache: "no-store"/.test(js), "C9 single fetch path, cache no-store");
	const sjs = fs.readFileSync(path.join(dir, "status.js"), "utf8");
	ok(/new AbortController\(\)/.test(sjs) && /signal: ctl \? ctl\.signal/.test(sjs) && /ctl\.abort\(\)/.test(sjs)
		&& /Promise\.race\(\[req, timeout\]\)/.test(sjs) && /C\.LIMITS\.fetchTimeoutMs/.test(sjs),
		"C12 every fetch carries an abort signal and is raced against the timeout");
	ok(/\.then\(done, done\)/.test(sjs) && /function done\(\) \{\s*busy = false;/.test(sjs), "C12 busy cleared on both outcomes (finally)");
	ok(/setInterval\(watchdog, WATCHDOG_MS\)/.test(sjs) && /C\.renderStale\(lastRenderOk, now\)/.test(sjs)
		&& /更新できていません/.test(sjs) && /lastRenderOk = now;/.test(sjs), "C12 watchdog wired: interval + render timestamp + verdict");
	ok(/last\[k\] === null\)\s*\{\s*el\.textContent = "未確認"/.test(sjs) && /未確認 " \+ h\.unknowns/.test(sjs),
		"C11 page renders null as 未確認 and counts 未確認 in 24 h");
	const mf = JSON.parse(fs.readFileSync(path.join(dir, "manifest.json"), "utf8"));
	ok(mf.start_url === "/status/" && mf.scope === "/status/" && mf.name === "Metal 状態", "C9 dedicated manifest scoped to /status/");
	ok(mf.icons.every((i) => fs.existsSync(path.join(REPO, "public", i.src))), "C9 manifest icons exist");
	const { execSync } = require("child_process");
	const linked = execSync("grep -rlE 'href=\"/status/?\"' public --include=*.html || true", { cwd: REPO }).toString().trim();
	ok(linked === "", "C9 /status/ is not linked from any page (" + linked + ")");
}

console.log(failures === 0 ? "RESULT: PASS" : "RESULT: FAIL (" + failures + ")");
process.exit(failures === 0 ? 0 : 1);
JS

exit "$fail"
