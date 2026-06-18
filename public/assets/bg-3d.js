// Kinetic page background — slowly-rotating node-and-line network that
// drifts behind the content below the hero. Completely independent of
// the hero scene:
//   • own canvas, scene, camera, renderer
//   • NO event listeners (no click / drag / wheel / scroll / parallax)
//   • auto-pauses while the hero is in view (no point rendering both)
//   • re-uses ParticleField from hero-3d/effects.js for ambient confetti,
//     plus a small custom NodeNetwork class for the visible mesh
//
// The hero remains the single point of WebGL interactivity. This file
// is strictly decoration.
import * as THREE from '/assets/vendor/three.module.min.js';
import { ParticleField } from '/assets/hero-3d/effects.js';

// All opacity values below are pre-multiplied by INTENSITY (35% per
// the user's "今の濃さの 35%" request). Tune INTENSITY in one place
// to brighten / dim the whole bg scene at once.
const INTENSITY = 0.35;

// ────────────────────────── NodeNetwork
// A small constellation of sphere nodes connected by line segments.
// Built once, rotated slowly. Visible on the cream page bg because
// the geometry is real (Mesh + LineSegments) rather than 1-px Points
// — the earlier ParticleField-only background disappeared against
// `#faf7f2` because individual particle dots collapsed to sub-pixel.
class NodeNetwork {
	constructor(scene, options) {
		options = options || {};
		const N = options.nodeCount || 38;
		const SX = options.spreadX || 64;
		const SY = options.spreadY || 32;
		const SZ = options.spreadZ || 10;
		const CONNECT = options.connectDist || 14;
		const COLOR_NODE = options.nodeColor || 0x10b386;       // mint
		const COLOR_LINE = options.lineColor || 0x344155;       // slate
		const NODE_OP   = (options.nodeOpacity || 0.65) * INTENSITY;
		const LINE_OP   = (options.lineOpacity || 0.32) * INTENSITY;
		const NODE_R    = options.nodeRadius  || 0.14;

		// Sample N random nodes inside the spread box
		const pts = [];
		for (let i = 0; i < N; i++) {
			pts.push(new THREE.Vector3(
				(Math.random() - 0.5) * SX,
				(Math.random() - 0.5) * SY,
				(Math.random() - 0.5) * SZ - 4
			));
		}

		// Group so the whole net rotates as one
		this.group = new THREE.Group();
		scene.add(this.group);

		// Lines: precompute pairs within CONNECT distance
		const linePos = [];
		for (let i = 0; i < N; i++) {
			for (let j = i + 1; j < N; j++) {
				if (pts[i].distanceTo(pts[j]) < CONNECT) {
					linePos.push(pts[i].x, pts[i].y, pts[i].z);
					linePos.push(pts[j].x, pts[j].y, pts[j].z);
				}
			}
		}
		const lineGeo = new THREE.BufferGeometry();
		lineGeo.setAttribute('position', new THREE.Float32BufferAttribute(linePos, 3));
		this.lineMat = new THREE.LineBasicMaterial({
			color: COLOR_LINE,
			transparent: true,
			opacity: LINE_OP,
			depthWrite: false,
		});
		this.lines = new THREE.LineSegments(lineGeo, this.lineMat);
		this.group.add(this.lines);

		// Nodes (one shared sphere geometry + material for batch perf)
		const nodeGeo = new THREE.SphereGeometry(NODE_R, 10, 10);
		this.nodeMat = new THREE.MeshBasicMaterial({
			color: COLOR_NODE,
			transparent: true,
			opacity: NODE_OP,
			depthWrite: false,
		});
		for (let i = 0; i < pts.length; i++) {
			const m = new THREE.Mesh(nodeGeo, this.nodeMat);
			m.position.copy(pts[i]);
			this.group.add(m);
		}

		// Rotation rates (rad/sec) — very slow, ambient
		this.rotX = options.rotX || 0.012;
		this.rotY = options.rotY || 0.035;
	}

	update(dt, t) {
		this.group.rotation.x += this.rotX * dt;
		this.group.rotation.y += this.rotY * dt;
		// gentle "breathing" of opacity so it feels alive
		const breath = 0.85 + 0.15 * Math.sin(t * 0.6);
		this.lineMat.opacity = 0.32 * INTENSITY * breath;
		this.nodeMat.opacity = 0.65 * INTENSITY * breath;
	}
}

