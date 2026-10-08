# Contributing

Thanks for helping out! Bug reports, printer compatibility notes, and pull
requests are all welcome.

## Reporting a bug

Please include:

- your printer and firmware (e.g. Qidi Q2, Voron 2.4 with Mainsail)
- what the popup says, plus a screenshot if you can
- the output of `omarchy-shell io.github.saurasanchezpablo.moonraker-plus status` (it never contains your API key)
- your Omarchy version (`omarchy version`)

If your printer uses an unusual chamber sensor or reports progress
differently, the output of `curl http://<printer>/printer/objects/list` helps a lot.

## Project layout

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for how the widget works.
In short, `Panel.qml` is the widget, `Model.js` holds the pure logic, and
`dev/` holds the tooling described below.

## Install your working copy

```bash
./dev/install.sh     # copy to ~/.config/omarchy/plugins/io.github.saurasanchezpablo.moonraker-plus, restart the shell
omarchy plugin enable io.github.saurasanchezpablo.moonraker-plus right   # first time only
omarchy plugin validate .                    # manifest check
```

## Mock printer

`dev/mock_moonraker.py` is a small fake Moonraker. It lets you work on any
state without waiting for a real print.

```bash
./dev/mock_moonraker.py --scenario printing
omarchy-shell io.github.saurasanchezpablo.moonraker-plus configure '{"url":"http://127.0.0.1:7125"}'
```

To try the API-key states, start it with `--require-key demo-key` and type
`demo-key` in the popup's Settings: `configure` refuses `apiKey`, since its
JSON is a command-line argument any local user can read.

- By default the fake job gets synthesized metadata and `dev/assets/thumbnail.png`.
- `--upstream`/`--file`: proxy file metadata, thumbnails, and the webcam to a real printer instead.
  Its API key, if needed, goes in the environment: `read -rs MOONRAKER_API_KEY && export MOONRAKER_API_KEY`.
  The proxy never follows redirects (they would carry the key to another host), caps answers at 8 MB,
  forwards only file metadata, `.thumbs/` images, and the webcam, and needs a test key for the mock
  itself (`MOCK_REQUIRE_KEY`, also kept out of the process list), so other local programs can't use it
  to reach the printer.
- `--require-key`: reject requests without this key (tests the auth states).
- `--file-filaments`, `--file-tools`, `--file-grams`: what the fake file needs (OrcaSlicer-style
  metadata), e.g. `--afc --file-tools 0,2 --file-filaments PETG,TPU,PETG,PLA` to trigger the
  filament check. The defaults match the `--afc` lanes.
- `--spoolman`: simulate Moonraker's Spoolman integration with three spools (one multi-color); with `--afc`, lanes accept `SET_SPOOL_ID`.
- `--afc`: simulate a 4-lane Elegoo Canvas (AFC). The `toolchange-unload`,
  `toolchange-load`, and `toolchange-resume` scenarios show change 3 of 12 from T0 to T2.
- A webcam named "Mock Cam" serves `dev/assets/webcam.jpg`; `--webcam` picks another JPEG, `--no-webcam` reports none.
- Pause / resume / cancel from the popup change the mock's state.

Switch scenarios while it runs:

```bash
curl -X POST http://127.0.0.1:7125/mock/scenario/paused
curl http://127.0.0.1:7125/mock/scenarios
```

Scenarios: `idle`, `heating`, `printing-start`, `printing`, `printing-end`,
`paused`, `complete`, `cancelled`, `error`, `klippy-startup`,
`klippy-shutdown`, `klippy-disconnected`, and with `--afc`:
`toolchange-unload`, `toolchange-load`, `toolchange-resume`.

Misbehaving-server scenarios, for checking the response limits: `flood` (endless
chunked body), `flood-declared` (500 MB `Content-Length`), `hang` (never
answers), `huge-thumbnail` (endless thumbnail), and `huge-snapshot` (endless
webcam frame). The mock prints how much
the client accepted before it hung up; the widget should report an error and
the shell's memory should stay flat (`ps -o rss= -p $(pgrep -f quickshell)`).

