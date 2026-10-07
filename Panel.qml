import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Moonraker printer widget: a bar chip showing print progress / time left /
// temperatures, plus a popup with job details, controls, and settings.
// Talks to Moonraker's HTTP API through short, size- and time-limited curl
// calls and sends the optional API key as X-Api-Key, so it works over VPNs
// and untrusted networks.
Panel {
  id: root
  moduleName: "io.github.prodpixa.moonraker"
  ipcTarget: "io.github.prodpixa.moonraker"
  // Own the IpcHandler so the target can expose refresh/cycleDisplay too.
  manageIpc: false

  // ---------- Settings ----------
  readonly property string baseUrl: Model.normalizeUrl(setting("url", ""))
  readonly property string apiKey: String(setting("apiKey", "")).trim()
  readonly property string display: Model.normalizeDisplay(setting("display", "progress"))
  readonly property var barTemps: Model.normalizeTemps(setting("temps", ["nozzle", "bed"]))
  readonly property int pollSeconds: Math.max(2, Math.min(120, Number(setting("pollInterval", 5)) || 5))
  readonly property bool hideWhenIdle: setting("hideWhenIdle", false) === true
  readonly property bool compactWhenIdle: setting("compactWhenIdle", false) === true
  readonly property bool hideWhenOffline: setting("hideWhenOffline", false) === true
  readonly property bool showCamera: setting("showCamera", true) !== false
  readonly property string webcamName: String(setting("webcam", "")).trim()
  readonly property bool showFilament: setting("showFilament", true) !== false
  readonly property bool configured: baseUrl !== ""

  // Theme colors come from the bar so the widget follows `omarchy theme set`;
  // fall back to the shell palette while the bar is not injected yet.
  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property color urgentColor: bar ? bar.urgent : Color.urgent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // ---------- Printer state ----------
  property bool online: false
  property bool everConnected: false
  property string lastError: ""
  property bool authFailed: false
  property string klippyState: ""
  property string klippyMessage: ""
  property string printState: ""
  property string filename: ""
  property string statusMessage: ""
  property real progress: 0
  property real printDuration: 0
  property real totalDuration: 0
  property real filamentUsed: 0
  property int currentLayer: 0
  property int totalLayer: 0
  property var temps: ({})
  property var fileMeta: null
  property string metaFor: ""
  property string chamberObject: ""
  property bool objectsProbed: false
  // Filament changer (AFC): every AFC_* object, the lane -> object map once
  // the AFC object has listed its lanes, and the reduced state (Model.afcState).
  property var afcObjects: []
  property var afcLaneObjects: ({})
  property string afcLanesKey: ""
  property var afc: null
  // Lane loaded when the current change started; AFC forgets it once unloaded.
  property string changeOrigin: ""
  property string thumbnailSource: ""
  property string thumbnailFor: ""
  // Webcams from /server/webcams/list (Model.webcamList entries).
  property var webcams: []
  property bool webcamsLoaded: false
  property var webcamsInflight: null

  // ---------- UI state ----------
  property bool settingsOpen: false
  property bool cancelArmed: false
  property bool actionBusy: false
  property int generation: 0
  property var inflight: null
  // Running curl processes, so a reset or teardown can stop all of them.
  property var activeRequests: []
  property int thumbnailSerial: 0
  property int cameraSerial: 0
  // Camera: the snapshot URL that last worked, the next candidate to try,
  // the newest frame on disk, and why the last frame failed.
  property string cameraUrl: ""
  property int cameraAttempt: 0
  property var cameraInflight: null
  property string cameraFrame: ""
  property bool cameraFresh: false
  property string cameraError: ""
  readonly property string runtimeDir: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/omarchy-moonraker"

  readonly property bool printing: online && Model.isActiveState(printState)
  readonly property real remaining: printing
    ? Model.remainingSeconds(printDuration, progress, fileMeta ? fileMeta.estimated_time : 0)
    : -1
  readonly property bool finished: online && filename !== ""
    && (printState === "complete" || printState === "cancelled" || printState === "error")
  readonly property bool klippyReady: klippyState === "" || klippyState === "ready"
  readonly property bool changing: online && afc !== null && afc.changing
  readonly property var changeFrom: changing ? Model.afcLane(afc, changeOrigin) : null
  readonly property var changeTo: changing ? Model.afcLane(afc, afc.target || afc.moving) : null

  readonly property int webcamIndex: Model.pickWebcam(webcams, webcamName)
  readonly property var webcam: webcamIndex >= 0 ? webcams[webcamIndex] : null
  readonly property string webcamKey: webcam ? webcam.name + "\n" + webcam.snapshot : ""
  // Frames are only fetched while the popup is open: nothing runs in the bar.
  readonly property bool cameraActive: opened && showCamera && online && webcam !== null
  readonly property bool problem: configured && (authFailed
    || (everConnected && (!online || !klippyReady || printState === "error")))

  // PRINT_START is still bringing heaters up: printing, no progress yet, and a
  // heater more than a couple of degrees short of its target.
  readonly property bool heating: {
    if (!printing || printState !== "printing" || progress > 0.001) return false
    for (var k in temps) {
      var t = temps[k]
      if (t && t.target > 0 && t.temperature < t.target - 2) return true
    }
    return false
  }

  readonly property string barLabel: Model.barText({
    configured: root.configured,
    online: root.online,
    authFailed: root.authFailed,
    compact: root.compactNow,
    heating: root.heating,
    changing: root.changing,
    changeTarget: Model.laneLabel(root.changeTo),
    klippyState: root.klippyState,
    state: root.printState,
    progress: root.progress,
    remaining: root.remaining,
    temps: root.temps
  }, root.display, root.barTemps)

  readonly property bool iconOnly: barLabel.indexOf(" ") < 0

  readonly property string heroStatus: {
    if (!configured) return "Not configured"
    if (authFailed) return "Unauthorized"
    if (!online) return everConnected ? "Offline" : (lastError ? "Unreachable" : "Connecting…")
    if (changing) return "Changing filament"
    if (heating) return "Heating"
    return Model.stateLabel(printState, klippyState)
  }

  // Fully hidden only through shell.json/IPC: the settings live in this
  // widget's own popup, so the popup must never offer a way to hide it.
  readonly property bool hiddenByRule: (hideWhenOffline && configured && !online)
    || (hideWhenIdle && configured && online && !printing)

  // Compact: a dimmed icon while nothing is printing, still clickable.
  readonly property bool compactNow: compactWhenIdle && configured && online
    && klippyReady && !printing && !changing && printState !== "error"

  // ---------- Settings persistence ----------
  function saveSettings(patch) {
    var next = Object.assign({}, root.settings || {}, patch)
    root.settings = next
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, next)
  }

  function cycleDisplay() {
    saveSettings({ display: Model.nextDisplay(root.display) })
  }

  // ---------- HTTP ----------
  // HTTP goes through curl rather than QML's XMLHttpRequest: aborting an XHR
  // only detaches it from JavaScript while the transfer keeps filling memory,
  // whereas curl stops the transfer at --max-filesize / --max-time. The URL
  // and API key reach curl on stdin, never in argv. `path` is relative to the
  // printer URL or absolute (webcams); the key only goes to the printer's own
  // origin. `file` requests ("thumbnail", "camera") save the body to one of two
  // alternating files under $XDG_RUNTIME_DIR and return { file, type, serial }.
  function request(method, path, onDone, file) {
    var gen = root.generation
    var url = /^https?:\/\//i.test(path) ? path : root.baseUrl + path
    var host = Model.hostLabel(url)
    var serial = 0
    var outFile = ""
    if (file === "camera") serial = ++root.cameraSerial
    else if (file) serial = ++root.thumbnailSerial
    if (file) outFile = root.runtimeDir + "/" + file + "-" + (serial % 2)
    var proc = curlComponent.createObject(root, {
      config: Model.curlConfig({
        url: url,
        method: method,
        apiKey: Model.sameOrigin(url, root.baseUrl) ? root.apiKey : "",
        maxBytes: file === "camera" ? Model.MAX_SNAPSHOT_BYTES : file ? Model.MAX_IMAGE_BYTES : Model.MAX_JSON_BYTES,
        output: outFile
      })
    })
    proc.callback = function(exitCode, text) {
      if (!root) return
      root.untrackRequest(proc)
      if (gen !== root.generation) return
      if (exitCode !== 0) {
        onDone(Model.curlError(exitCode, host), null)
        return
      }
      var res = Model.parseCurlOutput(text)
      var ok = res.status >= 200 && res.status < 300
      if (file) {
        if (ok) onDone(null, { file: outFile, type: res.contentType, serial: serial })
        else onDone({ status: res.status, redirect: res.redirect, message: "HTTP " + res.status
          + (res.redirect ? " → " + Model.redactUrl(res.redirect) : "") }, null)
        return
      }
      var body = null
      try { body = JSON.parse(res.body) } catch (e) {}
      if (ok && body) {
        onDone(null, body.result !== undefined ? body.result : body)
        return
      }
      var msg = ""
      if (res.status === 401 || res.status === 403)
        msg = root.apiKey === "" ? "This printer requires an API key" : "The printer rejected this API key"
      else if (body && body.error && body.error.message) msg = String(body.error.message)
      else msg = "HTTP " + res.status
      onDone({ status: res.status, auth: res.status === 401 || res.status === 403, message: msg }, body)
    }
    root.trackRequest(proc)
    proc.running = true
    return proc
  }

  function trackRequest(proc) {
    activeRequests.push(proc)
  }

  function untrackRequest(proc) {
    var i = activeRequests.indexOf(proc)
    if (i >= 0) activeRequests.splice(i, 1)
  }

  function stopRequest(proc) {
    if (!proc) return
    untrackRequest(proc)
    proc.callback = null
    proc.running = false
  }

  function abortAll() {
    var list = activeRequests.slice()
    activeRequests = []
    inflight = null
    webcamsInflight = null
    cameraInflight = null
    for (var i = 0; i < list.length; i++) {
      list[i].callback = null
      list[i].running = false
    }
  }

  function markOffline(err) {
    root.online = false
    root.authFailed = !!(err && err.auth)
    root.lastError = (err && err.message) || "Unreachable"
    // Surface the settings the moment the key is the problem.
    if (root.authFailed && root.opened) root.settingsOpen = true
  }

  function poll() {
    if (!configured) return
    // One status request at a time; curl ends one that hangs after 10 s.
    if (inflight) return
    if (!objectsProbed) {
      probeObjects()
      return
    }
    var extra = afcObjects.length > 0 ? Model.afcQuery(afcLaneObjects) : []
    inflight = request("GET", Model.queryPath(chamberObject, extra), function(err, result) {
      root.inflight = null
      if (err) {
        // Klippy not ready still means Moonraker is reachable.
        if (err.status === 503 || (err.message && /klippy/i.test(err.message))) {
          root.online = true
          root.everConnected = true
          root.authFailed = false
          root.klippyState = "disconnected"
          root.klippyMessage = ""
          root.lastError = err.message
          return
        }
        root.markOffline(err)
        return
      }
      root.applyStatus(result && result.status ? result.status : {})
    })
  }

  function probeObjects() {
    inflight = request("GET", "/printer/objects/list", function(err, result) {
      root.inflight = null
      if (err) {
        root.markOffline(err)
        return
      }
      var objects = Model.toArray(result ? result.objects : []) || []
      root.chamberObject = Model.pickChamberObject(objects, root.setting("chamberObject", ""))
      root.afcObjects = objects.indexOf("AFC") >= 0
        ? objects.filter(function(o) { return String(o).indexOf("AFC_") === 0 }) : []
      root.objectsProbed = true
      root.poll()
    })
  }

  function applyStatus(status) {
    online = true
    everConnected = true
    authFailed = false
    lastError = ""

    var ps = status.print_stats || {}
    var wh = status.webhooks || {}
    klippyState = wh.state ? String(wh.state) : "ready"
    klippyMessage = klippyState === "ready" ? "" : String(wh.state_message || "")
    printState = String(ps.state || "")
    filename = String(ps.filename || "")
    statusMessage = String(ps.message || (status.display_status && status.display_status.message) || "")
    printDuration = Number(ps.print_duration) || 0
    totalDuration = Number(ps.total_duration) || 0
    filamentUsed = Number(ps.filament_used) || 0
    progress = Model.progressFraction(status)
    var info = ps.info || {}
    currentLayer = Number(info.current_layer) || 0
    totalLayer = Number(info.total_layer) || 0

    var next = {}
    for (var i = 0; i < Model.TEMP_KEYS.length; i++) {
      var entry = Model.tempEntry(status, Model.TEMP_KEYS[i], chamberObject)
      if (entry) next[Model.TEMP_KEYS[i]] = entry
    }
    temps = next

    // The AFC object names its lanes; the lane objects join the next query.
    if (status.AFC) {
      var lanesKey = (Model.toArray(status.AFC.lanes) || []).join("\n")
      if (lanesKey !== afcLanesKey) {
        afcLanesKey = lanesKey
        afcLaneObjects = Model.afcLaneObjects(afcObjects, status.AFC)
        Qt.callLater(poll)
      }
    }
    var prevAfc = afc
    afc = Model.afcState(status, afcLaneObjects)
    if (!afc || !afc.changing) changeOrigin = ""
    else if (afc.stage === 0 && afc.loaded !== "") changeOrigin = afc.loaded
    else if (!prevAfc || !prevAfc.changing) changeOrigin = prevAfc ? prevAfc.loaded : ""

    if (filename !== metaFor) loadMetadata()
    if (opened) loadThumbnail()
    if (opened && !webcamsLoaded) loadWebcams()
  }

  function loadMetadata() {
    var file = filename
    metaFor = file
    fileMeta = null
    thumbnailSource = ""
    thumbnailFor = ""
    if (file === "") return
    request("GET", "/server/files/metadata?filename=" + encodeURIComponent(file), function(err, result) {
      if (err || root.metaFor !== file) return
      root.fileMeta = result
      if (root.totalLayer === 0 && result && result.layer_count) root.totalLayer = Number(result.layer_count) || 0
      if (root.opened) root.loadThumbnail()
    })
  }

  // Thumbnails go through request() like everything else, so they get the
  // same size/time caps and the X-Api-Key header. Two alternating files make
  // the Image reload. A thumbnail that was too large isn't retried.
  function loadThumbnail() {
    var rel = Model.thumbnailPath(filename, fileMeta)
    if (rel === "" || thumbnailFor === rel) return
    thumbnailFor = rel
    request("GET", "/server/files/gcodes/" + Model.encodePath(rel), function(err, img) {
      if (root.thumbnailFor !== rel) return
      if (err) {
        if (!err.tooLarge) root.thumbnailFor = ""
        return
      }
      root.thumbnailSource = "file://" + img.file + "?" + img.serial
    }, "thumbnail")
  }

  // ---------- Camera ----------
  // Re-read on every popup open, so a webcam added in Mainsail/Fluidd shows up
  // without a shell restart. Printers without a webcams API get an empty list.
  function loadWebcams() {
    if (!configured || webcamsInflight) return
    webcamsInflight = request("GET", "/server/webcams/list", function(err, result) {
      root.webcamsInflight = null
      if (err && err.status === 0) return   // unreachable: retried on the next status
      root.webcams = err ? [] : Model.webcamList(result)
      root.webcamsLoaded = true
    })
  }

  // One snapshot at a time: the next is requested only after this one is on
  // screen (or failed), so a slow camera can never pile up requests.
  function loadCameraFrame() {
    if (!cameraActive || cameraInflight) return
    var urls = Model.snapshotCandidates(baseUrl, webcam.snapshot)
    if (urls.length === 0) {
      cameraError = "This webcam has no usable snapshot URL"
      return
    }
    fetchCameraFrame(cameraUrl !== "" ? cameraUrl : urls[cameraAttempt % urls.length], urls, webcamKey, 0)
  }

  function fetchCameraFrame(url, urls, key, hops) {
    cameraInflight = request("GET", url, function(err, img) {
      root.cameraInflight = null
      if (root.webcamKey !== key) return
      // nginx often redirects /webcam/ to the streamer's own port. Follow
      // that, but only on the printer's host; the URL that answers is kept.
      if (err && err.redirect && hops < 2 && Model.sameHost(err.redirect, url)) {
        root.fetchCameraFrame(err.redirect, urls, key, hops + 1)
        return
      }
      if (!err && !/^image\//i.test(img.type)) err = { message: "The webcam didn't send an image" }
      if (err) {
        root.cameraUrl = ""
        root.cameraAttempt++
        // Try the next candidate URL straight away; after a full round, wait.
        if (root.cameraAttempt % urls.length !== 0) {
          Qt.callLater(root.loadCameraFrame)
          return
        }
        root.cameraFrameDone(false, err.message || "Camera unavailable")
        return
      }
      root.cameraUrl = url
      root.cameraFrame = "file://" + img.file + "?" + img.serial
    }, "camera")
  }

  // Called by the camera view once a frame is decoded (or failed to decode).
  function cameraFrameDone(ok, message) {
    cameraError = ok ? "" : message
    if (ok) cameraFresh = true
    cameraTimer.interval = ok ? Model.CAMERA_FRAME_MS : Model.CAMERA_RETRY_MS
    if (cameraActive) cameraTimer.restart()
  }

  function stopCamera() {
    cameraTimer.stop()
    stopRequest(cameraInflight)
    cameraInflight = null
    // Keep the last frame: it reappears dimmed on the next open until a new
    // one arrives, instead of an empty box.
    cameraFresh = false
  }

  function resetCamera() {
    stopCamera()
    cameraUrl = ""
    cameraAttempt = 0
    cameraError = ""
    cameraFrame = ""
  }

  function cycleWebcam() {
    if (webcams.length < 2) return
    saveSettings({ webcam: webcams[(webcamIndex + 1) % webcams.length].name })
  }

  function reset() {
    generation++
    abortAll()
    online = false
    everConnected = false
    authFailed = false
    lastError = ""
    klippyState = ""
    klippyMessage = ""
    printState = ""
    filename = ""
    metaFor = ""
    fileMeta = null
    temps = ({})
    objectsProbed = false
    chamberObject = ""
    afcObjects = []
    afcLaneObjects = ({})
    afcLanesKey = ""
    afc = null
    changeOrigin = ""
    thumbnailSource = ""
    thumbnailFor = ""
    webcams = []
    webcamsLoaded = false
    resetCamera()
    Qt.callLater(poll)
  }

  function printAction(action) {
    if (actionBusy) return
    actionBusy = true
    request("POST", "/printer/print/" + action, function(err) {
      root.actionBusy = false
      if (err) root.lastError = err.message
      root.poll()
    })
  }

  function requestCancel() {
    if (!cancelArmed) {
      cancelArmed = true
      cancelDisarm.restart()
      return
    }
    cancelArmed = false
    printAction("cancel")
  }

  function openWebUi() {
    if (!configured || !root.bar) return
    root.bar.run("xdg-open '" + root.baseUrl.replace(/'/g, "'\\''") + "'")
  }

  onBaseUrlChanged: reset()
  onApiKeyChanged: reset()
  onWebcamKeyChanged: {
    resetCamera()
    if (cameraActive) loadCameraFrame()
  }
  onCameraActiveChanged: {
    if (cameraActive) {
      cameraError = ""
      loadCameraFrame()
    } else {
      stopCamera()
    }
  }

  onOpenedChanged: {
    if (opened) {
      settingsOpen = !configured || authFailed
      cancelArmed = false
      urlField.text = setting("url", "")
      keyField.text = setting("apiKey", "")
      poll()
      loadThumbnail()
      if (online) loadWebcams()
    }
  }

  Component.onCompleted: poll()
  Component.onDestruction: {
    generation++
    abortAll()
  }

  // One curl per request. The callback runs once both the process has exited
  // and its stdout is complete; stopping a request clears the callback first.
  Component {
    id: curlComponent

    Process {
      id: curl
      property string config: ""
      property var callback: null
      property int exitCode: -1
      property bool exited: false
      property bool streamEnded: false
      property bool finished: false

      function finish() {
        if (finished || !exited || !streamEnded) return
        finished = true
        var cb = callback
        callback = null
        if (cb) cb(exitCode, collector.text)
        curl.destroy()
      }

      command: ["curl", "--config", "-"]
      stdinEnabled: true
      stdout: StdioCollector {
        id: collector
        waitForEnd: true
        onStreamFinished: { curl.streamEnded = true; curl.finish() }
      }
      onStarted: {
        write(config)
        config = ""
        stdinEnabled = false
      }
      onExited: function(code) {
        exitCode = code
        exited = true
        finish()
      }
    }
  }

  IpcHandler {
    target: "io.github.prodpixa.moonraker"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): void { root.poll() }
    function cycleDisplay(): void { root.cycleDisplay() }
    // Merge settings from a JSON object, e.g. '{"url":"http://printer","display":"full"}'.
    function configure(json: string): string {
      var patch
      try { patch = JSON.parse(json) } catch (e) { return "invalid JSON" }
      if (!patch || typeof patch !== "object" || Array.isArray(patch)) return "expected a JSON object"
      var allowed = ["url", "apiKey", "display", "temps", "pollInterval", "compactWhenIdle", "hideWhenIdle", "hideWhenOffline", "chamberObject", "showCamera", "webcam", "showFilament"]
      var clean = {}
      for (var k in patch) {
        if (allowed.indexOf(k) < 0) return "unknown setting: " + k
        clean[k] = patch[k]
      }
      root.saveSettings(clean)
      return "ok"
    }
    function showSettings(): void {
      root.open()
      root.settingsOpen = true
    }
    // Machine-readable snapshot for scripts (never includes the API key).
    function status(): string {
      return JSON.stringify({
        configured: root.configured, online: root.online, state: root.printState,
        auth: !root.authFailed, klippy: root.klippyState, file: root.filename, progress: root.progress,
        remaining: root.remaining, temps: root.temps, error: root.lastError,
        filament: root.afc === null ? null : {
          loaded: root.afc.loaded, state: root.afc.state, changing: root.changing,
          from: root.changeFrom ? root.changeFrom.name : "", to: root.changeTo ? root.changeTo.name : "",
          step: Model.afcStepLabel(root.afc), toolchange: root.afc.toolchange, toolchanges: root.afc.toolchanges,
          error: root.afc.error, message: root.afc.message,
          lanes: root.afc.lanes.map(function(l) {
            return { name: l.name, tool: l.tool, material: l.material, color: l.colors[0] || "",
                     weight: l.weight, ready: l.ready, loaded: l.loaded }
          })
        },
        camera: {
          enabled: root.showCamera, webcams: root.webcams.map(function(c) { return c.name }),
          active: root.webcam ? root.webcam.name : "", snapshot: root.webcam ? Model.redactUrl(root.webcam.snapshot) : "",
          url: Model.redactUrl(root.cameraUrl),
          streaming: root.cameraActive, error: root.cameraError
        }
      })
    }
  }

  Timer {
    interval: (root.opened && root.changing ? 1
      : root.opened || root.printing ? Math.min(root.pollSeconds, 3) : root.pollSeconds) * 1000
    running: root.configured
    repeat: true
    onTriggered: root.poll()
  }

  Timer {
    id: cameraTimer
    onTriggered: root.loadCameraFrame()
  }

  Timer {
    id: cancelDisarm
    interval: 3000
    onTriggered: root.cancelArmed = false
  }

  visible: !hiddenByRule
  implicitWidth: visible ? button.implicitWidth : 0
  implicitHeight: visible ? button.implicitHeight : 0

  readonly property real openPanelIndicatorWidth: iconOnly || button.vertical ? 0 : button.labelWidth

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: button.vertical ? Model.ICONS.printer : root.barLabel
    fontSize: root.iconOnly || button.vertical ? Style.bar.iconFont : Style.font.body
    fixedWidth: root.iconOnly && !button.vertical ? Style.bar.iconSlot : -1
    active: root.problem
    dimmed: !root.configured || (root.everConnected && !root.online) || root.compactNow
    tooltipText: ""
    onPressed: function(b) {
      if (b === Qt.RightButton) root.cycleDisplay()
      else if (b === Qt.MiddleButton) root.openWebUi()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: urlField.activeFocus || keyField.activeFocus
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "r") root.poll()
        else if (t === "s") root.settingsOpen = !root.settingsOpen
        else if (t === "o") root.openWebUi()
      }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(14)

        // ---------- Hero: icon · name/status · percent ----------
        Item {
          width: parent.width
          implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight, heroPercent.implicitHeight)

          Text {
            id: heroIcon
            textFormat: Text.PlainText
            text: root.authFailed ? Model.ICONS.lock
              : !root.online && root.configured ? Model.ICONS.offline
              : !root.klippyReady || root.printState === "error" ? Model.ICONS.alert
              : root.changing ? Model.ICONS.swap
              : root.heating ? Model.ICONS.heat
              : root.printState === "paused" ? Model.ICONS.pause
              : root.printState === "complete" ? Model.ICONS.check
              : Model.ICONS.printer
            color: root.problem ? root.urgentColor : root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.display
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            Behavior on color { ColorAnimation { duration: 200 } }
          }

          Column {
            id: heroLabels
            anchors.left: heroIcon.right
            anchors.leftMargin: Style.space(14)
            anchors.right: heroPercent.left
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              textFormat: Text.PlainText
              text: root.printing || root.filename !== "" ? Model.displayFileName(root.filename)
                : (Model.hostLabel(root.baseUrl) || "3D Printer")
              color: root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideMiddle
              width: parent.width
            }

            Text {
              textFormat: Text.PlainText
              text: root.heroStatus.toUpperCase()
              color: root.problem ? root.urgentColor : Qt.darker(root.fg, 1.4)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.2
              elide: Text.ElideRight
              width: parent.width
            }
          }

          Text {
            id: heroPercent
            textFormat: Text.PlainText
            visible: (root.printing && !root.heating) || root.finished
            text: Math.floor(root.progress * 100) + "%"
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.displayLarge
            font.bold: true
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
          }
        }

        // ---------- Error / message line ----------
        Text {
          visible: text !== ""
          width: parent.width
          textFormat: Text.PlainText
          readonly property bool afcError: root.afc !== null && root.afc.message !== ""
            && (root.afc.error || root.afc.messageType === "error")
          readonly property bool isError: root.lastError !== "" || !root.klippyReady || root.printState === "error" || afcError
          text: root.lastError !== "" ? root.lastError
            : !root.klippyReady ? root.klippyMessage
            : afcError ? root.afc.message
            : root.statusMessage
          color: isError ? root.urgentColor : root.fg
          opacity: isError ? 1 : 0.7
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.Wrap
        }

        // ---------- Progress bar ----------
        Item {
          visible: root.printing
          width: parent.width
          implicitHeight: Style.space(8)

          Rectangle {
            id: track
            anchors.fill: parent
            radius: height / 2
            color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.12)
          }

          Rectangle {
            anchors.left: track.left
            anchors.verticalCenter: track.verticalCenter
            height: track.height
            radius: track.radius
            color: root.fg
            width: Math.max(track.height, track.width * root.progress)
            Behavior on width { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }

            SequentialAnimation on opacity {
              running: root.printState === "paused" && root.opened
              loops: Animation.Infinite
              alwaysRunToEnd: true
              NumberAnimation { from: 1.0; to: 0.45; duration: 900; easing.type: Easing.InOutSine }
              NumberAnimation { from: 0.45; to: 1.0; duration: 900; easing.type: Easing.InOutSine }
            }
          }
        }

        // ---------- Filament change in progress ----------
        Rectangle {
          id: changeCard
          visible: root.changing && root.showFilament
          width: parent.width
          implicitHeight: changeColumn.implicitHeight + Style.space(24)
          radius: Style.cornerRadius
          color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.06)

          Column {
            id: changeColumn
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.margins: Style.space(12)
            spacing: Style.space(10)

            // From → to
            Row {
              anchors.horizontalCenter: parent.horizontalCenter
              spacing: Style.space(10)

              ChangeEnd { lane: root.changeFrom; fallback: "—" }
              Text {
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: "\u2192"
                color: root.fg
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
              }
              ChangeEnd { lane: root.changeTo; fallback: "?" }
            }

            // Unload → Load → Resume
            Row {
              id: steps
              width: parent.width
              spacing: Style.space(6)
              readonly property var labels: ["Unload", "Load", "Resume"]
              readonly property real cellWidth: (width - spacing * 2) / 3

              Repeater {
                model: steps.labels
                Column {
                  required property int index
                  required property string modelData
                  readonly property int stage: root.afc ? root.afc.stage : 0
                  width: steps.cellWidth
                  spacing: Style.space(4)

                  Rectangle {
                    width: parent.width
                    height: Style.space(6)
                    radius: height / 2
                    color: index <= stage ? root.fg : Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.15)
                    SequentialAnimation on opacity {
                      running: index === stage && root.opened && root.changing
                      loops: Animation.Infinite
                      alwaysRunToEnd: true
                      NumberAnimation { from: 1.0; to: 0.35; duration: 700; easing.type: Easing.InOutSine }
                      NumberAnimation { from: 0.35; to: 1.0; duration: 700; easing.type: Easing.InOutSine }
                    }
                  }
                  Text {
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    textFormat: Text.PlainText
                    text: modelData
                    color: root.fg
                    opacity: index === stage ? 1 : 0.5
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: index === stage
                  }
                }
              }
            }

            Text {
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              textFormat: Text.PlainText
              text: Model.afcStepLabel(root.afc)
                + (root.afc && root.afc.toolchanges > 0
                   ? "  ·  change " + root.afc.toolchange + " of " + root.afc.toolchanges : "")
              color: root.fg
              opacity: 0.7
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              elide: Text.ElideRight
            }
          }
        }

        // ---------- Camera ----------
        // Two images take turns: the next frame decodes in the hidden one and
        // is swapped in when ready, so the picture never blanks between frames.
        Rectangle {
          id: cameraView
          visible: root.showCamera && root.online && root.webcam !== null
          width: parent.width
          readonly property var cam: root.webcam
          readonly property bool sideways: cam !== null && (cam.rotation === 90 || cam.rotation === 270)
          readonly property var shown: front === 0 ? frameA : frameB
          // Real frame proportions once one is decoded, else the webcam's setting.
          readonly property real aspect: {
            var w = shown.implicitWidth, h = shown.implicitHeight
            var a = shown.status === Image.Ready && w > 0 && h > 0 ? w / h : (cam ? cam.aspect : 16 / 9)
            return sideways ? 1 / a : a
          }
          property int front: 0
          implicitHeight: Math.round(width / aspect)
          radius: Style.cornerRadius
          color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.06)

          Connections {
            target: root
            function onCameraFrameChanged() {
              if (root.cameraFrame === "") {
                frameA.source = ""
                frameB.source = ""
                cameraView.front = 0
              } else {
                (cameraView.front === 0 ? frameB : frameA).source = root.cameraFrame
              }
            }
          }

          CameraFrame { id: frameA; index: 0 }
          CameraFrame { id: frameB; index: 1 }

          Text {
            anchors.centerIn: parent
            width: parent.width - Style.space(24)
            visible: cameraView.shown.status !== Image.Ready
            textFormat: Text.PlainText
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            text: root.cameraError !== "" ? Model.ICONS.camera + "  " + root.cameraError
              : Model.ICONS.camera + "  Connecting to camera…"
            color: root.cameraError !== "" ? root.urgentColor : root.fg
            opacity: root.cameraError !== "" ? 1 : 0.6
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          // Camera name and a stale-frame warning, over the picture.
          Rectangle {
            visible: caption.text !== "" && cameraView.shown.status === Image.Ready
            anchors.left: parent.left
            anchors.bottom: parent.bottom
            anchors.margins: Style.space(8)
            width: caption.implicitWidth + Style.space(12)
            height: caption.implicitHeight + Style.space(6)
            radius: Style.cornerRadius
            color: Qt.rgba(0, 0, 0, 0.55)

            Text {
              id: caption
              anchors.centerIn: parent
              textFormat: Text.PlainText
              text: root.cameraError !== "" ? Model.ICONS.alert + "  " + root.cameraError
                : root.webcams.length > 1 ? Model.ICONS.camera + "  " + cameraView.cam.name
                  + "  " + (root.webcamIndex + 1) + "/" + root.webcams.length
                : ""
              color: "white"
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          MouseArea {
            anchors.fill: parent
            enabled: root.webcams.length > 1
            cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
            onClicked: root.cycleWebcam()
          }
        }

        // ---------- Job details (+ thumbnail) ----------
        Row {
          visible: root.printing || root.finished
          width: parent.width
          spacing: Style.space(14)

          Rectangle {
            id: thumbFrame
            visible: thumb.status === Image.Ready
            width: visible ? Style.space(92) : 0
            height: Style.space(92)
            radius: Style.cornerRadius
            color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.06)

            Image {
              id: thumb
              anchors.fill: parent
              anchors.margins: Style.space(4)
              source: root.thumbnailSource
              // Decode at display size; Qt's image allocation limit also
              // rejects absurd dimensions packed into a small file.
              sourceSize.width: Style.space(184)
              sourceSize.height: Style.space(184)
              cache: false
              fillMode: Image.PreserveAspectFit
              asynchronous: true
              smooth: true
              mipmap: true
            }
          }

          Column {
            width: parent.width - (thumbFrame.visible ? thumbFrame.width + parent.spacing : 0)
            spacing: Style.spacing.labelGap

            InfoPair {
              label: root.finished ? "Print time" : "Elapsed"
              value: Model.formatDuration(root.printDuration)
            }
            InfoPair {
              visible: root.printing
              label: "Remaining"
              value: Model.formatDuration(root.remaining)
            }
            InfoPair {
              visible: root.printing
              label: "Finishes at"
              value: root.remaining >= 0 ? Qt.formatTime(new Date(Date.now() + root.remaining * 1000), "HH:mm") : "—"
            }
            InfoPair {
              visible: root.printing && root.totalLayer > 0
              label: "Layer"
              value: root.currentLayer + " / " + root.totalLayer
            }
            InfoPair { label: "Filament"; value: Model.formatFilament(root.filamentUsed) }
            InfoPair {
              visible: root.printing && root.afc !== null && root.afc.toolchanges > 0
              label: "Color changes"
              value: root.afc ? root.afc.toolchange + " / " + root.afc.toolchanges : ""
            }
          }
        }

        // ---------- Temperatures ----------
        PanelSeparator {
          visible: tempsColumn.visible
          foreground: root.fg
        }

        Column {
          id: tempsColumn
          visible: root.online && Object.keys(root.temps).length > 0
          width: parent.width
          spacing: Style.space(10)

          PanelSectionHeader {
            text: "TEMPERATURES"
            foreground: root.fg
            fontFamily: root.fontFamily
          }

          Column {
            width: parent.width
            spacing: Style.spacing.labelGap

            Repeater {
              model: Model.TEMP_KEYS
              InfoPair {
                required property string modelData
                readonly property var entry: root.temps[modelData] || null
                visible: entry !== null
                label: Model.ICONS[modelData] + "  " + modelData.charAt(0).toUpperCase() + modelData.slice(1)
                value: entry ? Model.formatTempPair(entry.temperature, entry.target) : ""
                heating: entry !== null && entry.target > 0
              }
            }
          }
        }

        // ---------- Filament lanes ----------
        PanelSeparator {
          visible: laneSection.visible
          foreground: root.fg
        }

        Column {
          id: laneSection
          visible: root.showFilament && root.online && root.afc !== null && root.afc.lanes.length > 0
          width: parent.width
          spacing: Style.space(10)

          PanelSectionHeader {
            text: root.afc && root.afc.bypass ? "FILAMENT  ·  BYPASS" : "FILAMENT"
            foreground: root.fg
            fontFamily: root.fontFamily
          }

          Grid {
            id: laneGrid
            width: parent.width
            readonly property int count: root.afc ? root.afc.lanes.length : 0
            columns: Math.max(1, Math.min(4, count))
            spacing: Style.space(6)
            readonly property real cellWidth: (width - spacing * (columns - 1)) / columns

            Repeater {
              model: root.afc ? root.afc.lanes : []
              LaneCard {
                required property var modelData
                lane: modelData
                width: laneGrid.cellWidth
              }
            }
          }
        }

        // ---------- Actions ----------
        PanelSeparator { foreground: root.fg }

        Row {
          id: actionRow
          width: parent.width
          spacing: Style.space(6)

          readonly property int count: (root.printing ? 2 : 0) + 2
          readonly property real cellWidth: (width - spacing * (count - 1)) / count

          ActionButton {
            visible: root.printing
            iconText: root.printState === "paused" ? Model.ICONS.play : Model.ICONS.pause
            text: root.printState === "paused" ? "Resume" : "Pause"
            enabled: !root.actionBusy
            onClicked: root.printAction(root.printState === "paused" ? "resume" : "pause")
          }

          ActionButton {
            visible: root.printing
            iconText: Model.ICONS.stop
            text: root.cancelArmed ? "Confirm" : "Cancel"
            active: root.cancelArmed
            enabled: !root.actionBusy
            onClicked: root.requestCancel()
          }

          ActionButton {
            iconText: Model.ICONS.web
            text: "Web UI"
            enabled: root.configured
            onClicked: { root.openWebUi(); root.close() }
          }

          ActionButton {
            iconText: Model.ICONS.cog
            text: "Settings"
            active: root.settingsOpen
            onClicked: root.settingsOpen = !root.settingsOpen
          }
        }

        // ---------- Settings ----------
        Column {
          visible: root.settingsOpen
          width: parent.width
          spacing: Style.space(10)

          PanelSeparator { foreground: root.fg }

          PanelSectionHeader {
            text: "CONNECTION"
            foreground: root.fg
            fontFamily: root.fontFamily
          }

          TextField {
            id: urlField
            width: parent.width
            placeholderText: "Moonraker URL (http://192.168.1.50)"
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            foreground: root.fg
            onAccepted: keyField.forceActiveFocus()
          }

          TextField {
            id: keyField
            width: parent.width
            password: true
            placeholderText: "API key (optional)"
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            foreground: root.fg
            onAccepted: saveButton.clicked()
          }

          Button {
            id: saveButton
            width: parent.width
            iconText: Model.ICONS.check
            text: "Save & connect"
            fontSize: Style.font.bodySmall
            foreground: root.fg
            fontFamily: root.fontFamily
            bordered: true
            onClicked: {
              root.saveSettings({ url: urlField.text.trim(), apiKey: keyField.text.trim() })
              keyCatcher.forceActiveFocus()
              root.reset()
            }
          }

          PanelSectionHeader {
            text: "BAR DISPLAY"
            foreground: root.fg
            fontFamily: root.fontFamily
          }

          ButtonGroup {
            width: parent.width
            options: [
              { value: "icon", label: "Icon" },
              { value: "progress", label: "Progress" },
              { value: "full", label: "+ Temps" }
            ]
            value: root.display
            foreground: root.fg
            fontFamily: root.fontFamily
            fontSize: Style.font.bodySmall
            focusable: false
            onChanged: function(v) { root.saveSettings({ display: v }) }
          }

          PanelSectionHeader {
            visible: root.display === "full"
            text: "TEMPERATURES IN BAR"
            foreground: root.fg
            fontFamily: root.fontFamily
          }

          Row {
            id: tempToggleRow
            visible: root.display === "full"
            width: parent.width
            spacing: Style.space(6)
            readonly property real cellWidth: (width - spacing * 2) / 3

            Repeater {
              model: Model.TEMP_KEYS
              Button {
                required property string modelData
                width: tempToggleRow.cellWidth
                iconText: Model.ICONS[modelData]
                text: modelData.charAt(0).toUpperCase() + modelData.slice(1)
                fontSize: Style.font.bodySmall
                foreground: root.fg
                fontFamily: root.fontFamily
                bordered: true
                active: root.barTemps.indexOf(modelData) >= 0
                onClicked: root.saveSettings({ temps: Model.toggleTemp(root.barTemps, modelData) })
              }
            }
          }

          Toggle {
            width: parent.width
            label: "Compact when not printing"
            description: "Only a dimmed icon until a print starts"
            checked: root.compactWhenIdle
            foreground: root.fg
            fontFamily: root.fontFamily
            titleSize: Style.font.bodySmall
            onClicked: root.saveSettings({ compactWhenIdle: !root.compactWhenIdle })
          }

          Toggle {
            visible: root.afc !== null
            width: parent.width
            label: "Show filament"
            description: "Lanes, the loaded spool, and tool changes"
            checked: root.showFilament
            foreground: root.fg
            fontFamily: root.fontFamily
            titleSize: Style.font.bodySmall
            onClicked: root.saveSettings({ showFilament: !root.showFilament })
          }

          Toggle {
            visible: root.webcams.length > 0
            width: parent.width
            label: "Show camera"
            description: "Live snapshots, only while this popup is open"
            checked: root.showCamera
            foreground: root.fg
            fontFamily: root.fontFamily
            titleSize: Style.font.bodySmall
            onClicked: root.saveSettings({ showCamera: !root.showCamera })
          }
        }
      }
    }
  }

  // One of the camera view's two alternating images. Decodes at display size
  // (Qt's allocation limit also rejects absurd dimensions in a small file).
  component CameraFrame: Image {
    required property int index
    readonly property var cam: cameraView.cam
    anchors.centerIn: parent
    width: cameraView.sideways ? cameraView.height : cameraView.width
    height: cameraView.sideways ? cameraView.width : cameraView.height
    visible: cameraView.front === index && status === Image.Ready
    opacity: root.cameraFresh ? 1 : 0.4
    rotation: cam ? cam.rotation : 0
    transform: Scale {
      origin.x: width / 2
      origin.y: height / 2
      xScale: cam && cam.flipH ? -1 : 1
      yScale: cam && cam.flipV ? -1 : 1
    }
    sourceSize.width: Style.space(800)
    cache: false
    asynchronous: true
    fillMode: Image.PreserveAspectFit
    smooth: true
    onStatusChanged: {
      if (source == "" || cameraView.front === index) return
      if (status === Image.Ready) {
        cameraView.front = index
        root.cameraFrameDone(true)
      } else if (status === Image.Error) {
        root.cameraFrameDone(false, "Couldn't read the camera image")
      }
    }
  }

  // Round filament swatch: one slice per color, ringed so dark filament stays
  // visible on dark themes, with an optional label (the tool) on top.
  component Swatch: Canvas {
    property var colors: []
    property string label: ""
    implicitWidth: Style.space(34)
    implicitHeight: implicitWidth
    readonly property color ring: root.fg
    onColorsChanged: requestPaint()
    onRingChanged: requestPaint()
    onWidthChanged: requestPaint()
    onPaint: {
      var ctx = getContext("2d")
      var r = Math.min(width, height) / 2
      ctx.reset()
      var list = colors && colors.length ? colors : [Qt.rgba(ring.r, ring.g, ring.b, 0.12)]
      for (var i = 0; i < list.length; i++) {
        ctx.beginPath()
        ctx.moveTo(r, r)
        ctx.arc(r, r, r - 1, -Math.PI / 2 + i * 2 * Math.PI / list.length,
                -Math.PI / 2 + (i + 1) * 2 * Math.PI / list.length)
        ctx.closePath()
        ctx.fillStyle = list[i]
        ctx.fill()
      }
      ctx.beginPath()
      ctx.arc(r, r, r - 1, 0, 2 * Math.PI)
      ctx.lineWidth = 1.5
      ctx.strokeStyle = Qt.rgba(ring.r, ring.g, ring.b, 0.35)
      ctx.stroke()
    }

    Text {
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: parent.label
      color: Model.isLightColor(parent.colors && parent.colors.length ? parent.colors[0] : "") ? "#111111" : "#f5f5f5"
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
    }
  }

  // One lane of the changer: color, tool, material, and what's left.
  component LaneCard: Rectangle {
    property var lane: null
    readonly property bool involved: root.changing && lane !== null
      && ((root.changeFrom && root.changeFrom.name === lane.name) || (root.changeTo && root.changeTo.name === lane.name))
    implicitHeight: laneColumn.implicitHeight + Style.space(16)
    radius: Style.cornerRadius
    color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, lane && lane.loaded ? 0.12 : 0.04)
    border.width: lane && lane.loaded ? 2 : 1
    border.color: lane && lane.loaded ? root.fg : Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.15)
    property real pulse: 1
    opacity: (lane && lane.ready ? 1 : 0.45) * pulse

    SequentialAnimation on pulse {
      running: involved && root.opened
      loops: Animation.Infinite
      alwaysRunToEnd: true
      NumberAnimation { from: 1.0; to: 0.5; duration: 700; easing.type: Easing.InOutSine }
      NumberAnimation { from: 0.5; to: 1.0; duration: 700; easing.type: Easing.InOutSine }
    }

    // Nozzle badge on the lane that is in the toolhead.
    Text {
      visible: lane !== null && lane.loaded
      anchors.top: parent.top
      anchors.right: parent.right
      anchors.margins: Style.space(5)
      textFormat: Text.PlainText
      text: Model.ICONS.nozzle
      color: root.fg
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }

    Column {
      id: laneColumn
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.margins: Style.space(6)
      spacing: Style.space(4)

      Swatch {
        anchors.horizontalCenter: parent.horizontalCenter
        colors: lane ? lane.colors : []
        label: Model.laneLabel(lane)
      }
      Text {
        width: parent.width
        horizontalAlignment: Text.AlignHCenter
        textFormat: Text.PlainText
        text: lane && lane.ready ? (lane.material || "—") : "Empty"
        color: root.fg
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.bold: lane !== null && lane.loaded
        elide: Text.ElideRight
      }
      Text {
        width: parent.width
        horizontalAlignment: Text.AlignHCenter
        textFormat: Text.PlainText
        text: !lane ? "" : lane.status !== "" ? lane.status
          : lane.loaded ? "Loaded"
          : lane.ready ? (Model.formatWeight(lane.weight) || "Ready") : lane.name
        color: root.fg
        opacity: 0.6
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }
  }

  // One side of the change card: swatch plus material.
  component ChangeEnd: Row {
    property var lane: null
    property string fallback: ""
    spacing: Style.space(6)

    Swatch {
      implicitWidth: Style.space(28)
      colors: lane ? lane.colors : []
      label: lane ? Model.laneLabel(lane) : fallback
    }
    Text {
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: lane ? (lane.material || lane.name) : ""
      color: root.fg
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      font.bold: true
    }
  }

  component ActionButton: Button {
    width: actionRow.cellWidth
    iconSize: Style.font.title
    fontSize: Style.font.bodySmall
    foreground: root.fg
    fontFamily: root.fontFamily
    horizontalPadding: Style.spacing.controlPaddingX
    verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
    bordered: true
    opacity: enabled ? 1 : 0.5
  }

  component InfoPair: Row {
    property string label: ""
    property string value: ""
    property bool heating: false

    width: parent.width
    spacing: Style.space(8)

    InfoLabel { text: label }
    Item { width: Math.max(0, parent.width - parent.children[0].implicitWidth - parent.children[2].implicitWidth - parent.spacing * 2); height: 1 }
    InfoValue { text: value; font.bold: heating }
  }

  component InfoLabel: Text {
    textFormat: Text.PlainText
    color: root.fg
    opacity: 0.6
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
  }

  component InfoValue: Text {
    textFormat: Text.PlainText
    color: root.fg
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
  }
}
