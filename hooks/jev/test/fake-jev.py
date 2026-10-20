"""fake-jev.py — a local stand-in for POST /v1/systemone, for offline tests.

    python3 -I fake-jev.py <port> <capture-dir>

Writes every request body to <capture-dir>/body-<n>.json (and the headers, minus
Authorization, to headers-<n>.txt), and answers every question with a fixed,
valid answer: score -> level 2 ("important"), noul -> 0.1, choice -> the first
option. Prints "ready" once listening. Test-only; never used by the hooks.
"""
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = int(sys.argv[1])
CAP = sys.argv[2]
os.makedirs(CAP, exist_ok=True)
count = [0]


def answer(q):
    t = q.get("type")
    if t == "score":
        levels = q.get("criteria") or ["low", "high"]
        lv = min(2, len(levels) - 1)
        probs = {str(i): (1.0 if i == lv else 0.0) for i in range(len(levels))}
        return {"type": "score", "score": float(lv), "confidence": 1.0,
                "legend": {str(i): l for i, l in enumerate(levels)}, "probabilities": probs}
    if t == "choice":
        opts = list((q.get("criteria") or {"a": None}).keys())
        pick = opts[0]
        return {"type": "choice", "choice": pick, "confidence": 1.0,
                "probabilities": {o: (1.0 if o == pick else 0.0) for o in opts}}
    return {"type": "noul", "noul": 0.1}


class H(BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n)
        count[0] += 1
        with open(os.path.join(CAP, "body-%03d.json" % count[0]), "wb") as f:
            f.write(body)
        with open(os.path.join(CAP, "headers-%03d.txt" % count[0]), "w") as f:
            for k, v in self.headers.items():
                f.write("%s: %s\n" % (k, "<present>" if k.lower() == "authorization" else v))
        try:
            req = json.loads(body)
            out = {"model": "jev-fake", "answers": {k: answer(v) for k, v in req["questions"].items()},
                   "usage": {"input_tokens": len(body) // 4, "output_tokens": 1}}
            data, code = json.dumps(out).encode(), 200
        except Exception as e:  # malformed request: answer like the API does
            data, code = json.dumps({"detail": {"error_type": "api_usage_error", "message": str(e)}}).encode(), 400
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *a):
        pass


srv = HTTPServer(("127.0.0.1", PORT), H)
print("ready", flush=True)
srv.serve_forever()
