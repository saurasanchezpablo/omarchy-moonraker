# Widget states

Every state the widget can show, captured against the mock Moonraker
(`dev/mock_moonraker.py`) with `dev/screenshots.sh`. Colors come from the
active Omarchy theme, so they will differ on your system. The urgent color in
these shots happens to be green.

Each state shows the bar chip first, then the popup. The screenshots use a
neutral `calibration-cube.gcode` job and the bundled mock thumbnail.

## Camera and filament change

A print on a 4-lane AFC changer (Elegoo Canvas) in the middle of change 3 of 12,
loading T2: the change card with the Unload → Load → Resume stage, the live
camera with the chamber light switch, and the lanes with the loading one
pulsing.

<img src="screenshots/15-camera-filament-change.png" width="400">

## 1. Setup and connection

### Not configured

The first time the widget loads there is no URL. The chip shows a dimmed
printer icon, and the popup opens straight on the Settings form.

![bar](screenshots/01-not-configured-bar.png)

<img src="screenshots/01-not-configured.png" width="400">

### Unreachable

The URL doesn't answer, or a request takes longer than 10 seconds. Causes
include a wrong address, the printer being off, or the VPN being down. The
chip dims and shows a disconnected-network icon.

![bar](screenshots/02-unreachable-bar.png)

<img src="screenshots/02-unreachable.png" width="400">

### API key missing

Moonraker answered `401` and no key is set. The chip shows a lock, and the
popup opens on Settings with the reason.

![bar](screenshots/03-api-key-missing-bar.png)

<img src="screenshots/03-api-key-missing.png" width="400">

### API key rejected

Moonraker answered `401` and a key was sent, so the key is wrong.

![bar](screenshots/04-api-key-wrong-bar.png)

<img src="screenshots/04-api-key-wrong.png" width="400">

## 2. Klipper not ready

Moonraker is reachable but Klipper isn't. The chip shows an alert in the urgent
color. Temperatures stay visible whenever Klipper reports them.

| State | Bar | Popup |
|-------|-----|-------|
| Starting up | ![](screenshots/05-klippy-startup-bar.png) | <img src="screenshots/05-klippy-startup.png" width="330"> |
| Disconnected (Moonraker answers `503`) | ![](screenshots/05-klippy-disconnected-bar.png) | <img src="screenshots/05-klippy-disconnected.png" width="330"> |
| Shutdown (Klipper's message is shown) | ![](screenshots/05-klippy-shutdown-bar.png) | <img src="screenshots/05-klippy-shutdown.png" width="330"> |

## 3. Print lifecycle

### Idle

Ready and nothing loaded. In `full` style the chip shows the current temperatures.

![bar](screenshots/06-idle-bar.png)

<img src="screenshots/06-idle.png" width="400">

### Heating

The job has started, but `PRINT_START` is still bringing a heater up (progress
is 0 and a heater is more than 2° below its target). The chip shows
**Heating** instead of `0%`.

![bar](screenshots/07-heating-bar.png)

<img src="screenshots/07-heating.png" width="400">

### Printing

Progress, time left, and finish time. Time left averages the slicer estimate
with extrapolation from file progress. Before 5% progress only the slicer
estimate is used.

| Progress | Bar | Popup |
|----------|-----|-------|
| 3% | ![](screenshots/08-printing-start-bar.png) | <img src="screenshots/08-printing-start.png" width="330"> |
| 42% | ![](screenshots/08-printing-bar.png) | <img src="screenshots/08-printing.png" width="330"> |
| 97% | ![](screenshots/08-printing-end-bar.png) | <img src="screenshots/08-printing-end.png" width="330"> |

### Paused

A pause icon replaces the printer icon, and the progress bar pulses. Klipper's
pause message (e.g. a filament runout) appears under the title. **Resume**
replaces **Pause**.

![bar](screenshots/09-paused-bar.png)

<img src="screenshots/09-paused.png" width="400">

### Complete

The chip shows a check mark. The popup summarizes print time and filament used.

![bar](screenshots/10-complete-bar.png)

<img src="screenshots/10-complete.png" width="400">

### Cancelled

![bar](screenshots/11-cancelled-bar.png)

<img src="screenshots/11-cancelled.png" width="400">

### Error

The print stopped with an error. The chip turns urgent, and the error message
appears under the title.

![bar](screenshots/12-error-bar.png)

<img src="screenshots/12-error.png" width="400">

## 4. Bar styles and settings

| Style | Bar |
|-------|-----|
| `icon` | ![](screenshots/13-bar-icon-bar.png) |
| `progress` | ![](screenshots/13-bar-progress-bar.png) |
| `full` | ![](screenshots/13-bar-full-bar.png) |
| `full`, idle | ![](screenshots/13-bar-full-idle-bar.png) |
| Idle with **Compact when not printing** (a dimmed icon that stays clickable) | ![](screenshots/13-bar-compact-idle-bar.png) |

Settings open on top of a running print. The API key field is masked.

<img src="screenshots/14-settings.png" width="400">
