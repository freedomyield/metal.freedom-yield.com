// Camera + input controllers.
// CameraController: target-position smoothing, drag pan, wheel/pinch zoom.
//   *** focus dolly removed ***
//   The focus mechanism made the camera follow a clicked cube, which
//   suppressed zoomZ and silently broke wheel/pinch/keyboard zoom. It
//   also changed halfWidth mid-interaction and produced inconsistent
//   click selection. The hero now reacts to clicks purely through the
//   burst/flash/ring effects — the camera is owned by the user (drag,
//   wheel, keys) and only modulated by mouse parallax.
// InputController : mouse + touch + keyboard, normalised to a small event API.
import * as THREE from '/assets/vendor/three.module.min.js';
import { visibleHalfWidthAtZ, clamp } from './utils.js';

// ────────────────────────── CameraController
export class CameraController {
	constructor(camera, options) {
		options = options || {};
		this.camera = camera;
		this.cfg = {
			zoomMin:   options.zoomMin   || 6,
			zoomMax:   options.zoomMax   || 26,
			lerpRate:  options.idleLerpRate  || 0.9,
			mouseParallaxX: options.mouseParallaxX || 4.8,
			mouseParallaxY: options.mouseParallaxY || 3.0,
			dragLimit: options.dragLimit || 7.0,
			dragInertia: options.dragInertia || 0.93,
		};
		this.cameraTargetPos = new THREE.Vector3(0, 0, 14);
		this.cameraTargetLook = new THREE.Vector3(-1, 0, 0);
		this.currentLook = new THREE.Vector3(-1, 0, 0);
		this.zoomZ = 14;
		this.zoomZTarget = 14;
		this.mouseTarget = { x: 0, y: 0 };
		this.mouseOffset = { x: 0, y: 0 };
		this.dragOffset = { x: 0, y: 0 };
		this.dragVelocity = { x: 0, y: 0 };  // for inertia
	}

	// External API ----------------------------------------------------
	addDrag(dx, dy) {
		this.dragOffset.x = clamp(this.dragOffset.x - dx * 0.04, -this.cfg.dragLimit, this.cfg.dragLimit);
		this.dragOffset.y = clamp(this.dragOffset.y + dy * 0.04, -this.cfg.dragLimit, this.cfg.dragLimit);
		this.dragVelocity.x = -dx * 0.04;
		this.dragVelocity.y =  dy * 0.04;
	}

	resetDrag() {
		this.dragOffset.x = 0;
		this.dragOffset.y = 0;
		this.dragVelocity.x = 0;
		this.dragVelocity.y = 0;
	}

	setMouseTarget(nx, ny) {
		this.mouseTarget.x = nx;
		this.mouseTarget.y = ny;
	}

	wheel(deltaY, sensitivity) {
		this.zoomZTarget = clamp(this.zoomZTarget + deltaY * (sensitivity || 0.06), this.cfg.zoomMin, this.cfg.zoomMax);
	}

	pinch(zoomDelta) {
		// zoomDelta: positive = pinch out → zoom in (decrease z)
		this.zoomZTarget = clamp(this.zoomZTarget - zoomDelta * 4.0, this.cfg.zoomMin, this.cfg.zoomMax);
	}

