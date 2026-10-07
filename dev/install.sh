#!/bin/bash
# Copy the working tree into the Omarchy plugin dir and hot-reload the shell.
set -euo pipefail
cd "$(dirname "$0")/.."
DEST="$HOME/.config/omarchy/plugins/io.github.saurasanchezpablo.moonraker-plus"
mkdir -p "$DEST"
cp manifest.json Panel.qml Model.js "$DEST/"
if [[ -f LICENSE ]]; then cp LICENSE "$DEST/"; fi
# Hot reload keeps the previously compiled component cached, so restart.
omarchy restart shell >/dev/null 2>&1
