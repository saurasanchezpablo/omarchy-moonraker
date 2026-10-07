# Architecture

## Files

| File | Role |
|------|------|
| `manifest.json` | Omarchy plugin manifest: id `io.github.saurasanchezpablo.moonraker-plus`, kind `bar-widget`, entry point `Panel.qml`, defaults, and the settings schema. |
| `Panel.qml` | The widget: bar chip, popup, camera view, HTTP client, polling, settings persistence, and IPC. |
| `Model.js` | Pure helpers with no QML state: URL normalization, state labels, ETA math, formatting, chamber detection, and bar text. |
| `dev/install.sh` | Copies the plugin into `~/.config/omarchy/plugins/io.github.saurasanchezpablo.moonraker-plus` and restarts the shell. |
| `dev/mock_moonraker.py` | Fake Moonraker with switchable scenarios, for development and screenshots. |
| `dev/assets/thumbnail.png` | Thumbnail the mock serves for its fake job. |
| `dev/assets/webcam.jpg` | Frame the mock serves as its webcam snapshot. |
| `dev/screenshots.sh` | Walks the widget through every state and captures `docs/screenshots/`. |
| `dev/crop_popup.py`, `dev/crop_bar.py` | Crop the popup card and the bar chip out of screenshots (used by `screenshots.sh`). |

## How it plugs into Omarchy

`Panel.qml` extends `qs.Ui.Panel`, the same base the built-in popup widgets use
(Power, Weather, and others). The shell injects three properties:

- `bar`: a facade over the host bar (`foreground`, `urgent`, `fontFamily`,
  `run()`, `shell.updateEntryInline()`, …). Colors bind to it, so a theme change
  repaints the widget immediately.
- `settings`: the widget's entry from `shell.json`.
- `moduleName`: `io.github.saurasanchezpablo.moonraker-plus`.

The UI is built from the shell's own kit, `qs.Ui` (`WidgetButton`,
`KeyboardPanel`, `PanelKeyCatcher`, `Button`, `ButtonGroup`, `TextField`,
`Toggle`, `PanelSeparator`, `PanelSectionHeader`), plus `qs.Commons.Style` for
sizes. That's where the native look comes from: borders, spacing, focus rings,
and popup placement are the same code the built-in widgets run.

Settings are saved with `bar.shell.updateEntryInline(moduleName, settings)`,
the capability-scoped API Omarchy gives third-party plugins. It rewrites only
this widget's entry in `shell.json`.

## Talking to Moonraker

Every request runs one short `curl` process (`curl --config -`). The URL, the
`X-Api-Key` header, and the limits are written to curl's stdin, so the key never
appears in the process list.

Limits, enforced by curl while the data streams in:

| Limit | Value | curl option |
|-------|-------|-------------|
| JSON response size | 1 MB | `max-filesize` |
| Thumbnail size | 2 MB | `max-filesize` (partial files removed with `remove-on-error`) |
| Webcam snapshot size | 4 MB | `max-filesize` (same) |
| Whole request | 10 s | `max-time` |
| Connecting | 5 s | `connect-timeout` |
| Protocols | http, https | `proto` |

Why not QML's `XMLHttpRequest`: its `abort()` only detaches the request from
JavaScript. The transfer keeps running and buffering inside the shell, so an
endless response from a broken or hostile endpoint grows the shell's memory
until it crashes. curl closes the connection when a limit is hit.
`dev/mock_moonraker.py` has `flood`, `flood-declared`, `hang`, and
`huge-thumbnail` scenarios that check this.

| When | Request |
|------|---------|
| First connect / after the URL or key changes | `GET /printer/objects/list`: finds the chamber sensor object |
| Every poll | `GET /printer/objects/query?print_stats&virtual_sdcard&display_status&extruder&heater_bed&webhooks[&<chamber>][&AFC=…&<lane objects>=…]` |
| When the file name changes | `GET /server/files/metadata?filename=…`: slicer estimate, layer count, thumbnails |
| Popup open, when the job has a thumbnail | `GET /server/files/gcodes/<thumb>`, saved to `$XDG_RUNTIME_DIR/omarchy-moonraker-plus/` and shown from there |
| Pause / Resume / Cancel | `POST /printer/print/pause`, `/resume`, `/cancel` |
| Popup open | `GET /server/webcams/list`: webcams configured in Mainsail/Fluidd |
| A new print starts (with `[exclude_object]`) | `GET /printer/objects/query?exclude_object=objects`: object names, once per file |
| Popup open, with `[spoolman]` | `GET /server/spoolman/status`, then the active spool via `POST /server/spoolman/proxy` (`GET /v1/spool/<id>`) |
| Spool picker | `POST /server/spoolman/proxy` (`GET /v1/spool?allow_archived=false`), `POST /server/spoolman/spool_id` |
| Light button | `POST /printer/gcode/script?script=SET_LED …` or `SET_PIN …` |
| While the popup is open | `GET <snapshot_url>`, one frame at a time, saved to `$XDG_RUNTIME_DIR/omarchy-moonraker-plus/camera-{0,1}` |


