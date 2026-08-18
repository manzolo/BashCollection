#!/usr/bin/env python3

import json
from http.server import BaseHTTPRequestHandler, HTTPServer

# Context windows the mock advertises:
#   loaded  -> what /api/ps reports for a running model (the window in use)
#   maximum -> what /api/show reports as the model's own limit
MODELS = {
    "tinyllama:latest": {"loaded": 8192, "maximum": 32768, "family": "llama"},
    "qwen2.5-coder:1.5b": {"loaded": None, "maximum": 4096, "family": "qwen2"},
}


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
            self._write_json({"models": [{"name": name} for name in MODELS]})
            return
        if self.path == "/api/ps":
            self._write_json(
                {
                    "models": [
                        {"name": name, "context_length": info["loaded"]}
                        for name, info in MODELS.items()
                        if info["loaded"] is not None
                    ]
                }
            )
            return
        self._write_json({"error": "not found"}, status=404)

    def do_POST(self):
        if self.path != "/api/show":
            self._write_json({"error": "not found"}, status=404)
            return
        length = int(self.headers.get("Content-Length") or 0)
        try:
            body = json.loads(self.rfile.read(length) or b"{}")
        except json.JSONDecodeError:
            body = {}
        info = MODELS.get(body.get("model"))
        if info is None:
            self._write_json({"error": "model not found"}, status=404)
            return
        self._write_json(
            {
                "capabilities": ["completion", "tools"],
                "model_info": {
                    "general.architecture": info["family"],
                    f"{info['family']}.context_length": info["maximum"],
                },
            }
        )

    def log_message(self, *_args):
        return


if __name__ == "__main__":
    server = HTTPServer(("0.0.0.0", 11434), Handler)
    server.serve_forever()
