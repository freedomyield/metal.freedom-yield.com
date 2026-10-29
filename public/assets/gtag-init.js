// Google Analytics 4 bootstrap + custom event helpers.
//
// Externalised from inline <script> so the site CSP can stay
// `script-src 'self' https://www.googletagmanager.com` without
// needing `'unsafe-inline'`.
//
// Public custom events fired from elsewhere in the codebase:
//   • hero_cube_click   — user clicked a smart-contract cube in the
//                         hero 3D scene (`{ cube_index, base_scale }`)
//   • delegate_cta_click — user clicked a delegation call-to-action
//   • explorer_link_click — user opened the on-chain explorer (NodeID)
//   • language_switch   — user toggled EN/JA
//
// Anything else GA4 collects is via the auto-enhanced measurement
// you enable in the property settings (scroll depth, outbound clicks,
// file downloads, page view, session).
"use strict";

const GA_MEASUREMENT_ID = "G-GJY2EJE7BV";

window.dataLayer = window.dataLayer || [];
function gtag() { window.dataLayer.push(arguments); }
window.gtag = gtag;

gtag("js", new Date());
gtag("config", GA_MEASUREMENT_ID, {
	anonymize_ip: true,        // GA4 anonymises by default; explicit for clarity
	send_page_view: true,
});

// ────────────────────────── Declarative event wiring
// Any element with `data-ga-event="..."` fires that event on click,
// plus optional `data-ga-param-*` attributes flatten into the payload.
// Lets HTML mark up tracked links/buttons without ad-hoc JS.
document.addEventListener("click", function (ev) {
	let el = ev.target;
	while (el && el !== document.body) {
		const name = el.getAttribute && el.getAttribute("data-ga-event");
		if (name) {
			const params = {};
			for (const attr of el.attributes) {
				if (attr.name.startsWith("data-ga-param-")) {
					params[attr.name.slice("data-ga-param-".length).replace(/-/g, "_")] = attr.value;
				}
			}
			// Also record the link href so outbound destinations are visible
			if (el.tagName === "A" && el.href) params.link_url = el.href;
			gtag("event", name, params);
			break;
		}
		el = el.parentElement;
	}
}, { passive: true, capture: true });

// ────────────────────────── PWA install tracking
window.addEventListener("appinstalled", function () {
	gtag("event", "pwa_installed", { method: "browser_prompt" });
});

// ────────────────────────── Reduced-motion segment
if (window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches) {
	gtag("event", "user_preference", { prefers_reduced_motion: true });
}
