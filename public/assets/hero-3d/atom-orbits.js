// atom-orbits.js — Proton / XPR Network atom symbol around the hero cluster.
//
// Visual: three thin torus rings at classic-atom angles, encompassing the
// cube cluster centred at (9, 0, -1.5). Each ring carries one small
// "electron" sphere that orbits along it. The whole atom slowly tumbles
// so the rings catch the eye without ever feeling busy.
//
// Decorative only — no raycasting, no click interaction, no influence on
// any existing hero-3d module. Per [[feedback_hero_3d_tuning]] we extend
// by ADDING modules, never editing existing ones.
//
// prefers-reduced-motion fully respected: rings still render (static
// proton-symbol mark) but rotation + electron orbit halt.

import * as THREE from '/assets/vendor/three.module.min.js';
import { SPAWN_REGION, prefersReducedMotion } from './utils.js';

export class AtomOrbits {
	constructor(scene, options = {}) {
		this.scene = scene;
		this.reduceMotion = prefersReducedMotion();

		// Anchor the atom on the cluster centroid so the cubes sit inside
		// the orbits. SPAWN_REGION.centre = (9, 0, -1.5), radius = 7;
		// base radius 12 — the proton sits closely around the cluster at
		// the default contract count; the update() loop scales it up as
		// more cubes accumulate (sqrt of count ratio, see below).
		const center = SPAWN_REGION && SPAWN_REGION.centre ? SPAWN_REGION.centre : { x: 9, y: 0, z: -1.5 };
		this.radius = options.radius || 12;

		this.group = new THREE.Group();
		this.group.position.set(center.x, center.y, center.z);

		// Three rings at classic atom-symbol tilts. Each Euler is rotated
		// off two axes so the rings clearly diverge in 3D space (mutually
		// at ~60° as in the Proton wordmark).
		const tilts = [
			new THREE.Euler(0,             0,                 0),
			new THREE.Euler( Math.PI / 3,  Math.PI / 4,       0),
			new THREE.Euler(-Math.PI / 3, -Math.PI / 4,       0),
		];

		// Metallicus rainbow — three distinct positions on the brand
		// gradient (red / green / violet) so the atom reads as Metallicus
		// chrome, NOT as the validator's mint accent. Each electron uses
		// the same hue as its ring (just opaque + slightly larger) so the
		// ring + electron read as one unit per orbit.
		// Same hex stops used by atmosphere-band-tint, footer top border,
		// and acknowledgments accents.
		const ringColors = [
			0xdc323c,  // ring 1 — red
			0x3caa5a,  // ring 2 — green
			0x6e32aa,  // ring 3 — violet
		];
		const electronColors = ringColors.slice();   // same hues, opaque

		this.rings = [];
		this.electrons = [];

		for (let i = 0; i < 3; i++) {
			// Torus geometry — thin ring, smooth circumference. Tube
			// proportional to base radius; uniform group.scale in update()
			// scales tube alongside the radius so line weight stays
			// proportional as the proton grows.
			const ringGeom = new THREE.TorusGeometry(this.radius, 0.05, 8, 128);
			const ringMat = new THREE.MeshBasicMaterial({
				color: ringColors[i],
				transparent: true,
				opacity: 0.45,
				depthWrite: false,
			});
			const ring = new THREE.Mesh(ringGeom, ringMat);
			ring.setRotationFromEuler(tilts[i]);
			ring.renderOrder = -1;       // draw before cubes so cubes overlay
			this.rings.push(ring);
			this.group.add(ring);

			// Electron — small sphere riding along the torus circumference.
			// Bright unlit material so it pops against the ring even at low
			// opacity. Scales with the group when the proton grows.
			const eGeom = new THREE.SphereGeometry(0.14, 14, 14);
			const eMat  = new THREE.MeshBasicMaterial({
				color: electronColors[i],
				transparent: true,
				opacity: 0.95,
			});
			const electron = new THREE.Mesh(eGeom, eMat);
			electron.userData = {
				ringIndex: i,
				angle: (i / 3) * Math.PI * 2,   // stagger initial positions
				speed: 0.55 + i * 0.12,         // each electron at its own rate
			};
			this.electrons.push(electron);
			this.group.add(electron);
		}

		this._tiltVecs = tilts;   // keep for electron orbit math
		scene.add(this.group);
	}

	update(dt /* seconds */, t /* total seconds */, contracts /* optional */) {
		// Dynamic ring size — the proton symbol is the container; as more
		// smart contracts (cubes) accumulate inside, the rings expand so
		// the blockchain visibly *fills* the proton rather than spilling
		// out. Growth is sub-linear (sqrt of count ratio) so it feels
		// like the contained volume scaling rather than runaway expansion.
		//
		// Formula:
		//   target_scale = sqrt(max(count, base) / base)
		//   base = 30 (cubeCountDesktop default)
		// At default ~30 cubes the atom sits at radius 12 (scale 1.0).
		// At 70 cubes (cap) it scales to ~sqrt(70/30)=1.53× → radius ~18.
		// Lerp smoothly each frame to avoid jumps when bursts spawn cubes.
		const baseCount = 30;
		const count = (contracts && contracts.length) ? contracts.length : baseCount;
		const targetScale = Math.sqrt(Math.max(count, baseCount) / baseCount);
		if (typeof this._scale !== 'number') this._scale = targetScale;
		// 0.6/sec lerp — visible expansion over ~3 seconds, never abrupt
		this._scale += (targetScale - this._scale) * Math.min(dt * 0.6, 1);
		this.group.scale.setScalar(this._scale);

		if (this.reduceMotion) return;

		// Whole atom slowly tumbles — small angles so it never disorients
		// the viewer who's reading the hero text below.
		this.group.rotation.y += dt * 0.045;
		this.group.rotation.x += dt * 0.018;

		// Each electron orbits along its ring's plane. We recompute the
		// position in the ring's local frame (cos, sin) then apply that
		// ring's tilt to land the point in scene space.
		for (let i = 0; i < this.electrons.length; i++) {
			const e = this.electrons[i];
			e.userData.angle += dt * e.userData.speed;
			const a = e.userData.angle;
			const local = new THREE.Vector3(
				Math.cos(a) * this.radius,
				Math.sin(a) * this.radius,
				0
			);
			local.applyEuler(this._tiltVecs[e.userData.ringIndex]);
			e.position.copy(local);
		}
	}

	dispose() {
		for (const r of this.rings) {
			r.geometry.dispose();
			r.material.dispose();
		}
		for (const e of this.electrons) {
			e.geometry.dispose();
			e.material.dispose();
		}
		this.scene.remove(this.group);
	}
}
