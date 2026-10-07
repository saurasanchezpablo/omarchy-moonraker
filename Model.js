.pragma library

// Pure helpers for the Moonraker bar widget. Everything here is free of QML
// state so it can be unit-tested with plain node/qmltestrunner.

// Hard limits for anything read from the printer. curl enforces them while
// the data streams in, so a broken or hostile endpoint can't make the shell
// buffer an unbounded response or hold a request open forever.
var MAX_JSON_BYTES = 1048576      // Moonraker replies are a few KB
var MAX_IMAGE_BYTES = 2097152     // slicer thumbnails are tens of KB
var MAX_SNAPSHOT_BYTES = 4194304  // a 1080p webcam JPEG is a few hundred KB
var REQUEST_TIMEOUT_S = 10
var CONNECT_TIMEOUT_S = 5

// Webcam snapshots: one frame at a time, only while the popup is open.
var CAMERA_FRAME_MS = 1000        // pause between frames
var CAMERA_RETRY_MS = 5000        // pause after a failed frame

var DISPLAY_MODES = ["icon", "progress", "full"]
var TEMP_KEYS = ["nozzle", "bed", "chamber"]

// Candidate Klipper object names for a chamber sensor, most specific first.
var CHAMBER_CANDIDATES = [
  "heater_generic chamber",
  "temperature_sensor chamber",
  "temperature_fan chamber",
  "heater_generic chamber_heater",
  "temperature_sensor chamber_temp"
]

var ICONS = {
  printer: "\u{F042B}",   // nf-md-printer_3d
  nozzle: "\u{F0E5B}",    // nf-md-printer_3d_nozzle
  bed: "\u{F0438}",       // nf-md-radiator
  chamber: "\u{F050F}",   // nf-md-thermometer
  pause: "\u{F03E4}",     // nf-md-pause
  play: "\u{F040A}",      // nf-md-play
  stop: "\u{F04DB}",      // nf-md-stop
  check: "\u{F012C}",     // nf-md-check
  heat: "\u{F0238}",      // nf-md-fire
  lock: "\u{F033E}",      // nf-md-lock
  alert: "\u{F0026}",     // nf-md-alert
  offline: "\u{F0319}",   // nf-md-lan_disconnect
  web: "\u{F059F}",       // nf-md-web
  cog: "\u{F0493}",       // nf-md-cog
  refresh: "\u{F0450}",   // nf-md-refresh
  camera: "\u{F0100}",    // nf-md-camera
  swap: "\u{F04E1}"       // nf-md-swap_horizontal
}

