#!/bin/bash
# Renders the README scene (docs/scene/scene.html) to docs/images/scene-{light,dark}.png
# with headless Chrome. The HUD images come from screenshot mode, so run that first:
#   DICTATE_SCREENSHOTS=docs/images build/Dictate.app/Contents/MacOS/Dictate
# Other scenes in scene.html: chat, mail, term (pass as $1).
set -euo pipefail
cd "$(dirname "$0")/.."
kind="${1:-notes}"
chrome="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
for theme in light dark; do
  "$chrome" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=2 \
    --window-size=1280,800 --allow-file-access-from-files \
    --screenshot="$PWD/docs/images/scene-$theme.png" "file://$PWD/docs/scene/scene.html#$kind-$theme" >/dev/null 2>&1
  sips -Z 1600 "docs/images/scene-$theme.png" >/dev/null
done
echo "rendered: docs/images/scene-{light,dark}.png ($kind)"
