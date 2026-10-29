// Smart-contract cubes + the peer mesh that connects them.
import * as THREE from '/assets/vendor/three.module.min.js';
import { COLORS, PALETTES, SPAWN_REGION, CLICK_TIER_COLORS, easings, randRange } from './utils.js';

// ────────────────────────── Contract (one wireframe cube)
// A Contract is a Group containing:
//   • outerEdges  — the "container" (wireframe box)
//   • innerEdges  — the "code/data" inside (random poly: box/oct/tetra)
//   • core        — small bright sphere ("heartbeat")
// It owns its own animation state and palette. Render-side state mutates
// the underlying materials/scales each frame in update().
export class Contract {
	constructor(camera, options) {
		options = options || {};
		this.camera = camera;
		this.palette = options.palette || PALETTES.DEFAULT;
		this.baseScale = options.size || randRange(0.6, 2.0);

		const group = new THREE.Group();
		this.group = group;

		// Outer cube (wireframe edges only)
		const outerGeo = new THREE.BoxGeometry(this.baseScale, this.baseScale, this.baseScale);
		const outerMat = new THREE.LineBasicMaterial({
			color: this.palette.outer.clone(), transparent: true, opacity: 0.88,
		});
		this.outerEdges = new THREE.LineSegments(new THREE.EdgesGeometry(outerGeo), outerMat);
		group.add(this.outerEdges);
		outerGeo.dispose();

		// Inner shape — variety
		const innerGeo = Contract._makeInnerGeometry(this.baseScale);
		const innerMat = new THREE.LineBasicMaterial({
			color: this.palette.inner.clone(), transparent: true, opacity: 0.75,
		});
		this.innerEdges = new THREE.LineSegments(new THREE.EdgesGeometry(innerGeo), innerMat);
		group.add(this.innerEdges);
		innerGeo.dispose();

		// Core sphere
		const coreGeo = new THREE.SphereGeometry(this.baseScale * 0.08, 10, 10);
		const coreMat = new THREE.MeshBasicMaterial({
			color: this.palette.core.clone(), transparent: true, opacity: 0.95,
		});
		this.core = new THREE.Mesh(coreGeo, coreMat);
		group.add(this.core);

		// Initial pose
		group.position.copy(options.position || new THREE.Vector3());
		group.rotation.set(
			Math.random() * Math.PI * 2,
			Math.random() * Math.PI * 2,
			Math.random() * Math.PI * 2
		);
		group.scale.setScalar(options.initiallyVisible ? this.baseScale : 0.001);

		// Animation state
		this.spawnAge = options.initiallyVisible ? Infinity : 0;
		this.spawnDuration = 1.4;
		this.rotSpeed = new THREE.Vector3(
			randRange(-0.09, 0.09),
			randRange(-0.11, 0.11),
			randRange(-0.07, 0.07)
		);
		this.driftSpeed = new THREE.Vector3(
			randRange(-0.045, 0.045),
			randRange(-0.030, 0.030),
			randRange(-0.030, 0.030)
		);
		this.activationCooldown = randRange(2, 12);
		this.activationActive = 0;
		this.activationDuration = 1.0;
		this.innerSpinRate = randRange(0.4, 1.1);

		// Click / arrival flash
		this.flashTime = 0;
		this.flashDuration = 0;

		// Click-tier border colour. tier 0 = palette default; each click
		// increments the tier and copies the next rainbow colour into
		// targetOuter. The flash and idle branches in update() lerp /
		// copy FROM this colour so the cube's resting state follows the
		// tier rather than the original palette.
		this.clickCount = 0;
		this.targetOuter = this.palette.outer.clone();
	}

	registerClick() {
		this.clickCount += 1;
		const idx = (this.clickCount - 1) % CLICK_TIER_COLORS.length;
		this.targetOuter.copy(CLICK_TIER_COLORS[idx]);
	}

	static _makeInnerGeometry(size) {
		const r = Math.random();
		const s = size * 0.42;
		if (r < 0.55)      return new THREE.BoxGeometry(s, s, s);
		else if (r < 0.85) return new THREE.OctahedronGeometry(s * 0.7, 0);
		else               return new THREE.TetrahedronGeometry(s * 0.85, 0);
	}

