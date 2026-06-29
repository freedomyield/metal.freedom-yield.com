#!/usr/bin/env python3
"""Time-aware mock RPC for the endTime scenario test.

Serves validator-present response BEFORE the specified endtime, and
validator-absent response AT or AFTER the endtime. This simulates the
real metalgo behavior where a validator entry disappears from
getCurrentValidators the moment its on-chain endTime is reached.

Used by tests/cycle-gate/scenario-test-endtime.sh to verify that all
8 cycle-related cron scripts auto-stop (= cycle-gate.sh returns deferred)
once the endTime is reached.

Usage:
  python3 mock-rpc-timed.py PORT ENDTIME_UNIX
"""

import sys
import json
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = int(sys.argv[1])
ENDTIME_UNIX = int(sys.argv[2])


def chain_present():
    return {
        "jsonrpc": "2.0",
        "id": 1,
        "result": {
            "validators": [
                {
                    "nodeID": "NodeID-TEST123",
                    "startTime": "1700000000",
                    "endTime": str(ENDTIME_UNIX),
                    "weight": "5900000000000",
                    "delegationFee": "30000",
                    "delegators": [],
                }
            ]
        },
    }


def chain_absent():
    return {"jsonrpc": "2.0", "id": 1, "result": {"validators": []}}


class H(BaseHTTPRequestHandler):
    def _send(self, status, body=b"", ctype="application/json"):
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if body:
            self.wfile.write(body)

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        if length:
            self.rfile.read(length)
        if self.path == "/ext/bc/P":
            now = int(time.time())
            resp = chain_absent() if now >= ENDTIME_UNIX else chain_present()
            data = json.dumps(resp).encode()
            self._send(200, data)
        else:
            self._send(404)

    def do_GET(self):
        if self.path == "/api/cycles-history.json":
            data = json.dumps(
                {
                    "dag_root_hash": "1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef",
                    "branches": {"cycles": {"leaf_count": 2}},
                }
            ).encode()
            self._send(200, data)
        else:
            self._send(404)

    def log_message(self, *_a, **_kw):
        pass


if __name__ == "__main__":
    HTTPServer(("127.0.0.1", PORT), H).serve_forever()
