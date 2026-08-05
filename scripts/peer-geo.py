#!/usr/bin/env python3
"""
peer-geo.py — refresh /api/peer-geo.json from the validator server.

Pipeline:
  1. POST info.peers to api.metalblockchain.org/ext/info → list of
     (nodeID, publicIP) pairs for every peer we're connected to
  2. Batch the unique IPs to http://ip-api.com/batch (server-side HTTP
     is fine — we're not in a browser, so no mixed-content concern;
     the ip-api free tier only allows HTTP for non-authenticated calls)
  3. Write the result to /var/www/freedom-yield/api/peer-geo.json so
     Caddy can serve it as /api/peer-geo.json to the public site.

Designed to be called from cron every ~30 minutes.

The shape stays small: a top-level object with `generatedAt`,
`selfNodeID`, and `peers[]`. Each peer is just `{nodeID, lat, lng,
country, city, cc}` so the client can plot it on Leaflet without
exposing the IP back to the public site. (IPs are public via the RPC
anyway, but keeping them out of the JSON is good hygiene.)

`numPeers` vs `totalPeers`: `numPeers` is metalgo's raw info.peers
count (`.result.numPeers`, the same figure scripts/server-status.sh
reads) — the accurate "how many peers are we connected to" number.
`totalPeers` is `len(pairs)`, this script's own post-filter count
(peers missing publicIP/nodeID dropped, then de-duplicated by IP) —
smaller than numPeers whenever any peer lacks a usable public IP, and
kept only because it's the honest denominator for `resolved` (the geo
lookup success count) and is a documented public API field already.
Public copy that claims "we are connected to N peers" should read
numPeers, not totalPeers.
"""
import json
import os
import sys
import time
import urllib.request

API_PEERS    = "https://api.metalblockchain.org/ext/info"
API_GEOIP    = "http://ip-api.com/batch"
SELF_NODE    = "NodeID-yyPvtQHTA4FZU5cJtjWZa7RVBpWU3i5v"
# Output path is the first CLI argument; cron passes the absolute path
# to the deployment's public/api/ directory. Defaults to /tmp so a
# bare-run can't accidentally overwrite a wrong file.
OUT_PATH     = sys.argv[1] if len(sys.argv) > 1 else "/tmp/peer-geo.json"
BATCH_SIZE   = 100        # ip-api batch hard cap
BATCH_PAUSE  = 4          # seconds between batches (free tier ~15/min)
HTTP_TIMEOUT = 25


def fetch_peers():
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "info.peers"}).encode()
    req = urllib.request.Request(
        API_PEERS, data=body,
        headers={
            "Content-Type": "application/json",
            "User-Agent": "freedom-yield-peer-geo/1.0 (Mozilla/5.0 compatible)",
        },
    )
    with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as r:
        data = json.loads(r.read())
    result = data.get("result", {}) or {}
    peers = result.get("peers", []) or []
    seen = set()
    pairs = []
    for p in peers:
        ip = (p.get("publicIP") or p.get("ip") or "").split(":")[0]
        node_id = p.get("nodeID") or ""
        if not ip or not node_id or ip in seen:
            continue
        seen.add(ip)
        pairs.append((node_id, ip))
    # Raw peer count as metalgo itself reports it (same field
    # scripts/server-status.sh reads). Falls back to the filtered/deduped
    # pairs count only if the RPC response is ever missing this field —
    # keeps `numPeers` always present and int-typed for JS consumers.
    num_peers = result.get("numPeers")
    if not isinstance(num_peers, int):
        num_peers = len(pairs)
    return pairs, num_peers


def geo_lookup(ips):
    fields = "status,country,countryCode,city,lat,lon,query"
    out = {}
    for i in range(0, len(ips), BATCH_SIZE):
        batch = ips[i:i + BATCH_SIZE]
        body = json.dumps([{"query": ip, "fields": fields} for ip in batch]).encode()
        req = urllib.request.Request(
            API_GEOIP, data=body,
            headers={
            "Content-Type": "application/json",
            "User-Agent": "freedom-yield-peer-geo/1.0 (Mozilla/5.0 compatible)",
        },
        )
        with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as r:
            results = json.loads(r.read())
        for entry in results:
            q = entry.get("query")
            if q:
                out[q] = entry
        if i + BATCH_SIZE < len(ips):
            time.sleep(BATCH_PAUSE)
    return out


def main():
    out_path = OUT_PATH
    pairs, num_peers = fetch_peers()
    if not pairs:
        print("no peers returned; aborting", file=sys.stderr)
        sys.exit(1)
    ips = [ip for _, ip in pairs]
    geo = geo_lookup(ips)

    peer_records = []
    for node_id, ip in pairs:
        g = geo.get(ip) or {}
        if g.get("status") != "success":
            continue
        lat = g.get("lat")
        lng = g.get("lon")
        if not isinstance(lat, (int, float)) or not isinstance(lng, (int, float)):
            continue
        peer_records.append({
            "nodeID":  node_id,
            "lat":     round(float(lat), 4),
            "lng":     round(float(lng), 4),
            "country": g.get("country") or "",
            "city":    g.get("city") or "",
            "cc":      g.get("countryCode") or "",
            "self":    node_id == SELF_NODE,
        })

    output = {
        "generatedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "selfNodeID":  SELF_NODE,
        "numPeers":    num_peers,
        "totalPeers":  len(pairs),
        "resolved":    len(peer_records),
        "peers":       peer_records,
    }

    # Atomic write
    tmp = out_path + ".tmp"
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    with open(tmp, "w") as f:
        json.dump(output, f, separators=(",", ":"))
    os.replace(tmp, out_path)
    print(f"peer-geo.json: {len(peer_records)}/{len(pairs)} resolved "
          f"(numPeers={num_peers}) at {output['generatedAt']}")


if __name__ == "__main__":
    main()
