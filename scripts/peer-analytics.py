#!/usr/bin/env python3
"""
peer-analytics.py — companion to peer-validators.sh.

Reads the freshly-written peers.json, plus the explorer name map, and
emits two derived artefacts:

  1. peers-changes.json — diff vs last snapshot's NodeID set
     (new entrants + departed validators)

  2. peers-gini.json   — trailing 24 snapshots of Gini coefficient +
     top-10 share + Metallicus share. Master JSONL kept in STATE_DIR
     for indefinite history.

All inputs come from env vars set by the shell wrapper:
  PEERS_JSON, NAMES_JSON, STATE_DIR, OUT_CHANGES, OUT_GINI, GEN_ISO

Failure-mode: on any unexpected condition, log + exit 1 (so the
parent shell sees it and cron logs the trace). Don't silently swallow.
"""
import json, os, sys, re
from pathlib import Path

def env(k):
    v = os.environ.get(k)
    if not v:
        sys.exit(f"peer-analytics: missing env var {k}")
    return v

PEERS_JSON  = env("PEERS_JSON")
NAMES_JSON  = env("NAMES_JSON")
STATE_DIR   = Path(env("STATE_DIR"))
OUT_CHANGES = env("OUT_CHANGES")
OUT_GINI    = env("OUT_GINI")
GEN_ISO     = env("GEN_ISO")

with open(PEERS_JSON) as f:
    peers = json.load(f)
with open(NAMES_JSON) as f:
    name_map = json.load(f) if Path(NAMES_JSON).stat().st_size > 0 else {}

validators = peers.get("validators", [])

# ── C: changes ─────────────────────────────────────────────────────
PREV = STATE_DIR / "peers-prev-nodeids.txt"
prev_ids = set()
had_prev = PREV.exists()
if had_prev:
    prev_ids = {ln.strip() for ln in PREV.read_text().splitlines() if ln.strip()}
cur_ids = {v["node_id"] for v in validators}

new_ids = sorted(cur_ids - prev_ids)
departed_ids = sorted(prev_ids - cur_ids)

# Look up self-stake + name for new entries (from current peers)
by_id = {v["node_id"]: v for v in validators}
new_rows = [
    {
        "node_id": nid,
        "name": name_map.get(nid) or None,
        "self_stake_metal": by_id.get(nid, {}).get("self_stake_metal", 0),
    }
    for nid in new_ids
]
departed_rows = [{"node_id": nid} for nid in departed_ids]

changes = {
    "generated_at": GEN_ISO,
    "had_previous_snapshot": had_prev,
    "new_count": len(new_rows),
    "departed_count": len(departed_rows),
    "new": new_rows,
    "departed": departed_rows,
}
Path(OUT_CHANGES).write_text(json.dumps(changes, ensure_ascii=False, indent=2))
PREV.write_text("\n".join(sorted(cur_ids)) + "\n")
print(f"wrote {OUT_CHANGES} — new: {len(new_rows)}, departed: {len(departed_rows)}, had_prev: {had_prev}")

# ── D: Gini + top-10 + Metallicus share, append to JSONL ───────────
stakes = sorted([v.get("self_stake_metal", 0) for v in validators])
n = len(stakes)
total = sum(stakes)
gini = 0.0
if n > 0 and total > 0:
    cum = sum((i + 1) * v for i, v in enumerate(stakes))
    gini = (2 * cum) / (n * total) - (n + 1) / n

top10_share = (sum(sorted(stakes, reverse=True)[:10]) / total) if total > 0 else 0
metallicus_ids = {nid for nid, name in name_map.items() if name and re.search(r"metallicus", name, re.I)}
metallicus_stake = sum(v.get("self_stake_metal", 0) for v in validators if v["node_id"] in metallicus_ids)
metallicus_share = (metallicus_stake / total) if total > 0 else 0

gini_line = {
    "ts": GEN_ISO,
    "gini": round(gini, 6),
    "top10_share": round(top10_share, 6),
    "metallicus_share": round(metallicus_share, 6),
    "validator_count": n,
}
GINI_JSONL = STATE_DIR / "gini-history.jsonl"
with GINI_JSONL.open("a") as f:
    f.write(json.dumps(gini_line) + "\n")

# Master is now keep-forever (no trim). At 1 sample/day this grows by
# ~150 bytes/day = ~55 KB/year = ~550 KB over a decade. Trivial.
lines = GINI_JSONL.read_text().splitlines()

