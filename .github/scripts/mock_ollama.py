#!/usr/bin/env python3

import json
from http.server import BaseHTTPRequestHandler, HTTPServer


class Handler(BaseHTTPRequestHandler):
    def _write_json(self, payload, status=200):
        data = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/api/tags":
            self._write_json(
                {
                    "models": [
                        {"name": "tinyllama:latest"},
                        {"name": "qwen2.5-coder:1.5b"},
                    ]
                }
            )
            return
        self._write_json({"error": "not found"}, status=404)

    def log_message(self, *_args):
        return


if __name__ == "__main__":
    server = HTTPServer(("0.0.0.0", 11434), Handler)
    server.serve_forever()
