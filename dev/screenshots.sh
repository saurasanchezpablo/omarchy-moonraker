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
# top or bottom of the first monitor, grim, jq, and python-pillow. The popup is
# translucent: capture over an empty workspace or a plain window.
set -euo pipefail
cd "$(dirname "$0")/.."

ID=io.github.saurasanchezpablo.moonraker-plus
CFG="$HOME/.config/omarchy/shell.json"
OUT=docs/screenshots
PORT=7125
# A fresh test key per run, handed to the mock through its environment:
# with UPSTREAM set, it gates access to a proxy that holds the real key.
MOCK_KEY=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
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
# Only the shots this script takes; others (15-camera-filament-change.png)
# are made by hand.
rm -f "$OUT"/0*.png "$OUT"/1[0-4]-*.png

read -r MON_W MON_H < <(hyprctl monitors -j | jq -r '.[0] | "\(.width) \(.height)"')
# Bar geometry from its layer surface, so nothing beyond the bar gets captured.
read -r BAR_Y BAR_H < <(hyprctl layers -j |
  jq -r '[.. | objects | select(.namespace? == "omarchy-bar")][0] | "\(.y) \(.h)"')
BAR_REGION="$((MON_W - 700)),$((BAR_Y > 3 ? BAR_Y - 3 : 0)) 700x$((BAR_H + 6))"
# The popup opens below a top bar and above a bottom one. With the camera and
# the settings open it can be tall: take as much as the screen allows, up to 1300.
POP_H=$(( MON_H - BAR_H - 8 < 1300 ? MON_H - BAR_H - 8 : 1300 ))
if (( BAR_Y > MON_H / 2 )); then
  POP_REGION="$((MON_W - 700)),$((BAR_Y - POP_H - 2)) 700x$POP_H"
else
  POP_REGION="$((MON_W - 700)),$((BAR_Y + BAR_H + 2)) 700x$POP_H"
fi

# The widget's entry holds its real settings, possibly an API key: it stays in
# shell variables and reaches jq only through the environment (env.ORIGINAL),
# never as an argument other users could read in the process list.
ORIGINAL=$(jq -c --arg id "$ID" '[.bar.layout[][] | select(.id == $id)][0]' "$CFG")
[[ $ORIGINAL != null ]] || { echo "Enable $ID in the bar first" >&2; exit 1; }
BACKUP=$(mktemp --suffix .shell.json)
cp "$CFG" "$BACKUP"

set_entry() {  # set_entry '<JSON object merged into the widget settings>' (never secrets)
  local out
  for _ in $(seq 40); do
    out=$(omarchy-shell "$ID" configure "$1" 2>/dev/null) && [[ $out == ok ]] && return 0
    sleep 0.5
  done
  echo "configure $1 failed: $out" >&2
  return 1
}

# The widget's configure IPC refuses apiKey (its JSON is a command-line
# argument). Write the key into shell.json from the environment instead and
# restart the shell to load it.
set_api_key() {  # set_api_key <key>; function arguments stay inside this shell
  local tmp
  tmp=$(mktemp)
  API_KEY=$1 jq --arg id "$ID" '(.bar.layout[][] | select(.id == $id) | .apiKey) = env.API_KEY' \
    "$CFG" >"$tmp" && cat "$tmp" >"$CFG"
  rm -f "$tmp"
  omarchy restart shell >/dev/null 2>&1
  for _ in $(seq 60); do omarchy-shell "$ID" status >/dev/null 2>&1 && break; sleep 0.5; done
  sleep 2
}

restore() {
  # Nothing here may abort the trap (set -e): shell.json must come back.
  set +e
  omarchy-shell -q "$ID" close >/dev/null 2>&1
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
  python3 dev/crop_bar.py "$OUT/$name-bar.png" "$OUT/$name-bar.png"
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
  python3 dev/crop_popup.py "$closed" "$open" "$OUT/$name.png"
  rm -f "$closed" "$open"
  echo "captured $name"
}

mock_args=(--port "$PORT" --file "$FILE")
[[ -n ${UPSTREAM:-} ]] && mock_args+=(--upstream "$UPSTREAM")
MOCK_REQUIRE_KEY=$MOCK_KEY MOONRAKER_API_KEY=$upstream_key python3 dev/mock_moonraker.py "${mock_args[@]}" &
MOCK_PID=$!
upstream_key=

# Leave only this widget in the right section. A layout edit from outside the
# shell doesn't always bring third-party IPC targets back, so restart it.
tmp=$(mktemp)
ORIGINAL=$ORIGINAL jq --arg id "$ID" \
  '(.bar.layout[] |= map(select(.id != $id))) | .bar.layout.right = [env.ORIGINAL | fromjson]' "$CFG" >"$tmp"
cat "$tmp" >"$CFG"
rm -f "$tmp"
omarchy restart shell >/dev/null 2>&1
for _ in $(seq 60); do omarchy-shell "$ID" status >/dev/null 2>&1 && break; sleep 0.5; done
sleep 2

# ---- Setup / login ----
set_api_key ""
set_entry '{"url":"","display":"full","temps":["nozzle","bed","chamber"],"compactWhenIdle":false,"hideWhenIdle":false,"hideWhenOffline":false}'
sleep 1; capture 01-not-configured

set_entry '{"url":"http://127.0.0.1:7999"}'
sleep 1; capture 02-unreachable

set_entry "{\"url\":\"$MOCK_URL\"}"
scenario idle
sleep 1; capture 03-api-key-missing

set_api_key wrong-key
scenario idle
sleep 1; capture 04-api-key-wrong

set_api_key "$MOCK_KEY"
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
