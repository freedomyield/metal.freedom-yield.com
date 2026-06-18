// Network observatory renderer — fetches /api/peers.json and fills the
// placeholder elements on /network/. Designed to degrade gracefully when
// optional time-series endpoints (peers-gini.json, fee-market.json,
// peers-changes.json) return 404 — those slots just stay at "—" and the
// "additional analytic feeds are still being wired" copy explains why.
//
// CSP: script-src 'self' / connect-src 'self' — no inline JS, no external
// libraries. All bucket math is computed client-side from peers.json.
(function () {
	"use strict";

	function $all(sel) { return document.querySelectorAll(sel); }
	function setText(field, value) {
		var nodes = $all('[data-field="' + field + '"]');
		for (var i = 0; i < nodes.length; i++) nodes[i].textContent = value;
	}

	// Lang gate — EN vs JA labels for client-rendered strings.
	function isJa() {
		var lang = (document.documentElement.lang || "en").toLowerCase();
		return lang.indexOf("ja") === 0;
	}

	function fmtJST(epochMs) {
		var d = new Date(epochMs + 9 * 3600 * 1000);
		return d.toISOString().replace("T", " ").slice(0, 16) + " JST";
	}
	function fmtJSTFromISO(s) {
		var t = Date.parse(s);
		return isFinite(t) ? fmtJST(t) : s;
	}

	function fmtMetal(n) {
		if (n == null || !isFinite(n)) return "—";
		return Number(n).toLocaleString(undefined, { maximumFractionDigits: 0 }) + " METAL";
	}

	// Render a simple horizontal bucket row inside a <dl class="kv"> dt/dd
	// pair. We don't have a bar-chart class in styles.css; instead we put
	// "<count> validators · <pct>%" into the <dd>, which the existing .kv
	// styling renders cleanly without any new CSS.
	function renderBucketRow(field, count, total) {
		var pct = total > 0 ? (count / total * 100) : 0;
		var ja = isJa();
		var label = ja
			? (count + " validator · " + pct.toFixed(1) + "%")
			: (count + " validators · " + pct.toFixed(1) + "%");
		setText(field, label);
	}

	// Fee bucket assignment — exact 2.0% (protocol floor), >2 to <=5, >5 to
	// <=10, and >10. We intentionally separate the floor as its own bucket
	// because that's the minimum the protocol allows; everything above is a
	// validator-chosen rate.
	function feeBucket(pct) {
		if (pct == null || !isFinite(pct)) return null;
		var p = Number(pct);
		if (p === 2 || Math.abs(p - 2) < 0.01) return "fee_2";
		if (p > 2 && p <= 5) return "fee_2_5";
		if (p > 5 && p <= 10) return "fee_5_10";
		if (p > 10) return "fee_10p";
		return null;
	}

	// Self-stake bucket assignment — log-spaced because self-stake on Metal
	// spans ~2k (protocol minimum) to multi-million. The boundaries here are
	// observation-friendly, not value judgements.
	function stakeBucket(metal) {
		if (metal == null || !isFinite(metal)) return null;
		var s = Number(metal);
		if (s < 10000) return "stake_2_10k";
		if (s < 100000) return "stake_10_100k";
		if (s < 1000000) return "stake_100k_1m";
		return "stake_1m_plus";
	}

	async function loadPeers() {
		var res;
		try {
			res = await fetch("/api/peers.json", { cache: "no-store" });
		} catch (e) { return; }
		if (!res.ok) return;
		var data = await res.json();

		// generated_at — observation freshness
		if (data.generated_at) setText("generatedAt", fmtJSTFromISO(data.generated_at));

		var validators = Array.isArray(data.validators) ? data.validators : [];
		var total = (data.summary && data.summary.active_count) || validators.length;
		setText("totalValidators", String(total));

		// Source attribution string in the lead
		setText("source", "/api/peers.json");

		// Bucket tallies
		var fee = { fee_2: 0, fee_2_5: 0, fee_5_10: 0, fee_10p: 0, other: 0 };
		var stake = { stake_2_10k: 0, stake_10_100k: 0, stake_100k_1m: 0, stake_1m_plus: 0, other: 0 };

		var ownNodeId = data.own_node_id;
		var ownRow = null;

		for (var i = 0; i < validators.length; i++) {
			var v = validators[i];
			var fb = feeBucket(v.delegation_fee_pct);
			if (fb && fee[fb] != null) fee[fb]++; else fee.other++;
			var sb = stakeBucket(v.self_stake_metal);
			if (sb && stake[sb] != null) stake[sb]++; else stake.other++;
			if (v.is_self || (ownNodeId && v.node_id === ownNodeId)) ownRow = v;
		}

		// Render fee distribution
		renderBucketRow("fee_2", fee.fee_2, total);
		renderBucketRow("fee_2_5", fee.fee_2_5, total);
		renderBucketRow("fee_5_10", fee.fee_5_10, total);
		renderBucketRow("fee_10p", fee.fee_10p, total);

		// Render stake distribution
		renderBucketRow("stake_2_10k", stake.stake_2_10k, total);
		renderBucketRow("stake_10_100k", stake.stake_10_100k, total);
		renderBucketRow("stake_100k_1m", stake.stake_100k_1m, total);
		renderBucketRow("stake_1m_plus", stake.stake_1m_plus, total);

		// Freedom Yield position
		if (ownRow) {
			setText("self_nodeId", ownRow.node_id || "—");
			setText("self_fee", (ownRow.delegation_fee_pct != null) ? (ownRow.delegation_fee_pct + "%") : "—");
			setText("self_stake", fmtMetal(ownRow.self_stake_metal));

			var ja = isJa();
			var fbSelf = feeBucket(ownRow.delegation_fee_pct);
			var sbSelf = stakeBucket(ownRow.self_stake_metal);
			var feeLabel = {
				fee_2:    ja ? "2.0% ちょうど(プロトコル最低値)" : "2.0% exact (protocol floor)",
				fee_2_5:  ja ? ">2% 〜 5%" : ">2% to 5%",
				fee_5_10: ja ? "5% 〜 10%" : "5% to 10%",
				fee_10p:  ja ? ">10%" : ">10%"
			}[fbSelf] || (ja ? "対象外" : "uncategorised");
			var stakeLabel = {
				stake_2_10k:   "2k–10k METAL",
				stake_10_100k: "10k–100k METAL",
				stake_100k_1m: "100k–1M METAL",
				stake_1m_plus: "1M+ METAL"
			}[sbSelf] || (ja ? "対象外" : "uncategorised");
			setText("self_feeBucket", feeLabel);
			setText("self_stakeBucket", stakeLabel);
		} else {
			var ja2 = isJa();
			var noSelf = ja2 ? "自ノード行が peers.json に未掲載" : "Own-node row not found in peers.json";
			setText("self_nodeId", noSelf);
		}
	}

	// Optional analytic feeds — peers-gini.json / fee-market.json /
	// peers-changes.json. Today these return 404 on the public host; we
	// probe them so the "additional analytic feeds" copy can flip from
	// "still being wired" to "online" once they land, without anyone
	// editing HTML. 404 path is the expected steady state for now.
	async function probeOptional() {
		var slots = [
			{ path: "/api/peers-gini.json",    field: "feed_gini" },
			{ path: "/api/fee-market.json",    field: "feed_fee_market" },
			{ path: "/api/peers-changes.json", field: "feed_changes" }
		];
		var ja = isJa();
		var online = ja ? "オンライン" : "online";
		var offline = ja ? "未配信(後日接続予定)" : "not yet available";

		for (var i = 0; i < slots.length; i++) {
			(function (slot) {
				fetch(slot.path, { cache: "no-store", method: "HEAD" })
					.then(function (r) { setText(slot.field, r && r.ok ? online : offline); })
					.catch(function () { setText(slot.field, offline); });
			})(slots[i]);
		}
	}

	function boot() {
		loadPeers();
		probeOptional();
	}

	if (document.readyState === "loading") {
		document.addEventListener("DOMContentLoaded", boot);
	} else {
		boot();
	}
})();
