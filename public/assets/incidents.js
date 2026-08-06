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
			statusLabel: "Status",
			statusValue: { open: "Open", under_remediation: "Under remediation", resolved: "Resolved" },
			resolution: "Resolved"
		},
		ja: {
			none: "現在まで記録されたインシデントなし。",
			noneSince: "稼働開始から記録されたインシデントなし — ",
			loadError: "インシデントデータの読み込みに失敗しました。",
			severity: { critical: "重大", major: "大", minor: "中", info: "情報" },
			statusLabel: "状態",
			statusValue: { open: "未対応", under_remediation: "対応中", resolved: "解消済み" },
			resolution: "解消日"
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

	// Value-domain contract, not just a field-name one: incidents.schema.v1.json
	// declares severity as the capitalized enum ["Critical","Major","Minor","Info"]
	// and the live feed carries "Minor", but the I18N tables above are keyed in
	// lowercase. Until 2026-08-06 every lookup therefore missed, with two
	// consequences — the JA page fell through to the raw English enum value (a
	// locale leak), and, worse, `sev === "critical"` never matched, so a
	// Critical or Major incident was painted badge-ok GREEN: the page actively
	// signalled "all fine" for the most serious class of event it exists to
	// report. Normalizing once here is what keeps the enum's case an internal
	// detail of the feed rather than a styling input.
	function severityBadge(sev) {
		var key = String(sev || "").toLowerCase();
		var label = t.severity[key] || sev || t.severity.info;
		var cls = "badge " + ((key === "critical" || key === "major") ? "badge-warn" : "badge-ok");
		return '<span class="' + cls + '">' + escapeHtml(label) + "</span>";
	}

	// Same class as severityBadge: status is the enum
	// ["open","under_remediation","resolved"]. Rendering it raw would print
	// "under_remediation" to a visitor, in both locales.
	function statusLabel(status) {
		var key = String(status || "").toLowerCase();
		return t.statusValue[key] || status;
	}

	function escapeHtml(s) {
		return String(s || "").replace(/[&<>"']/g, function (c) {
			return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c];
		});
	}

	// Field names below MUST match incidents.schema.v1.json. Until 2026-08-06
	// this renderer read inc.date, inc.durationMinutes, inc.impact and
	// inc.resolution — none of which the schema, the example or the live feed
	// has ever defined. Every one was `|| ""`-guarded or ternary-guarded, so
	// the page rendered cleanly with the values simply missing: the incident
	// heading showed a bare " — " where the date belongs, and the Duration /
	// Impact / Resolution rows could never appear for any incident. Silent
	// blanks on a transparency page are worse than an error, because nothing
	// signals that the reader is asking for a name the writer never wrote.
	// Same class as the 2026-08-04 anchor-history near-miss; both are now
	// guarded by scripts/check-field-contracts.py.
	//   date            -> detectionDate
	//   resolution      -> resolutionDate  (schema has the date, not free text)
	//   durationMinutes -> no equivalent exists; the feed carries date-only
	//                      strings, so no duration can be derived. Row dropped.
	//   impact          -> no equivalent exists. Row dropped.
	function renderIncident(inc) {
		var resolution = inc.resolutionDate
			? ('<dt>' + t.resolution + '</dt><dd>' + escapeHtml(inc.resolutionDate) + '</dd>')
			: "";
		var status = inc.status ? ('<dt>' + t.statusLabel + '</dt><dd>' + escapeHtml(statusLabel(inc.status)) + '</dd>') : "";
		return '<article class="incident">' +
			'<h3>' + escapeHtml(inc.detectionDate || "") + ' — ' + severityBadge(inc.severity) + ' ' + escapeHtml(inc.title || "") + '</h3>' +
			(inc.summary ? '<p>' + escapeHtml(inc.summary) + '</p>' : "") +
			'<dl class="kv">' + status + resolution + '</dl>' +
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

		// sort by detection date desc (see renderIncident's field-name note:
		// this read `.date`, which does not exist, so the comparator returned 0
		// for every pair and the list was never actually ordered — and the
		// "Last incident" stat rendered "—" even with an incident on record).
		incidents.sort(function (a, b) {
			return (b.detectionDate || "").localeCompare(a.detectionDate || "");
		});
		setText("lastIncident", incidents[0].detectionDate || "—");
		setHTML("incidentList", incidents.map(renderIncident).join(""));
	}

	if (document.readyState === "loading") {
		document.addEventListener("DOMContentLoaded", load);
	} else {
		load();
	}
})();
