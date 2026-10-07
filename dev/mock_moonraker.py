#!/usr/bin/env python3
"""Tiny fake Moonraker for developing the widget without a real print.

Serves one of several scenarios (idle, heating, printing, paused, complete,
error, klippy shutdown, ...) and lets you switch between them at runtime.
File metadata and thumbnails come from dev/assets/thumbnail.png by default, and
the webcam serves dev/assets/webcam.jpg; with --upstream all of these are
proxied to a real printer instead.

  ./dev/mock_moonraker.py --scenario printing --file "benchy.gcode" \
      --upstream http://192.168.1.50

The real printer's API key, when it needs one, comes from the
MOONRAKER_API_KEY environment variable, never from the command line: other
local users can read every process's arguments, but not its environment.
Read it without leaving it in your shell history:

  read -rs MOONRAKER_API_KEY && export MOONRAKER_API_KEY

  # switch scenario while running
  curl -X POST http://127.0.0.1:7125/mock/scenario/paused
  curl http://127.0.0.1:7125/mock/scenarios

With --require-key KEY every request without that X-Api-Key (or a one-shot
token the mock issued) gets a 401, which reproduces an auth failure.
"""
import argparse
import hmac
import json
import os
import secrets
import time
import urllib.parse
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
    # Filament changer (--afc): a print at 42% in the middle of change 3 of 12.
    "toolchange-unload": ("printing", 0.42, "ready",    (220, 90, 45), ""),
    "toolchange-load":  ("printing",  0.42, "ready",    (220, 90, 45), ""),
    "toolchange-resume": ("printing", 0.42, "ready",    (220, 90, 45), ""),
}

