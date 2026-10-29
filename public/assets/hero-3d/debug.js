// Hero 3D debug overlay.
//
// Activated by `?debug=hero` (or `?debug=1`) on the page URL. Provides:
//   1. Numbered labels on every contract so users can identify cubes
//      by index ("#3 doesn't respond to clicks")
//   2. Floating bug button → opens a slide-out Diagnostics panel with
//      a "Copy all" button so the user can paste click logs back to me
//      without using DevTools.
//
// Production users never load this file — `import()` is lazy and gated
// on the URL flag in main.js.
import * as THREE from '/assets/vendor/three.module.min.js';

const MAX_ENTRIES = 200;

export class DebugOverlay {
	constructor(canvas, host) {
		this.canvas = canvas;
		this.host = host || canvas.parentElement;
		this.labels = [];
		this.entries = [];
		this.sessionId = this._mkSessionId();
		this._tmp = new THREE.Vector3();
		this._lastHoverIdx = -2;
		this._build();
		this.log('INFO', 'init', 'session=' + this.sessionId, {
			userAgent: navigator.userAgent,
			viewport: { w: window.innerWidth, h: window.innerHeight },
			devicePixelRatio: window.devicePixelRatio,
		});
	}

	// ──────────────────────────────────────── public API ─────────────
	log(level, name, summary, data) {
		const entry = {
			ts: new Date(),
			level,
			name,
			summary: summary || '',
			data: data || null,
		};
		this.entries.push(entry);
		if (this.entries.length > MAX_ENTRIES) this.entries.shift();
		this._renderEntry(entry);
	}

	update(contracts, camera, pickedClick, pickedHover, extra) {
		this._syncCubeLabels(contracts, camera, pickedClick, pickedHover);
		this._updateHud(contracts, pickedHover, extra);

		// Log hover changes only when the picked cube changes (otherwise
		// the buffer fills up immediately).
		const hoverIdx = pickedHover ? contracts.indexOf(pickedHover) : -1;
		if (hoverIdx !== this._lastHoverIdx) {
			this._lastHoverIdx = hoverIdx;
			if (hoverIdx >= 0) {
				this.log('INFO', 'hover', '#' + hoverIdx, {
					i: hoverIdx,
					baseScale: +pickedHover.baseScale.toFixed(2),
					position: this._posTriple(pickedHover.position),
				});
			}
		}
	}

	logClick(ev, contracts, raycaster, picked) {
		const idx = picked ? contracts.indexOf(picked) : -1;
		const rect = this.canvas.getBoundingClientRect();
		const rows = [];
		for (let i = 0; i < contracts.length; i++) {
			const c = contracts[i];
			const perp = raycaster.ray.distanceToPoint(c.position);
			const r = Math.max((c.baseScale || 1.0) * 0.9, 0.8);
			rows.push({
				i,
				clickable: c.isClickable,
				baseScale: +c.baseScale.toFixed(2),
				perp: +perp.toFixed(2),
				normPerp: +(perp / r).toFixed(2),
				x: +c.position.x.toFixed(1),
				y: +c.position.y.toFixed(1),
				z: +c.position.z.toFixed(1),
				scale: +c.group.scale.x.toFixed(2),
				picked: i === idx,
			});
		}
		rows.sort((a, b) => a.normPerp - b.normPerp);
		this.log('INFO', 'click',
			'picked=' + (idx >= 0 ? '#' + idx : '(none)') +
			' at (' + Math.round(ev.clientX - rect.left) + ',' + Math.round(ev.clientY - rect.top) + ')',
			{
				clickPx:  { x: Math.round(ev.clientX - rect.left), y: Math.round(ev.clientY - rect.top) },
				picked:   idx,
				topScores: rows.slice(0, 8),
				totalCubes: contracts.length,
				clickableCount: rows.filter(r => r.clickable).length,
			}
		);
	}

