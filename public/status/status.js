// status.js — renders the operator status page (/status/).
//
// Reads three same-origin JSON files with cache: "no-store" and nothing
// else: it never contacts the validator, so neither the 60 s auto-refresh
// nor the 再読み込み button can trigger a check against it. All judgement
// lives in status-calc.js (pure, tested under node).
(function () {
	"use strict";

	var C = window.StatusCalc;
	var REFRESH_MS = 60 * 1000;
	var SOURCES = {
		watch: "/api/watch-status.json",
		validator: "/api/validator.json",
		outages: "/api/known-outages.json"
	};
	var WATCHDOG_MS = 15 * 1000;
	var busy = false;
	var lastRenderOk = null; // Date.now() of the last successful render

	function $(id) { return document.getElementById(id); }

	function setText(id, text) { $(id).textContent = text; }

	// Resolves to { ok, data, network } — network=true means the request
	// never reached the server (offline, or aborted after fetchTimeoutMs), as
	// opposed to a 404 / bad JSON. Always settles: a stalled connection is
	// aborted (the signal covers the body read too), so busy never sticks.
	function getJson(url) {
		var sep = url.indexOf("?") === -1 ? "?" : "&";
		var ctl = typeof AbortController === "function" ? new AbortController() : null;
		var timer = null;
		var timeout = new Promise(function (resolve) {
			timer = setTimeout(function () {
				if (ctl) ctl.abort();
				resolve({ ok: false, data: null, network: true });
			}, C.LIMITS.fetchTimeoutMs);
		});
		var req = fetch(url + sep + "_=" + Date.now(), { cache: "no-store", credentials: "same-origin", signal: ctl ? ctl.signal : undefined })
			.then(function (res) {
				if (!res.ok) return { ok: false, data: null, network: false };
				return res.json()
					.then(function (d) { return { ok: true, data: d, network: false }; })
					.catch(function () { return { ok: false, data: null, network: false }; });
			})
			.catch(function () { return { ok: false, data: null, network: true }; });
		return Promise.race([req, timeout]).then(function (r) { clearTimeout(timer); return r; });
	}

	function minutesAgo(now, ms) {
		return Math.max(0, Math.floor((now - ms) / 60000));
	}

	function setState(el, state) {
		el.classList.remove("is-ok", "is-bad", "is-warn", "is-unknown");
		el.classList.add(state);
	}

	// "M/D HH:MM" in JST, without depending on the device's time zone.
	function jstDateTime(ms) {
		var d = new Date(ms + 9 * 3600000);
		return (d.getUTCMonth() + 1) + "/" + d.getUTCDate() + " " + C.jstHHMM(ms);
	}

	// "HH:MM JST (N 分前)" for a timestamp, or "不明".
	function whenText(now, ms) {
		return ms === null ? "不明" : C.jstHHMM(ms) + " JST (" + minutesAgo(now, ms) + " 分前)";
	}

	function num(x) {
		if (typeof x === "string" && x !== "") x = Number(x);
		return typeof x === "number" && isFinite(x) ? x : null;
	}

	function grouped(n) {
		return String(Math.round(n)).replace(/\B(?=(\d{3})+(?!\d))/g, ",");
	}

	// A value cell, with a state class or none (null = neutral colour).
	function setVal(id, text, state) {
		var el = $(id);
		el.textContent = text;
		el.classList.remove("is-ok", "is-bad", "is-warn", "is-unknown");
		if (state) el.classList.add(state);
	}

	function render(r, now) {
		var watch = r.watch.data;
		var validator = r.validator.data;
		var outages = Array.isArray(r.outages.data) ? r.outages.data : [];
		var offline = r.watch.network && r.validator.network && r.outages.network;

		var v = C.verdict({ now: now, offline: offline, watch: watch, validator: validator, outages: outages });

		$("verdict").textContent = v.title;
		setState($("verdict-box"), v.ok ? "is-ok" : "is-bad");
		document.title = (v.ok ? "✅" : "⚠️") + " Metal 状態";
		setText("verdict-detail", v.detail || "");

		if (v.next) {
			setText("next-text", v.next);
			$("next").hidden = false;
		} else {
			$("next").hidden = true;
		}

		var last = watch && watch.last;
		var lastT = last ? C.toMs(last.t) : null;
		setText("last-check", lastT === null ? "確認時刻: 不明"
			: minutesAgo(now, lastT) + " 分前に確認 (" + C.jstHHMM(lastT) + " JST)");

		// The three checks: only shown as ✅ when the watch data is current.
		// null = the watch could not confirm it → 未確認 (never ✅ / ❌).
		var watchUsable = v.code !== "offline" && v.code !== "stale_watch" && v.code !== "clock";
		C.CHECK_KEYS.forEach(function (k) {
			var el = $("c-" + k);
			if (last && last[k] === null) {
				el.textContent = "未確認";
				setState(el, "is-warn");
			} else if (!last || typeof last[k] !== "boolean") {
				el.textContent = "—";
				setState(el, "is-unknown");
			} else if (last[k] === true) {
				el.textContent = watchUsable ? "✅" : "✅?";
				setState(el, watchUsable ? "is-ok" : "is-warn");
			} else {
				el.textContent = "❌";
				setState(el, "is-bad");
			}
		});

		// Watch details (watch-status.json schema 2: last.alerting,
		// last.t, generated_at, interval_sec).
		var alerting = last && Array.isArray(last.alerting) ? last.alerting : null;
		if (alerting === null) {
			setVal("w-alerting", "—", "is-unknown");
		} else if (alerting.length === 0) {
			setVal("w-alerting", "なし", watchUsable ? "is-ok" : "is-warn");
		} else {
			setVal("w-alerting", alerting.map(function (k) {
				return C.CHECK_LABELS[k] ? C.CHECK_LABELS[k] + " (" + k + ")" : String(k);
			}).join("・"), "is-bad");
		}
		setVal("w-last", whenText(now, lastT), lastT === null ? "is-unknown"
			: now - lastT > C.LIMITS.watchStaleMs ? "is-bad" : null);
		var genT = watch ? C.toMs(watch.generated_at) : null;
		setVal("w-generated", whenText(now, genT), genT === null ? "is-unknown"
			: now - genT > C.LIMITS.watchStaleMs ? "is-bad" : null);
		var iv = watch ? num(watch.interval_sec) : null;
		setVal("w-interval", iv === null || iv <= 0 ? "—" : (iv % 60 === 0 ? iv / 60 + " 分" : iv + " 秒"), null);

		var h = C.countsSummary(watch, now);
		var hEl = $("history");
		if (h) {
			setText("h-fail", h.failures + " 回");
			setText("h-unknown", h.unknowns + " 回");
			setText("h-gap", h.gaps + " 回");
			var perDay = iv !== null && iv > 0 ? Math.round(86400 / iv) : null;
			setText("h-total", h.total + " 回" + (perDay === null ? "" : " (想定 " + perDay + " 回)"));
			setState(hEl, h.failures > 0 || h.gaps > 0 ? "is-bad" : h.unknowns > 0 ? "is-warn" : "is-ok");
		} else {
			["h-fail", "h-unknown", "h-gap"].forEach(function (id) { setText(id, "—"); });
			setText("h-total", "履歴を読めません");
			setState(hEl, "is-unknown");
		}

		var up = C.uptimeView(validator, outages);
		var upState = up.actual === null || up.expected === null ? "is-unknown"
			: up.actual < up.expected - C.LIMITS.uptimeSlackPts ? "is-bad" : "is-ok";
		var uEl = $("uptime");
		uEl.textContent = up.actual === null ? "—" : up.actual.toFixed(2) + " %";
		setState(uEl, upState);
		setVal("u-diff", up.diff === null ? "—" : C.signed(up.diff), upState);
		setVal("u-expected", up.expected === null ? "不明" : up.expected.toFixed(2) + " %",
			up.expected === null ? "is-unknown" : null);

		var bEl = $("budget");
		if (up.remainingHours === null) {
			bEl.textContent = "—";
			setState(bEl, "is-unknown");
		} else {
			bEl.textContent = "あと " + Math.floor(up.remainingHours) + " 時間";
			setState(bEl, up.low ? "is-bad" : "is-ok");
		}

		setVal("cycle-end", up.expectedAtEnd === null ? "—" : up.expectedAtEnd.toFixed(2) + " % 見込み", null);

		// Where the uptime value comes from (validator.json uptime block).
		var u = validator && validator.uptime ? validator.uptime : null;
		var samples = u ? num(u.sampleSize) : null;
		setVal("u-source", !u ? "—"
			: (u.source === "external-median" ? "外部 RPC の中央値" : String(u.source || "—"))
				+ (samples === null ? "" : " (" + samples + " か所)"), null);
		var selfUp = u ? num(u.self) : null;
		setVal("u-self", selfUp === null ? "—" : selfUp.toFixed(2) + " %", null);
		var age = u ? num(u.cacheAgeSec) : null;
		var ttl = u ? num(u.cacheTtlSec) : null;
		setVal("u-cache", age === null ? "—"
			: Math.floor(age / 60) + " 分" + (ttl === null ? "" : " (上限 " + Math.round(ttl / 60) + " 分)"), null);

		// Known outages subtracted from the expectation, within this cycle
		// up to the moment the uptime value describes (same span as uptimeView).
		var S = validator ? C.toMs(validator.startTime) : null;
		var E = validator ? C.toMs(validator.endTime) : null;
		var obs = validator ? C.toMs(validator.observedAt) : null;
		if (!r.outages.ok) {
			setVal("o-hours", "読めません", "is-warn");
			setVal("o-count", "—", "is-unknown");
		} else {
			setVal("o-hours", S === null || E === null || obs === null ? "—"
				: (C.overlapMs(outages, S, Math.min(obs, E)) / 3600000).toFixed(1) + " 時間", null);
			setVal("o-count", outages.length + " 件", null);
		}

		// Cycle window (validator.json startTime / endTime).
		setVal("cy-start", S === null ? "—" : jstDateTime(S) + " JST", null);
		setVal("cy-end", E === null ? "—" : jstDateTime(E) + " JST", null);
		if (E === null) {
			setVal("cy-left", "—", null);
		} else {
			var leftH = Math.max(0, (E - now) / 3600000);
			setVal("cy-left", Math.floor(leftH / 24) + " 日 " + Math.floor(leftH % 24) + " 時間", null);
		}

		// validator.json itself.
		setVal("v-observed", whenText(now, obs), obs === null ? "is-unknown"
			: now - obs > C.LIMITS.validatorStaleMs ? "is-bad" : null);
		var bs = validator && validator.bootstrap;
		if (!bs || typeof bs !== "object") {
			setVal("v-bootstrap", "—", "is-unknown");
		} else {
			var allOk = true;
			setVal("v-bootstrap", [["P", "pChain"], ["X", "xChain"], ["C", "cChain"]].map(function (c) {
				var x = bs[c[1]];
				if (x !== true) allOk = false;
				return c[0] + (x === true ? " ✅" : x === false ? " ❌" : " —");
			}).join("　"), allOk ? "is-ok" : "is-bad");
		}
		setVal("v-network", validator && validator.network ? String(validator.network) : "—", null);
		var st = validator && validator.stake ? validator.stake : null;
		var unit = st && st.unit ? " " + st.unit : "";
		var sSelf = st ? num(st.self) : null;
		setVal("v-self", sSelf === null ? "—" : grouped(sSelf) + unit, null);
		var sRecv = st ? num(st.totalReceived) : null;
		var dc = st ? num(st.delegatorCount) : null;
		setVal("v-deleg", sRecv === null ? "—" : grouped(sRecv) + unit + (dc === null ? "" : " (" + dc + " 件)"), null);
		var fee = validator && validator.delegationFee ? num(validator.delegationFee.percent) : null;
		setVal("v-fee", fee === null ? "—" : fee + " %", null);
		var tv = validator && validator.networkSize ? num(validator.networkSize.totalValidators) : null;
		setVal("v-total", tv === null ? "—" : tv + " 台", null);

		var notes = [];
		if (!r.outages.ok) notes.push("既知の障害一覧を読めないため、予定値は障害を差し引いていません。");
		notes.push("60 秒ごとに自動で更新します。このボタンはデータを読み直すだけで、validator には何も送りません。");
		notes.push("画面の更新: " + C.jstHHMM(now) + " JST");
		setText("foot", notes.join(" "));
		lastRenderOk = now;
	}

	// Watchdog: if no render has succeeded for renderStaleMs, nothing on
	// screen can be vouched for — drop the verdict and any ✅ to ⚠️.
	function watchdog() {
		var now = Date.now();
		if (!C.renderStale(lastRenderOk, now)) return;
		$("verdict").textContent = "⚠️ 更新できていません";
		setState($("verdict-box"), "is-bad");
		document.title = "⚠️ Metal 状態";
		setText("verdict-detail", lastRenderOk === null ? "まだ一度も画面を更新できていません。"
			: "最後に画面を更新できたのは " + C.jstHHMM(lastRenderOk) + " JST です。表示は古い可能性があります。");
		C.CHECK_KEYS.forEach(function (k) {
			var el = $("c-" + k);
			if (el.classList.contains("is-ok")) { el.textContent = "✅?"; setState(el, "is-warn"); }
		});
		["history", "uptime", "budget"].forEach(function (id) {
			var el = $(id);
			if (el.classList.contains("is-ok")) setState(el, "is-warn");
		});
		Array.prototype.forEach.call(document.querySelectorAll(".val.is-ok"), function (el) {
			setState(el, "is-warn");
		});
	}

	function refresh() {
		if (busy) return;
		busy = true;
		var btn = $("reload");
		btn.disabled = true;
		btn.textContent = "読み込み中…";
		Promise.all([getJson(SOURCES.watch), getJson(SOURCES.validator), getJson(SOURCES.outages)])
			.then(function (res) {
				render({ watch: res[0], validator: res[1], outages: res[2] }, Date.now());
			})
			.catch(function () {
				$("verdict").textContent = "⚠️ 通信できません";
				setState($("verdict-box"), "is-bad");
			})
			.then(done, done);
		// finally: busy is cleared whether the render succeeded or threw.
		function done() {
			busy = false;
			btn.disabled = false;
			btn.textContent = "再読み込み";
		}
	}

	function start() {
		if (!C) {
			setText("verdict", "⚠️ 画面を読み込めません");
			return;
		}
		$("reload").addEventListener("click", refresh);
		document.addEventListener("visibilitychange", function () {
			if (document.visibilityState === "visible") refresh();
		});
		refresh();
		setInterval(function () {
			if (document.visibilityState !== "hidden") refresh();
		}, REFRESH_MS);
		setInterval(watchdog, WATCHDOG_MS);
	}

	if (document.readyState === "loading") {
		document.addEventListener("DOMContentLoaded", start);
	} else {
		start();
	}
})();