	// Per-frame ------------------------------------------------------
	update(dt, t, contracts, isDraggingNow) {
		// Smooth mouse parallax + zoom
		this.mouseOffset.x += (this.mouseTarget.x * this.cfg.mouseParallaxX - this.mouseOffset.x) * Math.min(1, dt * 2.0);
		this.mouseOffset.y += (this.mouseTarget.y * this.cfg.mouseParallaxY - this.mouseOffset.y) * Math.min(1, dt * 2.0);
		this.zoomZ += (this.zoomZTarget - this.zoomZ) * Math.min(1, dt * 3.0);

		// Drag inertia: only when NOT actively dragging
		if (!isDraggingNow) {
			this.dragOffset.x = clamp(this.dragOffset.x + this.dragVelocity.x, -this.cfg.dragLimit, this.cfg.dragLimit);
			this.dragOffset.y = clamp(this.dragOffset.y + this.dragVelocity.y, -this.cfg.dragLimit, this.cfg.dragLimit);
			this.dragVelocity.x *= this.cfg.dragInertia;
			this.dragVelocity.y *= this.cfg.dragInertia;
			if (Math.abs(this.dragVelocity.x) < 0.001) this.dragVelocity.x = 0;
			if (Math.abs(this.dragVelocity.y) < 0.001) this.dragVelocity.y = 0;
		}

		// Cluster centroid (in world X) — used for both the look-at
		// anchor and the camera-X approach below.
		const halfWNow = visibleHalfWidthAtZ(this.camera, 0);
		let cx = 16, n = 0, sum = 0;
		for (let i = 0; i < contracts.length; i++) {
			if (contracts[i].isClickable) { sum += contracts[i].position.x; n++; }
		}
		if (n > 0) cx = sum / n;

		// Camera X "approach" — as the user wheels in past zoomZ=6 the
		// camera anchor slides from x=0 toward the cluster centroid X,
		// so wheel-zoom flies INTO the cluster instead of stopping
		// outside it. At default zoom and further out, anchor stays at
		// x=0 to preserve the hero composition.
		//   zoomZ ≥ APPROACH_START : approachT = 0 (camera at x=0)
		//   zoomZ ≤ APPROACH_END   : approachT = 1 (camera at x=cx)
		const APPROACH_START = 6;
		const APPROACH_END   = -5;
		const approachT = clamp((APPROACH_START - this.zoomZ) / (APPROACH_START - APPROACH_END), 0, 1);
		const cameraApproachX = cx * approachT;

		this.cameraTargetPos.set(
			cameraApproachX + Math.sin(t * 0.07) * 0.5 + this.mouseOffset.x + this.dragOffset.x,
			Math.sin(t * 0.05) * 0.35 + this.mouseOffset.y + this.dragOffset.y,
			this.zoomZ
		);

		// Look-at anchor fade — hard-coded range (NOT zoomMin/zoomMax)
		// so changing the zoom limits doesn't shift the default-zoom
		// composition. The hero's idle look at zoomZ=14 stays the same
		// regardless of whether zoomMin is 6 or -5.
		//   zoomZ ≤ LOOK_FADE_MIN : cluster centred (anchor 0)
		//   zoomZ ≥ LOOK_FADE_MAX : cluster pinned to NDC +0.65 (right)
		const LOOK_FADE_MIN = 6;
		const LOOK_FADE_MAX = 26;
		const lookT = clamp((this.zoomZ - LOOK_FADE_MIN) / (LOOK_FADE_MAX - LOOK_FADE_MIN), 0, 1);
		const anchorOffset = 0.65 * lookT;
		this.cameraTargetLook.set(cx - anchorOffset * halfWNow, 0, 0);

		// Exponential smoothing — gentle glide
		const alpha = 1 - Math.exp(-this.cfg.lerpRate * Math.max(0.001, dt) * 4.0);
		this.camera.position.lerp(this.cameraTargetPos, Math.min(1, alpha));
		this.currentLook.lerp(this.cameraTargetLook, Math.min(1, alpha));
		this.camera.lookAt(this.currentLook);
	}
}

// ────────────────────────── InputController
// Mouse + touch + keyboard. Reports normalised "intents" via callbacks:
//   onPick(ev)          → user clicked / tapped on a contract
//   onDoubleAction(ev)  → user double-clicked / double-tapped
//   onHoverChange(hit)  → cursor moved, hit = picked contract or null
//   onKey(action)       → 'reset' | 'random-burst' | 'zoom-in' | 'zoom-out'
//   onScrollZoom(delta) → wheel
//   onPinch(delta)      → pinch zoom (touch)
//   onDrag(dx, dy)      → drag motion in pixels
//   pickContract(ev)    → app-supplied picker, returns the cube under
//                         the cursor or null (single algorithm — there
//                         is no separate "click fallback" mode)
export class InputController {
	constructor(canvas, hostEl, callbacks) {
		this.canvas = canvas;
		this.hostEl = hostEl || canvas;
		this.cb = callbacks;
		this.dragging = false;
		this.dragLast = { x: 0, y: 0 };
		this.dragMoved = 0;
		this.lastMouseEv = null;
		this.cursorRefreshT = 0;
		// Pinch state
		this.pinchActive = false;
		this.pinchPrevDist = 0;
		this._install();
	}

