// Cycle journal renderer. Pulls /api/uptime-cycles.json and lists each
// closed cycle with operator notes. Empty state is explicit ("Cycle 1
// closes on …") rather than a generic loader stuck forever.
(() => {
	"use strict";

	const LIST   = document.querySelector("[data-journal-list]");
	const LOADER = document.querySelector("[data-journal-loading]");
	const EMPTY  = document.querySelector("[data-journal-empty]");
	const TPL    = document.querySelector("[data-journal-template]");
	const SUMMARY_COUNT = document.querySelector('[data-field="cycleCount"]');
	const SUMMARY_MED   = document.querySelector('[data-field="medianUptime"]');

	if (!LIST || !TPL) return;

	const isJa = document.documentElement.lang === "ja";
	const t = isJa
		? { err: "読み込みに失敗しました。後で再試行してください。", fail: "失敗" }
		: { err: "Could not load cycle data. Try again later.", fail: "failed" };

	function fmtDateRange(startIso, endIso) {
		if (!startIso || !endIso) return "—";
		const s = startIso.slice(0, 10);
		const e = endIso.slice(0, 10);
		return `${s} → ${e}`;
	}

	function fmtDuration(days) {
		if (typeof days !== "number") return "—";
		return isJa ? `${days} 日` : `${days} day${days === 1 ? "" : "s"}`;
	}

	function fmtUptime(pct) {
		if (typeof pct !== "number") return "—";
		return `${pct.toFixed(2)}%`;
	}

	function median(arr) {
		const s = arr.slice().sort((a, b) => a - b);
		const n = s.length;
		if (n === 0) return null;
		if (n % 2 === 1) return s[(n - 1) / 2];
		return (s[n / 2 - 1] + s[n / 2]) / 2;
	}

	function render(cycles) {
		LOADER && LOADER.remove();
		const sorted = cycles.slice().sort((a, b) => b.cycle_n - a.cycle_n); // newest first

		// Summary
		if (SUMMARY_COUNT) SUMMARY_COUNT.textContent = String(sorted.length);
		if (SUMMARY_MED) {
			const ups = sorted.map(c => c.final_uptime_pct).filter(x => typeof x === "number");
			const m = median(ups);
			SUMMARY_MED.textContent = m === null ? "—" : `${m.toFixed(2)}%`;
		}

		if (sorted.length === 0) {
			if (EMPTY) EMPTY.hidden = false;
			return;
		}

		for (const c of sorted) {
			const li = TPL.content.firstElementChild.cloneNode(true);
			li.querySelector(".journal-cycle-n").textContent =
				isJa ? `Cycle ${c.cycle_n}` : `Cycle ${c.cycle_n}`;
			li.querySelector(".journal-period").textContent = fmtDateRange(c.start_iso, c.end_iso);
			li.querySelector(".journal-uptime").textContent = fmtUptime(c.final_uptime_pct);
			li.querySelector(".journal-duration").textContent = fmtDuration(c.duration_days);
			const a = li.querySelector(".journal-explorer");
			if (c.explorer_url) {
				a.href = c.explorer_url;
			} else {
				a.removeAttribute("href");
				a.textContent = isJa ? "—" : "—";
			}
			const notesEl = li.querySelector(".journal-notes");
			if (c.notes && typeof c.notes === "string" && c.notes.trim().length > 0) {
				notesEl.textContent = c.notes.trim();
			} else {
				notesEl.classList.add("journal-notes--empty");
				notesEl.textContent = isJa ? "(ノート未記入)" : "(No notes recorded)";
			}
			LIST.appendChild(li);
		}
	}

	fetch("/api/uptime-cycles.json", { cache: "no-store" })
		.then(res => {
			if (!res.ok) throw new Error("HTTP " + res.status);
			return res.json();
		})
		.then(data => render(Array.isArray(data?.cycles) ? data.cycles : []))
		.catch(err => {
			console.error("[journal] load failed:", err);
			if (LOADER) {
				LOADER.textContent = t.err;
				LOADER.classList.add("journal-loading--error");
			}
		});
})();
