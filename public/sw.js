// Service worker — offline-safe fallback for the validator status page.
// Strategy:
//   - Pre-cache the app shell (HTML / CSS / JS / icons / manifest)
//   - validator.json: network-first with cache fallback (so a fresh fetch
//     wins when online, last-known value renders when offline)
//   - Versioned cache name; old caches deleted on activate.
"use strict";

const CACHE_VERSION = "v128-delegate-fact-correction";
const SHELL_CACHE = "shell-" + CACHE_VERSION;
const DATA_CACHE = "data-" + CACHE_VERSION;

const SHELL_ASSETS = [
	"/",
	"/ja/",
	"/styles.css",
	"/assets/main.js",
	"/assets/network.js",
	"/assets/logo.svg",
	"/assets/icon-192.png",
	"/assets/icon-512.png",
	"/assets/apple-touch-icon.png",
	"/manifest.json"
];

self.addEventListener("install", (event) => {
	event.waitUntil(
		caches.open(SHELL_CACHE).then((cache) => cache.addAll(SHELL_ASSETS))
	);
	self.skipWaiting();
});

self.addEventListener("activate", (event) => {
	event.waitUntil(
		caches.keys().then((keys) =>
			Promise.all(
				keys
					.filter((k) => k !== SHELL_CACHE && k !== DATA_CACHE)
					.map((k) => caches.delete(k))
			)
		)
	);
	self.clients.claim();
});

self.addEventListener("fetch", (event) => {
	const req = event.request;
	if (req.method !== "GET") return;

	const url = new URL(req.url);
	if (url.origin !== self.location.origin) return;

	// validator.json — network-first
	if (url.pathname === "/api/validator.json") {
		event.respondWith(
			fetch(req)
				.then((res) => {
					const copy = res.clone();
					caches.open(DATA_CACHE).then((c) => c.put(req, copy));
					return res;
				})
				.catch(() => caches.match(req))
		);
		return;
	}

	// everything else — cache-first
	event.respondWith(
		caches.match(req).then((cached) => cached || fetch(req))
	);
});
