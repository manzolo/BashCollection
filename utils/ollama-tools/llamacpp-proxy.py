#!/usr/bin/env python3
"""
llamacpp-proxy — traduce Anthropic Messages API → OpenAI Chat Completions API
Gestisce reasoning_content (thinking) e content (text) di DeepSeek e simili.
"""
import json
import sys
import uuid
import argparse
import requests
from http.server import HTTPServer, BaseHTTPRequestHandler

BACKEND = "http://localhost:11435"
MODEL_NAME = "deepseek-v4-flash"


def to_openai(data):
    messages = list(data.get("messages", []))
    if "system" in data:
        messages.insert(0, {"role": "system", "content": data["system"]})
    return {
        "model": MODEL_NAME,
        "messages": messages,
        "max_tokens": data.get("max_tokens", 8192),
        "temperature": data.get("temperature", 0.6),
        "stream": data.get("stream", False),
    }


def to_anthropic(oai, model):
    choice = oai["choices"][0]
    msg = choice["message"]
    reasoning = msg.get("reasoning_content") or ""
    text = msg.get("content") or ""
    usage = oai.get("usage", {})

    content = []
    if reasoning:
        content.append({"type": "thinking", "thinking": reasoning})
    content.append({"type": "text", "text": text})

    return {
        "id": f"msg_{uuid.uuid4().hex[:20]}",
        "type": "message",
        "role": "assistant",
        "content": content,
        "model": model,
        "stop_reason": "end_turn",
        "stop_sequence": None,
        "usage": {
            "input_tokens": usage.get("prompt_tokens", 0),
            "output_tokens": usage.get("completion_tokens", 0),
        },
    }


def sse_write(wfile, event, obj):
    payload = f"event: {event}\ndata: {json.dumps(obj)}\n\n".encode()
    wfile.write(f"{len(payload):x}\r\n".encode())
    wfile.write(payload)
    wfile.write(b"\r\n")
    wfile.flush()


