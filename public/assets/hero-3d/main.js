// Entry point — wires the modules into a working scene.
//
// Architecture:
//   utils.js     → constants, palettes, easings, Pool, helpers
//   contracts.js → Contract (one cube) + PeerMesh (lines)
//   effects.js   → TransactionLayer + BroadcastRingLayer + ParticleField
//   controls.js  → CameraController + InputController
//   main.js      → HeroScene orchestrator (this file)
//
// HeroScene options are forwarded to the subsystems so the same scene
// can be instantiated with different palettes, durations, or contract
// counts in the future (e.g., a sister site reusing the visuals).
import * as THREE from '/assets/vendor/three.module.min.js';
import { DEFAULTS, PALETTES, SPAWN_REGION, isMobileViewport, prefersReducedMotion, visibleHalfWidthAtZ, randRange } from './utils.js';
import { Contract, PeerMesh } from './contracts.js';
import { TransactionLayer, BroadcastRingLayer, ParticleField } from './effects.js';
import { CameraController, InputController } from './controls.js';
import { AtomOrbits } from './atom-orbits.js';

class HeroScene {
	constructor(canvas, options) {
		this.canvas = canvas;
		this.options = Object.assign({}, DEFAULTS, options || {});
		this.isMobile = isMobileViewport();
		this.reduceMotion = prefersReducedMotion();
		this.contracts = [];
		this.pendingSpawns = [];
		this._ringQueue = [];      // staggered sonar-ring fires queued by _fireBurst
		this.MAX = this.isMobile ? this.options.cubeCountMobile : this.options.cubeCountDesktop;
		this.CAP = this.isMobile ? this.options.cubeCapMobile : this.options.cubeCap;
		this._raycaster = new THREE.Raycaster();
		this._isVisible = true;
		this._nextSpawnAt = 2.0;
	}

