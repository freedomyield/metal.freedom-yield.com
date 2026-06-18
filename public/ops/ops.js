// Ops dashboard — fetches /api/validator.json + /api/server-status.json
// and renders into [data-field] slots. Refresh every 60s.
"use strict";
(function () {
	function setText(field, value) {
		var nodes = document.querySelectorAll('[data-field="' + field + '"]');
		for (var i = 0; i < nodes.length; i++) nodes[i].textContent = value;
	}

	function setBadge(field, value, level) {
		var nodes = document.querySelectorAll('[data-field="' + field + '"]');
		for (var i = 0; i < nodes.length; i++) {
			nodes[i].textContent = value;
			nodes[i].className = "badge";
			if (level === "ok") nodes[i].classList.add("badge-ok");
			else if (level === "warn") nodes[i].classList.add("badge-warn");
		}
	}

	function fmtBool(b) { return b === true ? "✓" : (b === false ? "✗" : "—"); }

	// JST display helpers (UTC+9)
	function fmtJST(epochMs) {
		var d = new Date(epochMs + 9 * 3600 * 1000);
		return d.toISOString().replace("T", " ").slice(0, 16) + " JST";
	}
	function fmtJSTFromISO(s) {
		var t = Date.parse(s);
		return isFinite(t) ? fmtJST(t) : s;
	}

	function fmtBytes(kb) {
		if (kb == null) return "—";
		var n = Number(kb);
		if (n >= 1024 * 1024) return (n / 1024 / 1024).toFixed(2) + " GB";
		if (n >= 1024) return (n / 1024).toFixed(1) + " MB";
		return n + " KB";
	}

	function fmtSeconds(s) {
		if (s == null) return "—";
		var d = Math.floor(s / 86400);
		var h = Math.floor((s % 86400) / 3600);
		var m = Math.floor((s % 3600) / 60);
		var parts = [];
		if (d > 0) parts.push(d + "d");
		if (h > 0) parts.push(h + "h");
		parts.push(m + "m");
		return parts.join(" ");
	}

	function levelFromPct(pct, warnAt, critAt) {
		if (pct == null) return null;
		if (pct >= critAt) return "warn";
		if (pct >= warnAt) return "warn";
		return "ok";
	}

	async function loadValidator() {
		try {
			var res = await fetch("/api/validator.json", { cache: "no-store" });
			if (!res.ok) return null;
			return await res.json();
		} catch (e) { return null; }
	}

	async function loadServer() {
		try {
			var res = await fetch("/api/server-status.json", { cache: "no-store" });
			if (!res.ok) return null;
			return await res.json();
		} catch (e) { return null; }
	}

	function renderValidator(v) {
		if (!v) return;
		if (v.nodeId) setText("nodeId", v.nodeId);
		if (v.network) setText("network", v.network);
		if (v.bootstrap) {
			setText("bootstrap-p", fmtBool(v.bootstrap.pChain));
			setText("bootstrap-x", fmtBool(v.bootstrap.xChain));
			setText("bootstrap-c", fmtBool(v.bootstrap.cChain));
		}
		if (v.stake && v.stake.self != null) {
			setText("selfStake", v.stake.self + " " + (v.stake.unit || "METAL"));
		}
		if (v.uptime && v.uptime.network != null) {
			setText("uptime", Number(v.uptime.network).toFixed(2) + "%");
		}
		if (v.endTime != null) {
			var endMs = Number(v.endTime) * 1000;
			if (isFinite(endMs) && endMs > 0) {
				setText("endTime", fmtJST(endMs));
				var daysLeft = Math.ceil((endMs - Date.now()) / 86400000);
				if (daysLeft <= 0) setBadge("daysRemaining", "expired", "warn");
				else if (daysLeft <= 7) setBadge("daysRemaining", daysLeft + "d left", "warn");
				else setBadge("daysRemaining", daysLeft + "d left", "ok");
			}
		}
	}

	function renderServer(s) {
		if (!s) {
			setBadge("overallStatus", "no data", "warn");
			return;
		}
		if (s.observedAt) setText("observedAt", "last: " + fmtJSTFromISO(s.observedAt));

		// host
		if (s.host) {
			if (s.host.cpu) {
				setText("cpu-pct", s.host.cpu.usedPercent);
			}
			if (s.host.load) {
				setText("load", "(load " + s.host.load["1m"] + " / " + s.host.load["5m"] + " / " + s.host.load["15m"] + ")");
			}
			if (s.host.memory) {
				setText("mem-pct", s.host.memory.usedPercent);
				setText("mem-used", fmtBytes(s.host.memory.usedKB));
				setText("mem-total", fmtBytes(s.host.memory.totalKB));
			}
			if (s.host.disk) {
				setText("disk-pct", s.host.disk.usedPercent);
				setText("disk-used", fmtBytes(s.host.disk.usedKB));
				setText("disk-total", fmtBytes(s.host.disk.totalKB));
			}
			if (s.host.uptimeSec != null) {
				setText("host-uptime", fmtSeconds(s.host.uptimeSec));
			}
		}

		// metalgo / chain
		if (s.metalgo) {
			setText("peers", s.metalgo.peerCount);
			setText("p-height", s.metalgo.pChainHeight);
			setText("c-height", s.metalgo.cChainHeight);
			var mLevel = s.metalgo.containerStatus === "running" ? "ok" : "warn";
			setBadge("metalgo-status", s.metalgo.containerStatus, mLevel);
		}
		if (s.caddy) {
			var cLevel = s.caddy.containerStatus === "running" ? "ok" : "warn";
			setBadge("caddy-status", s.caddy.containerStatus, cLevel);
		}
		if (s.security) {
			var banned = s.security.fail2banSshBanned;
			setText("f2b-banned", banned == null ? "(root-only metric, see security-audit.sh)" : banned);
		}

		// overall status
		var problems = [];
		if (s.metalgo && s.metalgo.containerStatus !== "running") problems.push("metalgo");
		if (s.caddy && s.caddy.containerStatus !== "running") problems.push("caddy");
		if (s.host && s.host.disk && s.host.disk.usedPercent > 80) problems.push("disk");
		if (s.host && s.host.memory && s.host.memory.usedPercent > 90) problems.push("memory");
		if (problems.length === 0) setBadge("overallStatus", "All systems normal", "ok");
		else setBadge("overallStatus", "Attention: " + problems.join(", "), "warn");
	}

	async function refresh() {
		var [v, s] = await Promise.all([loadValidator(), loadServer()]);
		renderValidator(v);
		renderServer(s);
	}

	refresh();
	setInterval(refresh, 60000);
})();