class ProxyHandler(BaseHTTPRequestHandler):

    def log_message(self, fmt, *args):
        print(f"[llamacpp-proxy] {fmt % args}", file=sys.stderr)

    def send_json(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", len(body))
        self.end_headers()
        self.wfile.write(body)

    def do_HEAD(self):
        self.send_response(200)
        self.end_headers()

    def do_GET(self):
        if self.path.startswith("/v1/models"):
            try:
                r = requests.get(f"{BACKEND}/v1/models", timeout=10)
                self.send_json(r.status_code, r.json())
            except Exception as e:
                self.send_json(502, {"error": str(e)})
        else:
            self.send_json(404, {"error": "not found"})

    def do_POST(self):
        if not self.path.startswith("/v1/messages"):
            self.send_json(404, {"error": "not found"})
            return

        length = int(self.headers.get("Content-Length", 0))
        try:
            data = json.loads(self.rfile.read(length))
        except Exception:
            self.send_json(400, {"error": "invalid json"})
            return

        oai_data = to_openai(data)
        is_stream = data.get("stream", False)

        if not is_stream:
            try:
                r = requests.post(f"{BACKEND}/v1/chat/completions",
                                  json=oai_data, timeout=300)
                self.send_json(200, to_anthropic(r.json(), data.get("model", MODEL_NAME)))
            except Exception as e:
                self.send_json(502, {"error": str(e)})
            return

        # ── streaming ──────────────────────────────────────────────────────
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()

        msg_id = f"msg_{uuid.uuid4().hex[:20]}"
        model_name = data.get("model", MODEL_NAME)

        sse_write(self.wfile, "message_start", {
            "type": "message_start",
            "message": {
                "id": msg_id, "type": "message", "role": "assistant",
                "content": [], "model": model_name,
                "stop_reason": None, "stop_sequence": None,
                "usage": {"input_tokens": 0, "output_tokens": 0},
            },
        })
        sse_write(self.wfile, "ping", {"type": "ping"})

        # Block state: we open blocks lazily as content arrives
        thinking_open = False   # thinking block (index 0) opened
        text_open = False       # text block opened
        text_index = 0          # index of the text block

        oai_data["stream"] = True
        try:
            with requests.post(f"{BACKEND}/v1/chat/completions",
                               json=oai_data, stream=True, timeout=300) as r:
                for raw in r.iter_lines():
                    if not raw:
                        continue
                    line = raw.decode("utf-8")
                    if not line.startswith("data: "):
                        continue
                    payload = line[6:]
                    if payload == "[DONE]":
                        break
                    try:
                        chunk = json.loads(payload)
                        delta = chunk["choices"][0].get("delta", {})
                        reasoning = delta.get("reasoning_content") or ""
                        content = delta.get("content") or ""

                        if reasoning:
                            if not thinking_open:
                                sse_write(self.wfile, "content_block_start", {
                                    "type": "content_block_start", "index": 0,
                                    "content_block": {"type": "thinking", "thinking": ""},
                                })
                                thinking_open = True
                            sse_write(self.wfile, "content_block_delta", {
                                "type": "content_block_delta", "index": 0,
                                "delta": {"type": "thinking_delta", "thinking": reasoning},
                            })

                        if content:
                            if not text_open:
                                if thinking_open:
                                    # Close thinking block before opening text
                                    sse_write(self.wfile, "content_block_stop",
                                              {"type": "content_block_stop", "index": 0})
                                    thinking_open = False
                                    text_index = 1
                                else:
                                    text_index = 0
                                sse_write(self.wfile, "content_block_start", {
                                    "type": "content_block_start", "index": text_index,
                                    "content_block": {"type": "text", "text": ""},
                                })
                                text_open = True
                            sse_write(self.wfile, "content_block_delta", {
                                "type": "content_block_delta", "index": text_index,
                                "delta": {"type": "text_delta", "text": content},
                            })
                    except Exception:
                        pass
        except Exception as e:
            print(f"[llamacpp-proxy] stream error: {e}", file=sys.stderr)

        # Close any still-open blocks
        if thinking_open:
            sse_write(self.wfile, "content_block_stop",
                      {"type": "content_block_stop", "index": 0})
            text_index = 1
        if text_open:
            sse_write(self.wfile, "content_block_stop",
                      {"type": "content_block_stop", "index": text_index})
        if not thinking_open and not text_open:
            # Nothing generated — emit empty text block for protocol compliance
            sse_write(self.wfile, "content_block_start", {
                "type": "content_block_start", "index": 0,
                "content_block": {"type": "text", "text": ""},
            })
            sse_write(self.wfile, "content_block_stop",
                      {"type": "content_block_stop", "index": 0})

        sse_write(self.wfile, "message_delta", {
            "type": "message_delta",
            "delta": {"stop_reason": "end_turn", "stop_sequence": None},
            "usage": {"output_tokens": 0},
        })
        sse_write(self.wfile, "message_stop", {"type": "message_stop"})
        self.wfile.write(b"0\r\n\r\n")
        self.wfile.flush()


def main():
    ap = argparse.ArgumentParser(description="Anthropic→OpenAI proxy per llamacpp-claude")
    ap.add_argument("--port", type=int, default=11436,
                    help="Porta locale su cui il proxy ascolta (default: 11436)")
    ap.add_argument("--backend", default="http://localhost:11435",
                    help="URL del llama-server (default: http://localhost:11435)")
    ap.add_argument("--model", default="deepseek-v4-flash",
                    help="Nome modello (default: deepseek-v4-flash)")
    args = ap.parse_args()

    global BACKEND, MODEL_NAME
    BACKEND = args.backend
    MODEL_NAME = args.model

    print(f"[llamacpp-proxy] Anthropic→OpenAI proxy :{args.port} → {BACKEND} (model: {MODEL_NAME})",
          file=sys.stderr)
    HTTPServer(("127.0.0.1", args.port), ProxyHandler).serve_forever()


if __name__ == "__main__":
    main()
