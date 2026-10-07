#!/usr/bin/env python3
"""Tiny fake Moonraker for developing the widget without a real print.

Serves one of several scenarios (idle, heating, printing, paused, complete,
error, klippy shutdown, ...) and lets you switch between them at runtime.
File metadata and thumbnails come from dev/assets/thumbnail.png by default, and
the webcam serves dev/assets/webcam.jpg; with --upstream all of these are
proxied to a real printer instead.

  ./dev/mock_moonraker.py --scenario printing --file "benchy.gcode" \
      --upstream http://192.168.1.50 --api-key XXXX

  # switch scenario while running
  curl -X POST http://127.0.0.1:7125/mock/scenario/paused
  curl http://127.0.0.1:7125/mock/scenarios

With --require-key KEY every request without that X-Api-Key (or a one-shot
token the mock issued) gets a 401, which reproduces an auth failure.
"""
import argparse
import json
import os
import secrets
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TOTAL = 3 * 3600

# name -> (print state, progress, klippy state, heater targets, message)
SCENARIOS = {
    "idle":             ("standby",   0.00, "ready",    (0, 0, 0),     ""),
    "heating":          ("printing",  0.00, "ready",    (220, 90, 45), ""),
    "printing-start":   ("printing",  0.03, "ready",    (220, 90, 45), ""),
    "printing":         ("printing",  0.42, "ready",    (220, 90, 45), ""),
    "printing-end":     ("printing",  0.97, "ready",    (220, 90, 45), ""),
    "paused":           ("paused",    0.58, "ready",    (220, 90, 45), "Filament runout detected"),
    "complete":         ("complete",  1.00, "ready",    (0, 0, 0),     ""),
    "cancelled":        ("cancelled", 0.37, "ready",    (0, 0, 0),     ""),
    "error":            ("error",     0.61, "ready",    (0, 0, 0),     "MCU 'mcu' shutdown: Heater extruder not heating at expected rate"),
    "klippy-startup":   ("standby",   0.00, "startup",  (0, 0, 0),     ""),
    "klippy-shutdown":  ("standby",   0.00, "shutdown", (0, 0, 0),     "Lost communication with MCU 'mcu'"),
    "klippy-disconnected": (None,     0.00, None,       (0, 0, 0),     "Klippy Disconnected"),
}

# Misbehaving-server scenarios: a normal print, except for the abuse named.
ABUSE = {
    "flood": "status query streams an endless chunked body",
    "flood-declared": "status query declares a 500 MB Content-Length",
    "hang": "status query never answers",
    "huge-thumbnail": "thumbnail streams an endless body",
    "huge-snapshot": "webcam snapshot streams an endless body",
}

args = None
scenario = {"name": "printing"}
tokens = set()