# Elegoo Canvas style AFC unit: name, tool, material, color, grams, ready.
AFC_LANES = [
    ("CANVAS_1", "T0", "PETG", "#212121", 980.4, True),
    ("CANVAS_2", "T1", "TPU", "#F5F5F5", 0, True),
    ("CANVAS_3", "T2", "PLA", "#E64A19", 1000, True),
    ("CANVAS_4", "T3", "PLA", "", 0, False),
]
# scenario -> (AFC state, loaded lane, lane being moved, target, moving lane's status)
AFC_CHANGES = {
    "toolchange-unload": ("Unloading", "CANVAS_1", "CANVAS_1", "CANVAS_3", "Tool Unloading"),
    "toolchange-load": ("Loading", None, "CANVAS_3", "CANVAS_3", "HUB Loading"),
    "toolchange-resume": ("Restoring", "CANVAS_3", None, "CANVAS_3", "Tool Loaded"),
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
upstream_key = ""
# Upstream answers are read whole before being relayed, so cap them.
MAX_PROXY_BYTES = 8 * 1024 * 1024
scenario = {"name": "printing"}
# State changed by G-code sent through /printer/gcode/script.
machine = {"spool_id": 3, "lane_spools": {"CANVAS_1": 3}, "light": 1.0, "pause_next": False, "pause_at": 0, "excluded": []}
# Spoolman inventory (--spoolman), served through Moonraker's proxy.
SPOOLS = [
    {"id": 3, "remaining_weight": 642.5, "archived": False, "last_used": "2026-10-06T18:00:00Z",
     "filament": {"name": "PLA+ Galaxy Black", "material": "PLA", "color_hex": "1B1B2F",
                  "vendor": {"name": "Polymaker"}}},
    {"id": 7, "remaining_weight": 980.0, "archived": False, "last_used": "2026-10-01T10:00:00Z",
     "filament": {"name": "PETG Silk Rainbow", "material": "PETG", "color_hex": "FF0000",
                  "multi_color_hexes": "E53935,FDD835,43A047,1E88E5", "vendor": {"name": "Sunlu"}}},
    {"id": 9, "remaining_weight": 120.0, "archived": False, "last_used": None,
     "filament": {"name": "TPU 95A White", "material": "TPU", "color_hex": "F5F5F5", "vendor": None}},
    {"id": 2, "remaining_weight": 0, "archived": True, "last_used": "2025-01-01T00:00:00Z",
     "filament": {"name": "Old PLA", "material": "PLA", "color_hex": "888888"}},
]
MOCK_OBJECTS = ["calibration_cube.stl_id_0_copy_0", "calibration_cube.stl_id_0_copy_1",
                "benchy.stl_id_1_copy_0", "clip.stl_id_2_copy_0"]
gcode_log = []
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
        if hmac.compare_digest(self.headers.get("X-Api-Key", ""), args.require_key):
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
        if not proxy_allowed(path):
            self.send_err(403, "the mock only proxies file metadata, thumbnails, and the webcam")
            return
        req = urllib.request.Request(args.upstream + path)
        if upstream_key:
            req.add_header("X-Api-Key", upstream_key)
        try:
            # No redirects: urllib would copy X-Api-Key to wherever they point.
            with NO_REDIRECTS.open(req, timeout=5) as r:
                body = r.read(MAX_PROXY_BYTES + 1)
                if len(body) > MAX_PROXY_BYTES:
                    self.send_error(502, "upstream response too large")
                    return
                self.send_response(r.status)
                self.send_header("Content-Type", r.headers.get("Content-Type", "application/octet-stream"))
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
        except Exception as e:  # noqa: BLE001
            self.send_error(502, str(e))

    def afc_status(self):
        state, loaded, moving, target, lane_status = AFC_CHANGES.get(
            scenario["name"], ("Idle", "CANVAS_1", None, None, ""))
        changing = scenario["name"] in AFC_CHANGES
        out = {"AFC": {
            "current_load": loaded, "current_lane": moving, "next_lane": target,
            "current_state": state, "current_toolchange": 3 if changing else 0,
            "number_of_toolchanges": 12 if changing else 0, "error_state": False,
            "message": {"message": "", "type": ""}, "lanes": [l[0] for l in AFC_LANES],
            "units": ["canvas CANVAS_1"], "bypass_state": False,
        }}
        for i, (name, tool, material, color, grams, ready) in enumerate(AFC_LANES):
            out["AFC_lane " + name] = {
                "lane": i + 1, "map": tool, "load": ready, "prep": ready,
                "tool_loaded": name == loaded, "material": material, "color": color,
                "filament_name": "", "multi_color_hexes": [], "weight": grams,
                "status": lane_status if name == moving else "None",
                "spool_id": machine["lane_spools"].get(name),
            }
        return out

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
            "led case": {"color_data": [[0.0, 0.0, 0.0, machine["light"]]]},
            "exclude_object": {
                "objects": [{"name": n, "center": [60 + 40 * i, 110],
                             "polygon": [[40 + 40 * i, 90], [80 + 40 * i, 90], [80 + 40 * i, 130], [40 + 40 * i, 130]]}
                            for i, n in enumerate(MOCK_OBJECTS)] if has_file else [],
                "excluded_objects": machine["excluded"] if has_file else [],
                "current_object": next((n for n in MOCK_OBJECTS if n not in machine["excluded"]), None)
                if active else None,
            },
            "gcode_macro SET_PRINT_STATS_INFO": {
                "pause_next_layer": {"enable": machine["pause_next"], "call": "PAUSE"},
                "pause_at_layer": {"enable": machine["pause_at"] > 0, "layer": machine["pause_at"], "call": "PAUSE"},
            },
            **(self.afc_status() if args.afc else {}),
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
            objects = ["print_stats", "virtual_sdcard", "display_status", "extruder",
                       "heater_bed", "webhooks", "heater_generic chamber", "led case", "led hotend",
                       "exclude_object", "gcode_macro SET_PRINT_STATS_INFO", "gcode_macro SET_PAUSE_AT_LAYER",
                       "gcode_macro SET_PAUSE_NEXT_LAYER"]
            if args.afc:
                objects += ["AFC", "AFC_canvas CANVAS_1", "AFC_hub toolhead_4way_hub", "AFC_extruder extruder"]
                objects += ["AFC_lane " + l[0] for l in AFC_LANES] + ["AFC_canvas_lane " + l[0] for l in AFC_LANES]
            self.send_json({"objects": objects})
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
        elif path == "/server/spoolman/status":
            if not args.spoolman:
                self.send_error(404)
                return
            self.send_json({"spoolman_connected": True, "pending_reports": [], "spool_id": machine["spool_id"]})
        elif path.startswith(("/server/files/", "/server/webcams/", "/webcam/")):
            self.proxy()
        else:
            self.send_error(404)

    def json_body(self):
        length = int(self.headers.get("Content-Length") or 0)
        try:
            return json.loads(self.rfile.read(length) or b"{}") if length else {}
        except ValueError:
            return {}

    def spoolman(self, path):
        if not args.spoolman:
            self.send_error(404)
            return
        body = self.json_body()
        if path == "/server/spoolman/spool_id":
            machine["spool_id"] = body.get("spool_id")
            self.send_json({"spool_id": machine["spool_id"]})
        elif path == "/server/spoolman/proxy":
            target = body.get("path", "")
            if target.startswith("/v1/spool/"):
                spool = next((s for s in SPOOLS if str(s["id"]) == target.rsplit("/", 1)[1]), None)
                self.send_json({"response": spool, "error": None if spool else {"status_code": 404, "message": "not found"}})
            elif target.startswith("/v1/spool"):
                live = [s for s in SPOOLS if not s["archived"]] if "allow_archived=false" in target else SPOOLS
                self.send_json({"response": live, "error": None})
            else:
                self.send_json({"response": None, "error": {"status_code": 404, "message": "unknown path"}})
        else:
            self.send_error(404)

    def gcode(self, script):
        """The few commands the widget sends; everything else is just logged."""
        gcode_log.append(script)
        print(f"[mock] gcode: {script}", flush=True)
        words = script.split()
        params = dict(w.split("=", 1) for w in words[1:] if "=" in w)
        if words and words[0] == "SET_LED" and params.get("LED") == "case":
            machine["light"] = float(params.get("WHITE", 0))
        elif words and words[0] == "SET_PAUSE_AT_LAYER":
            machine["pause_at"] = int(params["LAYER"]) if "LAYER" in params else 0
        elif words and words[0] == "EXCLUDE_OBJECT" and params.get("NAME") in MOCK_OBJECTS:
            if params["NAME"] not in machine["excluded"]:
                machine["excluded"].append(params["NAME"])
        elif words and words[0] == "SET_SPOOL_ID" and params.get("LANE") in [l[0] for l in AFC_LANES]:
            lane, spool = params["LANE"], params.get("SPOOL_ID", "")
            if spool == "":
                machine["lane_spools"].pop(lane, None)
            elif int(spool) not in [v for k, v in machine["lane_spools"].items() if k != lane]:
                machine["lane_spools"][lane] = int(spool)   # AFC refuses a spool held by another lane
        elif words and words[0] == "SET_PAUSE_NEXT_LAYER":
            machine["pause_next"] = params.get("ENABLE", "1") != "0"
        return "ok"

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
        if path.startswith("/server/spoolman/"):
            self.spoolman(path)
            return
        if path == "/printer/gcode/script":
            query = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)
            self.send_json(self.gcode(query.get("script", [""])[0]))
            return
        if path in transitions:
            want, nxt = transitions[path]
            current = SCENARIOS[scenario["name"]][0]
            if want is None or current == want:
                scenario["name"] = nxt
        self.send_json("ok")


