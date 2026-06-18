// Incidents page — fetch /api/incidents.json and render into [data-field] slots.
// Locale auto-detect via <html lang>. Empty incident list is rendered as a positive signal,
// not a missing-data error.
"use strict";
(function () {
	var lang = document.documentElement.lang || "en";
	var I18N = {
		en: {
			none: "No incidents recorded yet.",
			noneSince: "No incidents recorded since",
			loadError: "Could not load incident data.",
			severity: { critical: "Critical", major: "Major", minor: "Minor", info: "Info" },
			duration: "Duration",
			impact: "Impact",
			resolution: "Resolution",
			minutes: "min"
		},
		ja: {
			none: "現在まで記録されたインシデントなし。",
			noneSince: "稼働開始から記録されたインシデントなし — ",
			loadError: "インシデントデータの読み込みに失敗しました。",
			severity: { critical: "重大", major: "大", minor: "中", info: "情報" },
			duration: "影響時間",
			impact: "影響範囲",
			resolution: "対応",
			minutes: "分"
		}
	};
	var t = I18N[lang] || I18N.en;

	function setText(field, value) {
		var nodes = document.querySelectorAll('[data-field="' + field + '"]');
		for (var i = 0; i < nodes.length; i++) nodes[i].textContent = value;
	}
	function setHTML(field, html) {
		var nodes = document.querySelectorAll('[data-field="' + field + '"]');
		for (var i = 0; i < nodes.length; i++) nodes[i].innerHTML = html;
	}

	function severityBadge(sev) {
		var label = (t.severity[sev] || sev || "Info");
		var cls = "badge ";
		if (sev === "critical" || sev === "major") cls += "badge-warn";
		else cls += "badge-ok";
		return '<span class="' + cls + '">' + escapeHtml(label) + "</span>";
	}

	function escapeHtml(s) {
		return String(s || "").replace(/[&<>"']/g, function (c) {
			return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c];
		});
	}

	function renderIncident(inc) {
		var dur = inc.durationMinutes
			? ('<dt>' + t.duration + '</dt><dd>' + inc.durationMinutes + ' ' + t.minutes + '</dd>')
			: "";
		var impact = inc.impact ? ('<dt>' + t.impact + '</dt><dd>' + escapeHtml(inc.impact) + '</dd>') : "";
		var resolution = inc.resolution ? ('<dt>' + t.resolution + '</dt><dd>' + escapeHtml(inc.resolution) + '</dd>') : "";
		return '<article class="incident">' +
			'<h3>' + escapeHtml(inc.date || "") + ' — ' + severityBadge(inc.severity) + ' ' + escapeHtml(inc.title || "") + '</h3>' +
			(inc.summary ? '<p>' + escapeHtml(inc.summary) + '</p>' : "") +
			'<dl class="kv">' + dur + impact + resolution + '</dl>' +
			'</article>';
	}

	function fmtJSTFromISO(s) {
		var t = Date.parse(s);
		if (!isFinite(t)) return s;
		var d = new Date(t + 9 * 3600 * 1000);
		return d.toISOString().slice(0, 10);
	}

	async function load() {
		var res;
		try {
			res = await fetch("/api/incidents.json", { cache: "no-store" });
		} catch (e) {
			setText("incidentList", t.loadError);
			return;
		}
		if (!res.ok) {
			setText("incidentList", t.loadError);
			return;
		}
		var data = await res.json();
		var incidents = (data && data.incidents) || [];
		var since = data && data.validatorSince;

		setText("validatorSince", since ? fmtJSTFromISO(since) : "—");
		setText("incidentCount", incidents.length);

		if (incidents.length === 0) {
			var msg = since
				? (t.noneSince + " " + fmtJSTFromISO(since))
				: t.none;
			setHTML("incidentList",
				'<p><span class="badge badge-ok">✓ ' + escapeHtml(t.severity.info || "Info") + '</span> ' + escapeHtml(msg) + "</p>");
			setText("lastIncident", "—");
			return;
		}

		// sort by date desc
		incidents.sort(function (a, b) {
			return (b.date || "").localeCompare(a.date || "");
		});
		setText("lastIncident", incidents[0].date || "—");
		setHTML("incidentList", incidents.map(renderIncident).join(""));
	}

	if (document.readyState === "loading") {
		document.addEventListener("DOMContentLoaded", load);
	} else {
		load();
	}
})();