## Screenshots of every state

```bash
./dev/screenshots.sh
# or with a real file's metadata and thumbnail:
UPSTREAM=http://192.168.1.50 FILE="file.gcode" ./dev/screenshots.sh
```

If that printer needs an API key, the script asks for it without echoing it.
Never put a real key on a command line (`--api-key`, `UPSTREAM_KEY=… ./…`):
arguments are readable by every local user through the process list, and the
line lands in your shell history. The mock takes the key only from
`MOONRAKER_API_KEY` in its environment.

The script:

1. backs up `shell.json`, leaves only this widget in the bar's right section
   (so none of your other widgets appear in the shots), restarts the shell,
   and starts the mock with a required key,
2. drives the widget through configuration states (no URL, unreachable,
   missing key, wrong key) and then every print scenario, using the
   `configure`, `refresh`, and `open` IPC calls,
3. saves the bar chip (`*-bar.png`) and the popup (`*.png`) for each state
   into `docs/screenshots/`,
4. restores `shell.json` from the backup and restarts the shell on exit.

Bar chips are trimmed to the widget by `dev/crop_bar.py`. Popups are cropped
by `dev/crop_popup.py`. It finds the card from the difference between a closed
and an open shot, then trims to the card's own border. Each open shot is retaken until two in a row are identical, so the
open animation has finished.

Requirements: `grim`, `jq`, `python-pillow`, and a horizontal bar at the top.

## Before opening a pull request

- Run `omarchy plugin validate .`
- Try your change against the mock in the states it touches
- If the look changed, regenerate the screenshots with `./dev/screenshots.sh`
- Add a line to [CHANGELOG.md](CHANGELOG.md)
- For bigger changes, also go through the checklist below on a real printer

## Manual checklist (real printer)

- [ ] Fresh install: the popup opens on Settings, and Save & connect works
- [ ] Wrong key → *Unauthorized*, then fixing the key recovers without a restart
- [ ] Unplug the network or stop the VPN → *Unreachable*, and it recovers by itself
- [ ] Start a print: *Heating* → *Printing* with the thumbnail, then time left looks sane after ~5%
- [ ] Pause from the popup → printer pauses, then Resume continues
- [ ] Cancel: the first click arms, the second click within 3 s cancels
- [ ] A print whose file needs a material that isn't loaded shows the filament warning and sends one notification
- [ ] Klipper shutdown: Restart appears; the first click arms, the second restarts Klipper and the popup returns to the normal state
- [ ] Right click cycles the styles and survives `omarchy restart shell`
- [ ] Middle click opens the web UI
- [ ] Tools → pause at a layer two layers ahead: the print pauses there, and "Pauses at" disappears afterwards
- [ ] Idle: Tools → pause the next print at layer 3; the note shows under the title, and the next print pauses at layer 3
- [ ] Tools on a multi-object plate: skipping an object needs a second click, then it shows as skipped and the printer leaves it out
- [ ] With Spoolman: Tools shows the active spool; picking another one switches it in Mainsail too
- [ ] With Spoolman and AFC: Tools lists every lane; assigning a spool to a lane updates the lane card, and spools on other lanes are marked
- [ ] The bulb on the camera switches the chamber light and shows its state
- [ ] A finished print, a filament-runout pause, and a Klipper shutdown each send one notification; pausing from the popup doesn't
- [ ] With an AFC changer: every lane shows its color, tool, and material, the loaded one is highlighted, and a tool change walks through Unload → Load → Resume with the right old and new filament
- [ ] The camera shows within a couple of seconds of opening the popup, updates about once a second, and stops when the popup closes (`status` → `camera.streaming: false`)
- [ ] `omarchy theme set <other>` repaints the widget and popup
- [ ] Bar on the left/right edge (vertical): the chip shows the icon only
