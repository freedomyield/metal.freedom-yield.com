#!/usr/bin/env python3
# mock-rpc.py — minimal HTTP server for cycle-gate.sh + resume-after-cycle-start.sh
# tests. Serves both metalgo RPC POST (= /ext/bc/P) and Xserver GET fixtures
# (= /api/* and /.well-known/*) based on a single JSON config file.
#
# Usage:   python3 mock-rpc.py <port> <fixture-config.json>
#
# Fixture config shape:
# {
#   "rpc_response": {...},           # JSON returned for POST /ext/bc/P
#                                     # (omit / null to return 500)
#   "files": {                       # served verbatim for GET <path>
#     "/api/identity.json": {...},   #   - dict / list → JSON-encoded
#     "/api/cycles-history.json": "literal text body"
#                                    #   - string → returned as-is
#   }
# }

import sys, json
from http.server import BaseHTTPRequestHandler, HTTPServer

config = {}


class H(BaseHTTPRequestHandler):
    def _send(self, status, body=b"", ctype="application/octet-stream"):
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
            resp = config.get("rpc_response")
            if resp is None:
                self._send(500)
                return
            data = json.dumps(resp).encode()
            self._send(200, data, "application/json")
        else:
            self._send(404)

    def _serve_file(self, head_only=False):
        files = config.get("files", {})
        if self.path in files:
            entry = files[self.path]
            if isinstance(entry, str):
                data = entry.encode()
            else:
                data = json.dumps(entry).encode()
            if head_only:
                self._send(200, b"")
            else:
                self._send(200, data)
        else:
            self._send(404)

    def do_GET(self):
        self._serve_file(head_only=False)

    def do_HEAD(self):
        self._serve_file(head_only=True)

    def log_message(self, *_a, **_kw):
        pass  # silence


if __name__ == "__main__":
    port = int(sys.argv[1])
    with open(sys.argv[2]) as f:
        config = json.load(f)
    HTTPServer(("127.0.0.1", port), H).serve_forever()
