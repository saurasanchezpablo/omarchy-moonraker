# Changelog

## 0.2.1 — 2026-10-07

- The Tools button is always available, not only while printing. Between
  prints it arms a pause at a chosen layer of the next print, shown as
  "Next print pauses at layer N" under the title until it fires or is
  cleared. Sections that don't apply (no layers, a single object, missing
  macros) show a short note instead of disappearing.

## 0.2.0 — 2026-10-07

First release of **Moonraker Printer Plus**, an extended fork of
[Moonraker Printer](https://github.com/prodpixa/omarchy-moonraker) by prodpixa
(versions 0.1.x below are theirs).

- New plugin ID `io.github.saurasanchezpablo.moonraker-plus` and name, so it can
  be listed and installed alongside the original. Settings don't carry over from
  the original's ID. Runtime files moved to `$XDG_RUNTIME_DIR/omarchy-moonraker-plus/`.

- New: desktop notifications when a print finishes, is cancelled, fails, pauses
  (e.g. filament runout), or has 10 minutes left, and when Klipper or the
  filament changer stops with an error. Pause/cancel from the popup stays
  quiet. Setting: `notify` (also a toggle in the popup).
- New: Spoolman. One line shows the active spool's name, color, and grams
  left; clicking it lists the other spools to switch to. Uses Moonraker's
  Spoolman proxy, fetched on popup open only. IPC: `setSpool`. The HTTP
  layer can now send JSON request bodies (through curl's stdin config).
- New: print tools (the Tools button while printing, or `t`): pause at a
  chosen layer or after the current one, using the standard Mainsail/Fluidd
  macros. A planned pause shows as "Pauses at" in the job details. IPC:
  `pauseAtLayer`, `showTools`.
- New: skip a failed object and keep printing the rest (Tools → Objects, with
  `[exclude_object]`). Shows which object is printing now and which are
  skipped; skipping needs a second click. IPC: `skipObject`.
- New: a bulb on the camera picture switches the chamber light (also `l` in
  the popup and the `toggleLight` IPC call). The light is detected from the
  printer's LED objects; setting: `lightObject`.
- New: notifications carry a camera snapshot of the printer, so a finished
  part or a failed print is visible right in the notification. Setting:
  `notifySnapshot`.
- New: filament changer support for [AFC](https://github.com/ArmoredTurtle/AFC-Klipper-Add-On)
  (Elegoo Canvas, Box Turtle, Night Owl, …). The popup lists every lane with its
  color, tool, material, and remaining weight, and highlights the one in the
  toolhead. During a tool change it shows the old and new filament, the
  Unload → Load → Resume stage with AFC's current step, and "change 3 of 12";
  the bar chip shows the target tool. AFC errors appear in the message line.
  New setting: `showFilament` (also a toggle in the popup). `status` gains a
  `filament` object. The mock printer gains `--afc` and three tool-change scenarios.
- New: the printer's camera in the popup. Webcams come from Mainsail/Fluidd
  (`/server/webcams/list`). Snapshots are fetched one at a time, about once a
  second, and only while the popup is open. Rotation and flips from the webcam
  settings are applied. With several webcams, click the picture to switch.
  New settings: `showCamera` (also a toggle in the popup) and `webcam`.
- The camera follows the `/webcam/` redirect to the streamer's own port, but only
  on the printer's host, and the API key is only sent to the printer's own origin.
- HTTP errors for images now show the redirect target, e.g. `HTTP 302 → …`.
- `status` gains a `camera` object.
- Mock printer gains a webcam, `--webcam`/`--no-webcam`, and a `huge-snapshot` scenario.

## 0.1.2 — 2026-10-01

- Security: responses from the printer are now size- and time-limited. HTTP
  moved from QML's `XMLHttpRequest`, whose `abort()` leaves the transfer
  buffering inside the shell, to short `curl` calls capped at 1 MB (2 MB for
  thumbnails) and 10 seconds. An endless response from a broken or
  compromised Moonraker could previously exhaust the shell's memory.
  Reported by HANCORE-linux in the marketplace review.
- The API key now reaches curl on stdin, so it never appears in the process list.
- Thumbnails are fetched with the API key header directly; the one-shot token
  round trip is gone.
- Mock printer gains `flood`, `flood-declared`, `hang`, and `huge-thumbnail` scenarios.
- Screenshots and preview regenerated for the new "Compact when not printing" toggle, plus a compact-idle bar shot.

## 0.1.1 — 2026-09-30

- Fix: the popup's "Hide when not printing" toggle hid the whole widget, and
  with it the popup needed to turn the option back off. The toggle is now
  **Compact when not printing** (`compactWhenIdle`): a dimmed icon that stays
  clickable. Full hiding (`hideWhenIdle`) is still available through
  `shell.json` or IPC, with the command to undo it documented.

## 0.1.0 — 2026-09-30

First release.

- Bar chip with three styles (`icon`, `progress`, `full`), cycled with a right click
- Detail popup: thumbnail, elapsed/remaining/finish time, layer, filament, temperatures
- Pause, resume, and cancel (confirmed with a second click)
- API key support; thumbnails load through Moonraker one-shot tokens
- States: not configured, unreachable, unauthorized, Klipper starting up,
  disconnected, or shut down, idle, heating, printing, paused, complete,
  cancelled, and error
- Automatic chamber sensor detection
- IPC: `toggle`, `showSettings`, `refresh`, `cycleDisplay`, `status`, `configure`
- Mock Moonraker and screenshot automation for development