	// ──────────────────────────────────────── DOM ────────────────────
	_build() {
		// Floating bug button (always visible while debug=on)
		const btn = document.createElement('button');
		btn.type = 'button';
		btn.setAttribute('aria-label', 'Open diagnostics panel');
		btn.style.cssText = [
			'position:fixed', 'right:18px', 'bottom:18px',
			'width:48px', 'height:48px',
			'border-radius:50%',
			'border:1px solid #f1c40f',
			'background:rgba(20,20,30,0.85)',
			'color:#f1c40f',
			'cursor:pointer',
			'z-index:99998',
			'box-shadow:0 4px 20px rgba(0,0,0,0.5)',
			'display:flex', 'align-items:center', 'justify-content:center',
			'padding:0',
			'transition:transform 0.15s ease',
		].join(';');
		btn.innerHTML =
			'<svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">' +
			'<ellipse cx="12" cy="13" rx="6" ry="7"/>' +
			'<path d="M12 6V4M12 6 9 3M12 6l3-3"/>' +
			'<path d="M6 10 3 9M6 10 3 12"/>' +
			'<path d="M18 10l3-1M18 10l3 2"/>' +
			'<path d="M6 15l-3 1M6 15l-3 3"/>' +
			'<path d="M18 15l3 1M18 15l3 3"/>' +
			'<path d="M12 13v6"/>' +
			'</svg>';
		btn.addEventListener('mouseenter', () => { btn.style.transform = 'scale(1.08)'; });
		btn.addEventListener('mouseleave', () => { btn.style.transform = 'scale(1.0)'; });
		btn.addEventListener('click', () => this._togglePanel());
		document.body.appendChild(btn);
		this.btn = btn;

		// Slide-out panel — slides in from the LEFT so the right-side
		// hero cubes stay clickable. Built entirely via createElement +
		// el.style (CSSOM) because the site CSP is `style-src 'self'`
		// with no `'unsafe-inline'` — inline `style="..."` attributes
		// in innerHTML are stripped by the parser.
		const panel = document.createElement('div');
		panel.style.cssText = [
			'position:fixed', 'top:0', 'left:0', 'bottom:0',
			'width:min(720px, 60vw)',
			'background:rgba(8,10,18,0.97)',
			'color:#e8eef8',
			'font-family:ui-monospace,Menlo,Consolas,monospace',
			'font-size:12px', 'line-height:1.45',
			'z-index:99999',
			'transform:translateX(-100%)',
			'transition:transform 0.25s ease',
			'border-right:1px solid rgba(241,196,15,0.4)',
			'box-shadow:8px 0 28px rgba(0,0,0,0.6)',
			'display:flex', 'flex-direction:column',
		].join(';');

		const mk = (tag, css, text) => {
			const el = document.createElement(tag);
			if (css) el.style.cssText = css;
			if (text != null) el.textContent = text;
			return el;
		};

		// ── header
		const head = mk('div', 'padding:18px 20px 6px');
		const headRow = mk('div', 'display:flex;align-items:flex-start;justify-content:space-between;gap:14px');
		const headLeft = mk('div', 'min-width:0;flex:1');
		headLeft.appendChild(mk('div', 'font-size:22px;font-weight:700;color:#fff;letter-spacing:-0.01em', 'Diagnostics'));
		headLeft.appendChild(mk('div', 'opacity:0.6;font-size:12px;margin-top:4px;line-height:1.5',
			'In-app log viewer. Append ?debug=hero (or ?debug=1) to any URL to re-enable.'));
		const headRight = mk('div', 'display:flex;gap:8px;flex-shrink:0;white-space:nowrap');
		const btnHide  = mk('button', 'background:transparent;color:#cdd6ea;border:1px solid rgba(120,135,170,0.45);border-radius:10px;padding:8px 14px;font:inherit;font-size:12px;cursor:pointer;display:inline-flex;align-items:center;gap:6px;white-space:nowrap', '✕  Hide debug button');
		const btnClose = mk('button', 'background:transparent;color:#cdd6ea;border:1px solid rgba(120,135,170,0.45);border-radius:10px;padding:8px 14px;font:inherit;font-size:12px;cursor:pointer;white-space:nowrap', 'Close');
		btnHide.type  = 'button';
		btnClose.type = 'button';
		headRight.appendChild(btnHide);
		headRight.appendChild(btnClose);
		headRow.appendChild(headLeft);
		headRow.appendChild(headRight);
		head.appendChild(headRow);

		// ── tabs (pill row, like the reference design)
		const tabsWrap = mk('div', 'padding:14px 20px 6px');
		const tabs = mk('div', 'display:inline-flex;background:rgba(255,255,255,0.04);border:1px solid rgba(255,255,255,0.06);border-radius:14px;padding:4px;gap:2px;width:100%;box-sizing:border-box');
		const tabActive = mk('div', 'flex:1;padding:9px 16px;background:rgba(255,255,255,0.07);color:#fff;border-radius:11px;font-size:13px;font-weight:600;text-align:center', 'Click events');
		const tabB = mk('div', 'flex:1;padding:9px 16px;color:#9aa6c4;border-radius:11px;font-size:13px;text-align:center;opacity:0.5', 'Server log');
		const tabC = mk('div', 'flex:1;padding:9px 16px;color:#9aa6c4;border-radius:11px;font-size:13px;text-align:center;opacity:0.5', 'Reported errors');
		tabs.appendChild(tabActive);
		tabs.appendChild(tabB);
		tabs.appendChild(tabC);
		tabsWrap.appendChild(tabs);

		// ── toolbar
		const toolbar = mk('div', 'display:flex;align-items:center;gap:14px;padding:8px 20px 12px');
		const btnCopy  = mk('button', 'background:transparent;border:none;color:#cdd6ea;padding:6px 0;font:inherit;font-size:13px;cursor:pointer;display:inline-flex;align-items:center;gap:8px', '📋  Copy all');
		const btnClear = mk('button', 'background:transparent;border:none;color:#cdd6ea;padding:6px 0;font:inherit;font-size:13px;cursor:pointer;display:inline-flex;align-items:center;gap:8px', '🧹  Clear');
		btnCopy.type  = 'button';
		btnClear.type = 'button';
		const rightGroup = mk('div', 'margin-left:auto;display:flex;align-items:center;gap:12px');
		const flashEl  = mk('div', 'opacity:0;transition:opacity 0.2s;color:#2ecc71;font-size:12px', 'copied');
		const session  = mk('div', 'opacity:0.55;font-size:11px');
		session.textContent = 'session ' + this.sessionId;
		rightGroup.appendChild(flashEl);
		rightGroup.appendChild(session);
		toolbar.appendChild(btnCopy);
		toolbar.appendChild(btnClear);
		toolbar.appendChild(rightGroup);

		// ── hud + log list
		const hud = mk('div', 'padding:10px 18px;border-bottom:1px solid rgba(255,255,255,0.05);background:rgba(255,255,255,0.02);font-size:11px;white-space:pre-wrap;color:#9aa6c4');
		const log = mk('div', 'flex:1;overflow-y:auto;padding:8px 14px 24px');

		panel.appendChild(head);
		panel.appendChild(tabsWrap);
		panel.appendChild(toolbar);
		panel.appendChild(hud);
		panel.appendChild(log);
		document.body.appendChild(panel);

		this.panel = panel;
		this.logEl   = log;
		this.hudEl   = hud;
		this.flashEl = flashEl;

		btnClose.addEventListener('click', () => this._togglePanel(false));
		btnHide.addEventListener('click',  () => this._hideButton());
		btnCopy.addEventListener('click',  () => this._copyAll());
		btnClear.addEventListener('click', () => this._clear());

		// Cube label container (sits inside the hero element)
		const container = document.createElement('div');
		container.style.cssText = 'position:absolute;top:0;left:0;width:100%;height:100%;pointer-events:none;z-index:5;overflow:hidden';
		const hostStyle = window.getComputedStyle(this.host);
		if (hostStyle.position === 'static') this.host.style.position = 'relative';
		this.host.appendChild(container);
		this.labelContainer = container;
	}