### Polling

- Every `pollInterval` seconds (default 5), or every 3 seconds or less while
  printing or while the popup is open.
- One status request at a time. curl ends a request after 10 seconds, and the
  printer is reported unreachable.
- A `generation` counter is bumped whenever the URL or key changes, or the
  widget is destroyed. Responses from an older generation are dropped, so
  switching printers never mixes data.

### Camera

Nothing camera-related runs while the popup is closed. On open the widget reads
`/server/webcams/list` and keeps the enabled webcams that can give a still
frame: `snapshot_url`, or for mjpg-streamer style services, `stream_url` with
`action=stream` swapped for `action=snapshot`. WebRTC/HLS-only webcams are
skipped, because a still image is all the shell can show without a video stack.

Snapshots are fetched one at a time. The next request goes out
`Model.CAMERA_FRAME_MS` (1 s) after the previous frame is on screen, or
`CAMERA_RETRY_MS` (5 s) after a failure, so a slow camera slows the frame rate
down instead of piling up requests. Frames are decoded at display size in two
`Image`s that take turns, so the picture never blanks between frames. On close
the loop stops and the last frame is kept; it shows dimmed on the next open
until a new one arrives.

Finding the snapshot:

- An absolute `http(s)` URL is used as is. Any other scheme is rejected.
- A relative URL is tried at the configured origin, then at the same host on
  its default port, because Mainsail/Fluidd serve `/webcam/` from nginx rather
  than Moonraker's port 7125.