function normalizeUrl(raw) {
  var url = String(raw || "").trim()
  if (url === "") return ""
  if (!/^https?:\/\//i.test(url)) url = "http://" + url
  return url.replace(/\/+$/, "")
}

// "scheme://host[:port]", lowercased; "" for anything that isn't http(s).
function urlOrigin(url) {
  var m = String(url || "").match(/^(https?:\/\/[^\/?#]+)/i)
  return m ? m[1].toLowerCase() : ""
}

function sameOrigin(a, b) {
  var o = urlOrigin(a)
  return o !== "" && o === urlOrigin(b)
}

function sameHost(a, b) {
  var h = hostLabel(a).toLowerCase()
  return h !== "" && h === hostLabel(b).toLowerCase()
}

function hostLabel(url) {
  var m = String(url || "").match(/^https?:\/\/([^\/:]+)/i)
  return m ? m[1] : ""
}

function normalizeDisplay(value) {
  var v = String(value || "")
  return DISPLAY_MODES.indexOf(v) >= 0 ? v : "progress"
}

function nextDisplay(value) {
  var i = DISPLAY_MODES.indexOf(normalizeDisplay(value))
  return DISPLAY_MODES[(i + 1) % DISPLAY_MODES.length]
}

// shell.json arrays reach QML as sequence wrappers, not JS arrays.
function toArray(value) {
  if (Array.isArray(value)) return value
  if (value && typeof value === "object" && typeof value.length === "number")
    return Array.prototype.slice.call(value)
  return null
}

function normalizeTemps(value) {
  value = toArray(value)
  if (!value) return ["nozzle", "bed"]
  var out = []
  for (var i = 0; i < TEMP_KEYS.length; i++)
    if (value.indexOf(TEMP_KEYS[i]) >= 0) out.push(TEMP_KEYS[i])
  return out
}

function toggleTemp(list, key) {
  var cur = normalizeTemps(list)
  var i = cur.indexOf(key)
  if (i >= 0) cur.splice(i, 1)
  else cur.push(key)
  return normalizeTemps(cur)
}

function pickChamberObject(objects, override) {
  var o = String(override || "").trim()
  if (o !== "") return o
  objects = toArray(objects)
  if (!objects) return ""
  for (var i = 0; i < CHAMBER_CANDIDATES.length; i++)
    if (objects.indexOf(CHAMBER_CANDIDATES[i]) >= 0) return CHAMBER_CANDIDATES[i]
  for (var j = 0; j < objects.length; j++) {
    var name = String(objects[j])
    if (/^(heater_generic|temperature_sensor|temperature_fan) .*chamber/i.test(name)
        && !/protection|thermal/i.test(name)) return name
  }
  return ""
}

// `extra` holds already-encoded query parts, e.g. from afcQuery().
function queryPath(chamberObject, extra) {
  var objs = ["print_stats", "virtual_sdcard", "display_status", "extruder", "heater_bed", "webhooks"]
  if (chamberObject) objs.push(chamberObject)
  return "/printer/objects/query?" + objs.map(encodeURIComponent).concat(extra || []).join("&")
}

function isActiveState(state) {
  return state === "printing" || state === "paused"
}

function stateLabel(state, klippyState) {
  if (klippyState && klippyState !== "ready") {
    if (klippyState === "startup") return "Starting up"
    if (klippyState === "shutdown") return "Klipper shutdown"
    if (klippyState === "error") return "Klipper error"
    return "Klipper " + klippyState
  }
  switch (state) {
  case "printing": return "Printing"
  case "paused": return "Paused"
  case "complete": return "Complete"
  case "cancelled": return "Cancelled"
  case "error": return "Error"
  case "standby": return "Idle"
  default: return state ? state.charAt(0).toUpperCase() + state.slice(1) : "Unknown"
  }
}

function progressFraction(status) {
  var ds = status && status.display_status ? Number(status.display_status.progress) : 0
  var vs = status && status.virtual_sdcard ? Number(status.virtual_sdcard.progress) : 0
  var p = isFinite(ds) && ds > 0 ? ds : (isFinite(vs) ? vs : 0)
  return Math.max(0, Math.min(1, p))
}

// Remaining seconds, blending the slicer estimate with file-progress
// extrapolation the way Mainsail/Fluidd do. Returns -1 when unknown.
function remainingSeconds(printDuration, progress, slicerEstimate) {
  var elapsed = Number(printDuration) || 0
  var p = Number(progress) || 0
  var est = []
  if (p > 0.01 && elapsed > 0) est.push(Math.max(0, elapsed / p - elapsed))
  var slicer = Number(slicerEstimate) || 0
  if (slicer > 0) est.push(Math.max(0, slicer - elapsed))
  if (est.length === 0) return -1
  // Early in the print file extrapolation is noisy — trust the slicer.
  if (est.length === 2 && p < 0.05) return est[1]
  var sum = 0
  for (var i = 0; i < est.length; i++) sum += est[i]
  return sum / est.length
}

function formatDuration(seconds) {
  var s = Math.round(Number(seconds))
  if (!isFinite(s) || s < 0) return "—"
  var h = Math.floor(s / 3600)
  var m = Math.floor((s % 3600) / 60)
  if (h > 0) return h + "h " + (m < 10 ? "0" : "") + m + "m"
  if (m > 0) return m + "m"
  return s + "s"
}

function formatTemp(t) {
  var n = Number(t)
  return isFinite(n) ? Math.round(n) + "°" : "—"
}

function formatTempPair(temp, target) {
  var t = Number(target)
  return formatTemp(temp) + (isFinite(t) && t > 0 ? " / " + Math.round(t) + "°" : "")
}

function formatFilament(mm) {
  var n = Number(mm)
  if (!isFinite(n) || n <= 0) return "—"
  return n >= 1000 ? (n / 1000).toFixed(2) + " m" : Math.round(n) + " mm"
}

function baseName(path) {
  var p = String(path || "")
  var i = p.lastIndexOf("/")
  return i >= 0 ? p.slice(i + 1) : p
}

function displayFileName(path) {
  return baseName(path).replace(/\.(gcode(\.3mf)?|3mf|bgcode|g)$/i, "")
}

// Largest thumbnail from file metadata, resolved to a gcodes-root path.
function thumbnailPath(filename, metadata) {
  var thumbs = metadata && Array.isArray(metadata.thumbnails) ? metadata.thumbnails : []
  var best = null
  for (var i = 0; i < thumbs.length; i++) {
    var t = thumbs[i]
    if (!t || !t.relative_path) continue
    if (!best || (Number(t.width) || 0) > (Number(best.width) || 0)) best = t
  }
  if (!best) return ""
  var file = String(filename || "")
  var slash = file.lastIndexOf("/")
  var dir = slash >= 0 ? file.slice(0, slash + 1) : ""
  return dir + best.relative_path
}

// ---------- Filament changer (AFC) ----------
// Armored Turtle's AFC add-on drives Box Turtle, Night Owl, Elegoo's Canvas
// and others. The `AFC` object holds the changer state; every lane is its own
// object ("AFC_lane CANVAS_1", "AFC_stepper lane1", …) with the same fields.

var AFC_FIELDS = ["current_load", "current_lane", "next_lane", "current_state", "current_toolchange",
                  "number_of_toolchanges", "error_state", "message", "lanes", "units", "bypass_state"]
var AFC_LANE_FIELDS = ["lane", "map", "load", "prep", "tool_loaded", "material", "color", "filament_name",
                       "multi_color_hexes", "weight", "status"]
// Lane object types, preferred first. Unknown AFC_* types with the lane's
// name are accepted too, except the unit objects (which can share it).
var AFC_LANE_TYPES = ["AFC_lane", "AFC_stepper", "AFC_hybrid_stepper"]

// AFC.current_state values that mean filament is moving.
var AFC_BUSY = ["Loading", "Unloading", "ToolSwap", "ToolDock", "ToolPickup", "Ejecting", "Moving", "Restoring"]

// lane name -> Klipper object name, from the printer's object list.
function afcLaneObjects(objects, afcStatus) {
  objects = toArray(objects) || []
  var lanes = toArray(afcStatus && afcStatus.lanes) || []
  var units = (toArray(afcStatus && afcStatus.units) || []).map(function(u) { return "AFC_" + String(u) })
  var out = {}
  for (var i = 0; i < lanes.length; i++) {
    var lane = String(lanes[i])
    var best = "", bestRank = 99
    for (var j = 0; j < objects.length; j++) {
      var obj = String(objects[j])
      var space = obj.indexOf(" ")
      if (space < 0 || obj.slice(space + 1) !== lane || obj.indexOf("AFC_") !== 0) continue
      if (units.indexOf(obj) >= 0) continue
      var rank = AFC_LANE_TYPES.indexOf(obj.slice(0, space))
      if (rank < 0) rank = AFC_LANE_TYPES.length
      if (rank < bestRank) { best = obj; bestRank = rank }
    }
    if (best !== "") out[lane] = best
  }
  return out
}

// Encoded query parts for the AFC object and the lanes, trimmed to the
// fields the widget uses.
function afcQuery(laneObjects) {
  var parts = ["AFC=" + AFC_FIELDS.join(",")]
  for (var lane in laneObjects)
    parts.push(encodeURIComponent(laneObjects[lane]) + "=" + AFC_LANE_FIELDS.join(","))
  return parts
}

// "#rrggbb" from AFC's "#RRGGBB", "RRGGBB", or "#RGB"; "" when unusable.
function normalizeColor(value) {
  var c = String(value || "").trim().replace(/^#/, "")
  if (/^[0-9a-f]{3}$/i.test(c)) c = c.replace(/(.)/g, "$1$1")
  return /^[0-9a-f]{6}$/i.test(c) ? "#" + c.toLowerCase() : ""
}

// Whether dark text reads better than light text on this color.
function isLightColor(hex) {
  var c = normalizeColor(hex)
  if (c === "") return false
  var r = parseInt(c.slice(1, 3), 16), g = parseInt(c.slice(3, 5), 16), b = parseInt(c.slice(5, 7), 16)
  return 0.299 * r + 0.587 * g + 0.114 * b > 150
}

function formatWeight(grams) {
  var g = Number(grams)
  if (!isFinite(g) || g <= 0) return ""
  return g >= 1000 ? (g / 1000).toFixed(g >= 10000 ? 0 : 1) + " kg" : Math.round(g) + " g"
}

// Reduced changer state, or null when the printer has no AFC.
//   lanes:    [{ name, tool, material, colors, weight, ready, loaded, status }]
//   changing: filament is being moved; stage 0 unload, 1 load, 2 resume
function afcState(status, laneObjects) {
  var afc = status && status.AFC
  if (!afc) return null
  var names = toArray(afc.lanes) || []
  var lanes = []
  for (var i = 0; i < names.length; i++) {
    var name = String(names[i])
    var l = (laneObjects && laneObjects[name] && status[laneObjects[name]]) || {}
    var colors = (toArray(l.multi_color_hexes) || []).map(normalizeColor).filter(function(c) { return c !== "" })
    if (colors.length === 0 && normalizeColor(l.color) !== "") colors = [normalizeColor(l.color)]
    lanes.push({
      name: name,
      tool: String(l.map || ""),
      material: String(l.filament_name || l.material || ""),
      colors: colors,
      weight: Number(l.weight) || 0,
      ready: l.load === true && l.prep === true,
      loaded: name === afc.current_load,
      status: l.status && l.status !== "None" ? String(l.status) : ""
    })
  }
  var state = String(afc.current_state || "")
  var target = afc.next_lane ? String(afc.next_lane) : ""
  var moving = afc.current_lane ? String(afc.current_lane) : ""
  var changing = target !== "" || AFC_BUSY.indexOf(state) >= 0
  var stage = state === "Unloading" ? 0 : state === "Restoring" ? 2 : 1
  var msg = afc.message && afc.message.message ? String(afc.message.message) : ""
  return {
    lanes: lanes,
    loaded: afc.current_load ? String(afc.current_load) : "",
    state: state,
    changing: changing,
    stage: stage,
    target: target,
    // Lane being moved right now (unload: the old one, load: the new one).
    moving: moving !== "" ? moving : (stage === 0 ? String(afc.current_load || "") : target),
    toolchange: Number(afc.current_toolchange) || 0,
    toolchanges: Number(afc.number_of_toolchanges) || 0,
    error: afc.error_state === true,
    message: msg,
    messageType: afc.message && afc.message.type ? String(afc.message.type) : "",
    bypass: afc.bypass_state === true
  }
}

function afcLane(afc, name) {
  if (!afc || !name) return null
  for (var i = 0; i < afc.lanes.length; i++)
    if (afc.lanes[i].name === name) return afc.lanes[i]
  return null
}

// Short label for a lane: its tool ("T2") or, without a map, its name.
function laneLabel(lane) {
  return lane ? (lane.tool || lane.name) : ""
}

// The step AFC is on, for the change card.
function afcStepLabel(afc) {
  if (!afc || !afc.changing) return ""
  var lane = afcLane(afc, afc.moving)
  if (lane && lane.status !== "") return lane.status
  switch (afc.state) {
  case "Unloading": return "Unloading"
  case "Loading": return "Loading"
  case "Restoring": return "Purging and resuming"
  case "Ejecting": return "Ejecting"
  case "Moving": return "Moving lane"
  default: return afc.state || "Preparing"
  }
}

// ---------- Webcams ----------

// Enabled webcams from /server/webcams/list that can produce a still frame.
function webcamList(result) {
  var cams = toArray(result && result.webcams) || []
  var out = []
  for (var i = 0; i < cams.length; i++) {
    var c = cams[i]
    if (!c || c.enabled === false) continue
    var snapshot = snapshotPath(c)
    if (snapshot === "") continue
    var rotation = Number(c.rotation) || 0
    out.push({
      name: String(c.name || "Camera " + (out.length + 1)),
      snapshot: snapshot,
      rotation: [0, 90, 180, 270].indexOf(rotation) >= 0 ? rotation : 0,
      flipH: c.flip_horizontal === true,
      flipV: c.flip_vertical === true,
      aspect: parseAspect(c.aspect_ratio)
    })
  }
  return out
}

// The snapshot URL as configured. mjpg-streamer style services that only
// list a stream URL give a snapshot by swapping the action, as Mainsail does.
function snapshotPath(cam) {
  var snap = String(cam.snapshot_url || "").trim()
  if (snap !== "") return snap
  var stream = String(cam.stream_url || "").trim()
  if (/[?&]action=stream\b/.test(stream)) return stream.replace(/([?&]action=)stream\b/, "$1snapshot")
  return ""
}

function parseAspect(value) {
  var m = String(value || "").match(/^\s*(\d+(?:\.\d+)?)\s*[:\/x]\s*(\d+(?:\.\d+)?)\s*$/)
  var r = m ? Number(m[1]) / Number(m[2]) : 0
  return r > 0.2 && r < 5 ? r : 16 / 9
}

// Index of the webcam named `name`, else the first one; -1 when there's none.
function pickWebcam(list, name) {
  if (!list || list.length === 0) return -1
  for (var i = 0; i < list.length; i++)
    if (list[i].name === name) return i
  return 0
}

// Absolute URLs to try for a snapshot, most likely first. Relative URLs go to
// the configured origin, then to the same host on its default port: Mainsail
// and Fluidd serve /webcam/ from the web UI (nginx), not from Moonraker's 7125.
function snapshotCandidates(baseUrl, snapshot) {
  var snap = String(snapshot || "")
  if (/^https?:\/\//i.test(snap)) return [snap]
  if (/^[a-z][a-z0-9+.-]*:/i.test(snap)) return []   // rtsp:, webrtc:, …
  var origin = urlOrigin(baseUrl)
  if (origin === "" || snap === "") return []
  var path = snap.charAt(0) === "/" ? snap : "/" + snap
  var out = [origin + path]
  var portless = origin.replace(/:\d+$/, "")
  if (portless !== origin) out.push(portless + path)
  return out
}

// A URL safe to show in `status`: no user:password@.
function redactUrl(url) {
  return String(url || "").replace(/^(https?:\/\/)[^\/@]*@/i, "$1")
}

function encodePath(path) {
  return String(path || "").split("/").map(encodeURIComponent).join("/")
}

function tempEntry(status, key, chamberObject) {
  var obj = null
  if (key === "nozzle") obj = status.extruder
  else if (key === "bed") obj = status.heater_bed
  else if (key === "chamber" && chamberObject) obj = status[chamberObject]
  if (!obj || obj.temperature === undefined) return null
  return {
    key: key,
    temperature: Number(obj.temperature),
    target: obj.target === undefined ? 0 : Number(obj.target)
  }
}

// Text painted in the bar. `data` is the widget's reduced state.
function barText(data, display, temps) {
  var mode = normalizeDisplay(display)
  if (!data.configured) return ICONS.printer
  if (data.authFailed) return ICONS.lock
  if (!data.online) return ICONS.offline
  if (data.klippyState && data.klippyState !== "ready") return ICONS.alert
  if (data.compact) return data.state === "complete" ? ICONS.check : ICONS.printer

  var parts = []
  var active = isActiveState(data.state)
  var icon = data.state === "paused" ? ICONS.pause
    : data.state === "error" ? ICONS.alert
    : data.state === "complete" ? ICONS.check
    : ICONS.printer
  if (data.changing) icon = ICONS.swap
  parts.push(icon)

  if (data.changing && mode !== "icon") {
    parts.push(data.changeTarget ? "→ " + data.changeTarget : "Changing")
  } else if (mode !== "icon" && data.heating) {
    parts.push(ICONS.heat + " Heating")
  } else if (mode !== "icon" && active) {
    parts.push(Math.floor(data.progress * 100) + "%")
    if (data.remaining >= 0) parts.push(formatDuration(data.remaining))
  }

  if (mode === "full") {
    var list = normalizeTemps(temps)
    for (var i = 0; i < list.length; i++) {
      var entry = data.temps[list[i]]
      if (entry) parts.push(ICONS[list[i]] + " " + formatTemp(entry.temperature))
    }
  }

  return parts.join("  ")
}

// ---------- curl transport ----------

// A value for curl's config file syntax. Newlines are dropped so a value can
// never start a new config line (and with it, a new option).
function curlQuote(value) {
  return "\"" + String(value).replace(/[\r\n]/g, "").replace(/\\/g, "\\\\").replace(/"/g, "\\\"") + "\""
}

// Config fed to `curl --config -` on stdin, so the URL and API key never
// appear in the process list.
function curlConfig(opts) {
  var lines = [
    "url = " + curlQuote(opts.url),
    "proto = \"=http,https\"",
    "silent",
    "max-filesize = " + opts.maxBytes,
    "max-time = " + REQUEST_TIMEOUT_S,
    "connect-timeout = " + CONNECT_TIMEOUT_S,
    "write-out = \"\\n%{http_code} %{redirect_url} %{content_type}\""
  ]
  if (opts.method && opts.method !== "GET") lines.push("request = " + curlQuote(opts.method))
  if (opts.apiKey) lines.push("header = " + curlQuote("X-Api-Key: " + opts.apiKey))
  if (opts.output) {
    lines.push("output = " + curlQuote(opts.output))
    lines.push("create-dirs")
    lines.push("remove-on-error")
  }
  return lines.join("\n") + "\n"
}

// stdout is the body (unless written to a file) followed by the write-out
// trailer "\n<status> <redirect-url> <content-type>". curl never follows
// redirects; the target is only reported. The redirect URL has no spaces
// (curl encodes them) and is empty when there was none.
function parseCurlOutput(text) {
  var s = String(text || "")
  var cut = s.lastIndexOf("\n")
  var parts = (cut >= 0 ? s.slice(cut + 1) : s).split(" ")
  return {
    body: cut >= 0 ? s.slice(0, cut) : "",
    status: Number(parts[0]) || 0,
    redirect: parts.length > 2 ? parts[1] : "",
    contentType: parts.length > 2 ? parts.slice(2).join(" ") : (parts[1] || "")
  }
}

function curlError(exitCode, host) {
  if (exitCode === 63) return { status: 0, tooLarge: true, message: "The printer sent an unexpectedly large response" }
  if (exitCode === 28) return { status: 0, message: "Timed out reaching " + host }
  return { status: 0, message: "No response from " + host }
}