	_togglePanel(open) {
		const isOpen = this.panel.style.transform === 'translateX(0%)';
		const shouldOpen = (open === undefined) ? !isOpen : open;
		this.panel.style.transform = shouldOpen ? 'translateX(0%)' : 'translateX(-100%)';
	}

	_hideButton() {
		this.btn.style.display = 'none';
		this._togglePanel(false);
	}

	async _copyAll() {
		const text = this._formatBuffer();
		try {
			await navigator.clipboard.writeText(text);
			this._flash('✓ Copied ' + this.entries.length + ' entries');
		} catch (e) {
			// Fallback: select via textarea
			const ta = document.createElement('textarea');
			ta.value = text;
			ta.style.cssText = 'position:fixed;left:-10000px;top:0';
			document.body.appendChild(ta);
			ta.select();
			try { document.execCommand('copy'); this._flash('✓ Copied (fallback)'); }
			catch (e2) { this._flash('✗ Copy failed — open DevTools'); console.log(text); }
			finally { ta.remove(); }
		}
	}

	_clear() {
		this.entries = [];
		this.logEl.innerHTML = '';
		this._flash('cleared');
	}

	_flash(msg) {
		this.flashEl.textContent = msg;
		this.flashEl.style.opacity = '1';
		clearTimeout(this._flashTimer);
		this._flashTimer = setTimeout(() => { this.flashEl.style.opacity = '0'; }, 1600);
	}