	// ──────────────────────────────────────────────── lifecycle ────────
	init() {
		const o = this.options;

		this.renderer = new THREE.WebGLRenderer({
			canvas: this.canvas, antialias: !this.isMobile, alpha: true, powerPreference: 'high-performance',
		});
		this.renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, this.isMobile ? 1 : 1.5));
		this.renderer.setClearColor(0x000000, 0);
		this.renderer.toneMapping = THREE.ACESFilmicToneMapping;
		this.renderer.toneMappingExposure = 1.0;

		this.scene = new THREE.Scene();
		// Cream-coloured fog to match the page bg — cubes fade into the
		// page background at distance instead of disappearing into black
		this.scene.fog = new THREE.Fog(0xfaf7f2, 16, 44);

		this.camera = new THREE.PerspectiveCamera(o.cameraFov, 16/9, 0.1, 80);
		this.camera.position.set(0, 0, o.cameraStartZ);
		this.camera.lookAt(0, 0, 0);
		this._resize();

		// Lights — light theme uses softer / warmer fills
		this.scene.add(new THREE.AmbientLight(0xfff4dd, 0.85));
		const mint = new THREE.PointLight(0x10b386, 12, 30); mint.position.set(-8, 2, 4); this.scene.add(mint);
		const sun  = new THREE.PointLight(0xffd9a8, 10, 30); sun.position.set(8, -3, 4);  this.scene.add(sun);

		// Subsystems
		this.peerMesh = new PeerMesh(this.scene);
		this.txLayer = new TransactionLayer(this.scene, {
			poolSize: this.isMobile ? o.txPoolMobile : o.txPoolDesktop,
			onBurstArrival: (recipient) => recipient.flash(0.8),
		});
		this.rings = new BroadcastRingLayer(this.scene, {
			camera: this.camera, poolSize: o.ringPoolSize, duration: o.ringDuration,
		});
		this.particles = new ParticleField(this.scene, { isMobile: this.isMobile });
		// Proton / XPR-Network atom symbol encompassing the cube cluster —
		// decorative-only, no raycasting, no interaction with existing
		// modules. See atom-orbits.js for the per-frame contract.
		this.atomOrbits = new AtomOrbits(this.scene);
		this.camCtl = new CameraController(this.camera, o);

		this.input = new InputController(this.canvas, this.canvas.closest('header.hero') || this.canvas, {
			pickContract: (ev) => this._pickContract(ev),
			onPointerMove: (nx, ny) => this.camCtl.setMouseTarget(nx, ny),
			onDrag: (dx, dy) => this.camCtl.addDrag(dx, dy),
			onPick: (ev) => this._handlePick(ev),
			onDoubleAction: () => { /* reserved — no-op per latest user pref */ },
			onScrollZoom: (deltaY) => this.camCtl.wheel(deltaY, 0.06),
			onPinch: (delta) => this.camCtl.pinch(delta),
			onKey: (action) => this._handleKey(action),
		});

		// Pre-populate contracts (visible immediately)
		const initial = Math.floor(this.MAX * o.prespawnRatio);
		for (let i = 0; i < initial; i++) this._addContract({ initiallyVisible: true });

		// Viewport pause (battery friendly)
		if ('IntersectionObserver' in window) {
			const heroEl = this.canvas.closest('header.hero');
			if (heroEl) {
				const io = new IntersectionObserver((entries) => {
					for (let i = 0; i < entries.length; i++) this._isVisible = entries[i].isIntersecting;
				}, { threshold: 0.01 });
				io.observe(heroEl);
			}
		}

		window.addEventListener('resize', () => this._resize(), { passive: true });

		this._clock = new THREE.Clock();

		// Debug overlay — opt-in via `?debug=…` URL flag (accepts hero/1/on/true).
		// Lazy-loaded so production users don't pay for it.
		try {
			const params = new URLSearchParams(window.location.search);
			const d = params.get('debug');
			if (d && /^(hero|1|on|true|yes)$/i.test(d)) {
				import('./debug.js').then((mod) => {
					this.debug = new mod.DebugOverlay(this.canvas, this.canvas.closest('header.hero'));
					console.log('[HERO] debug overlay attached');
				}).catch(err => console.warn('[HERO] debug load failed', err));
			}
		} catch (e) { /* no-op */ }
	}

	start() {
		this.init();
		if (this.reduceMotion) {
			// Single static frame
			while (this.contracts.length < this.MAX) this._addContract({ initiallyVisible: true });
			this.peerMesh.rebuild(this.contracts);
			this.renderer.render(this.scene, this.camera);
		} else {
			this._tick();
		}
	}

	// ──────────────────────────────────────────────── helpers ──────────
	_resize() {
		const w = this.canvas.clientWidth || this.canvas.parentElement.clientWidth || 1;
		const h = this.canvas.clientHeight || this.canvas.parentElement.clientHeight || 1;
		this.renderer.setSize(w, h, false);
		this.camera.aspect = w / h;
		this.camera.updateProjectionMatrix();
	}

	// Sample a single point uniformly inside the fixed SPAWN_REGION
	// sphere. This is the raw geometric sample; collision-aware spawn
	// goes through _randomPosition() which calls this repeatedly.
	_samplePosition() {
		const CENTRE = SPAWN_REGION.centre;
		const RADIUS = SPAWN_REGION.radius;
		const r = Math.cbrt(Math.random()) * RADIUS;   // uniform-in-volume
		const cosPhi = 2 * Math.random() - 1;
		const sinPhi = Math.sqrt(1 - cosPhi * cosPhi);
		const theta = Math.random() * Math.PI * 2;
		return new THREE.Vector3(
			CENTRE.x + r * sinPhi * Math.cos(theta),
			CENTRE.y + r * sinPhi * Math.sin(theta),
			CENTRE.z + r * cosPhi
		);
	}

	// Rejection-sampled position that tries to avoid overlapping any
	// existing cube. Returns the first sample that respects a minimum
	// gap from every clickable cube, or the last attempt after the
	// budget is exhausted (the per-frame repulsion in _applyRepulsion
	// will then push the newcomer out of any residual overlap).
	_randomPosition(opts) {
		const newSize = (opts && opts.size) || 1.3;     // approx mean baseScale
		const MIN_GAP = 0.5;                            // extra buffer
		const MAX_TRIES = 12;
		let last = null;
		for (let attempt = 0; attempt < MAX_TRIES; attempt++) {
			const pos = this._samplePosition();
			last = pos;
			let ok = true;
			for (let i = 0; i < this.contracts.length; i++) {
				const c = this.contracts[i];
				if (!c.isClickable) continue;
				const minDist = (newSize + c.baseScale) * 0.5 + MIN_GAP;
				if (pos.distanceToSquared(c.position) < minDist * minDist) { ok = false; break; }
			}
			if (ok) return pos;
		}
		return last;
	}

	// Pairwise soft repulsion — cubes that overlap each other (or come
	// closer than their combined half-extents plus a small gap) push
	// each other apart proportionally. The displacement is dt-scaled
	// so the effect is smooth and stable. O(n²) over ~70 cubes is
	// well under a millisecond per frame.
	_applyRepulsion(dt) {
		const cs = this.contracts;
		const tmp = (this._repTmp = this._repTmp || new THREE.Vector3());
		const MIN_GAP = 0.45;
		const STRENGTH = 5.5;
		for (let i = 0; i < cs.length; i++) {
			const a = cs[i];
			if (!a.isClickable) continue;
			for (let j = i + 1; j < cs.length; j++) {
				const b = cs[j];
				if (!b.isClickable) continue;
				tmp.copy(b.position).sub(a.position);
				const distSq = tmp.lengthSq();
				const minDist = (a.baseScale + b.baseScale) * 0.5 + MIN_GAP;
				if (distSq < minDist * minDist && distSq > 0.0001) {
					const dist = Math.sqrt(distSq);
					const push = (minDist - dist) * STRENGTH * dt * 0.5;
					tmp.multiplyScalar(push / dist);
					a.position.sub(tmp);
					b.position.add(tmp);
				}
			}
		}
	}

	_addContract(opts) {
		opts = opts || {};
		opts.position = opts.position || this._randomPosition();
		const c = new Contract(this.camera, opts);
		this.contracts.push(c);
		this.scene.add(c.group);
		return c;
	}

	_maybeAutoSpawn(t) {
		if (this.contracts.length >= this.MAX) return;
		if (t < this._nextSpawnAt) return;
		this._addContract({ initiallyVisible: false });
		this._nextSpawnAt = t + randRange(4.5, 8.0);
	}

	// Pick the contract most directly under the cursor.
	//
	// AABB intersection: build each cube's axis-aligned bounding box in
	// world space and ask the raycaster if the ray intersects it. The
	// cube whose box the ray enters CLOSEST to the camera wins — exactly
	// how a 3D viewport's natural depth-order resolves.
	//
	// Why not perpendicular-distance + radius normalisation? Because the
	// "score = perp / radius" heuristic systematically beat small cubes
	// in favour of larger neighbours, even when the cursor was visually
	// on the small one. AABB hit-testing is the geometric truth.
	//
	// Single algorithm for hover AND click — pointer cursor and click
	// always resolve to the same cube. Returns null when the ray hits
	// no cube, so empty-space clicks remain a no-op.
	_pickContract(ev) {
		const rect = this.canvas.getBoundingClientRect();
		const mx = ((ev.clientX - rect.left) / rect.width) * 2 - 1;
		const my = -((ev.clientY - rect.top) / rect.height) * 2 + 1;
		this._raycaster.setFromCamera({ x: mx, y: my }, this.camera);
		const ray = this._raycaster.ray;
		// Lazy-create reusable scratch objects (avoid per-pick allocations)
		const box = (this._pickBox = this._pickBox || new THREE.Box3());
		const hit = (this._pickHit = this._pickHit || new THREE.Vector3());
		// 10% forgiveness margin around the actual cube edges so clicks
		// landing right on (or 1–2 px outside) the visible wireframe
		// still register. baseScale/2 is the geometric half-extent;
		// 0.55 = baseScale/2 * 1.1.
		const MARGIN = 0.55;

		let best = null;
		let bestDistSq = Infinity;
		for (let i = 0; i < this.contracts.length; i++) {
			const c = this.contracts[i];
			if (!c.isClickable) continue;
			const half = c.baseScale * MARGIN;
			box.min.set(c.position.x - half, c.position.y - half, c.position.z - half);
			box.max.set(c.position.x + half, c.position.y + half, c.position.z + half);
			if (ray.intersectBox(box, hit) !== null) {
				const dx = hit.x - ray.origin.x;
				const dy = hit.y - ray.origin.y;
				const dz = hit.z - ray.origin.z;
				const d2 = dx * dx + dy * dy + dz * dz;
				if (d2 < bestDistSq) { bestDistSq = d2; best = c; }
			}
		}
		return best;
	}

	_handlePick(ev) {
		const c = this._pickContract(ev);
		if (this.debug) {
			const rect = this.canvas.getBoundingClientRect();
			const mx = ((ev.clientX - rect.left) / rect.width) * 2 - 1;
			const my = -((ev.clientY - rect.top) / rect.height) * 2 + 1;
			this._raycaster.setFromCamera({ x: mx, y: my }, this.camera);
			this.debug.logClick(ev, this.contracts, this._raycaster, c);
		}
		if (!c) return;        // click on empty space → no-op (matches cursor)
		this._fireBurst(c);    // no camera change — click reward is the burst only
		// GA4 custom event — only emitted when a real cube was hit.
		if (window.gtag) {
			window.gtag('event', 'hero_cube_click', {
				cube_index: this.contracts.indexOf(c),
				base_scale: +c.baseScale.toFixed(2),
				is_purple: c.palette && c.palette.outer && c.palette.outer.getHex() !== 0xffffff,
				tier: c.clickCount,
				total_clicks: (this._heroClickCount = (this._heroClickCount || 0) + 1),
			});
		}
	}

	_handleKey(action) {
		switch (action) {
			case 'reset':
				this.camCtl.resetDrag();
				break;
			case 'random-burst': {
				const candidates = this.contracts.filter(c => c.isClickable);
				if (candidates.length === 0) return;
				const c = candidates[Math.floor(Math.random() * candidates.length)];
				this._fireBurst(c);
				break;
			}
			case 'zoom-in':  this.camCtl.wheel(-50, 0.06); break;
			case 'zoom-out': this.camCtl.wheel( 50, 0.06); break;
		}
	}

	_fireBurst(source) {
		// Bump the source's click tier so its border colour advances
		// through the Metallicus rainbow palette before the flash runs.
		// The flash code uses targetOuter as its base, so the cube
		// settles on the new tier colour as the green flash fades.
		source.registerClick();

		// 10 streaks so the broadcast really fans out
		this.txLayer.fireBurst(source, this.contracts, 10);
		source.flash(2.4);

		// Triple-ring sonar ping (staggered) — reads unmistakably as a
		// broadcast from this source. First ring fires immediately, two
		// more follow at 0.15 s and 0.30 s so the source pulses thrice.
		this.rings.spawn(source.position);
		const tNow = this._clock.elapsedTime;
		this._ringQueue.push({ at: tNow + 0.15, pos: source.position.clone() });
		this._ringQueue.push({ at: tNow + 0.30, pos: source.position.clone() });

		// Deferred purple contract spawns — ALWAYS at a fresh spherical
		// random position. Previous "anchor near burst arrival" caused
		// repeat-clicks on the same source to pile cubes vertically in
		// the same band. Random sphere keeps the cluster ball-shaped.
		const spawnsAvailable = Math.min(3, this.CAP - this.contracts.length - this.pendingSpawns.length);
		for (let i = 0; i < spawnsAvailable; i++) {
			this.pendingSpawns.push({
				spawnAt: tNow + 0.25 + i * 0.18,
				nearPosition: this._randomPosition(),
			});
		}
	}

	// ──────────────────────────────────────────────── animation ────────
	_tick() {
		requestAnimationFrame(() => this._tick());
		if (!this._isVisible) return;

		const dt = Math.min(this._clock.getDelta(), 0.05);
		const t = this._clock.elapsedTime;

		// Cursor refresh while mouse is stationary
		this.input.tickCursorRefresh(dt);

		// Background contract growth
		this._maybeAutoSpawn(t);

		// Deferred click-spawned contracts (purple). Position is already
		// the spherical-random target from fireBurst(); no extra offset.
		while (this.pendingSpawns.length > 0 && this.pendingSpawns[0].spawnAt <= t) {
			const item = this.pendingSpawns.shift();
			if (this.contracts.length >= this.CAP) continue;
			this._addContract({ position: item.nearPosition.clone(), palette: PALETTES.PURPLE });
		}

		// Pairwise soft repulsion BEFORE per-cube update — that way the
		// clamp in Contract.update catches any cube the repulsion may
		// have pushed past SPAWN_REGION.bounds.
		this._applyRepulsion(dt);

		// Contracts
		for (let i = 0; i < this.contracts.length; i++) this.contracts[i].update(dt, t, i);

		// Peer mesh
		this.peerMesh.maybeRebuild(t, this.contracts, 0.15);
		this.peerMesh.updateBreath(t);

		// Transactions
		this.txLayer.maybeFireAmbient(t, this.peerMesh.activeEdges);
		this.txLayer.update(dt);

		// Process queued sonar-ping rings (staggered)
		if (this._ringQueue.length > 0) {
			const ready = [];
			this._ringQueue = this._ringQueue.filter(item => {
				if (item.at <= t) { ready.push(item); return false; }
				return true;
			});
			for (let i = 0; i < ready.length; i++) this.rings.spawn(ready[i].pos);
		}
		// Rings
		this.rings.update(dt);

		// Particles
		this.particles.update(dt);

		// Atom orbits (decorative — outside the contract / peer / particle stack).
		// Pass contracts so the ring radius can scale with the blockchain mass —
		// "first the proton ring, then the contracts inside it grow into it."
		this.atomOrbits.update(dt, t, this.contracts);

		// Camera
		this.camCtl.update(dt, t, this.contracts, this.input.isDragging());

		this.renderer.render(this.scene, this.camera);

		// Debug overlay (always after render so the projection uses the
		// final camera state for this frame).
		if (this.debug) {
			const lastEv = this.input.getLastMouseEv && this.input.getLastMouseEv();
			// Single pick: hover and click resolve to the same cube now.
			const picked = lastEv ? this._pickContract(lastEv) : null;
			this.debug.update(this.contracts, this.camera, picked, picked, {
				halfW: visibleHalfWidthAtZ(this.camera, 0),
				camZ:  this.camera.position.z,
			});
		}
	}
}

// ──────────────────────────────────────────────── boot ──────────────────
// SP init enabled. Historical skip rationale (controls.js
// native scroll を block / scene が dense で text を遮蔽)は両方解消:
// touch handler に direction-detection 入っていて vertical-dominant gesture
// は native scroll に解放、加えて .hero-scroll-cue で明示的迂回路あり、
// text 側は white panel 化済で 3D 背景下でも可読。perf は mobile-tuned
// params(cubeCountMobile / pixelRatio 1 / no antialiasing)で対処済。
const canvas = document.querySelector('canvas.hero-canvas');
if (canvas) new HeroScene(canvas).start();
