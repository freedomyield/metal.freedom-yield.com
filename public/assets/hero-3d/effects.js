// Visual effects: transactions, broadcast rings, background particles.
import * as THREE from '/assets/vendor/three.module.min.js';
import { COLORS, easings, Pool, randRange } from './utils.js';

// ────────────────────────── TransactionLayer
// Streaks travelling between contracts along the peer mesh. Two flavours:
// ambient (1.0–2.4 s, soft mint) and burst (0.12–0.18 s, bright green,
// stretched comet shape, triggers flash on arrival recipient).
export class TransactionLayer {
	constructor(scene, options) {
		options = options || {};
		const size = options.poolSize || 24;
		this.scene = scene;
		this.onBurstArrival = options.onBurstArrival || function(){};
		this._tmpDir = new THREE.Vector3();
		this._tmpAxis = new THREE.Vector3(1, 0, 0);
		this.pool = new Pool(size, () => {
			// Larger sphere with additive blending → glow effect on top of
			// the dark background; the streaks really pop when this kicks in.
			const g = new THREE.SphereGeometry(0.12, 10, 10);
			const m = new THREE.MeshBasicMaterial({
				color: COLORS.txAmbient.clone(),
				transparent: true,
				opacity: 1.0,
				blending: THREE.AdditiveBlending,
				depthWrite: false,
			});
			const mesh = new THREE.Mesh(g, m);
			mesh.visible = false;
			scene.add(mesh);
			return { mesh, active: false, t: 0, dur: 1.0, from: null, to: null, isBurst: false };
		});
		this._nextAmbientAt = 0.8;
	}

	// Fire a single ambient streak along a random peer edge.
	fireAmbient(activeEdges) {
		if (activeEdges.length === 0) return;
		const slot = this.pool.acquire(x => !x.active);
		if (!slot) return;
		const edge = activeEdges[Math.floor(Math.random() * activeEdges.length)];
		slot.active = true;
		slot.t = 0;
		slot.dur = randRange(1.0, 2.4);
		slot.from = edge.a;
		slot.to = edge.b;
		slot.isBurst = false;
		slot.mesh.visible = true;
		slot.mesh.material.color.copy(COLORS.txAmbient);
		slot.mesh.quaternion.identity();
		slot.mesh.scale.setScalar(randRange(0.8, 1.4));
	}

	// Fire N burst streaks outward from `source` to its nearest neighbours.
	fireBurst(source, contracts, n) {
		const targets = [];
		for (let i = 0; i < contracts.length; i++) {
			const c = contracts[i];
			if (c === source || !c.isClickable) continue;
			targets.push({ contract: c, dist: source.position.distanceTo(c.position) });
		}
		targets.sort((a, b) => a.dist - b.dist);
		const N = Math.min(targets.length, n || 8);
		const dispatched = [];
		for (let i = 0; i < N; i++) {
			const slot = this.pool.acquire(x => !x.active);
			if (!slot) break;
			slot.active = true;
			slot.t = 0;
			slot.dur = randRange(0.12, 0.18);
			slot.from = source;
			slot.to = targets[i].contract;
			slot.isBurst = true;
			slot.mesh.visible = true;
			slot.mesh.material.color.copy(COLORS.txBurst);
			slot.mesh.material.opacity = 1.0;
			dispatched.push(targets[i].contract);
		}
		return { dispatched, targetPool: targets };
	}

	maybeFireAmbient(t, activeEdges) {
		if (t < this._nextAmbientAt) return;
		this._nextAmbientAt = t + randRange(0.4, 1.8);
		this.fireAmbient(activeEdges);
	}

	update(dt) {
		this.pool.forEach(x => {
			if (!x.active) return;
			x.t += dt;
			const p = x.t / x.dur;
			if (p >= 1 || !x.from || !x.to) {
				if (x.isBurst && x.to) this.onBurstArrival(x.to);
				x.active = false;
				x.mesh.visible = false;
				x.mesh.scale.setScalar(1);
				x.mesh.quaternion.identity();
				return;
			}
			const eased = easings.easeInOut(p);
			x.mesh.position.lerpVectors(x.from.position, x.to.position, eased);

			if (x.isBurst) {
				// Shooting-star streak — stretched along motion + glowing
				this._tmpDir.copy(x.to.position).sub(x.from.position).normalize();
				x.mesh.quaternion.setFromUnitVectors(this._tmpAxis, this._tmpDir);
				// Bigger streaks (1.5×) + longer tail
				const lenFactor = 5.0 + 6.0 * (1 - Math.abs(p - 0.5) * 2);
				x.mesh.scale.set(lenFactor, 1.5, 1.5);
				x.mesh.material.opacity = 1.0;
			} else {
				x.mesh.scale.setScalar(1);
				x.mesh.material.opacity = Math.min(1, (1 - p) * 1.8);
			}
		});
	}
}

