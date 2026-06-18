// Shared utilities + constants for the hero 3D scene.
// Imported by contracts.js / effects.js / controls.js / main.js.
import * as THREE from '/assets/vendor/three.module.min.js';

// ────────────────────────── Defaults (overridable via HeroScene options)
export const DEFAULTS = Object.freeze({
	// Cube counts
	cubeCountDesktop: 30,
	cubeCountMobile: 18,
	cubeCap: 70,          // soft cap including click-spawned
	cubeCapMobile: 40,
	prespawnRatio: 0.35,  // fraction of MAX_CUBES visible at page load

	// Camera
	cameraStartZ: 14,
	cameraFov: 62,
	// zoomMin < 0 = camera can pass through the cluster centre (z=-1.5)
	// and emerge on the back side. Combined with the X-approach in
	// CameraController, wheel-zoom turns into a fly-through.
	zoomMin: -5,
	zoomMax: 26,

	// Camera smoothing (single lerp rate)
	idleLerpRate: 0.9,

	// Mouse parallax
	mouseParallaxX: 4.8,
	mouseParallaxY: 3.0,

	// Drag
	dragLimit: 7.0,
	dragInertia: 0.93,

	// Transactions
	txPoolDesktop: 24,
	txPoolMobile: 14,

	// Rings (broadcast halo)
	ringPoolSize: 8,
	ringDuration: 0.9,
});

// ────────────────────────── Spawn region (camera-independent)
// MUST NOT depend on the current camera position — when the camera
// dollies in to focus on a cube, visibleHalfWidthAtZ collapses, and any
// camera-relative spawn/clamp logic degenerates the cluster into a
// vertical column. Both contracts.js (clamping) and main.js (random
// spawn) use these same constants.
export const SPAWN_REGION = Object.freeze({
	centre: Object.freeze({ x: 9.0, y: 0.0, z: -1.5 }),
	radius: 7.0,
	bounds: Object.freeze({
		minX:  2.0, maxX: 16.0,
		minY: -7.5, maxY:  7.5,
		minZ: -7.0, maxZ:  5.5,
	}),
});

// ────────────────────────── Click-tier rainbow palette
// Border colours that a cube's outer wireframe cycles through as the
// user clicks it. Tier 0 is the cube's original palette colour (white-
// blue or purple); each subsequent click bumps it to the next entry.
// After all entries are consumed it wraps around, so heavily-clicked
// cubes keep rotating through Metallicus-friendly hues.
function color(hex) { return new THREE.Color(hex); }

// Light-theme palette. Pale glows that worked on
// a black bg become invisible on cream, so the resting colours are
// now darker / AA-contrast against the cream page background.
export const CLICK_TIER_COLORS = Object.freeze([
	color(0x10b386),  // tier 1: deep mint
	color(0x059669),  // tier 2: emerald
	color(0xb8860b),  // tier 3: dark gold
	color(0xea580c),  // tier 4: deep orange
	color(0xe11d48),  // tier 5: rose
	color(0x7c3aed),  // tier 6: violet
	color(0x2563eb),  // tier 7: blue
]);

export const COLORS = Object.freeze({
	flashFrom: color(0x344155),   // outer idle — slate (visible on cream)
	flashTo:   color(0x059669),   // outer flash — emerald
	coreIdle:  color(0x1f2937),   // core — near-black
	coreFlash: color(0x10b981),   // core flash — mint
	innerIdle: color(0x10b386),   // inner — deep mint
	innerFlash:color(0x047857),   // inner flash — darker mint
	white:     color(0xffffff),
	txAmbient: color(0x6ea58d),   // ambient streak — mid mint
	txBurst:   color(0x059669),   // burst streak — emerald
	ringColor: color(0x10b386),   // sonar ring — mint
});

export const PALETTES = Object.freeze({
	DEFAULT: {
		outer: COLORS.flashFrom,
		inner: COLORS.innerIdle,
		core:  COLORS.coreIdle,
	},
	PURPLE: {
		outer: color(0x7c3aed),   // violet-600
		inner: color(0x9333ea),   // violet-500
		core:  color(0x6b21a8),   // violet-800
	},
});

// ────────────────────────── Easings
export const easings = Object.freeze({
	outBack(t) {
		const c1 = 1.70158, c3 = c1 + 1;
		return 1 + c3 * Math.pow(t - 1, 3) + c1 * Math.pow(t - 1, 2);
	},
	inCubic(t) { return t * t * t; },
	inOutQuart(t) {
		return t < 0.5 ? 8 * t * t * t * t : 1 - Math.pow(-2 * t + 2, 4) / 2;
	},
	easeInOut(t) {
		return t < 0.5 ? 2 * t * t : 1 - Math.pow(-2 * t + 2, 2) / 2;
	},
});

// ────────────────────────── Generic object pool
// Used for transaction streaks, broadcast rings, etc.
export class Pool {
	constructor(size, factory) {
		this.items = [];
		for (let i = 0; i < size; i++) this.items.push(factory(i));
	}
	acquire(predicate) {
		// predicate(item) → truthy means "free, give it to me"
		for (let i = 0; i < this.items.length; i++) {
			if (predicate(this.items[i])) return this.items[i];
		}
		return null;
	}
	forEach(fn) {
		for (let i = 0; i < this.items.length; i++) fn(this.items[i], i);
	}
}

// ────────────────────────── Camera frustum helpers
// World-space half width at a given z, given a camera. The cluster spread
// uses this so cubes fill the frame at any zoom/aspect.
export function visibleHalfWidthAtZ(camera, z) {
	const distFromCam = camera.position.z - z;
	if (distFromCam <= 0) return 0;
	const halfH = distFromCam * Math.tan(THREE.MathUtils.degToRad(camera.fov) / 2);
	return halfH * camera.aspect;
}

// ────────────────────────── Misc helpers
export function randRange(min, max) {
	return min + Math.random() * (max - min);
}

export function clamp(v, lo, hi) {
	return v < lo ? lo : (v > hi ? hi : v);
}

export function isMobileViewport() {
	return window.matchMedia('(max-width: 768px)').matches;
}

export function prefersReducedMotion() {
	return window.matchMedia('(prefers-reduced-motion: reduce)').matches;
}
