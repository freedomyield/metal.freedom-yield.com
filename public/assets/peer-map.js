// peer-map.js — real Leaflet map of the validator's peer set.
//
// Reads /api/peer-geo.json (refreshed every 30 min by a cron on the
// validator server: scripts/peer-geo.py → info.peers → ip-api.com).
// Plots every peer as a small slate dot and the validator's own node
// as a larger mint marker — the "we are one node among many"
// narrative, not a peer-distribution analytics dashboard.
//
// Implementation notes:
//   • Leaflet is self-hosted under /assets/vendor/leaflet/ so CSP
//     `script-src 'self'` stays strict.
//   • Map tiles come from openstreetmap.org (CSP img-src whitelist
//     was extended in Caddyfile to allow `*.tile.openstreetmap.org`).
//   • Custom CircleMarker (not L.Marker) so we don't ship a PNG icon
//     and so the visual fits the cream theme.
"use strict";

(function () {
	var container = document.getElementById("peer-map");
	if (!container || typeof L === "undefined") return;

	// Light, monochrome basemap — keep it subdued so the dots read clearly.
	var map = L.map(container, {
		center: [22, 12],
		zoom: 2,
		minZoom: 2,
		maxZoom: 6,
		worldCopyJump: true,
		zoomControl: true,
		scrollWheelZoom: false,
		// Keep gestures sane on touch — pinch to zoom, drag to pan.
		dragging: true,
		attributionControl: true,
	});
	L.tileLayer("https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png", {
		attribution: '© <a href="https://www.openstreetmap.org/copyright" rel="nofollow noopener noreferrer" target="_blank">OpenStreetMap</a>',
		maxZoom: 8,
		className: "peer-map-tile",
	}).addTo(map);

	function pluralize(n, singular, plural) {
		return n + " " + (n === 1 ? singular : plural);
	}

	// Lang gate — matches the (document.documentElement.lang) convention
	// used by main.js / network.js / journal.js / incidents.js.
	function isJa() {
		var lang = (document.documentElement.lang || "en").toLowerCase();
		return lang.indexOf("ja") === 0;
	}

	function statusText(d) {
		var fmt = d.generatedAt ? new Date(d.generatedAt).toLocaleString() : "—";
		var n = d.resolved || 0;
		// "with known location" / 「位置が判明している」 — d.resolved is the
		// geo-lookup success count, smaller than the raw peer count quoted
		// in the note below the map (data-field="liveTotalNetwork", fed by
		// numPeers). Distinguishing the two here stops the map caption
		// reading as a second, silently different answer to "how many
		// peers".
		if (isJa()) {
			return "位置が判明している " + n + " 件 · 更新 " + fmt;
		}
		return pluralize(n, "peer with known location", "peers with known location") + " · updated " + fmt;
	}

	function paint(data) {
		// Reset (in case of refresh)
		map.eachLayer(function (l) {
			if (l instanceof L.CircleMarker) map.removeLayer(l);
		});

		var peers = (data && data.peers) || [];
		var ourMarker = null;
		for (var i = 0; i < peers.length; i++) {
			var p = peers[i];
			if (typeof p.lat !== "number" || typeof p.lng !== "number") continue;
			var isSelf = !!p.self;
			var marker = L.circleMarker([p.lat, p.lng], {
				radius: isSelf ? 9 : 3,
				color:  isSelf ? "#0a7d5c" : "#4a5568",
				weight: isSelf ? 2 : 1,
				fillColor: isSelf ? "#10b386" : "#94a3b8",
				fillOpacity: isSelf ? 0.95 : 0.55,
				interactive: isSelf,         // others are decorative; only ours is clickable
			}).addTo(map);
			if (isSelf) {
				ourMarker = marker;
				marker.bindTooltip(
					"<strong>Freedom Yield · Metal</strong><br>" +
					(p.city || "") + (p.city && p.country ? ", " : "") + (p.country || ""),
					{ direction: "top", offset: [0, -8], opacity: 0.95 }
				);
			}
		}

		var statusEl = document.querySelector("[data-peer-map-status]");
		if (statusEl) statusEl.textContent = statusText(data);

		// Gently focus on our own node so it's the visual anchor.
		if (ourMarker) {
			map.setView(ourMarker.getLatLng(), 3, { animate: true });
		}
	}

	function fail(msg) {
		var statusEl = document.querySelector("[data-peer-map-status]");
		if (statusEl) statusEl.textContent = msg;
	}

	// No explicit cache option: Caddy already serves /api/*.json with
	// Cache-Control: public, max-age=120, must-revalidate, and main.js's
	// loadNetworkCounts() fetches this exact URL on the same page load —
	// letting the browser's HTTP cache apply means the second of the two
	// fetches is typically served from cache instead of hitting the
	// network again (was `cache: "no-store"`, which forced two real
	// network round-trips on every homepage load).
	fetch("/api/peer-geo.json")
		.then(function (r) {
			if (!r.ok) throw new Error("HTTP " + r.status);
			return r.json();
		})
		.then(paint)
		.catch(function (e) {
			fail("Live map data unavailable — fallback view shown.");
		});
})();