// ────────────────────────── BroadcastRingLayer
// Expanding torus rings at the source of a click-burst, signalling
// "this contract just broadcasted".
export class BroadcastRingLayer {
	constructor(scene, options) {
		options = options || {};
		this.camera = options.camera;
		this.duration = options.duration || 0.9;
		this.pool = new Pool(options.poolSize || 12, () => {
			// Thicker tube + additive blending → ring glows
			const g = new THREE.TorusGeometry(0.6, 0.10, 12, 48);
			const m = new THREE.MeshBasicMaterial({
				color: COLORS.ringColor.clone(),
				transparent: true,
				opacity: 0,
				depthWrite: false,
				blending: THREE.AdditiveBlending,
			});
			const mesh = new THREE.Mesh(g, m);
			mesh.visible = false;
			scene.add(mesh);
			return { mesh, active: false, t: 0 };
		});
	}

	spawn(at) {
		const slot = this.pool.acquire(r => !r.active);
		if (!slot) return;
		slot.active = true;
		slot.t = 0;
		slot.mesh.position.copy(at);
		slot.mesh.visible = true;
		slot.mesh.scale.setScalar(0.001);
		slot.mesh.material.opacity = 1.0;
		if (this.camera) slot.mesh.lookAt(this.camera.position);
	}

	update(dt) {
		this.pool.forEach(r => {
			if (!r.active) return;
			r.t += dt;
			const p = r.t / this.duration;
			if (p >= 1) {
				r.active = false;
				r.mesh.visible = false;
				return;
			}
			r.mesh.scale.setScalar(0.001 + p * 5.0);
			r.mesh.material.opacity = 1.0 - p;
			if (this.camera) r.mesh.lookAt(this.camera.position);
		});
	}
}

// ────────────────────────── ParticleField
// Three depth layers of background star-particles (far / mid / near).
// Sized and densified to fill the viewport corners.
export class ParticleField {
	constructor(scene, options) {
		options = options || {};
		const isMobile = options.isMobile;
		// opacityScale lets callers tune brightness without changing
		// the underlying palette — bg-3d passes a lower value because
		// the kinetic background should be much more subtle than the
		// hero's busy scene.
		const oS = (typeof options.opacityScale === 'number') ? options.opacityScale : 1.0;
		// Light theme: particles need DARK dots so they're visible on the
		// cream page bg. Were bright white/blue on dark in the prior
		// design. Slate-blue at low opacity reads as soft confetti.
		this.layers = [
			this._makeLayer(scene, isMobile ? 140 : 260, {
				spreadX: 70, spreadY: 36, spreadZ: 6,
				zCenter: -10, color: 0x9aa3b6, size: 0.045, opacity: 0.55 * oS,
			}),
			this._makeLayer(scene, isMobile ? 110 : 200, {
				spreadX: 50, spreadY: 22, spreadZ: 8,
				zCenter: -2, color: 0x5b6577, size: 0.055, opacity: 0.45 * oS,
			}),
			this._makeLayer(scene, isMobile ?  60 : 100, {
				spreadX: 36, spreadY: 16, spreadZ: 5,
				zCenter: 5, color: 0x344155, size: 0.075, opacity: 0.4 * oS,
			}),
		];
		this.spinRates = [0.005, 0.015, 0.025];
	}

	_makeLayer(scene, count, opts) {
		const geo = new THREE.BufferGeometry();
		const pos = new Float32Array(count * 3);
		for (let i = 0; i < count; i++) {
			pos[i*3+0] = (Math.random() - 0.5) * opts.spreadX;
			pos[i*3+1] = (Math.random() - 0.5) * opts.spreadY;
			pos[i*3+2] = opts.zCenter + (Math.random() - 0.5) * opts.spreadZ;
		}
		geo.setAttribute('position', new THREE.Float32BufferAttribute(pos, 3));
		const mat = new THREE.PointsMaterial({
			color: opts.color,
			size: opts.size,
			transparent: true,
			opacity: opts.opacity,
			sizeAttenuation: true,
			depthWrite: false,
		});
		const pts = new THREE.Points(geo, mat);
		scene.add(pts);
		return pts;
	}

	update(dt) {
		for (let i = 0; i < this.layers.length; i++) {
			this.layers[i].rotation.y += this.spinRates[i] * dt;
			this.layers[i].rotation.x += this.spinRates[i] * 0.3 * dt;
		}
	}
}