	_formatBuffer() {
		const lines = [];
		lines.push('# hero-3d debug log');
		lines.push('# session: ' + this.sessionId);
		lines.push('# url: ' + location.href);
		lines.push('# generated: ' + new Date().toISOString());
		lines.push('# entries: ' + this.entries.length);
		lines.push('');
		for (const e of this.entries) {
			lines.push('[' + this._fmtTs(e.ts) + '] [' + e.level + '] ' + e.name + (e.summary ? ' — ' + e.summary : ''));
			if (e.data) lines.push(JSON.stringify(e.data, null, 2));
			lines.push('');
		}
		return lines.join('\n');
	}

	_renderEntry(e) {
		if (!this.logEl) return;
		const levelColor = e.level === 'ERROR' ? '#e74c3c' : e.level === 'WARN' ? '#f1c40f' : '#76e4be';

		const wrap = document.createElement('div');
		wrap.style.cssText = 'border:1px solid rgba(255,255,255,0.07);border-left:3px solid ' + levelColor + ';border-radius:6px;padding:8px 10px;margin:8px 0;background:rgba(255,255,255,0.015)';

		const head = document.createElement('div');
		head.style.cssText = 'display:flex;align-items:baseline;gap:8px;flex-wrap:wrap';

		const ts = document.createElement('span');
		ts.style.cssText = 'color:#9aa6c4;font-size:10px';
		ts.textContent = this._fmtTs(e.ts);
		head.appendChild(ts);

		const lv = document.createElement('span');
		lv.style.cssText = 'color:' + levelColor + ';font-size:10px;font-weight:600';
		lv.textContent = '[' + e.level + ']';
		head.appendChild(lv);

		const nm = document.createElement('span');
		nm.style.cssText = 'color:#fff;font-weight:600';
		nm.textContent = e.name;
		head.appendChild(nm);

		if (e.summary) {
			const sm = document.createElement('span');
			sm.style.cssText = 'color:#cdd6ea';
			sm.textContent = '— ' + e.summary;
			head.appendChild(sm);
		}
		wrap.appendChild(head);

		if (e.data) {
			const pre = document.createElement('pre');
			pre.style.cssText = 'margin:6px 0 0;padding:6px 8px;background:rgba(0,0,0,0.35);border-radius:4px;font-size:11px;color:#cdd6ea;white-space:pre-wrap;word-break:break-word;max-height:240px;overflow:auto';
			pre.textContent = JSON.stringify(e.data, null, 2);
			wrap.appendChild(pre);
		}
		// Prepend so newest is on top
		this.logEl.insertBefore(wrap, this.logEl.firstChild);
		// Prune DOM nodes past MAX_ENTRIES
		while (this.logEl.children.length > MAX_ENTRIES) {
			this.logEl.removeChild(this.logEl.lastChild);
		}
	}

