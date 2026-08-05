// validator status の動的反映
// CSP: script-src 'self' / connect-src 'self' 内で完結する vanilla JS
// /api/validator.json (gitignored, scripts/node-info.sh で生成) を読み、
// HTML の [data-field="..."] 要素を実値で置換する。
// 失敗時は HTML 上の "—" placeholder のまま(graceful degradation)
(function () {
	"use strict";

	// Module-level cache of the current on-chain period so secondary
	// renderers (cycle chart empty state, cadence next-events) don't
	// each re-fetch validator.json. load() writes here; readers fall
	// back gracefully when fields are unset (validator.json missing
	// or pre-mainnet).
	var currentPeriodCache = { startUnix: null, endUnix: null, nodeId: null };

	function setText(field, value) {
		var nodes = document.querySelectorAll('[data-field="' + field + '"]');
		for (var i = 0; i < nodes.length; i++) {
			nodes[i].textContent = value;
		}
	}

	function setLink(field, href, text) {
		var nodes = document.querySelectorAll('[data-field="' + field + '"]');
		for (var i = 0; i < nodes.length; i++) {
			var n = nodes[i];
			n.innerHTML = "";
			var a = document.createElement("a");
			a.href = href;
			a.rel = "noopener";
			a.textContent = text || href;
			n.appendChild(a);
		}
	}

	function fmtBool(b) {
		return b === true ? "✓" : (b === false ? "✗" : "—");
	}

	// Display timestamps in Japan Standard Time (UTC+9) for the operator's locale.
	function fmtJST(epochMs) {
		var d = new Date(epochMs + 9 * 3600 * 1000);
		return d.toISOString().replace("T", " ").slice(0, 16) + " JST";
	}
	function fmtJSTFromISO(s) {
		var t = Date.parse(s);
		return isFinite(t) ? fmtJST(t) : s;
	}

	async function load() {
		var res;
		try {
			res = await fetch("/api/validator.json", { cache: "no-store" });
		} catch (e) {
			return; // network error, keep "—"
		}
		if (!res.ok) return;
		var v = await res.json();

		// network / mode
		if (v.network) setText("network", v.network);
		if (v.mode) setText("mode", v.mode);

		// Cache the current on-chain period for secondary renderers.
		if (typeof v.startTime === "number") currentPeriodCache.startUnix = v.startTime;
		if (typeof v.endTime === "number")   currentPeriodCache.endUnix   = v.endTime;
		if (v.nodeId)                        currentPeriodCache.nodeId    = v.nodeId;

		// NodeID(主要表示) + explorer リンク
		if (v.nodeId) {
			setText("nodeId", v.nodeId);
			// explorer がある場合は NodeID をリンクにしたバージョンも別 slot に出せる
			var expBase = (v.explorer || "").replace(/\/$/, "");
			setLink("nodeIdLink", expBase + "/validators", v.nodeId);
			// inline "view on explorer ↗" anchor を NodeID 単体ページに向ける
			var anchors = document.querySelectorAll('a[data-field="explorerLink"]');
			for (var j = 0; j < anchors.length; j++) {
				anchors[j].href = expBase + "/validators/" + v.nodeId;
			}
		}

		// bootstrap 状態
		if (v.bootstrap) {
			setText("bootstrap-p", fmtBool(v.bootstrap.pChain));
			setText("bootstrap-x", fmtBool(v.bootstrap.xChain));
			setText("bootstrap-c", fmtBool(v.bootstrap.cChain));
		}

		// stake — schema: stake.self / stake.totalReceived / stake.unit
		// Stake numbers — display delegator-focused values so visitors see
		// at a glance whether the validator has room for more delegations.
		// Max delegation cap = 4 × self_stake (the 5× constraint is on the
		// validator's total weight = self + delegators; the 1× reserved for
		// self means delegators can fill up to 4×). Showing "received / cap"
		// with a percent is more useful than "max total weight (5× self)".
		var unit = (v.stake && v.stake.unit) || "METAL";
		if (v.stake) {
			var selfVal = (v.stake.self != null) ? v.stake.self
			            : (v.stake.amount != null ? v.stake.amount : null);
			if (selfVal != null) {
				setText("selfStake", selfVal + " " + unit);
			}
			if (selfVal != null && v.stake.totalReceived != null) {
				var cap = selfVal * 4;
				var got = v.stake.totalReceived;
				var pct = cap > 0 ? Math.round((got / cap) * 100) : 0;
				// "23600 / 23600 METAL (100%)"
				setText("receivedCombined", got + " / " + cap + " " + unit + " (" + pct + "%)");
				// keep totalStake field populated for any consumer still
				// reading the raw received number on its own
				setText("totalStake", got + " " + unit);
			}
			if (v.stake.delegatorCount != null) {
				// Append "件" only on JA pages so EN gets just the number.
				var ja = (document.documentElement.lang || "").toLowerCase().indexOf("ja") === 0;
				setText("delegatorCount", v.stake.delegatorCount + (ja ? " 件" : ""));
			}
		}
		if (v.uptime && v.uptime.network != null) {
			// metalgo API returns uptime already as 0-100 percentage (e.g. 100.0000),
			// not a 0.0-1.0 fraction. Just format without re-multiplying.
			setText("uptime", Number(v.uptime.network).toFixed(2) + "%");
		}
		if (v.delegationFee && v.delegationFee.percent != null) {
			setText("delegationFee", v.delegationFee.percent + "%");
		}

		// Network size — populated server-side from our local metalgo so
		// visitor browsers don't hammer api.metalblockchain.org per page load.
		if (v.networkSize && v.networkSize.totalValidators != null) {
			setText("totalValidators", Number(v.networkSize.totalValidators).toLocaleString());
		}

		// 期間 endTime + 残日数 countdown
		// endTime は validator.json の Unix epoch (seconds, string or number)
		if (v.endTime != null) {
			var endMs = Number(v.endTime) * 1000;
			if (isFinite(endMs) && endMs > 0) {
				setText("endTime", fmtJST(endMs));
				var msLeft = endMs - Date.now();
				var daysLeft = Math.ceil(msLeft / 86400000);
				var badgeNodes = document.querySelectorAll('[data-field="daysRemaining"]');
				for (var k = 0; k < badgeNodes.length; k++) {
					var b = badgeNodes[k];
					b.className = "badge";
					if (daysLeft <= 0) {
						b.textContent = "expired";
						b.classList.add("badge-warn");
					} else if (daysLeft <= 3) {
						b.textContent = daysLeft + "d left";
						b.classList.add("badge-warn");
					} else if (daysLeft <= 7) {
						b.textContent = daysLeft + "d left";
						b.classList.add("badge-warn");
					} else {
						b.textContent = daysLeft + "d left";
						b.classList.add("badge-ok");
					}
				}
			}
		}

		// 観測時刻 — show absolute JST + relative "N min ago" so a visitor
		// instantly sees the data is live, not a stale snapshot. Wraps the
		// dd in a live-dot span via class swap based on freshness threshold.
		if (v.observedAt) {
			var lang = (document.documentElement.lang || "en").toLowerCase();
			var ja = lang.indexOf("ja") === 0;
			var abs = fmtJSTFromISO(v.observedAt);
			var t = Date.parse(v.observedAt);
			var rel = "";
			var fresh = "stale";
			if (isFinite(t)) {
				var diffMin = Math.floor((Date.now() - t) / 60000);
				if (diffMin < 1) rel = ja ? "今" : "just now";
				else if (diffMin < 60) rel = diffMin + (ja ? " 分前" : " min ago");
				else if (diffMin < 1440) rel = Math.floor(diffMin / 60) + (ja ? " 時間前" : "h ago");
				else rel = Math.floor(diffMin / 1440) + (ja ? " 日前" : "d ago");
				// "fresh" = updated within the cron cadence (5 min) + a little buffer.
				fresh = diffMin < 15 ? "fresh" : (diffMin < 60 ? "ageing" : "stale");
			}
			var nodes = document.querySelectorAll('[data-field="observedAt"]');
			for (var i = 0; i < nodes.length; i++) {
				nodes[i].innerHTML = '<span class="live-dot live-dot--' + fresh + '" aria-hidden="true"></span>'
					+ '<span class="live-abs">' + abs + '</span>'
					+ (rel ? ' <span class="live-rel">· ' + rel + '</span>' : '');
			}
		}

		// 実績(稼働日数 etc)
		renderTrackRecord(v);
	}

	// Our node's live peer count. server-status.json sits behind the ops
	// vhost so the public site gets a 403 there — that endpoint never
	// resolves for a visitor's browser, so the "—" copy was permanently
	// stuck. Read the same peer count instead from /api/peer-geo.json,
	// the public feed peer-map.js already relies on for the map above
	// this note (scripts/peer-geo.py, cron-refreshed ~every 30 min).
	// Read numPeers, NOT totalPeers: numPeers is metalgo's raw info.peers
	// count (same field scripts/server-status.sh reads). totalPeers is
	// peer-geo.py's own post-filter count — peers missing a usable
	// publicIP dropped, then de-duplicated by IP — which under-counts
	// whenever any connected peer lacks a resolvable public IP. Fall
	// back to totalPeers only for a cached peer-geo.json written before
	// numPeers existed (pre-deploy rollout window).
	// The global validator count used to live here too but was pulled
	// to the backend (validator.json -> networkSize.totalValidators)
	// to stop each visitor's browser from hitting api.metalblockchain.org.
	//
	// [data-field="liveTotalNetwork"] only exists on the homepage (EN/JA);
	// every other page was still paying for this 31.5 KB fetch on every
	// load with no element to write into. Gate on the element existing
	// so the other ~41 pages skip the network call entirely. Also drop
	// `cache: "no-store"` — Caddy already serves /api/*.json with
	// `Cache-Control: public, max-age=120, must-revalidate`, so letting
	// the browser's own HTTP cache apply means peer-map.js's fetch of
	// this same URL (homepage only, see peer-map.js) can be served from
	// cache instead of hitting the network a second time.
	async function loadNetworkCounts() {
		if (!document.querySelector('[data-field="liveTotalNetwork"]')) return;
		try {
			var r = await fetch("/api/peer-geo.json");
			if (r.ok) {
				var s = await r.json();
				if (s.numPeers != null) {
					setText("liveTotalNetwork", s.numPeers);
				} else if (s.totalPeers != null) {
					setText("liveTotalNetwork", s.totalPeers);
				}
			}
		} catch (e) { /* offline / feed missing — leave default */ }
	}

	// service worker 登録(PWA installability)
	// + seamless update: 既存タブが controlling SW を新版に乗り換えた瞬間に
	// 自動 reload する。これがないと visitor は手動 reload するまで旧 shell
	// が見え続ける (= 2026-06-22 nav redesign 後に visualization 抜けが顕在化、
	// reference_sw_cache_invalidation 参照)。
	// 注意: 初回 install の controllerchange (= controller が null から最初の SW
	// に切り替わるイベント) では reload しない。 reload するとブラウザが SW
	// install を再実行 → 無限 reload ループ。 既に controlling SW が存在する状態
	// での swap のみ reload 対象。
	function registerSW() {
		if (!("serviceWorker" in navigator)) return;
		var hadController = !!navigator.serviceWorker.controller;
		var refreshed = false;
		navigator.serviceWorker.addEventListener("controllerchange", function () {
			if (!hadController) {
				// 初回 install 完了の controllerchange — reload しない
				hadController = true;
				return;
			}
			if (refreshed) return;
			refreshed = true;
			window.location.reload();
		});
		navigator.serviceWorker.register("/sw.js").catch(function () {
			// SW 登録失敗時は静かに諦める(サイト本体には影響なし)
		});
	}

	// install ボタン制御 — beforeinstallprompt が来たら表示、押されたら prompt 呼ぶ。
	// standalone モード(既にインストール済み)では出さない。prompt() は 1 度しか呼べないので
	// クリック直後に必ず deferred を捨てる + try/catch で「何も起きない」を回避する。
	function wireInstall() {
		function rows() { return document.querySelectorAll('[data-field="installRow"]'); }
		function show() { var r = rows(); for (var i = 0; i < r.length; i++) r[i].hidden = false; }
		function hide() { var r = rows(); for (var i = 0; i < r.length; i++) r[i].hidden = true; }

		// 既に PWA として起動している場合はボタンを出す意味がない
		var isStandalone = (window.matchMedia && window.matchMedia("(display-mode: standalone)").matches) ||
			window.navigator.standalone === true;
		if (isStandalone) { hide(); return; }

		var deferred = null;
		window.addEventListener("beforeinstallprompt", function (e) {
			e.preventDefault();
			deferred = e;
			show();
		});

		// インストール完了通知が来たらボタンを消す
		window.addEventListener("appinstalled", function () {
			deferred = null;
			hide();
		});

		var btns = document.querySelectorAll('[data-action="install"]');
		for (var j = 0; j < btns.length; j++) {
			btns[j].addEventListener("click", function () {
				if (!deferred) {
					// イベントが来ていない / 既に消費済み。ブラウザのメニューから追加する
					// よう促す(Chrome Android: ⋮ → 「ホーム画面に追加」)。
					hide();
					return;
				}
				var ev = deferred;
				deferred = null; // prompt() は 1 度しか呼べないので即捨て
				try {
					var p = ev.prompt();
					// 新 API は prompt() が Promise を返す。古い API は userChoice を使う。
					var choice = (p && typeof p.then === "function") ? p : ev.userChoice;
					Promise.resolve(choice).then(function () { hide(); }, function () { hide(); });
				} catch (err) {
					hide();
				}
			});
		}
	}

	// Validator-count trend chart — fetches /api/peers-gini-history.jsonl,
	// dedups to one sample per day (keep latest), draws an inline SVG line
	// chart. Backs the "even if our node goes down, ~200 others still
	// vote" narrative on the Network section.
	async function loadValidatorTrend() {
		var fig = document.querySelector('[data-validator-trend]');
		var svg = document.querySelector('[data-validator-trend-svg]');
		if (!fig || !svg) return;

		try {
			var res = await fetch("/api/peers-gini-history.jsonl", { cache: "no-store" });
			if (!res.ok) return;
			var text = await res.text();
			var lines = text.split("\n").filter(function (s) { return s.trim().length > 0; });
			if (lines.length === 0) return;

			// Parse + dedup to one point per UTC day (last sample wins).
			var byDay = {};
			for (var i = 0; i < lines.length; i++) {
				try {
					var o = JSON.parse(lines[i]);
					if (!o.ts || typeof o.validator_count !== "number") continue;
					var day = String(o.ts).slice(0, 10);
					var t = Date.parse(o.ts);
					if (!isFinite(t)) continue;
					if (!byDay[day] || byDay[day].t < t) {
						byDay[day] = { t: t, count: o.validator_count };
					}
				} catch (e) { /* skip malformed line */ }
			}
			var points = Object.keys(byDay).sort().map(function (d) {
				return { day: d, t: byDay[d].t, count: byDay[d].count };
			});
			if (points.length === 0) return;

			// Keep at most last 60 days to avoid stretching when history grows.
			if (points.length > 60) points = points.slice(points.length - 60);

			var last = points[points.length - 1];
			setText("validatorTrendCount", String(last.count));
			setText("validatorTrendPeers", String(Math.max(0, last.count - 1)));

			// Render in real pixel coordinates so text labels stay legible at any
			// aspect ratio. (viewBox + preserveAspectRatio="none" squashes text.)
			var rect = svg.getBoundingClientRect();
			var W = Math.max(280, Math.round(rect.width || 600));
			var H = Math.max(120, Math.round(rect.height || 180));
			var PAD_L = 36, PAD_R = 8, PAD_T = 10, PAD_B = 22;
			svg.setAttribute("viewBox", "0 0 " + W + " " + H);
			svg.removeAttribute("preserveAspectRatio");

			var counts = points.map(function (p) { return p.count; });
			var minC = Math.min.apply(null, counts);
			var maxC = Math.max.apply(null, counts);
			// Pad y-range so the line never hugs the edges; if data is flat,
			// fake a ±2 range so the chart still looks intentional.
			var span = Math.max(maxC - minC, 4);
			var yMin = Math.floor(minC - span * 0.25);
			var yMax = Math.ceil(maxC + span * 0.25);
			if (yMin < 0) yMin = 0;

			function x(i) {
				if (points.length === 1) return PAD_L + (W - PAD_L - PAD_R) / 2;
				return PAD_L + (W - PAD_L - PAD_R) * (i / (points.length - 1));
			}
			function y(c) {
				return PAD_T + (H - PAD_T - PAD_B) * (1 - (c - yMin) / (yMax - yMin));
			}

			// Build path strings
			var linePath = "";
			var areaPath = "";
			for (var k = 0; k < points.length; k++) {
				var px = x(k), py = y(points[k].count);
				linePath += (k === 0 ? "M" : "L") + px.toFixed(2) + " " + py.toFixed(2) + " ";
			}
			areaPath = linePath + "L" + x(points.length - 1).toFixed(2) + " " + (H - PAD_B) + " " +
				"L" + x(0).toFixed(2) + " " + (H - PAD_B) + " Z";

			var NS = "http://www.w3.org/2000/svg";
			while (svg.firstChild) svg.removeChild(svg.firstChild);

			// Y-axis grid + tick labels (yMin, midpoint, yMax)
			var ticks = [yMax, Math.round((yMax + yMin) / 2), yMin];
			for (var ti = 0; ti < ticks.length; ti++) {
				var ty = y(ticks[ti]);
				var line = document.createElementNS(NS, "line");
				line.setAttribute("class", "vt-grid");
				line.setAttribute("x1", PAD_L);
				line.setAttribute("x2", W - PAD_R);
				line.setAttribute("y1", ty);
				line.setAttribute("y2", ty);
				svg.appendChild(line);
				var label = document.createElementNS(NS, "text");
				label.setAttribute("class", "vt-tick");
				label.setAttribute("x", PAD_L - 6);
				label.setAttribute("y", ty + 3);
				label.setAttribute("text-anchor", "end");
				label.textContent = String(ticks[ti]);
				svg.appendChild(label);
			}

			// X-axis date labels (first, last)
			function dayLabel(d) {
				return d.slice(5).replace("-", "/"); // "MM/DD"
			}
			var xFirst = document.createElementNS(NS, "text");
			xFirst.setAttribute("class", "vt-tick");
			xFirst.setAttribute("x", PAD_L);
			xFirst.setAttribute("y", H - 6);
			xFirst.setAttribute("text-anchor", "start");
			xFirst.textContent = dayLabel(points[0].day);
			svg.appendChild(xFirst);

			var xLast = document.createElementNS(NS, "text");
			xLast.setAttribute("class", "vt-tick");
			xLast.setAttribute("x", W - PAD_R);
			xLast.setAttribute("y", H - 6);
			xLast.setAttribute("text-anchor", "end");
			xLast.textContent = dayLabel(points[points.length - 1].day);
			svg.appendChild(xLast);

			// Area fill
			var area = document.createElementNS(NS, "path");
			area.setAttribute("class", "vt-area");
			area.setAttribute("d", areaPath);
			svg.appendChild(area);

			// Line
			var line2 = document.createElementNS(NS, "path");
			line2.setAttribute("class", "vt-line");
			line2.setAttribute("d", linePath);
			svg.appendChild(line2);

			// Last-point dot
			var dot = document.createElementNS(NS, "circle");
			dot.setAttribute("class", "vt-dot-last");
			dot.setAttribute("cx", x(points.length - 1));
			dot.setAttribute("cy", y(last.count));
			dot.setAttribute("r", 3.5);
			svg.appendChild(dot);

			fig.hidden = false;
		} catch (e) {
			/* network error / parse fail — leave figure hidden */
		}
	}

	// Track record — "Validator since" and "Days serving" must reflect the
	// operator's continuous service since the very first cycle, not the
	// current cycle's startTime (which resets every monthly renewal).
	// Strategy: pull the earliest cycle from uptime-cycles.json; if there
	// are no closed cycles yet (pre-first-renewal), fall back to the live
	// validator.json startTime so the section still renders.
	async function renderTrackRecord(v) {
		var earliestStartSec = null;
		try {
			var res = await fetch("/api/uptime-cycles.json", { cache: "no-store" });
			if (res.ok) {
				var data = await res.json();
				var cycles = (data && Array.isArray(data.cycles)) ? data.cycles : [];
				if (cycles.length > 0) {
					earliestStartSec = cycles
						.map(function (c) { return Number(c.start_unix); })
						.filter(function (n) { return isFinite(n) && n > 0; })
						.reduce(function (a, b) { return Math.min(a, b); }, Infinity);
					if (!isFinite(earliestStartSec)) earliestStartSec = null;
				}
			}
		} catch (e) { /* fall through to validator.json */ }

		if (earliestStartSec == null && v && v.startTime != null) {
			earliestStartSec = Number(v.startTime);
		}
		if (earliestStartSec == null || !isFinite(earliestStartSec) || earliestStartSec <= 0) return;

		var startMs = earliestStartSec * 1000;
		var days = Math.floor((Date.now() - startMs) / 86400000);
		setText("daysServing", days);
		setText("validatorSince", fmtJST(startMs));
	}

	// ROI calculator — pure client-side estimator.
	// Formula:
	//   expected_reward = principal × apy × (lock_days / 365) × uptime_factor × (1 - fee)
	// APY scales with lock period in Avalanche/Metal: short stakes earn less,
	// long stakes near the cap. We expose three uptime scenarios so users see
	// the realistic band, not a single optimistic figure.
	function wireCalculator() {
		var amountEl = document.querySelector('input[data-calc="amount"]');
		var periodEl = document.querySelector('select[data-calc="period"]');
		if (!amountEl || !periodEl) return;

		// APY scaling table — empirical from Avalanche reward curve.
		// (Conservative; actual returns depend on network stake participation.)
		var APY_BY_DAYS = {
			14:  0.055,   // 2 weeks — minimum, near floor
			30:  0.064,
			90:  0.077,
			180: 0.085,
			365: 0.096    // 1 year — near cap
		};
		var DELEGATION_FEE = 0.03;  // 3% to validator
		var UPTIME_SCENARIOS = [
			{ name: "lowEnd",   factor: 0.80, key: "lowEnd"   },
			{ name: "expected", factor: 0.95, key: "expected" },
			{ name: "highEnd",  factor: 1.00, key: "highEnd"  }
		];

		function fmtMetal(n) {
			if (!isFinite(n)) return "—";
			// Unit "METAL" lives in the HTML next to the number — keep this string
			// numeric-only so the typographic treatment (tabular nums, big hero,
			// muted unit pill) can size them independently.
			return n.toFixed(2);
		}

		function recompute() {
			var amount = Number(amountEl.value) || 0;
			var days = Number(periodEl.value) || 14;
			var apy = APY_BY_DAYS[days] || 0.06;
			var yearFrac = days / 365;

			UPTIME_SCENARIOS.forEach(function (sc) {
				var net = amount * apy * yearFrac * sc.factor * (1 - DELEGATION_FEE);
				setText("calc-" + sc.key, fmtMetal(net));
			});
			setText("calc-apy", (apy * 100).toFixed(1) + "%");
			// Localised lock-period label — EN gets "days", JA gets "日"
			var lang = (document.documentElement.lang || "en").toLowerCase();
			var unit = lang.indexOf("ja") === 0 ? "日" : "days";
			setText("calc-period", days + " " + unit);
		}

		amountEl.addEventListener("input", recompute);
		periodEl.addEventListener("change", recompute);
		recompute();
	}

	// Reveal-on-scroll: progressively fade in sections as they enter the viewport.
	// Falls back gracefully on browsers without IntersectionObserver
	// (elements receive .in-view immediately, no animation).
	function wireReveal() {
		var els = document.querySelectorAll('.reveal');
		if (!('IntersectionObserver' in window)) {
			for (var i = 0; i < els.length; i++) els[i].classList.add('in-view');
			return;
		}
		var observer = new IntersectionObserver(function (entries, obs) {
			for (var j = 0; j < entries.length; j++) {
				if (entries[j].isIntersecting) {
					entries[j].target.classList.add('in-view');
					obs.unobserve(entries[j].target);
				}
			}
		}, { threshold: 0.1, rootMargin: '0px 0px -80px 0px' });
		for (var k = 0; k < els.length; k++) observer.observe(els[k]);
	}

	// Light parallax: shift hero background slower than scroll. Respects
	// prefers-reduced-motion. Pure transform on the body::before ribbon via a
	// CSS variable, so the browser can composite efficiently.
	function wireParallax() {
		if (!document.querySelector('.parallax-bg')) return;
		if (window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches) return;
		var bg = document.querySelector('.parallax-bg');
		var ticking = false;
		function update() {
			var y = window.scrollY || window.pageYOffset || 0;
			bg.style.setProperty('--parallax-y', (-y * 0.25).toFixed(1) + 'px');
			ticking = false;
		}
		window.addEventListener('scroll', function () {
			if (!ticking) {
				window.requestAnimationFrame(update);
				ticking = true;
			}
		}, { passive: true });
		update();
	}

	// Horizontal card carousel — prev/next buttons scroll one page at a
	// time, dot indicators map to each "page" of visible cards. Uses
	// native scroll-snap so dragging / wheel still work naturally.
	function wireCarousels() {
		var carousels = document.querySelectorAll('[data-carousel]');
		for (var i = 0; i < carousels.length; i++) {
			(function (root) {
				var track = root.querySelector('[data-carousel-track]');
				var prevBtn = root.querySelector('[data-carousel-prev]');
				var nextBtn = root.querySelector('[data-carousel-next]');
				var dotsBox = root.querySelector('[data-carousel-dots]');
				if (!track) return;

				function pageWidth() {
					var w = track.clientWidth;
					// One "page" = the full visible track width. Snap to nearest
					// page boundary so prev/next align to scroll-snap stops.
					return Math.max(1, w);
				}
				function pageCount() {
					var cardCount = track.children.length;
					if (cardCount === 0) return 1;
					var firstCard = track.children[0];
					var cardW = firstCard.getBoundingClientRect().width;
					var gap = parseFloat(window.getComputedStyle(track).columnGap || '0') || 0;
					var perPage = Math.max(1, Math.round(track.clientWidth / (cardW + gap)));
					return Math.max(1, Math.ceil(cardCount / perPage));
				}
				function currentPage() {
					return Math.round(track.scrollLeft / pageWidth());
				}
				function syncDots() {
					if (!dotsBox) return;
					var total = pageCount();
					var here = currentPage();
					if (dotsBox.childElementCount !== total) {
						dotsBox.innerHTML = '';
						for (var k = 0; k < total; k++) {
							var b = document.createElement('button');
							b.type = 'button';
							b.setAttribute('aria-label', 'Page ' + (k + 1));
							(function (idx) {
								b.addEventListener('click', function () {
									track.scrollTo({ left: idx * pageWidth(), behavior: 'smooth' });
								});
							})(k);
							dotsBox.appendChild(b);
						}
					}
					var btns = dotsBox.children;
					for (var m = 0; m < btns.length; m++) {
						if (m === here) btns[m].setAttribute('aria-current', 'true');
						else btns[m].removeAttribute('aria-current');
					}
					if (prevBtn) prevBtn.disabled = here <= 0;
					if (nextBtn) nextBtn.disabled = here >= total - 1;
				}
				if (prevBtn) prevBtn.addEventListener('click', function () {
					track.scrollBy({ left: -pageWidth(), behavior: 'smooth' });
				});
				if (nextBtn) nextBtn.addEventListener('click', function () {
					track.scrollBy({ left:  pageWidth(), behavior: 'smooth' });
				});
				track.addEventListener('scroll', function () {
					window.requestAnimationFrame(syncDots);
				}, { passive: true });
				window.addEventListener('resize', syncDots, { passive: true });
				syncDots();
			})(carousels[i]);
		}
	}

	// Nav menu — <details class="nav-menu"> wraps the link list. On SP
	// the summary acts as a hamburger; on desktop the links must be
	// shown regardless of open state, but browsers' <details> UA
	// rendering hides non-summary children when closed and CSS can't
	// fully override that. So we force open=true on desktop via JS and
	// open=false on mobile, and listen for viewport changes so the
	// state stays in sync when the user resizes.
	function wireHamburger() {
		var details = document.querySelector('details.nav-menu');
		if (!details) return;

		var desktopMql = window.matchMedia('(min-width: 769px)');
		function syncOpenForViewport() {
			details.open = desktopMql.matches;
		}
		syncOpenForViewport();
		if (desktopMql.addEventListener) {
			desktopMql.addEventListener('change', syncOpenForViewport);
		} else if (desktopMql.addListener) {
			// Safari < 14 fallback
			desktopMql.addListener(syncOpenForViewport);
		}

		// Mobile: close on link click + close on outside click. On
		// desktop we skip these so the always-open nav stays open.
		// Exclude `.nav-dropdown-toggle` — those are <a> elements whose
		// mobile click is supposed to expand the sub-menu (handled by
		// wireNavDropdown); closing the hamburger here would hide the
		// sub-menu we just opened.
		var links = details.querySelectorAll('.nav a:not(.nav-dropdown-toggle)');
		for (var i = 0; i < links.length; i++) {
			links[i].addEventListener('click', function () {
				if (!desktopMql.matches) details.open = false;
			});
		}
		document.addEventListener('click', function (ev) {
			if (desktopMql.matches) return;
			if (!details.open) return;
			if (details.contains(ev.target)) return;
			details.open = false;
		});
	}

	// Section sidebar (= institutional cluster navigation) — same
	// open/closed-by-viewport pattern as wireHamburger above. Desktop
	// (>=769px) force-opens the <details> so the nav list always renders;
	// mobile leaves it closed by default for a small footprint.
	function wireSectionSidebar() {
		var details = document.querySelector('details.section-sidebar-details');
		if (!details) return;
		var desktopMql = window.matchMedia('(min-width: 769px)');
		function syncOpenForViewport() {
			details.open = desktopMql.matches;
		}
		syncOpenForViewport();
		if (desktopMql.addEventListener) {
			desktopMql.addEventListener('change', syncOpenForViewport);
		} else if (desktopMql.addListener) {
			desktopMql.addListener(syncOpenForViewport);
		}
	}

	// Per-cycle uptime bar chart — pure SVG, no chart library.
	// Y-axis zooms to 80-100% so day-to-day differences in the 95-99.9%
	// range are visible. The 80% network reward threshold is drawn as a
	// dashed red baseline so an underperforming cycle is impossible to
	// miss. Bars are mint-accent; on hover, the bar gets a tooltip via
	// <title>. Empty state keeps the axes and threshold visible so a
	// visitor immediately understands the scale before any cycle closes.
	async function renderCycleChart(cycles) {
		var host = document.querySelector('[data-cycle-chart]');
		if (!host) return;
		var lang = (document.documentElement.lang || "en").toLowerCase();
		var ja = lang.indexOf("ja") === 0;

		// SVG geometry — viewBox is virtual units, scales to container.
		// PAD_B is generous (62) to fit two stacked label rows under the
		// chart: x-axis cycle labels (top row) + threshold annotation
		// (bottom row), neither overlapping the bars.
		var W = 800, H = 300;
		var PAD_L = 56, PAD_R = 24, PAD_T = 28, PAD_B = 62;
		var plotW = W - PAD_L - PAD_R;
		var plotH = H - PAD_T - PAD_B;
		var YMIN = 80, YMAX = 100;
		function y(v) { return PAD_T + (1 - (v - YMIN) / (YMAX - YMIN)) * plotH; }

		// Gridlines + Y-axis labels at every 5%.
		var gridLines = "";
		var yLabels = "";
		[80, 85, 90, 95, 100].forEach(function (v) {
			var yy = y(v);
			gridLines += '<line x1="' + PAD_L + '" y1="' + yy + '" x2="' + (PAD_L + plotW) + '" y2="' + yy + '" stroke="#e5e1d8" stroke-width="1"/>';
			yLabels += '<text x="' + (PAD_L - 8) + '" y="' + (yy + 4) + '" text-anchor="end" font-size="11" fill="#5b6577" font-family="Montserrat, sans-serif" font-weight="500">' + v + '%</text>';
		});

		// 80% reward threshold — dashed red line + label.
		var thr = y(80);
		var thresholdLabel = ja ? "報酬閾値 80%" : "Reward threshold 80%";
		gridLines += '<line x1="' + PAD_L + '" y1="' + thr + '" x2="' + (PAD_L + plotW) + '" y2="' + thr + '" stroke="#dc323c" stroke-width="1.25" stroke-dasharray="4 4"/>';

		// Bar layout — distribute bars evenly across the plot width so
		// 4 cycles don't huddle in the left corner of an empty chart.
		// Center of bar i sits at the i-th equal subdivision of plotW.
		// Bar width grows with available space up to BAR_MAX_W. With many
		// cycles (10+ years × monthly = 120+), bars get thin but still fit.
		var n = cycles.length;
		var bars = "";
		var xLabels = "";
		var BAR_MAX_W = 64;
		var slot = plotW / Math.max(n, 1);
		var barW = Math.min(BAR_MAX_W, slot * 0.65);

		cycles.forEach(function (c, i) {
			var v = (typeof c.final_uptime_pct === "number") ? c.final_uptime_pct : null;
			if (v == null) return;
			var cx = PAD_L + slot * (i + 0.5);
			var bx = cx - barW / 2;
			var by = y(Math.max(YMIN, Math.min(YMAX, v)));
			var bh = (PAD_T + plotH) - by;
			var safe = v >= 80;
			var fill = safe ? "#10b386" : "#dc323c";
			var label = "#" + (c.cycle_n || "?");
			var tip = label + " · " + v.toFixed(2) + "% · " + (c.start_iso || "").slice(0, 10) + " → " + (c.end_iso || "").slice(0, 10);
			bars += '<g class="cycle-bar">'
				+ '<rect x="' + bx + '" y="' + by + '" width="' + barW + '" height="' + bh + '" rx="2" fill="' + fill + '"><title>' + tip + '</title></rect>'
				+ '<text x="' + cx + '" y="' + (by - 6) + '" text-anchor="middle" font-size="10" fill="#1f2937" font-family="Montserrat, sans-serif" font-weight="600">' + v.toFixed(1) + '</text>'
				+ '</g>';
			xLabels += '<text x="' + cx + '" y="' + (PAD_T + plotH + 18) + '" text-anchor="middle" font-size="11" fill="#5b6577" font-family="Montserrat, sans-serif" font-weight="600">' + label + '</text>';
		});

		// Empty-state — instead of flat copy, render a live progress bar
		// for the in-flight cycle so a first-time visitor sees something
		// moving, not an idle placeholder. Read current period start/end
		// from the module-level cache populated by load() from validator.json.
		// load() and loadCycleHistory() race in boot(); if the cache isn't
		// populated yet we self-fetch as a fallback.
		var emptyMsg = "";
		if (n === 0) {
			var startUnix = currentPeriodCache.startUnix;
			var endUnix = currentPeriodCache.endUnix;
			if (!isFinite(startUnix) || !isFinite(endUnix)) {
				try {
					var vRes = await fetch("/api/validator.json", { cache: "no-store" });
					if (vRes.ok) {
						var vData = await vRes.json();
						if (typeof vData.startTime === "number") {
							startUnix = vData.startTime;
							currentPeriodCache.startUnix = vData.startTime;
						}
						if (typeof vData.endTime === "number") {
							endUnix = vData.endTime;
							currentPeriodCache.endUnix = vData.endTime;
						}
					}
				} catch (e) { /* keep flat fallback below */ }
			}
			if (isFinite(startUnix) && isFinite(endUnix) && endUnix > startUnix) {
				var nowSec = Math.floor(Date.now() / 1000);
				var elapsed = Math.max(0, Math.min(endUnix - startUnix, nowSec - startUnix));
				var totalDur = endUnix - startUnix;
				var pct = Math.max(0, Math.min(100, (elapsed / totalDur) * 100));
				var dayN = Math.floor(elapsed / 86400) + 1;
				var totalDays = Math.round(totalDur / 86400);
				var barX = PAD_L + plotW * 0.1;
				var barW = plotW * 0.8;
				var barY = PAD_T + plotH / 2 - 6;
				var fillW = barW * (pct / 100);
				emptyMsg = ''
					+ '<text x="' + (PAD_L + plotW / 2) + '" y="' + (PAD_T + plotH / 2 - 24) + '" text-anchor="middle" font-size="13" fill="#1f2937" font-family="Montserrat, sans-serif" font-weight="600">'
						+ (ja ? "現 cycle 進行中 · " : "Current cycle in progress · ") + "Day " + dayN + " / " + totalDays
					+ '</text>'
					+ '<rect x="' + barX + '" y="' + barY + '" width="' + barW + '" height="12" rx="6" fill="#e5e1d8"/>'
					+ '<rect x="' + barX + '" y="' + barY + '" width="' + fillW + '" height="12" rx="6" fill="#10b386"/>'
					+ '<text x="' + (PAD_L + plotW / 2) + '" y="' + (PAD_T + plotH / 2 + 32) + '" text-anchor="middle" font-size="11" fill="#5b6577" font-family="Montserrat, sans-serif" font-weight="500">'
						+ pct.toFixed(0) + (ja ? "% 完了 · 最初のバーは cycle 終了後" : "% complete · first bar lands at close")
					+ '</text>';
			} else {
				emptyMsg = '<text x="' + (PAD_L + plotW / 2) + '" y="' + (PAD_T + plotH / 2) + '" text-anchor="middle" font-size="13" fill="#5b6577" font-family="Montserrat, sans-serif" font-weight="500">'
					+ (ja ? "現在の cycle 終了後、最初のバーが立ちます。" : "First bar lands when the current cycle closes.")
					+ '</text>';
			}
		}

		// Axis lines
		var axes = ''
			+ '<line x1="' + PAD_L + '" y1="' + PAD_T + '" x2="' + PAD_L + '" y2="' + (PAD_T + plotH) + '" stroke="#5b6577" stroke-width="1"/>'
			+ '<line x1="' + PAD_L + '" y1="' + (PAD_T + plotH) + '" x2="' + (PAD_L + plotW) + '" y2="' + (PAD_T + plotH) + '" stroke="#5b6577" stroke-width="1"/>';

		// Threshold annotation sits BELOW the plot area, in its own row
		// under the x-axis cycle labels. This way it never collides with
		// bars regardless of how many cycles are rendered. Small left-
		// pointing tick connects it visually to the dashed threshold line.
		var thrLabelY = PAD_T + plotH + 42;
		var thrText = ''
			+ '<line x1="' + (PAD_L + 14) + '" y1="' + thr + '" x2="' + (PAD_L + 14) + '" y2="' + (thrLabelY - 8) + '" stroke="#dc323c" stroke-width="1" stroke-dasharray="2 2"/>'
			+ '<text x="' + (PAD_L + 22) + '" y="' + thrLabelY + '" text-anchor="start" font-size="10.5" fill="#dc323c" font-family="Montserrat, sans-serif" font-weight="600">' + thresholdLabel + '</text>';

		var caption = ja
			? "縦軸: uptime (%)、横軸: cycle 番号。バーをホバーで詳細表示。"
			: "Vertical: uptime (%). Horizontal: cycle number. Hover a bar for details.";

		var svg = '<svg class="cycle-chart-svg" viewBox="0 0 ' + W + ' ' + H + '" preserveAspectRatio="xMidYMid meet" role="img" aria-labelledby="cycleChartTitle">'
			+ '<title id="cycleChartTitle">' + (ja ? "サイクル別 uptime バーチャート" : "Per-cycle uptime bar chart") + '</title>'
			+ gridLines + axes + yLabels + thrText + bars + xLabels + emptyMsg
			+ '</svg>'
			+ '<p class="cycle-chart-caption">' + caption + '</p>';
		host.innerHTML = svg;
	}

	// Long-horizon validator track record. Each closed cycle is rendered
	// as a row with the on-chain period dates, final uptime %, and an
	// explorer link so a 3rd party can verify against P-Chain. The current
	// in-flight cycle stays out — only finalized rows are written here.
	async function loadCycleHistory() {
		var host = document.querySelector('[data-cycle-history-body]');
		if (!host) return;
		var lang = (document.documentElement.lang || "en").toLowerCase();
		var ja = lang.indexOf("ja") === 0;

		// 404 → empty (no closed cycles yet, or file briefly absent
		// after deploy). Render the empty-state chart + table copy.
		// Other failures (network drop, 5xx) surface as an error so it
		// isn't silently hidden.
		var res, cycles;
		try {
			res = await fetch("/api/uptime-cycles.json", { cache: "no-store" });
			if (res.status === 404) {
				cycles = [];
			} else if (!res.ok) {
				throw new Error("HTTP " + res.status);
			} else {
				var data = await res.json();
				cycles = (data && data.cycles) || [];
			}
		} catch (e) {
			host.innerHTML = '<p class="note">' + (ja ? "履歴の読み込みに失敗" : "Could not load history") + "</p>";
			return;
		}

		if (cycles.length === 0) {
			// Render chart's own empty state (axes + threshold visible) so
			// visitors can see the y-scale before any bar lands.
			renderCycleChart([]);
			host.innerHTML = '<p class="cycle-history-empty">' + (ja
				? "現在の cycle 進行中。最初の cycle が終了すると、ここに最終 uptime と explorer リンクが刻まれます。"
				: "Current cycle in progress. The first row lands here when the cycle closes, with its final uptime and explorer link."
			) + "</p>";
			return;
		}

		// Chart uses chronological order (oldest → newest, reading left-to-
		// right like a timeline). Pass a copy before we sort the table copy
		// in the reverse direction.
		var chronological = cycles.slice().sort(function (a, b) { return (a.end_unix || 0) - (b.end_unix || 0); });
		renderCycleChart(chronological);

		// Newest first.
		cycles.sort(function (a, b) { return (b.end_unix || 0) - (a.end_unix || 0); });

		function fmtDate(iso) { return (iso || "").slice(0, 10); }
		function fmtPct(n) { return (typeof n === "number") ? (n.toFixed(2) + "%") : "—"; }

		var rows = cycles.map(function (c) {
			var period = fmtDate(c.start_iso) + " → " + fmtDate(c.end_iso);
			var ex = c.explorer_url ? ('<a href="' + c.explorer_url + '" rel="noopener noreferrer" target="_blank">' + (ja ? "explorer ↗" : "explorer ↗") + '</a>') : "—";
			return '<tr>' +
				'<th scope="row"><span class="cycle-num">#' + (c.cycle_n || "?") + '</span></th>' +
				'<td class="cycle-period">' + period + '<span class="cycle-duration">' + (c.duration_days || "?") + (ja ? " 日" : " days") + '</span></td>' +
				'<td class="cycle-uptime"><span class="num">' + fmtPct(c.final_uptime_pct) + '</span></td>' +
				'<td class="cycle-audit">' + ex + '</td>' +
				'</tr>';
		}).join("");

		var thHead = ja
			? '<tr><th scope="col">#</th><th scope="col">期間</th><th scope="col">最終 uptime</th><th scope="col">監査</th></tr>'
			: '<tr><th scope="col">#</th><th scope="col">Period</th><th scope="col">Final uptime</th><th scope="col">Audit</th></tr>';
		host.innerHTML = '<table class="cycle-table"><thead>' + thHead + '</thead><tbody>' + rows + '</tbody></table>';
	}

	// Operating cadence — compute the next renewal events from
	// validator.json's current period_end. One marker per cycle at endTime
	// (= the renewal moment). Operator-internal prep windows are no longer
	// surfaced publicly because they don't reflect operational reality
	// uniformly (issuance can be pre-expiry or post-expiry depending on
	// FREE-balance accounting). Delegators only need to know when the
	// rollover happens; ntfy alerts (T-7/T-1/T-0/T-10min) carry the
	// per-event urgency on the operator side.
	async function loadCadence() {
		var listHost = document.querySelector('[data-cadence-list]');
		if (!listHost) return;
		var lang = (document.documentElement.lang || "en").toLowerCase();
		var ja = lang.indexOf("ja") === 0;

		var res;
		try {
			res = await fetch("/api/validator.json", { cache: "no-store" });
		} catch (e) { return; }
		if (!res.ok) return;
		var v = await res.json();
		var endUnix = Number(v && v.endTime);
		if (!endUnix || !isFinite(endUnix)) return;

		var nowSec = Math.floor(Date.now() / 1000);
		var BUFFER = 8 * 60; // 8-min startTime buffer between cycles

		// Build renewal events for cycle 1 (current) + cycle 2 (estimated)
		// + cycle 3 (estimated). One marker per cycle.
		var endC1 = endUnix;
		var endC2 = endC1 + 30 * 86400 + BUFFER;
		var endC3 = endC2 + 30 * 86400 + BUFFER;
		var candidates = [
			{ when: endC1, kind: "renewal", cycle: "current", note: ja ? "現サイクル更新(on-chain endTime)" : "Current cycle renewal (on-chain endTime)" },
			{ when: endC2, kind: "renewal", cycle: "next",    note: ja ? "次サイクル更新(推定 +30 日)" : "Next cycle renewal (estimated, +30 days)" },
			{ when: endC3, kind: "renewal", cycle: "after",   note: ja ? "翌々サイクル更新(推定)" : "Following cycle renewal (estimated)" }
		];
		var upcoming = candidates.filter(function (e) { return e.when > nowSec; }).slice(0, 3);

		if (upcoming.length === 0) {
			listHost.innerHTML = '<li class="cadence-event cadence-event--idle"><span class="note">' + (ja
				? "予定なし(次サイクルの確定待ち)"
				: "No upcoming events (waiting for next cycle confirmation)"
			) + "</span></li>";
			return;
		}

		function fmtJSTLong(epochSec) {
			var d = new Date((epochSec + 9 * 3600) * 1000);
			var y = d.getUTCFullYear();
			var m = String(d.getUTCMonth() + 1).padStart(2, "0");
			var day = String(d.getUTCDate()).padStart(2, "0");
			var hh = String(d.getUTCHours()).padStart(2, "0");
			var mm = String(d.getUTCMinutes()).padStart(2, "0");
			return ja
				? (y + "-" + m + "-" + day + " " + hh + ":" + mm + " JST")
				: (y + "-" + m + "-" + day + " · " + hh + ":" + mm + " JST");
		}
		function fmtRelative(epochSec) {
			var diff = epochSec - nowSec;
			var days = Math.floor(diff / 86400);
			var hours = Math.floor((diff % 86400) / 3600);
			if (days > 0) return ja ? ("あと " + days + " 日 " + hours + " 時間") : ("in " + days + "d " + hours + "h");
			if (hours > 0) return ja ? ("あと " + hours + " 時間") : ("in " + hours + "h");
			return ja ? "まもなく" : "imminent";
		}

		var html = upcoming.map(function (e) {
			var iconChar = "🔁";
			var title = ja ? "サイクル更新" : "Cycle renewal";
			return '<li class="cadence-event cadence-event--' + e.kind + '">'
				+ '<span class="cadence-event-icon" aria-hidden="true">' + iconChar + '</span>'
				+ '<div class="cadence-event-body">'
					+ '<div class="cadence-event-head"><span class="cadence-event-title">' + title + '</span>'
					+ ' <span class="cadence-event-rel">' + fmtRelative(e.when) + '</span></div>'
					+ '<div class="cadence-event-when">' + fmtJSTLong(e.when) + '</div>'
					+ '<div class="cadence-event-note">' + e.note + '</div>'
				+ '</div>'
				+ '</li>';
		}).join("");
		listHost.innerHTML = html;

		// Monthly grid view — same event set, plotted on a 3-month calendar
		// grid so visitors can see scheduling at a glance instead of reading
		// a flat list. Pure DOM/SVG, no external dependency (we explicitly
		// don't use Google Calendar embed — owner identity would leak).
		renderCadenceGrid(candidates, ja);
	}

	function renderCadenceGrid(events, ja) {
		var host = document.querySelector('[data-cadence-grid]');
		if (!host) return;

		// JST date of an epoch second, as "YYYY-MM-DD"
		function jstDateKey(epochSec) {
			var d = new Date((epochSec + 9 * 3600) * 1000);
			var y = d.getUTCFullYear();
			var m = String(d.getUTCMonth() + 1).padStart(2, "0");
			var day = String(d.getUTCDate()).padStart(2, "0");
			return y + "-" + m + "-" + day;
		}
		function jstHM(epochSec) {
			var d = new Date((epochSec + 9 * 3600) * 1000);
			return String(d.getUTCHours()).padStart(2, "0") + ":" + String(d.getUTCMinutes()).padStart(2, "0");
		}

		// Bucket events by JST date key
		var byDate = {};
		events.forEach(function (e) {
			var k = jstDateKey(e.when);
			(byDate[k] = byDate[k] || []).push(e);
		});

		// Pick which months to show: current JST month + next 2.
		var nowJst = new Date((Math.floor(Date.now() / 1000) + 9 * 3600) * 1000);
		var year = nowJst.getUTCFullYear();
		var month = nowJst.getUTCMonth(); // 0-based
		var todayKey = jstDateKey(Math.floor(Date.now() / 1000));

		var monthNamesEn = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"];
		var monthNamesJa = ["1月", "2月", "3月", "4月", "5月", "6月", "7月", "8月", "9月", "10月", "11月", "12月"];
		var dowJa = ["日", "月", "火", "水", "木", "金", "土"];
		var dowEn = ["Su", "Mo", "Tu", "We", "Th", "Fr", "Sa"];
		var dow = ja ? dowJa : dowEn;
		var monthNames = ja ? monthNamesJa : monthNamesEn;

		function buildMonth(yy, mm) {
			// First weekday of month (0=Sun .. 6=Sat), and day count.
			var first = new Date(Date.UTC(yy, mm, 1));
			var firstDow = first.getUTCDay();
			var daysInMonth = new Date(Date.UTC(yy, mm + 1, 0)).getUTCDate();
			var head = (ja ? (yy + " 年 ") : "") + monthNames[mm] + (ja ? "" : " " + yy);

			var dowHtml = dow.map(function (d) {
				return '<span class="cad-cell cad-cell--dow">' + d + '</span>';
			}).join("");
			var cells = "";
			for (var i = 0; i < firstDow; i++) cells += '<span class="cad-cell cad-cell--empty"></span>';
			for (var d = 1; d <= daysInMonth; d++) {
				var key = yy + "-" + String(mm + 1).padStart(2, "0") + "-" + String(d).padStart(2, "0");
				var evs = byDate[key] || [];
				var kindCls = "";
				if (evs.some(function (e) { return e.kind === "renewal"; })) kindCls += " cad-cell--renewal";
				var isToday = key === todayKey ? " cad-cell--today" : "";
				var markers = "";
				if (evs.length > 0) {
					markers = '<span class="cad-cell-marks">' + evs.map(function (e) {
						var tt = (ja ? "サイクル更新" : "Cycle renewal") + " · " + jstHM(e.when) + " JST";
						return '<span class="cad-mark cad-mark--' + e.kind + '" title="' + tt + '">🔁</span>';
					}).join("") + '</span>';
				}
				cells += '<span class="cad-cell cad-cell--day' + kindCls + isToday + '">'
					+ '<span class="cad-cell-date">' + d + '</span>'
					+ markers
				+ '</span>';
			}
			return '<div class="cad-month">'
				+ '<div class="cad-month-head">' + head + '</div>'
				+ '<div class="cad-month-grid">' + dowHtml + cells + '</div>'
			+ '</div>';
		}

		var months = [];
		for (var i = 0; i < 3; i++) {
			var y = year, m = month + i;
			while (m > 11) { m -= 12; y += 1; }
			months.push(buildMonth(y, m));
		}
		var legend = '<div class="cad-legend">'
			+ '<span class="cad-legend-item"><span class="cad-mark cad-mark--renewal" aria-hidden="true">🔁</span>' + (ja ? "サイクル更新" : "Cycle renewal") + '</span>'
			+ '</div>';

		host.innerHTML = months.join("") + legend;
	}

	// Past cycles — rendered from the same uptime-cycles.json the
	// per-cycle chart consumes. Different angle though: cadence focuses
	// on "did we execute on schedule" (renewal dates), the chart focuses
	// on "how was our uptime per cycle" (the % metric). Both views share
	// the audit angle: every row is verifiable against the on-chain
	// validator entry.
	async function loadPastCycles() {
		var host = document.querySelector('[data-cadence-past-list]');
		if (!host) return;
		var statEl = document.querySelector('[data-cadence-past-stat]');
		var lang = (document.documentElement.lang || "en").toLowerCase();
		var ja = lang.indexOf("ja") === 0;

		// 404 is treated as "no cycles yet" — the file is generated on
		// validator host only after the first cycle closes, and it can also be
		// briefly absent right after a fresh deploy. Render the friendly
		// empty state, not a load-failure error. Other failures (network
		// drop, 5xx) still surface as an explicit error so it's not silent.
		var res, cycles;
		try {
			res = await fetch("/api/uptime-cycles.json", { cache: "no-store" });
			if (res.status === 404) {
				cycles = [];
			} else if (!res.ok) {
				throw new Error("HTTP " + res.status);
			} else {
				var data = await res.json();
				cycles = (data && data.cycles) || [];
			}
		} catch (e) {
			host.innerHTML = '<li class="cadence-past-item cadence-past-item--idle"><span class="note">' + (ja ? "履歴の読み込みに失敗" : "Could not load history") + "</span></li>";
			return;
		}

		if (cycles.length === 0) {
			if (statEl) statEl.textContent = ja ? "最初の完了サイクル待ち" : "Awaiting first closed cycle";
			host.innerHTML = '<li class="cadence-past-item cadence-past-item--idle"><span class="note">' + (ja
				? "現在の cycle 終了後、最初の行がここに刻まれます(renewal 日時 + duration + uptime)。"
				: "First row lands here once the current cycle closes — renewal time + duration + uptime, verifiable on-chain."
			) + "</span></li>";
			return;
		}

		// Summary line: count + days served + threshold compliance.
		var totalDays = cycles.reduce(function (s, c) { return s + (c.duration_days || 0); }, 0);
		var above80 = cycles.filter(function (c) { return (c.final_uptime_pct || 0) >= 80; }).length;
		if (statEl) {
			var ok = (above80 === cycles.length);
			statEl.textContent = ja
				? (cycles.length + " cycle 完走 · " + totalDays + " 日稼働 · " + (ok ? "全 cycle 報酬閾値以上 ✓" : (above80 + "/" + cycles.length + " が閾値以上")))
				: (cycles.length + " cycles served · " + totalDays + " days in service · " + (ok ? "all above reward threshold ✓" : (above80 + "/" + cycles.length + " above threshold")));
		}

		// Newest first so a returning visitor sees the latest activity.
		var sorted = cycles.slice().sort(function (a, b) { return (b.end_unix || 0) - (a.end_unix || 0); });
		// Cap to 6 visible (archive page will hold the full list later).
		var VISIBLE = 6;
		var visible = sorted.slice(0, VISIBLE);
		var hidden = sorted.length - visible.length;

		function fmtSwitch(unix) {
			var d = new Date((unix + 9 * 3600) * 1000);
			var y = d.getUTCFullYear();
			var m = String(d.getUTCMonth() + 1).padStart(2, "0");
			var day = String(d.getUTCDate()).padStart(2, "0");
			var hh = String(d.getUTCHours()).padStart(2, "0");
			var mm = String(d.getUTCMinutes()).padStart(2, "0");
			return y + "-" + m + "-" + day + " · " + hh + ":" + mm + " JST";
		}

		var rows = visible.map(function (c) {
			var ok = (c.final_uptime_pct || 0) >= 80;
			var statusIcon = ok ? "✓" : "⚠";
			var statusClass = ok ? "cadence-past-item--ok" : "cadence-past-item--warn";
			var upStr = (typeof c.final_uptime_pct === "number") ? (c.final_uptime_pct.toFixed(2) + "%") : "—";
			var ex = c.explorer_url
				? ('<a href="' + c.explorer_url + '" rel="noopener noreferrer" target="_blank" class="cadence-past-audit">' + (ja ? "audit ↗" : "audit ↗") + '</a>')
				: "";
			return '<li class="cadence-past-item ' + statusClass + '">'
				+ '<span class="cadence-past-status" aria-hidden="true">' + statusIcon + '</span>'
				+ '<div class="cadence-past-body">'
					+ '<div class="cadence-past-head">'
						+ '<span class="cadence-past-cycle">' + (ja ? "Cycle #" : "Cycle #") + (c.cycle_n || "?") + '</span>'
						+ '<span class="cadence-past-when">' + fmtSwitch(c.end_unix) + '</span>'
					+ '</div>'
					+ '<div class="cadence-past-meta">'
						+ '<span>' + (c.duration_days || "?") + (ja ? " 日 cycle" : "-day cycle") + '</span>'
						+ '<span class="cadence-past-sep" aria-hidden="true">·</span>'
						+ '<span><strong>' + upStr + '</strong> ' + (ja ? "uptime" : "uptime") + '</span>'
						+ (ex ? ('<span class="cadence-past-sep" aria-hidden="true">·</span>' + ex) : '')
					+ '</div>'
				+ '</div>'
				+ '</li>';
		}).join("");

		if (hidden > 0) {
			rows += '<li class="cadence-past-more"><span class="note">'
				+ (ja ? ("+ あと " + hidden + " cycle(将来の archive ページで全件表示予定)") : ("+ " + hidden + " more (full archive page coming when count grows)"))
				+ "</span></li>";
		}
		host.innerHTML = rows;
	}

	// Nav dropdown: <div> + <button>, no <details>.
	// Desktop (>=769px): pure CSS :hover opens menu. Click on the button
	// toggles .is-open as a fallback for touch+desktop users.
	// Mobile (<769px): tap on .nav-dropdown-toggle opens / closes the
	// dropdown panel via the .is-open class. The toggle is an <a> with a
	// real href to the cluster hub page; on mobile we preventDefault so
	// tap can be used to expand the dropdown without navigating.
	// Desktop (>=769px): we DO NOT preventDefault — clicking the toggle
	// follows the link to the hub page (= selection-evidence / data /
	// delegate). The dropdown opens on :hover via pure CSS.
	function wireNavDropdown() {
		var desktopMql = window.matchMedia('(min-width: 769px)');
		document.querySelectorAll(".nav-dropdown").forEach((dd) => {
			const btn = dd.querySelector(":scope > .nav-dropdown-toggle");
			if (!btn) return;
			btn.addEventListener("click", (ev) => {
				if (desktopMql.matches) return; // desktop: let the anchor navigate
				ev.preventDefault();
				dd.classList.toggle("is-open");
			});
		});
		// Click anywhere outside an open dropdown closes it (mobile-only state).
		document.addEventListener("click", (ev) => {
			document.querySelectorAll(".nav-dropdown.is-open").forEach((dd) => {
				if (!dd.contains(ev.target)) dd.classList.remove("is-open");
			});
		});
	}

	// Measure the sticky site-header and publish its height as --topnav-h
	// on :root. The hero (min-height: calc(100vh - var(--topnav-h))) uses
	// it so site-header + hero together equal one viewport. Re-measure
	// on resize because the nav can wrap to multiple rows at narrow widths
	// and the hamburger toggle changes height on tap.
	function measureTopnav() {
		const topnav = document.querySelector(".topnav");
		if (!topnav) return;
		const h = topnav.offsetHeight;
		if (h > 0) {
			document.documentElement.style.setProperty("--topnav-h", h + "px");
		}
	}

	// Apply a page-specific modifier class to the sub-page hero so CSS can
	// load the right background photo. Path-based mapping avoids touching
	// each sub-page's HTML when adding new themes later.
	function tagSubHero() {
		const hero = document.querySelector(".hero.hero--simple");
		if (!hero) return;
		const path = window.location.pathname.replace(/^\/ja\//, "/");
		const themes = ["incidents", "about-metal", "delegate", "data", "journal", "continuity"];
		for (const t of themes) {
			if (path.startsWith("/" + t)) {
				hero.classList.add("hero--photo-" + t);
				return;
			}
		}
	}

	function boot() {
		load();
		loadNetworkCounts();
		loadValidatorTrend();
		loadCycleHistory();
		loadCadence();
		loadPastCycles();
		registerSW();
		wireInstall();
		wireCalculator();
		wireReveal();
		wireParallax();
		wireCarousels();
		wireHamburger();
		wireSectionSidebar();
		tagSubHero();
		measureTopnav();
		window.addEventListener("resize", measureTopnav, { passive: true });
		wireNavDropdown();
	}

	if (document.readyState === "loading") {
		document.addEventListener("DOMContentLoaded", boot);
	} else {
		boot();
	}
})();