	getLastMouseEv() { return this.lastMouseEv; }
	isDragging() { return this.dragging; }

	_install() {
		const c = this.canvas;
		const host = this.hostEl;

		// ── mouse ─────────────────────────────────────────────────
		c.addEventListener('mousemove', (ev) => {
			this.lastMouseEv = ev;
			const rect = c.getBoundingClientRect();
			const nx = ((ev.clientX - rect.left) / rect.width) * 2 - 1;
			const ny = -((ev.clientY - rect.top) / rect.height) * 2 + 1;
			this.cb.onPointerMove && this.cb.onPointerMove(nx, ny);

			if (this.dragging) {
				const dx = ev.clientX - this.dragLast.x;
				const dy = ev.clientY - this.dragLast.y;
				this.dragLast.x = ev.clientX;
				this.dragLast.y = ev.clientY;
				this.dragMoved += Math.abs(dx) + Math.abs(dy);
				// Only treat as a real drag once cumulative motion exceeds
				// a threshold — this avoids classifying tiny incidental
				// motions (Mac trackpad) as drags and suppressing onPick.
				if (this.dragMoved > 8) {
					this.wasDrag = true;
					this.cb.onDrag && this.cb.onDrag(dx, dy);
				}
				c.style.cursor = 'grabbing';
				return;
			}
			const hit = this.cb.pickContract(ev);
			c.style.cursor = hit ? 'pointer' : 'grab';
			this.cb.onHoverChange && this.cb.onHoverChange(hit);
		}, { passive: true });

		c.addEventListener('mouseleave', () => {
			this.cb.onPointerMove && this.cb.onPointerMove(0, 0);
			this.dragging = false;
			c.style.cursor = 'default';
		});

		c.addEventListener('mousedown', (ev) => {
			this.dragging = true;
			this.wasDrag = false;
			this.dragLast.x = ev.clientX;
			this.dragLast.y = ev.clientY;
			this.dragMoved = 0;
			c.style.cursor = 'grabbing';
		});

		c.addEventListener('mouseup', (ev) => {
			this.dragging = false;
			const hit = this.cb.pickContract(ev);
			c.style.cursor = hit ? 'pointer' : 'grab';
		});

		// Window-level mouseup safety net
		window.addEventListener('mouseup', () => {
			if (this.dragging) { this.dragging = false; c.style.cursor = 'grab'; }
		});

		// Use the browser-native click event (which already debounces
		// "down → up with small motion"). Skip only if we registered a
		// real drag during this interaction. This is far more reliable
		// than our own dragMoved threshold, especially on Mac trackpads
		// where a tap can produce 8–12 px of incidental motion.
		c.addEventListener('click', (ev) => {
			if (this.wasDrag) return;
			this.cb.onPick && this.cb.onPick(ev);
		});
		c.addEventListener('dblclick', (ev) => {
			ev.preventDefault();
			this.cb.onDoubleAction && this.cb.onDoubleAction(ev);
		});

		// ── wheel ─────────────────────────────────────────────────
		host.addEventListener('wheel', (ev) => {
			ev.preventDefault();
			this.cb.onScrollZoom && this.cb.onScrollZoom(ev.deltaY);
		}, { passive: false });

		// ── touch ─────────────────────────────────────────────────
		// Direction detection: on mobile, vertical-dominant drags should
		// scroll the page (not rotate the 3D). On the first ~8 px of motion
		// we lock the gesture's intent; vertical-dominant releases drag-rotate
		// so the browser can scroll natively. CSS `touch-action: pan-y` alone
		// is unreliable on Brave/Chromium-Android because preventDefault on
		// a non-passive touchmove can still override the hint.
		c.addEventListener('touchstart', (ev) => {
			if (ev.touches.length === 1) {
				const t = ev.touches[0];
				this.dragging = true;
				this.dragLast.x = t.clientX;
				this.dragLast.y = t.clientY;
				this.dragMoved = 0;
				this.touchStartX = t.clientX;
				this.touchStartY = t.clientY;
				this.touchDir = null; // 'vertical' | 'horizontal' | null=未確定
			} else if (ev.touches.length === 2) {
				this.pinchActive = true;
				this.pinchPrevDist = this._pinchDist(ev.touches);
				this.dragging = false;
				this.touchDir = null;
			}
		}, { passive: true });

		c.addEventListener('touchmove', (ev) => {
			if (this.pinchActive && ev.touches.length === 2) {
				const d = this._pinchDist(ev.touches);
				const delta = (d - this.pinchPrevDist) / 50;   // normalize
				this.pinchPrevDist = d;
				this.cb.onPinch && this.cb.onPinch(delta);
				ev.preventDefault();
			} else if (this.dragging && ev.touches.length === 1) {
				const t = ev.touches[0];

				// First-cycle direction detection — once per gesture.
				if (this.touchDir === null) {
					const totalDx = t.clientX - this.touchStartX;
					const totalDy = t.clientY - this.touchStartY;
					if (Math.abs(totalDx) + Math.abs(totalDy) > 8) {
						if (Math.abs(totalDy) > Math.abs(totalDx)) {
							// Vertical → user is scrolling the page.
							// Release drag and don't preventDefault so the
							// browser handles native scroll for the rest
							// of the gesture.
							this.touchDir = 'vertical';
							this.dragging = false;
							return;
						}
						this.touchDir = 'horizontal';
					}
				}

				// Horizontal drag-rotate (also covers the undecided early
				// frames, which only have <=8 px of total motion).
				const dx = t.clientX - this.dragLast.x;
				const dy = t.clientY - this.dragLast.y;
				this.dragLast.x = t.clientX;
				this.dragLast.y = t.clientY;
				this.dragMoved += Math.abs(dx) + Math.abs(dy);
				this.cb.onDrag && this.cb.onDrag(dx, dy);
				ev.preventDefault();
			}
		}, { passive: false });

		c.addEventListener('touchend', (ev) => {
			if (this.pinchActive && ev.touches.length < 2) this.pinchActive = false;
			if (this.dragging && this.dragMoved < 12 && ev.changedTouches.length > 0) {
				const t = ev.changedTouches[0];
				const fakeEv = { clientX: t.clientX, clientY: t.clientY };
				this.cb.onPick && this.cb.onPick(fakeEv);
			}
			if (ev.touches.length === 0) this.dragging = false;
		}, { passive: true });

		// ── keyboard ──────────────────────────────────────────────
		window.addEventListener('keydown', (ev) => {
			// Only act on global keys when the user isn't typing in an input
			const tag = (ev.target && ev.target.tagName) || '';
			if (tag === 'INPUT' || tag === 'TEXTAREA' || ev.metaKey || ev.ctrlKey || ev.altKey) return;
			switch (ev.key) {
				case 'Escape':
				case ' ':
					this.cb.onKey && this.cb.onKey('reset');
					break;
				case 'r':
				case 'R':
					this.cb.onKey && this.cb.onKey('random-burst');
					break;
				case '+':
				case '=':
					this.cb.onKey && this.cb.onKey('zoom-in');
					break;
				case '-':
				case '_':
					this.cb.onKey && this.cb.onKey('zoom-out');
					break;
			}
		});
	}

	_pinchDist(touches) {
		const a = touches[0], b = touches[1];
		return Math.hypot(a.clientX - b.clientX, a.clientY - b.clientY);
	}

	// Called from the main update loop so stationary cursors still refresh.
	tickCursorRefresh(dt) {
		this.cursorRefreshT += dt;
		if (this.cursorRefreshT > 0.2 && this.lastMouseEv && !this.dragging) {
			this.cursorRefreshT = 0;
			const hit = this.cb.pickContract(this.lastMouseEv, false);
			this.canvas.style.cursor = hit ? 'pointer' : 'grab';
		}
	}
}