	/** Trigger a green flash. scale > 1 → longer flash. */
	flash(scale) {
		this.flashTime = 0;
		this.flashDuration = 1.2 * (scale || 1.0);
	}

	// Clickable as soon as the cube has any visible scale at all. The
	// previous 20%-of-baseScale threshold created a brief dead zone at
	// the start of every spawn-in animation where the cube was visible
	// but unclickable — caused intermittent "click doesn't work"
	// reports on freshly-spawned purple contracts.
	get isClickable() {
		return this.group.scale.x > 0.05;
	}

	get position() { return this.group.position; }

	update(dt, t, i) {
		const ud = this;

		// Rotation + drift
		ud.group.rotation.x += ud.rotSpeed.x * dt;
		ud.group.rotation.y += ud.rotSpeed.y * dt;
		ud.group.rotation.z += ud.rotSpeed.z * dt;
		ud.group.position.x += ud.driftSpeed.x * dt;
		ud.group.position.y += ud.driftSpeed.y * dt;
		ud.group.position.z += ud.driftSpeed.z * dt;

		// Clamping in FIXED world-space bounds (camera-independent).
		// Previously used visibleHalfWidthAtZ which collapses when the
		// camera dollies in, squashing existing cubes into a narrow
		// vertical column — that's the "縦一列" bug the user kept
		// reporting. Bounds match SPAWN_REGION so cubes spawn and
		// drift within the same region forever.
		const B = SPAWN_REGION.bounds;
		const p = ud.group.position;
		if (p.x > B.maxX) { p.x = B.maxX; ud.driftSpeed.x = -Math.abs(ud.driftSpeed.x); }
		if (p.x < B.minX) { p.x = B.minX; ud.driftSpeed.x =  Math.abs(ud.driftSpeed.x); }
		if (p.y > B.maxY) { p.y = B.maxY; ud.driftSpeed.y = -Math.abs(ud.driftSpeed.y); }
		if (p.y < B.minY) { p.y = B.minY; ud.driftSpeed.y =  Math.abs(ud.driftSpeed.y); }
		if (p.z > B.maxZ) { p.z = B.maxZ; ud.driftSpeed.z = -Math.abs(ud.driftSpeed.z); }
		if (p.z < B.minZ) { p.z = B.minZ; ud.driftSpeed.z =  Math.abs(ud.driftSpeed.z); }

		// Inner spin (the "code executing" cue)
		ud.innerEdges.rotation.x += ud.innerSpinRate * dt * 0.8;
		ud.innerEdges.rotation.y += ud.innerSpinRate * dt;
		ud.innerEdges.rotation.z += ud.innerSpinRate * dt * 0.6;

		// Spawn-in animation (one-shot)
		if (ud.spawnAge !== Infinity) {
			ud.spawnAge += dt;
			const p = Math.min(1, ud.spawnAge / ud.spawnDuration);
			ud.group.scale.setScalar(Math.max(0.001, ud.baseScale * easings.outBack(p)));
			if (p >= 1) { ud.spawnAge = Infinity; ud.group.scale.setScalar(ud.baseScale); }
		}

		// Click / arrival flash → green ramp.
		// Uses ud.targetOuter (the click-tier border colour) as the
		// flash base, so the post-flash resting state lands on the
		// new tier colour instead of the original palette.
		const flashActive = ud.flashDuration > 0 && ud.flashTime < ud.flashDuration;
		if (flashActive) {
			ud.flashTime += dt;
			const fp = ud.flashTime / ud.flashDuration;
			let intensity;
			if (fp < 0.18)      intensity = fp / 0.18;
			else if (fp < 0.45) intensity = 1.0;
			else                intensity = (1 - fp) / 0.55;
			intensity = Math.max(0, intensity);
			ud.outerEdges.material.color.copy(ud.targetOuter).lerp(COLORS.flashTo, intensity);
			ud.outerEdges.material.opacity = 0.85 + 0.15 * intensity;
			ud.innerEdges.material.color.copy(ud.palette.inner).lerp(COLORS.innerFlash, intensity);
			ud.innerEdges.material.opacity = 0.75 + 0.25 * intensity;
			ud.core.material.color.copy(ud.palette.core).lerp(COLORS.coreFlash, intensity);
			ud.core.material.opacity = Math.max(0.6, 0.85 + 0.15 * intensity);
			ud.core.scale.setScalar(1 + 0.6 * intensity);
			ud.activationActive = 0;
			return;
		}

		// Idle activation flash (periodic, no user input)
		ud.activationCooldown -= dt;
		if (ud.activationCooldown <= 0 && ud.activationActive <= 0) {
			ud.activationActive = ud.activationDuration;
			ud.activationCooldown = randRange(4, 14);
		}
		if (ud.activationActive > 0) {
			ud.activationActive -= dt;
			const flash = Math.max(0, ud.activationActive / ud.activationDuration);
			ud.core.material.opacity = 1.0;
			ud.core.scale.setScalar(1 + 0.9 * flash);
			ud.outerEdges.material.opacity = 0.88 + 0.12 * flash;
			ud.outerEdges.material.color.copy(ud.targetOuter).lerp(COLORS.white, flash * 0.4);
		} else {
			const pulse = 0.7 + 0.3 * Math.sin(t * 1.4 + i * 0.7);
			ud.core.material.opacity = pulse;
			ud.core.scale.setScalar(1);
			ud.core.material.color.copy(ud.palette.core);
			ud.outerEdges.material.opacity = 0.88;
			ud.outerEdges.material.color.copy(ud.targetOuter);
			ud.innerEdges.material.color.copy(ud.palette.inner);
			ud.innerEdges.material.opacity = 0.75;
		}
	}
}

