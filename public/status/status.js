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
		var req = fetch(url + sep + "_=" + Date.now(), { cache: "no-store", credentials: "omit", signal: ctl ? ctl.signal : undefined })
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

	function render(r, now) {
		var watch = r.watch.data;
		var validator = r.validator.data;
		var outages = Array.isArray(r.outages.data) ? r.outages.data : [];
		var offline = r.watch.network && r.validator.network && r.outages.network;

		var v = C.verdict({ now: now, offline: offline, watch: watch, validator: validator, outages: outages });

		var vEl = $("verdict");
		vEl.textContent = v.title;
		setState(vEl, v.ok ? "is-ok" : "is-bad");
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
		setText("last-check", lastT === null ? "最終確認: 不明"
			: "最終確認: " + minutesAgo(now, lastT) + " 分前 (" + C.jstHHMM(lastT) + " JST)");

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

		var h = C.countsSummary(watch, now);
		if (h) {
			var hEl = $("history");
			hEl.textContent = "失敗 " + h.failures + " 回・未確認 " + h.unknowns + " 回・見張りの抜け " + h.gaps + " 回 (確認 " + h.total + " 回)";
			setState(hEl, h.failures > 0 || h.gaps > 0 ? "is-bad" : h.unknowns > 0 ? "is-warn" : "is-ok");
		} else {
			setText("history", "履歴を読めません");
			setState($("history"), "is-unknown");
		}

		var up = C.uptimeView(validator, outages);
		var uEl = $("uptime");
		if (up.actual === null) {
			uEl.textContent = "—";
			setState(uEl, "is-unknown");
		} else if (up.expected === null) {
			uEl.textContent = up.actual.toFixed(2) + "% (予定 不明)";
			setState(uEl, "is-unknown");
		} else {
			uEl.textContent = up.actual.toFixed(2) + "% (予定 " + up.expected.toFixed(2) + "%・差 " + C.signed(up.diff) + ")";
			setState(uEl, up.actual < up.expected - C.LIMITS.uptimeSlackPts ? "is-bad" : "is-ok");
		}

		var bEl = $("budget");
		if (up.remainingHours === null) {
			bEl.textContent = "—";
			setState(bEl, "is-unknown");
		} else {
			bEl.textContent = "あと約 " + Math.floor(up.remainingHours) + " 時間 止まっても基準内";
			setState(bEl, up.low ? "is-bad" : "is-ok");
		}

		setText("cycle-end", up.expectedAtEnd === null ? "サイクル末の見込み: —"
			: "サイクル末の見込み: " + up.expectedAtEnd.toFixed(2) + "% (これ以上止まらなければ)");

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
		var vEl = $("verdict");
		vEl.textContent = "⚠️ 更新できていません";
		setState(vEl, "is-bad");
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
				var vEl = $("verdict");
				vEl.textContent = "⚠️ 通信できません";
				setState(vEl, "is-bad");
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