// ────────────────────────── BackgroundCubes
// Wireframe boxes that read as smart-contract glyphs floating in the
// far distance. Cheap to render (LineSegments via EdgesGeometry, no
// fills, no inner geometry, no flash logic) so they ride alongside
// the NodeNetwork without strain. Each cube has its own slow random
// rotation; the whole field stays put (no drift) to avoid drawing
// attention away from foreground content.
class BackgroundCubes {
	constructor(scene, options) {
		options = options || {};
		const N = options.count || 12;
		const SX = options.spreadX || 60;
		const SY = options.spreadY || 28;
		const SZ = options.spreadZ || 12;
		const COLOR = options.color || 0x344155;
		const OPACITY = (options.opacity || 0.55) * INTENSITY;
		this.opacityBase = OPACITY;

		this.group = new THREE.Group();
		scene.add(this.group);

		this.cubes = [];
		for (let i = 0; i < N; i++) {
			const s = 1.0 + Math.random() * 1.4;
			const boxGeo = new THREE.BoxGeometry(s, s, s);
			const edgeGeo = new THREE.EdgesGeometry(boxGeo);
			boxGeo.dispose();
			const mat = new THREE.LineBasicMaterial({
				color: COLOR,
				transparent: true,
				opacity: OPACITY,
				depthWrite: false,
			});
			const cube = new THREE.LineSegments(edgeGeo, mat);
			cube.position.set(
				(Math.random() - 0.5) * SX,
				(Math.random() - 0.5) * SY,
				(Math.random() - 0.5) * SZ - 4
			);
			cube.rotation.set(
				Math.random() * Math.PI * 2,
				Math.random() * Math.PI * 2,
				Math.random() * Math.PI * 2
			);
			cube.userData = {
				rx: (Math.random() - 0.5) * 0.12,
				ry: (Math.random() - 0.5) * 0.12,
				rz: (Math.random() - 0.5) * 0.08,
				mat: mat,
			};
			this.group.add(cube);
			this.cubes.push(cube);
		}
	}

	update(dt, t) {
		for (let i = 0; i < this.cubes.length; i++) {
			const c = this.cubes[i];
			c.rotation.x += c.userData.rx * dt;
			c.rotation.y += c.userData.ry * dt;
			c.rotation.z += c.userData.rz * dt;
		}
		// shared subtle breath, in sync with NodeNetwork
		const breath = 0.85 + 0.15 * Math.sin(t * 0.6 + 0.7);
		for (let i = 0; i < this.cubes.length; i++) {
			this.cubes[i].userData.mat.opacity = this.opacityBase * breath;
		}
	}
}

class BackgroundScene {
	constructor(canvas) {
		this.canvas = canvas;
		this._visible = false;
		this._reducedMotion = window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches;
	}

	init() {
		this.renderer = new THREE.WebGLRenderer({
			canvas: this.canvas,
			antialias: true,
			alpha: true,
			powerPreference: 'low-power',
		});
		this.renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 1.5));
		this.renderer.setClearColor(0x000000, 0);

		this.scene = new THREE.Scene();
		this.camera = new THREE.PerspectiveCamera(56, 1, 0.1, 80);
		this.camera.position.set(0, 0, 14);
		this._resize();

		// Ambient confetti — softest layer
		this.particles = new ParticleField(this.scene, {
			isMobile: window.innerWidth < 800,
			opacityScale: 0.7 * INTENSITY,
		});

		// Node + line constellation — the rotating "validator network" feel
		this.network = new NodeNetwork(this.scene);

		// Wireframe boxes — smart-contract glyphs in the distance
		this.cubes = new BackgroundCubes(this.scene);

		window.addEventListener('resize', () => this._resize(), { passive: true });
		this._clock = new THREE.Clock();
	}

	_resize() {
		const w = this.canvas.clientWidth || window.innerWidth;
		const h = this.canvas.clientHeight || window.innerHeight;
		this.renderer.setSize(w, h, false);
		this.camera.aspect = w / Math.max(1, h);
		this.camera.updateProjectionMatrix();
	}

	start() {
		this.init();
		if (this._reducedMotion) {
			this.renderer.render(this.scene, this.camera);
			return;
		}
		this._tick();
	}

	setVisible(v) {
		this._visible = !!v;
		if (this._visible) this._clock.getDelta();   // avoid dt spike after pause
	}

	_tick() {
		requestAnimationFrame(() => this._tick());
		if (!this._visible) return;
		const dt = Math.min(this._clock.getDelta(), 0.05);
		const t = this._clock.elapsedTime;
		this.particles.update(dt);
		this.network.update(dt, t);
		this.cubes.update(dt, t);
		this.renderer.render(this.scene, this.camera);
	}
}

// ────────────────────────── boot
(() => {
	const canvas = document.querySelector('canvas.bg-canvas');
	if (!canvas) return;
	const scene = new BackgroundScene(canvas);
	scene.start();

	// SP layout (max-width: 768px): hero-3d is disabled (see hero-3d/main.js
	// — its event handlers blocked native scroll on mobile). Keep bg-3d
	// ALWAYS visible so the hero area isn't visually empty. bg-3d has zero
	// event listeners, so it's known-safe for scroll on mobile.
	// 同 breakpoint を styles.css の @media (max-width: 768px) と揃えている。
	const isMobile =
		typeof window.matchMedia === 'function' &&
		window.matchMedia('(max-width: 768px)').matches;

	const hero = document.querySelector('header.hero');
	if (hero && 'IntersectionObserver' in window && !isMobile) {
		// Desktop: pause bg-3d while hero is in view (hero-3d is rendering
		// there). Wasteful and visually busy to run both at once.
		const io = new IntersectionObserver((entries) => {
			for (let i = 0; i < entries.length; i++) {
				const heroVisible = entries[i].isIntersecting;
				scene.setVisible(!heroVisible);
				canvas.classList.toggle('is-visible', !heroVisible);
			}
		}, { threshold: 0.5 });
		io.observe(hero);
	} else {
		// Touch device, or no IO support: always-on background.
		scene.setVisible(true);
		canvas.classList.add('is-visible');
	}
})();