	_updateHud(contracts, pickedHover, extra) {
		if (!this.hudEl) return;
		const clickable = contracts.reduce((n, c) => n + (c.isClickable ? 1 : 0), 0);
		const hoverIdx = pickedHover ? contracts.indexOf(pickedHover) : -1;
		this.hudEl.textContent =
			'cubes:     ' + contracts.length + '   clickable: ' + clickable + '\n' +
			'hover:     ' + (hoverIdx >= 0 ? '#' + hoverIdx : '—') + '\n' +
			'halfW @0:  ' + ((extra && extra.halfW) ? extra.halfW.toFixed(2) : '—') + '\n' +
			'cam.z:     ' + ((extra && extra.camZ)  ? extra.camZ.toFixed(2)  : '—');
	}

	// ──────────────────────────────────────── cube labels ────────────
	_syncCubeLabels(contracts, camera, pickedClick, pickedHover) {
		while (this.labels.length < contracts.length) {
			const div = document.createElement('div');
			div.style.cssText = [
				'position:absolute',
				'font-family:ui-monospace,Menlo,monospace',
				'font-size:11px',
				'background:rgba(0,0,0,0.78)',
				'padding:1px 4px',
				'border-radius:3px',
				'pointer-events:none',
				'transform:translate(-50%,-50%)',
				'border:1px solid transparent',
			].join(';');
			this.labelContainer.appendChild(div);
			this.labels.push({ div });
		}
		while (this.labels.length > contracts.length) {
			const l = this.labels.pop();
			l.div.remove();
		}
		const rect = this.canvas.getBoundingClientRect();
		const hostRect = this.host.getBoundingClientRect();
		const W = rect.width, H = rect.height;
		const offsetX = rect.left - hostRect.left;
		const offsetY = rect.top - hostRect.top;
		const v = this._tmp;

		for (let i = 0; i < contracts.length; i++) {
			const c = contracts[i];
			const l = this.labels[i];
			v.copy(c.position).project(camera);
			const offscreen = v.z > 1 || v.z < -1 || v.x < -1.5 || v.x > 1.5 || v.y < -1.5 || v.y > 1.5;
			if (offscreen) { l.div.style.display = 'none'; continue; }
			l.div.style.display = '';
			l.div.style.left = ((v.x * 0.5 + 0.5) * W + offsetX) + 'px';
			l.div.style.top  = ((-v.y * 0.5 + 0.5) * H + offsetY) + 'px';
			const clickable = c.isClickable;
			const isPicked  = c === pickedClick;
			const isHover   = c === pickedHover;
			l.div.textContent = '#' + i + (clickable ? '' : '✗');
			l.div.style.color =
				!clickable ? '#f55' :
				isPicked   ? '#0f0' :
				isHover    ? '#0ff' :
				             '#ff0';
			l.div.style.borderColor =
				isPicked ? '#0f0' :
				isHover  ? '#0ff' :
				           'transparent';
		}
	}

	// ──────────────────────────────────────── utils ──────────────────
	_mkSessionId() {
		const buf = new Uint8Array(4);
		(window.crypto || window.msCrypto).getRandomValues(buf);
		return Array.from(buf).map(b => b.toString(16).padStart(2, '0')).join('');
	}

	_fmtTs(d) {
		const pad = (n, w) => String(n).padStart(w || 2, '0');
		return pad(d.getHours()) + ':' + pad(d.getMinutes()) + ':' + pad(d.getSeconds()) + '.' + pad(d.getMilliseconds(), 3);
	}

	_posTriple(p) {
		return { x: +p.x.toFixed(1), y: +p.y.toFixed(1), z: +p.z.toFixed(1) };
	}

	_esc(s) {
		return String(s)
			.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
			.replace(/"/g, '&quot;').replace(/'/g, '&#39;');
	}
}