- curl reports redirects but never follows them. The widget follows up to two
  itself, and only when they stay on the same host (nginx often redirects
  `/webcam/` to the streamer's own port, e.g. `:8080`).
- The URL that answered is remembered until the webcam or printer changes.
- A response that isn't `image/*` counts as a failure.

### Filament changer (AFC)

Printers running Armored Turtle's
[AFC add-on](https://github.com/ArmoredTurtle/AFC-Klipper-Add-On) (Box Turtle,
Night Owl, Elegoo's Canvas, …) have an `AFC` object plus one object per lane,
whose type depends on the hardware: `AFC_lane CANVAS_1`, `AFC_stepper lane1`, ….

- The object probe notes whether `AFC` exists and keeps every `AFC_*` name.
- Once a status reply lists `AFC.lanes`, `Model.afcLaneObjects()` picks one
  object per lane (`AFC_lane` first, then `AFC_stepper`, then any other
  `AFC_* <lane>` that isn't a unit) and the lanes join the next poll.
- The query asks only for the fields the widget uses (`AFC=current_load,…`,
  `<lane>=map,material,color,…`), so four lanes add well under 2 KB per poll.
- `Model.afcState()` reduces it to lanes plus a change in progress.

| AFC field | Used for |
|-----------|----------|
| `current_load` | lane in the toolhead (highlighted, nozzle badge) |
| `next_lane` | target of a tool change |
| `current_state` | change stage: `Unloading` → `Loading` → `Restoring` → `Idle` |
| `current_lane` | lane moving right now; its `status` (`Tool Unloading`, `HUB Loading`, …) is the step text |
| `current_toolchange` / `number_of_toolchanges` | "change 3 of 12" |
| `error_state`, `message` | AFC errors in the popup's message line |
| lane `map`, `material`/`filament_name`, `color`/`multi_color_hexes`, `weight`, `load`+`prep` | lane cards |

AFC forgets the old lane once it is unloaded, so the widget remembers which lane
was loaded when the change started (`changeOrigin`) to keep showing "T0 → T2".
While a change runs and the popup is open, polling speeds up to once a second.

### Chamber light

`Model.pickLight()` chooses from the object list: `led`, `neopixel`, `dotstar`,
and `pca95xx` objects named like a case or chamber light first, then ones named
"light"/"lamp", then any other LED that isn't obviously the toolhead or a
status display. An `output_pin` only qualifies by name, because pins also drive
beepers and heaters. The `lightObject` setting overrides the choice.

The light's `color_data` (or `value`) joins the status query, and the button
sends `SET_LED LED=<name> RED=1 GREEN=1 BLUE=1 WHITE=1` (channels the LED
doesn't have are ignored) or `SET_PIN PIN=<name> VALUE=1`. Object names are
checked against `[A-Za-z0-9_.-]` before they go into G-code.

### Print tools: pause at layer

Mainsail's and Fluidd's standard configs ship `SET_PAUSE_AT_LAYER` and
`SET_PAUSE_NEXT_LAYER`, which store their plan in `SET_PRINT_STATS_INFO`'s
variables and fire when the slicer's `SET_PRINT_STATS_INFO CURRENT_LAYER=…`
reaches it. When all three macros exist, those two variables join the status
query. The Tools button is always there once the printer answers; sections
that don't apply show a short note instead. Nothing in Klipper resets the plan
until it fires, so between prints the layer field arms a pause for the next
print (1–9999, the next job's layer count being unknown), and a pending plan
is shown under the popup's title. "Pause after this layer" needs a running
print with known layers.
Commands are built from integers only (`SET_PAUSE_AT_LAYER LAYER=120`,
`ENABLE=0` to clear, `SET_PAUSE_NEXT_LAYER ENABLE=1`).

### Print tools: skip object

With `[exclude_object]`, each poll adds `exclude_object=excluded_objects,current_object`.
The object list itself carries polygons and can be large, so it is fetched once
per file. Names that couldn't be a `NAME=` parameter (whitespace, `;`, control
characters) are dropped. The list shows only for plates with more than one
object, since skipping the only one equals cancelling. Skip needs a second
click within 3 s, like Cancel, and sends `EXCLUDE_OBJECT NAME=<name>`.

### Spoolman

Everything goes through Moonraker's `spoolman` component, so the widget never
needs Spoolman's own address or credentials. On popup open it asks
`/server/spoolman/status`; a 404 means no Spoolman, and it isn't asked again
until the printer changes. The active spool and the picker list come through
`/server/spoolman/proxy` with `use_v2_response`, as JSON request bodies (curl
reads them from its stdin config like everything else). Nothing Spoolman-related
is polled. The line is hidden on AFC printers, whose lanes already carry the
spool data AFC syncs from Spoolman.

### Notifications

After every status update, `Model.notifications(previous, current)` compares
two snapshots and returns the events to announce: a print finishing, being
cancelled, failing, or pausing; Klipper leaving `ready` (but not a restart into
`startup`); an AFC error; and the remaining time crossing 10 minutes (once per
job). The first status after start-up or a printer change never notifies.
Pause and cancel clicked in the popup within the last 15 s stay quiet.

With `notifySnapshot`, every notification except "minutes left" first grabs
one still from the webcam (loading the webcam list if the popup was never
opened) through the same candidates, redirect rules, and 4 MB cap as the live
view, saved to `notify-{0,1}` under the runtime dir and passed as the icon and
`image-path` hint. If that fails the notification goes out without it.

Each notification is one `notify-send` process started from an argument list,
never through a shell, and the body is markup-escaped, so file names and
messages from the printer stay plain text.

### State mapping

| Source | Widget state |
|--------|--------------|
| No URL | *Not configured* |
| Network error / timeout | *Unreachable*: dimmed, disconnect icon |
| HTTP 401/403 | *Unauthorized*: lock icon, settings open automatically |
| HTTP 503 or a "Klippy …" error | Klipper *disconnected* |
| `webhooks.state` ≠ `ready` | Klipper *starting up* / *shutdown* / *error*, with `webhooks.state_message` shown |
| `print_stats.state` | *Idle* (`standby`), *Printing*, *Paused*, *Complete*, *Cancelled*, *Error* |
| Printing, progress 0, a heater more than 2° under its target | *Heating* |

Progress is `display_status.progress`, falling back to `virtual_sdcard.progress`.
Layers come from `print_stats.info` (`SET_PRINT_STATS_INFO`), falling back to
the file metadata's `layer_count`.

### Time remaining

`Model.remainingSeconds()` averages two estimates, similar to Mainsail/Fluidd:

- file-based: `elapsed / progress − elapsed`
- slicer-based: `metadata.estimated_time − elapsed`

Below 5% progress only the slicer estimate is used, because file extrapolation
is noisy early in a print.

### Chamber detection

When `chamberObject` is empty, the first of these that exists is used:
`heater_generic chamber`, `temperature_sensor chamber`, `temperature_fan chamber`,
`heater_generic chamber_heater`, `temperature_sensor chamber_temp`. After
that, any `heater_generic`/`temperature_sensor`/`temperature_fan` whose name
contains "chamber" (ignoring thermal-protection sensors).

## Shell quirks worth knowing

- **Arrays from `shell.json`** reach QML as sequence wrappers, where
  `Array.isArray()` is false. `Model.toArray()` converts them.
- **Hot reload caches components.** Saving files under `~/.config/omarchy/plugins`
  triggers a reload, but the previously compiled QML can stay in use. Run
  `omarchy restart shell` (which `dev/install.sh` does).
- **`console.log` from third-party plugins doesn't reach the shell log.** Debug
  through IPC instead (`status` returns the live state).
- **Editing `shell.json` from outside** rebuilds the whole bar (several seconds).
  The `configure` IPC goes through the shell and applies instantly.
- The third-party `bar` facade has no `shellQuote()`. The widget quotes the URL itself.

## Security notes

- The API key lives in `shell.json` in plain text, like all widget settings.
- `status` over IPC never includes the key.
- `configure` accepts only the known setting keys.
- The key is sent only to the configured URL's origin, and only through curl's
  stdin. Webcam snapshots on another port or host get no key.
- Webcam URLs come from the printer. They are limited to http/https, and
  redirects are followed only within the printer's host.
- Responses are size- and time-limited (see *Talking to Moonraker*), and curl
  does not follow redirects.
