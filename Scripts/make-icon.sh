#!/bin/zsh
# Renders the app icon from source: Scripts/make-icon.swift -> Resources/AppIcon.png -> Resources/AppIcon.icns
# Both outputs are committed, so building the app doesn't need this script.
set -euo pipefail
cd "${0:A:h}/.."

PNG="Resources/AppIcon.png"
ICONSET="$(mktemp -d)/AppIcon.iconset"

swift Scripts/make-icon.swift "$PNG"

mkdir -p "$ICONSET"
for spec in 16:16x16 32:16x16@2x 32:32x32 64:32x32@2x 128:128x128 256:128x128@2x 256:256x256 512:256x256@2x 512:512x512 1024:512x512@2x; do
  sips -z "${spec%%:*}" "${spec%%:*}" "$PNG" --out "$ICONSET/icon_${spec##*:}.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
rm -rf "$(dirname "$ICONSET")"
echo "Wrote Resources/AppIcon.icns ($(du -h Resources/AppIcon.icns | cut -f1))"