# peers-gini.json — small preview (last 24 entries) for the inline chart's
# default view. Keep as-is so existing frontend keeps working.
public_entries = [json.loads(ln) for ln in lines[-24:]]
Path(OUT_GINI).write_text(json.dumps({"generated_at": GEN_ISO, "entries": public_entries}, ensure_ascii=False, indent=2))

# peers-gini-history.jsonl — FULL history mirror, world-readable. The
# The chart can toggle to "all time" by fetching this. JSONL (one
# JSON object per line) is also append-friendly so clients can read
# incrementally if file grows large.
OUT_HISTORY = os.environ.get("OUT_GINI_HISTORY", str(Path(OUT_GINI).parent / "peers-gini-history.jsonl"))
Path(OUT_HISTORY).write_text("\n".join(lines) + "\n")
print(f"wrote {OUT_GINI} (preview, {len(public_entries)}) + {OUT_HISTORY} (full, {len(lines)})")
print(f"  latest: gini={gini:.4f}, top10={top10_share:.4f}, metallicus={metallicus_share:.4f}")

# ── Phase γ #2: fee market percentile time-series ──────────────────
# Distribution of delegationFee across the active validator set.
# Use case: prove our 3% fee remains in the bottom decile (or watch the
# market move). Lets us answer "did fee compression actually happen
# after a network-relevant announcement?" with on-chain evidence later.
#
# Schema per line (append-only forever):
#   ts, n, mean, p10, p25, p50, p75, p90, max, self_fee_pct, self_pctile
def _percentile(sorted_vals, q):
    if not sorted_vals:
        return None
    if len(sorted_vals) == 1:
        return sorted_vals[0]
    pos = q * (len(sorted_vals) - 1)
    lo = int(pos)
    hi = min(lo + 1, len(sorted_vals) - 1)
    return sorted_vals[lo] + (sorted_vals[hi] - sorted_vals[lo]) * (pos - lo)

fees = sorted([v.get("delegation_fee_pct", 0) for v in validators])
nf = len(fees)
own_node_id = peers.get("own_node_id") or ""
self_v = next((v for v in validators if v.get("node_id") == own_node_id), None)
self_fee = self_v.get("delegation_fee_pct") if self_v else None
self_pctile = None
if self_fee is not None and nf > 0:
    rank = sum(1 for f in fees if f < self_fee)
    self_pctile = round(rank / nf, 4)

fee_line = {
    "ts": GEN_ISO,
    "n": nf,
    "mean": round(sum(fees) / nf, 4) if nf else None,
    "p10":  round(_percentile(fees, 0.10), 4) if nf else None,
    "p25":  round(_percentile(fees, 0.25), 4) if nf else None,
    "p50":  round(_percentile(fees, 0.50), 4) if nf else None,
    "p75":  round(_percentile(fees, 0.75), 4) if nf else None,
    "p90":  round(_percentile(fees, 0.90), 4) if nf else None,
    "max":  round(max(fees), 4) if nf else None,
    "self_fee_pct":  self_fee,
    "self_percentile": self_pctile,
}
FEE_JSONL = STATE_DIR / "fee-market-history.jsonl"
with FEE_JSONL.open("a") as f:
    f.write(json.dumps(fee_line) + "\n")
fee_lines = FEE_JSONL.read_text().splitlines()

OUT_FEE = os.environ.get("OUT_FEE_MARKET", str(Path(OUT_GINI).parent / "fee-market.json"))
fee_preview = [json.loads(ln) for ln in fee_lines[-30:]]
Path(OUT_FEE).write_text(json.dumps({"generated_at": GEN_ISO, "entries": fee_preview}, ensure_ascii=False, indent=2))

OUT_FEE_HISTORY = os.environ.get("OUT_FEE_HISTORY", str(Path(OUT_GINI).parent / "fee-market-history.jsonl"))
Path(OUT_FEE_HISTORY).write_text("\n".join(fee_lines) + "\n")
print(f"wrote {OUT_FEE} (preview, {len(fee_preview)}) + {OUT_FEE_HISTORY} (full, {len(fee_lines)})")
print(f"  fee market: p10={fee_line['p10']} p50={fee_line['p50']} p90={fee_line['p90']} self={self_fee} (pctile={self_pctile})")
