// status-calc.js — pure calculations for the operator status page (/status/).
//
// No DOM, no fetch, no clock: every function takes "now" as an argument so
// the same module is exercised by tests/status-page/test-status-calc.sh under
// node and by status.js in the browser. Loaded as a classic script (CSP
// script-src 'self'); exposes window.StatusCalc in the browser and
// module.exports under node.
//
// Fail-closed rule: missing / unreadable / old data never yields "正常".
(function (root, factory) {
	"use strict";
	var api = factory();
	if (typeof module === "object" && module.exports) {
		module.exports = api;
	} else {
		root.StatusCalc = api;
	}
})(typeof self !== "undefined" ? self : this, function () {
	"use strict";

	var MIN = 60 * 1000;
	var HOUR = 60 * MIN;

	var LIMITS = {
		watchStaleMs: 15 * MIN,     // (a) watch-status last.t older than this
		validatorStaleMs: 20 * MIN, // (c) validator.json observedAt older than this
		gapMs: 7 * MIN,             // a check-to-check interval above this is a gap
		uptimeSlackPts: 0.5,        // (d) actual < expected - this → unexpected drop
		rewardThresholdPct: 80,     // reward requirement
		lowBudgetHours: 24,         // remaining budget below this is shown red
		futureSkewMs: 2 * MIN,      // a timestamp this far ahead of now → clock is wrong
		renderStaleMs: 3 * MIN,     // screen not re-rendered for this long → 更新できていません
		fetchTimeoutMs: 15 * 1000   // each fetch is aborted after this
	};

	var CHECK_LABELS = {
		p2p: "外から届く",
		chain: "ネットワークに接続",
		fresh: "データ更新"
	};
	var CHECK_KEYS = ["p2p", "chain", "fresh"];

	// Time → epoch ms. Accepts ISO strings, unix seconds (number or numeric
	// string), or epoch ms (number above 1e12). Anything else → null.
	function toMs(x) {
		if (typeof x === "number" && isFinite(x)) {
			return x > 1e12 ? x : x * 1000;
		}
		if (typeof x === "string" && x !== "") {
			if (/^\d+(\.\d+)?$/.test(x)) return toMs(Number(x));
			var ms = Date.parse(x);
			return isNaN(ms) ? null : ms;
		}
		return null;
	}

	// Total ms of [a, b] covered by the outage intervals (clipped to [a, b]).
	// Overlapping outage entries are merged so time is never counted twice.
	function overlapMs(outages, a, b) {
		if (!(b > a) || !Array.isArray(outages)) return 0;
		var spans = [];
		for (var i = 0; i < outages.length; i++) {
			var o = outages[i] || {};
			var s = toMs(o.start);
			var e = toMs(o.end);
			if (s === null || e === null || !(e > s)) continue;
			s = Math.max(s, a);
			e = Math.min(e, b);
			if (e > s) spans.push([s, e]);
		}
		spans.sort(function (x, y) { return x[0] - y[0]; });
		var total = 0;
		var curS = null;
		var curE = null;
		for (var j = 0; j < spans.length; j++) {
			if (curE === null || spans[j][0] > curE) {
				if (curE !== null) total += curE - curS;
				curS = spans[j][0];
				curE = spans[j][1];
			} else if (spans[j][1] > curE) {
				curE = spans[j][1];
			}
		}
		if (curE !== null) total += curE - curS;
		return total;
	}

	// Uptime (%) we expect at time t given the known outages since start S:
	// 100 * (elapsed - overlap(outages, [S, t])) / elapsed.
	function expectedUptime(startMs, tMs, outages) {
		var elapsed = tMs - startMs;
		if (!(elapsed > 0)) return null;
		return 100 * (elapsed - overlapMs(outages, startMs, tMs)) / elapsed;
	}

	// Hours of further downtime that still keep the cycle at or above 80%:
	// 0.2 * (E - S) - (1 - actual/100) * (t - S), floored at 0.
	function remainingHours(startMs, endMs, tMs, actualPct) {
		if (typeof actualPct !== "number" || !isFinite(actualPct)) return null;
		if (!(endMs > startMs) || !(tMs >= startMs)) return null;
		var budget = (1 - LIMITS.rewardThresholdPct / 100) * (endMs - startMs);
		var used = (1 - actualPct / 100) * (tMs - startMs);
		return Math.max(0, (budget - used) / HOUR);
	}

	// Check values are tri-state: true (PASS), false (FAIL), null (UNKNOWN =
	// not confirmed). Anything else (missing, string, …) counts as failed.
	function checkFailed(c) {
		if (!c) return true;
		for (var i = 0; i < CHECK_KEYS.length; i++) {
			var x = c[CHECK_KEYS[i]];
			if (x !== true && x !== null) return true;
		}
		return false;
	}

	function checkUnknown(c) {
		if (!c) return false;
		for (var i = 0; i < CHECK_KEYS.length; i++) {
			if (c[CHECK_KEYS[i]] === null) return true;
		}
		return false;
	}

	// 24-hour summary of the watch history: failed checks, unconfirmed checks
	// (some value null, none failed) and gaps. A gap is
	// a consecutive-check interval > 7 min; the interval from the newest check
	// to now counts too (a silent watcher is a gap, not a pass).
	function historySummary(checks, nowMs) {
		var list = Array.isArray(checks) ? checks : [];
		var failures = 0;
		var unknowns = 0;
		var gaps = 0;
		var prev = null;
		for (var i = 0; i < list.length; i++) {
			if (checkFailed(list[i])) failures++;
			else if (checkUnknown(list[i])) unknowns++;
			var t = toMs(list[i] && list[i].t);
			if (t === null) continue;
			if (prev !== null && t - prev > LIMITS.gapMs) gaps++;
			prev = t;
		}
		if (prev !== null && nowMs - prev > LIMITS.gapMs) gaps++;
		return { failures: failures, unknowns: unknowns, gaps: gaps, total: list.length };
	}

	// 24-hour summary from the watch's published aggregates (schema 2: the
	// per-run timeline is not public). The web host counts gaps between runs;
	// the interval from the newest run to now is added here, so a silent
	// watcher still shows as a gap. Malformed counts → null (never a clean 0).
	function countsSummary(watch, nowMs) {
		var c = watch && watch.counts_24h;
		var keys = ["runs", "fail", "unknown", "gap"];
		if (!c || typeof c !== "object") return null;
		for (var i = 0; i < keys.length; i++) {
			var x = c[keys[i]];
			if (typeof x !== "number" || x < 0 || Math.floor(x) !== x) return null;
		}
		var lastT = toMs(watch.last && watch.last.t);
		var tail = lastT !== null && nowMs - lastT > LIMITS.gapMs ? 1 : 0;
		return { failures: c.fail, unknowns: c.unknown, gaps: c.gap + tail, total: c.runs };
	}

	function alertNames(last) {
		var names = [];
		var seen = {};
		var alerting = last && Array.isArray(last.alerting) ? last.alerting : [];
		for (var i = 0; i < alerting.length; i++) {
			var n = String(alerting[i]);
			if (!seen[n]) { seen[n] = true; names.push(n); }
		}
		for (var k = 0; k < CHECK_KEYS.length; k++) {
			var key = CHECK_KEYS[k];
			// null = 未確認 (handled by unknownNames), not an alert
			if (last && last[key] !== true && last[key] !== null && !seen[key]) { seen[key] = true; names.push(key); }
		}
		return names;
	}

	function unknownNames(last) {
		var names = [];
		for (var k = 0; k < CHECK_KEYS.length; k++) {
			if (last && last[CHECK_KEYS[k]] === null) names.push(CHECK_KEYS[k]);
		}
		return names;
	}

	// true when ms lies further in the future than the allowed clock skew.
	function inFuture(ms, now) {
		return ms !== null && ms - now > LIMITS.futureSkewMs;
	}

	// Watchdog: the screen must have been re-rendered successfully within
	// renderStaleMs, otherwise whatever it shows can no longer be vouched for.
	function renderStale(lastRenderMs, now) {
		return typeof lastRenderMs !== "number" || !isFinite(lastRenderMs) || now - lastRenderMs > LIMITS.renderStaleMs;
	}

	function labelOf(name) {
		return CHECK_LABELS[name] ? CHECK_LABELS[name] + " (" + name + ")" : name;
	}

	// Verdict, evaluated strictly in this order:
	//   (0) nothing could be fetched at all            → 通信できません
	//   (t) last.t / generated_at / observedAt more
	//       than 2 min in the future                   → 時刻が不正
	//   (a) watch-status missing/unreadable/>15 min    → 見張りの情報が古い
	//   (b) last.alerting non-empty or any check false → 異常あり
	//   (u) any check null (UNKNOWN)                   → 一部未確認
	//   (c) validator.json missing or observedAt >20 m → validator の情報が古い
	//   (d) uptime unknown, or actual < expected - 0.5 → 取得できない / 想定外の低下
	//   else                                           → 正常
	// input: { now, offline, watch, validator, outages }
	function verdict(input) {
		var now = input.now;
		var watch = input.watch;
		var validator = input.validator;
		var outages = Array.isArray(input.outages) ? input.outages : [];

		if (input.offline) {
			return { ok: false, code: "offline", title: "⚠️ 通信できません",
				detail: "どのデータも取得できませんでした。電波を確認して再読み込みしてください。",
				next: null };
		}

		var last = watch && watch.last;
		var lastT = last ? toMs(last.t) : null;
		var genT = watch ? toMs(watch.generated_at) : null;
		var obs = validator ? toMs(validator.observedAt) : null;
		if (inFuture(lastT, now) || inFuture(genT, now) || inFuture(obs, now)) {
			return { ok: false, code: "clock", title: "⚠️ 時刻が不正 (端末か見張りの時計)",
				detail: "データの時刻が端末の時刻より 2 分以上先です。どちらかの時計がずれているため、新しさを判断できません。",
				next: "端末の時刻設定 (自動) を確認。正しければ web host / validator host の時計 (NTP) を確認" };
		}
		if (!watch || watch.schema !== 2 || !last || lastT === null || now - lastT > LIMITS.watchStaleMs) {
			return { ok: false, code: "stale_watch", title: "⚠️ 見張りの情報が古い",
				detail: lastT === null ? "見張りの結果が読めません。"
					: "最後の確認から " + Math.floor((now - lastT) / MIN) + " 分たっています。",
				next: "web host か見張りが止まっている可能性" };
		}

		var names = alertNames(last);
		if (names.length > 0) {
			var p2p = names.indexOf("p2p") !== -1;
			return { ok: false, code: "alert", title: "⚠️ 異常あり",
				detail: names.map(labelOf).join("・"), alerting: names,
				next: p2p
					? "VPS provider へ問い合わせ (見張りが下書きを作成済み)。1 時間続けば docs/DISASTER_RECOVERY.md の経路断の手順"
					: "docs/DISASTER_RECOVERY.md を開き、該当する手順を確認" };
		}

		var unk = unknownNames(last);
		if (unk.length > 0) {
			return { ok: false, code: "unknown", title: "⚠️ 一部未確認",
				detail: unk.map(labelOf).join("・") + " を確認できていません。",
				next: "見張りが結果を出せていない確認があります (公開 RPC の不調、更新期間、validator が集合に居ない など)。docs/MONITORING_OPS.md を確認" };
		}

		if (obs === null || now - obs > LIMITS.validatorStaleMs) {
			return { ok: false, code: "stale_validator", title: "⚠️ validator の情報が古い",
				detail: obs === null ? "validator.json が読めません。"
					: "validator.json の観測から " + Math.floor((now - obs) / MIN) + " 分たっています。",
				next: "公開 API を更新する処理 (web host への配信) が止まっている可能性" };
		}

		var up = uptimeView(validator, outages);
		if (up.actual === null || up.expected === null) {
			return { ok: false, code: "uptime_unknown", title: "⚠️ uptime が取得できない",
				detail: "validator.json に uptime か期間の情報がありません。", next: "公開 API の内容を確認" };
		}
		if (up.actual < up.expected - LIMITS.uptimeSlackPts) {
			return { ok: false, code: "uptime_drop", title: "⚠️ 想定外の低下",
				detail: "uptime " + up.actual.toFixed(2) + "% (予定 " + up.expected.toFixed(2) + "%)",
				next: "見張りの履歴を確認し、docs/DISASTER_RECOVERY.md の手順を確認" };
		}

		return { ok: true, code: "ok", title: "✅ 正常", detail: "", next: null };
	}

	// Uptime figures derived from validator.json (+ known outages).
	// t = validator.observedAt (the moment the uptime value describes).
	function uptimeView(validator, outages) {
		var out = { actual: null, expected: null, diff: null, remainingHours: null,
			expectedAtEnd: null, low: false };
		if (!validator) return out;
		var actual = validator.uptime ? validator.uptime.network : null;
		if (typeof actual === "string" && actual !== "") actual = Number(actual);
		if (typeof actual !== "number" || !isFinite(actual)) actual = null;
		var S = toMs(validator.startTime);
		var E = toMs(validator.endTime);
		var t = toMs(validator.observedAt);
		out.actual = actual;
		if (S === null || E === null || t === null) return out;
		var tc = Math.min(t, E);
		out.expected = expectedUptime(S, tc, outages);
		out.expectedAtEnd = expectedUptime(S, E, outages);
		if (actual !== null && out.expected !== null) {
			out.diff = actual - out.expected;
			out.remainingHours = remainingHours(S, E, tc, actual);
			out.low = out.remainingHours !== null && out.remainingHours < LIMITS.lowBudgetHours;
		}
		return out;
	}

	function pad2(n) { return (n < 10 ? "0" : "") + n; }

	// "HH:MM" in JST, without depending on the device's time zone.
	function jstHHMM(ms) {
		var d = new Date(ms + 9 * HOUR);
		return pad2(d.getUTCHours()) + ":" + pad2(d.getUTCMinutes());
	}

	function signed(n) {
		return (n >= 0 ? "+" : "-") + Math.abs(n).toFixed(2);
	}

	return {
		LIMITS: LIMITS,
		CHECK_KEYS: CHECK_KEYS,
		CHECK_LABELS: CHECK_LABELS,
		toMs: toMs,
		overlapMs: overlapMs,
		expectedUptime: expectedUptime,
		remainingHours: remainingHours,
		historySummary: historySummary,
		countsSummary: countsSummary,
		renderStale: renderStale,
		verdict: verdict,
		uptimeView: uptimeView,
		jstHHMM: jstHHMM,
		signed: signed
	};
});