// ────────────────────────── PeerMesh
// Lines between nearby contracts, dual brightness (near / far). Rebuilt
// every ~0.15 s as cubes drift.
export class PeerMesh {
	constructor(scene) {
		// Light theme: lines need darker pigments to be visible on cream.
		this.matNear = new THREE.LineBasicMaterial({ color: 0x10b386, transparent: true, opacity: 0.50 });
		this.matFar  = new THREE.LineBasicMaterial({ color: 0x344155, transparent: true, opacity: 0.20 });
		this.lineNear = new THREE.LineSegments(new THREE.BufferGeometry(), this.matNear);
		this.lineFar  = new THREE.LineSegments(new THREE.BufferGeometry(), this.matFar);
		scene.add(this.lineNear);
		scene.add(this.lineFar);
		this.edges = [];  // {a, b} contract pairs for tx routing
		this._lastBuild = -Infinity;
	}

	get activeEdges() { return this.edges; }

	rebuild(contracts) {
		const NEAR_DIST = 5.0;
		const FAR_DIST = 8.0;
		const nearPos = [];
		const farPos = [];
		this.edges = [];
		for (let i = 0; i < contracts.length; i++) {
			if (!contracts[i].isClickable) continue;
			for (let j = i + 1; j < contracts.length; j++) {
				if (!contracts[j].isClickable) continue;
				const d = contracts[i].position.distanceTo(contracts[j].position);
				if (d < NEAR_DIST) {
					nearPos.push(
						contracts[i].position.x, contracts[i].position.y, contracts[i].position.z,
						contracts[j].position.x, contracts[j].position.y, contracts[j].position.z
					);
					this.edges.push({ a: contracts[i], b: contracts[j] });
				} else if (d < FAR_DIST) {
					farPos.push(
						contracts[i].position.x, contracts[i].position.y, contracts[i].position.z,
						contracts[j].position.x, contracts[j].position.y, contracts[j].position.z
					);
				}
			}
		}
		this.lineNear.geometry.dispose();
		this.lineFar.geometry.dispose();
		const gn = new THREE.BufferGeometry();
		gn.setAttribute('position', new THREE.Float32BufferAttribute(nearPos, 3));
		this.lineNear.geometry = gn;
		const gf = new THREE.BufferGeometry();
		gf.setAttribute('position', new THREE.Float32BufferAttribute(farPos, 3));
		this.lineFar.geometry = gf;
	}

	maybeRebuild(t, contracts, interval) {
		if (t - this._lastBuild < (interval || 0.15)) return;
		this._lastBuild = t;
		this.rebuild(contracts);
	}

	updateBreath(t) {
		const breathe = 0.7 + 0.3 * Math.sin(t * 0.7);
		this.lineNear.material.opacity = 0.45 + 0.20 * breathe;
		this.lineFar.material.opacity  = 0.15 + 0.12 * breathe;
	}
}