def proxy_allowed(path):
    """Only what the widget needs from a real printer, never other endpoints
    (config files, G-code, /access/api_key) that the forwarded key could open."""
    route, _, query = path.partition("?")
    if ".." in urllib.parse.unquote(route).split("/") or "\\" in urllib.parse.unquote(route):
        return False
    if route == "/server/files/metadata":
        return True
    if route.startswith("/server/files/gcodes/"):
        name = urllib.parse.unquote(route).lower()
        return "/.thumbs/" in name and name.endswith((".png", ".jpg", ".jpeg"))
    if route == "/server/webcams/list":
        return True
    return route == "/webcam/" and query in ("action=snapshot", "")


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None   # surfaces as an HTTPError, relayed as 502


NO_REDIRECTS = urllib.request.build_opener(_NoRedirect)


def main():
    global args, upstream_key
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=7125)
    ap.add_argument("--scenario", default="printing", choices=list(SCENARIOS))
    ap.add_argument("--file", default="benchy.gcode")
    ap.add_argument("--upstream", default="", help="real Moonraker to proxy metadata/thumbnails from")
    # Kept only to refuse it: a key in argv is visible to every local user.
    ap.add_argument("--api-key", default=None, help=argparse.SUPPRESS)
    ap.add_argument("--require-key", default="",
                    help="reject requests without this X-Api-Key (a made-up test key, never a real one; "
                         "MOCK_REQUIRE_KEY in the environment keeps it out of the process list)")
    ap.add_argument("--thumbnail", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "assets", "thumbnail.png"),
                    help="PNG served as the job thumbnail when there is no --upstream")
    ap.add_argument("--webcam", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "assets", "webcam.jpg"),
                    help="JPEG served as the webcam snapshot when there is no --upstream")
    ap.add_argument("--no-webcam", action="store_true", help="report no webcams")
    ap.add_argument("--afc", action="store_true", help="simulate an AFC filament changer (4-lane Canvas)")
    ap.add_argument("--spoolman", action="store_true", help="simulate Moonraker's Spoolman integration")
    args = ap.parse_args()
    if args.api_key is not None:
        ap.error("--api-key is no longer accepted: it would show the key in the process list. "
                 "Set MOONRAKER_API_KEY in the environment instead.")
    if args.upstream:
        parts = urllib.parse.urlsplit(args.upstream)
        if parts.scheme not in ("http", "https") or not parts.hostname:
            ap.error("--upstream must be an http(s) URL")
        if parts.username or parts.password:
            ap.error("--upstream must not contain credentials; use MOONRAKER_API_KEY")
        args.upstream = args.upstream.rstrip("/")
    # Taken out of the environment so nothing started later inherits it.
    upstream_key = os.environ.pop("MOONRAKER_API_KEY", "")
    args.require_key = os.environ.pop("MOCK_REQUIRE_KEY", "") or args.require_key
    if args.upstream and not args.require_key:
        # Otherwise any local process could use the mock to reach the printer
        # with the real key.
        ap.error("--upstream needs a test key for the mock itself: set MOCK_REQUIRE_KEY")
    scenario["name"] = args.scenario
    ThreadingHTTPServer(("127.0.0.1", args.port), Handler).serve_forever()


if __name__ == "__main__":
    main()