def temps(targets, heating):
    tn, tb, tc = targets
    if heating:
        return (148.3, 71.6, 31.2)
    return (tn - 0.4 if tn else 27.1, tb + 0.2 if tb else 25.8, tc - 0.2 if tc else 24.6)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"  # needed for chunked responses

    def log_message(self, *a):
        pass

    def flood(self, content_type, declared=False):
        """Stream up to 500 MB and report how much the client accepted."""
        chunk, sent, limit = b"x" * 65536, 0, 500 * 1024 * 1024
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        if declared:
            self.send_header("Content-Length", str(limit))
        else:
            self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        try:
            while sent < limit:
                self.wfile.write(chunk if declared else b"%x\r\n%s\r\n" % (len(chunk), chunk))
                sent += len(chunk)
        except OSError:
            pass
        print(f"[mock] {scenario['name']}: client stopped after {sent // 1024} KiB", flush=True)
        self.close_connection = True

    def send_body(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def send_json(self, obj):
        self.send_body(200, {"result": obj})

    def send_err(self, code, message):
        self.send_body(code, {"error": {"code": code, "message": message}})

    def authorized(self):
        if not args.require_key:
            return True
        if self.headers.get("X-Api-Key") == args.require_key:
            return True
        query = self.path.split("?", 1)[1] if "?" in self.path else ""
        for part in query.split("&"):
            if part.startswith("token=") and part[6:] in tokens:
                tokens.discard(part[6:])
                return True
        return False

    def local_file(self, path):
        # Synthesized metadata + the bundled thumbnail when there's no upstream.
        if path == "/server/files/metadata":
            self.send_json({
                "filename": args.file, "estimated_time": TOTAL, "layer_count": 240,
                "filament_total": 13890.0,
                "thumbnails": [{"width": 300, "height": 300, "size": 0,
                                "relative_path": ".thumbs/mock-300x300.png"}],
            })
            return
        if path.endswith("/.thumbs/mock-300x300.png") and scenario["name"] == "huge-thumbnail":
            self.flood("image/png")
            return
        if path.endswith("/.thumbs/mock-300x300.png"):
            self.send_file(args.thumbnail, "image/png")
            return
        if path == "/server/webcams/list":
            cams = [] if args.no_webcam else [{
                "name": "Mock Cam", "enabled": True, "service": "mjpegstreamer-adaptive",
                "stream_url": "/webcam/?action=stream", "snapshot_url": "/webcam/?action=snapshot",
                "rotation": 0, "flip_horizontal": False, "flip_vertical": False, "aspect_ratio": "16:9",
            }]
            self.send_json({"webcams": cams})
            return
        if path == "/webcam/" and not args.no_webcam:
            if scenario["name"] == "huge-snapshot":
                self.flood("image/jpeg")
            else:
                self.send_file(args.webcam, "image/jpeg")
            return
        self.send_error(404)

    def send_file(self, name, content_type):
        with open(name, "rb") as f:
            body = f.read()
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def proxy(self):
        if not args.upstream:
            self.local_file(self.path.split("?")[0])
            return
        path = self.path.split("?token=")[0]
        req = urllib.request.Request(args.upstream + path)
        if args.api_key:
            req.add_header("X-Api-Key", args.api_key)
        try:
            with urllib.request.urlopen(req, timeout=5) as r:
                body = r.read()
                self.send_response(r.status)
                self.send_header("Content-Type", r.headers.get("Content-Type", "application/octet-stream"))
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
        except Exception as e:  # noqa: BLE001
            self.send_error(502, str(e))

    def status(self):
        name = scenario["name"] if scenario["name"] in SCENARIOS else "printing"
        state, progress, klippy, targets, message = SCENARIOS[name]
        heating = scenario["name"] == "heating"
        active = state in ("printing", "paused")
        elapsed = TOTAL * progress if progress else (95 if heating else 0)
        has_file = state not in ("standby",)
        nozzle, bed, chamber = temps(targets, heating)
        return {
            "webhooks": {"state": klippy, "state_message": message},
            "print_stats": {
                "state": state,
                "filename": args.file if has_file else "",
                "print_duration": elapsed if has_file else 0,
                "total_duration": elapsed + 240 if has_file else 0,
                "filament_used": 13890 * progress if has_file else 0,
                "message": message if state in ("paused", "error") else "",
                "info": {"current_layer": int(progress * 240) if active else None,
                         "total_layer": 240 if active else None},
            },
            "virtual_sdcard": {"progress": progress},
            "display_status": {"progress": progress, "message": None},
            "extruder": {"temperature": nozzle, "target": targets[0]},
            "heater_bed": {"temperature": bed, "target": targets[1]},
            "heater_generic chamber": {"temperature": chamber, "target": targets[2]},
        }

    def do_GET(self):
        path = self.path.split("?")[0]
        if path == "/mock/scenarios":
            self.send_json({"current": scenario["name"], "available": list(SCENARIOS) + list(ABUSE)})
            return
        if not self.authorized():
            self.send_err(401, "Unauthorized")
            return
        if path == "/access/oneshot_token":
            token = secrets.token_hex(16).upper()
            tokens.add(token)
            self.send_json(token)
        elif path == "/printer/objects/list":
            self.send_json({"objects": ["print_stats", "virtual_sdcard", "display_status", "extruder",
                                        "heater_bed", "webhooks", "heater_generic chamber"]})
        elif path == "/printer/objects/query":
            if scenario["name"] == "klippy-disconnected":
                self.send_err(503, "Klippy Disconnected")
                return
            if scenario["name"] in ("flood", "flood-declared"):
                self.flood("application/json", declared=scenario["name"] == "flood-declared")
                return
            if scenario["name"] == "hang":
                time.sleep(60)
                self.close_connection = True
                return
            self.send_json({"status": self.status()})
        elif path.startswith(("/server/files/", "/server/webcams/", "/webcam/")):
            self.proxy()
        else:
            self.send_error(404)

    def do_POST(self):
        path = self.path.split("?")[0]
        if path.startswith("/mock/scenario/"):
            name = path.rsplit("/", 1)[1]
            if name not in SCENARIOS and name not in ABUSE:
                self.send_err(404, "unknown scenario " + name)
                return
            scenario["name"] = name
            self.send_json(name)
            return
        if not self.authorized():
            self.send_err(401, "Unauthorized")
            return
        transitions = {
            "/printer/print/pause": ("printing", "paused"),
            "/printer/print/resume": ("paused", "printing"),
            "/printer/print/cancel": (None, "cancelled"),
        }
        if path in transitions:
            want, nxt = transitions[path]
            current = SCENARIOS[scenario["name"]][0]
            if want is None or current == want:
                scenario["name"] = nxt
        self.send_json("ok")


def main():
    global args
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=7125)
    ap.add_argument("--scenario", default="printing", choices=list(SCENARIOS))
    ap.add_argument("--file", default="benchy.gcode")
    ap.add_argument("--upstream", default="", help="real Moonraker to proxy metadata/thumbnails from")
    ap.add_argument("--api-key", default="", help="API key for --upstream")
    ap.add_argument("--require-key", default="", help="reject requests without this X-Api-Key")
    ap.add_argument("--thumbnail", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "assets", "thumbnail.png"),
                    help="PNG served as the job thumbnail when there is no --upstream")
    ap.add_argument("--webcam", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "assets", "webcam.jpg"),
                    help="JPEG served as the webcam snapshot when there is no --upstream")
    ap.add_argument("--no-webcam", action="store_true", help="report no webcams")
    args = ap.parse_args()
    scenario["name"] = args.scenario
    ThreadingHTTPServer(("127.0.0.1", args.port), Handler).serve_forever()


if __name__ == "__main__":
    main()
