#!/bin/bash
# Walk the widget through every state against the mock Moonraker and capture
# the bar chip and the popup for each one into docs/screenshots/.
#
#   ./dev/screenshots.sh
#   UPSTREAM=http://192.168.1.50 FILE="part.gcode" ./dev/screenshots.sh
#
# If that printer needs an API key, the script asks for it (hidden) unless
# UPSTREAM_KEY is already exported. The key reaches the mock only through its
# environment, never its command line, where any local user could read it.
#
# By default the mock serves dev/assets/thumbnail.png. With UPSTREAM set it
# proxies real file metadata and thumbnails instead. While capturing, the bar's
# right section holds only this widget so no other widgets end up in the shots;
# shell.json is restored from a backup on exit. Needs a horizontal bar at the
# top of the first monitor, grim, jq, and python-pillow.
set -euo pipefail
cd "$(dirname "$0")/.."

ID=io.github.saurasanchezpablo.moonraker-plus
CFG="$HOME/.config/omarchy/shell.json"
OUT=docs/screenshots
PORT=7125
MOCK_KEY=demo-api-key-1234
MOCK_URL="http://127.0.0.1:$PORT"
FILE=${FILE:-calibration-cube.gcode}

# Keep the real key out of argv and out of every other child's environment.
upstream_key=${UPSTREAM_KEY:-}
unset UPSTREAM_KEY
if [[ -n ${UPSTREAM:-} && -z $upstream_key && -t 0 ]]; then
  read -rsp "API key for $UPSTREAM (Enter for none): " upstream_key
  echo
fi

mkdir -p "$OUT"
rm -f "$OUT"/*.png

read -r MON_W < <(hyprctl monitors -j | jq -r '.[0].width')
# Bar geometry from its layer surface, so nothing below the bar gets captured.
read -r BAR_Y BAR_H < <(hyprctl layers -j |
  jq -r '[.. | objects | select(.namespace? == "omarchy-bar")][0] | "\(.y) \(.h)"')
BAR_REGION="$((MON_W - 700)),$((BAR_Y > 3 ? BAR_Y - 3 : 0)) 700x$((BAR_H + 6))"
POP_REGION="$((MON_W - 700)),$((BAR_Y + BAR_H + 2)) 700x1000"

ORIGINAL=$(jq -c --arg id "$ID" '[.bar.layout[][] | select(.id == $id)][0]' "$CFG")
[[ $ORIGINAL != null ]] || { echo "Enable $ID in the bar first" >&2; exit 1; }
BACKUP=$(mktemp --suffix .shell.json)
cp "$CFG" "$BACKUP"

set_entry() {  # set_entry '<JSON object merged into the widget settings>'
  local out
  for _ in $(seq 40); do
    out=$(omarchy-shell "$ID" configure "$1" 2>/dev/null) && [[ $out == ok ]] && return 0
    sleep 0.5
  done
  echo "configure $1 failed: $out" >&2
  return 1
}

restore() {
  omarchy-shell -q $ID close
  cat "$BACKUP" >"$CFG" && rm -f "$BACKUP"
  [[ -n ${MOCK_PID:-} ]] && kill "$MOCK_PID" 2>/dev/null || true
  omarchy restart shell >/dev/null 2>&1 || true
}
trap restore EXIT

# The widget briefly drops its IPC target while shell.json reloads; retry.
ipc() {
  for _ in $(seq 20); do
    omarchy-shell "$ID" "$@" >/dev/null 2>&1 && return 0
    sleep 0.25
  done
  echo "IPC $* failed" >&2
  return 1
}

scenario() { curl -s -X POST "$MOCK_URL/mock/scenario/$1" >/dev/null; }

# capture <name>: bar chip, then the popup cropped to what changed on screen.
capture() {
  local name=$1 closed open
  ipc close
  ipc refresh
  sleep 1.5
  grim -g "$BAR_REGION" "$OUT/$name-bar.png"
  ./dev/crop_bar.py "$OUT/$name-bar.png" "$OUT/$name-bar.png"
  [[ ${2:-} == bar-only ]] && return
  closed=$(mktemp --suffix .png)
  open=$(mktemp --suffix .png)
  grim -g "$POP_REGION" "$closed"
  if [[ ${2:-} == settings ]]; then ipc showSettings; else ipc open; fi
  # Wait for the card to finish animating: two identical shots in a row.
  sleep 1.5
  grim -g "$POP_REGION" "$open"
  for _ in $(seq 20); do
    sleep 0.4
    grim -g "$POP_REGION" "$open.next"
    cmp -s "$open" "$open.next" && break
    mv "$open.next" "$open"
  done
  rm -f "$open.next"
  ./dev/crop_popup.py "$closed" "$open" "$OUT/$name.png"
  rm -f "$closed" "$open"
  echo "captured $name"
}

mock_args=(--port "$PORT" --require-key "$MOCK_KEY" --file "$FILE")
[[ -n ${UPSTREAM:-} ]] && mock_args+=(--upstream "$UPSTREAM")
MOONRAKER_API_KEY=$upstream_key python3 dev/mock_moonraker.py "${mock_args[@]}" &
MOCK_PID=$!
upstream_key=

# Leave only this widget in the right section. A layout edit from outside the
# shell doesn't always bring third-party IPC targets back, so restart it.
tmp=$(mktemp)
jq --arg id "$ID" --argjson entry "$ORIGINAL" \
  '(.bar.layout[] |= map(select(.id != $id))) | .bar.layout.right = [$entry]' "$CFG" >"$tmp"
cat "$tmp" >"$CFG"
rm -f "$tmp"
omarchy restart shell >/dev/null 2>&1
for _ in $(seq 60); do omarchy-shell "$ID" status >/dev/null 2>&1 && break; sleep 0.5; done
sleep 2

# ---- Setup / login ----
set_entry '{"url":"","apiKey":"","display":"full","temps":["nozzle","bed","chamber"],"compactWhenIdle":false,"hideWhenIdle":false,"hideWhenOffline":false}'
sleep 1; capture 01-not-configured

set_entry '{"url":"http://127.0.0.1:7999"}'
sleep 1; capture 02-unreachable

set_entry "{\"url\":\"$MOCK_URL\",\"apiKey\":\"\"}"
scenario idle
sleep 1; capture 03-api-key-missing

set_entry '{"apiKey":"wrong-key"}'
sleep 1; capture 04-api-key-wrong

set_entry "{\"apiKey\":\"$MOCK_KEY\"}"
sleep 1

# ---- Printer lifecycle ----
for s in klippy-startup klippy-disconnected klippy-shutdown idle heating \
         printing-start printing printing-end paused complete cancelled error; do
  scenario "$s"
  case $s in
    klippy-*) n=05 ;; idle) n=06 ;; heating) n=07 ;; printing*) n=08 ;;
    paused) n=09 ;; complete) n=10 ;; cancelled) n=11 ;; error) n=12 ;;
  esac
  capture "$n-$s"
done

# ---- Bar display modes & settings ----
scenario printing
for mode in icon progress full; do
  set_entry "{\"display\":\"$mode\"}"
  sleep 1; capture "13-bar-$mode" bar-only
done
scenario idle
set_entry '{"display":"full"}'
sleep 1; capture 13-bar-full-idle bar-only
set_entry '{"compactWhenIdle":true}'
sleep 1; capture 13-bar-compact-idle bar-only
set_entry '{"compactWhenIdle":false}'

scenario printing
capture 14-settings settings

ls "$OUT"
