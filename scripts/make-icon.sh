#!/bin/zsh
# Regenerates Resources/AppIcon.icns and brand/icon-1024.png from brand/icon.svg.
# Sizes ≤ 32 px use brand/icon-small.svg (no shadow/glow, bigger dots) so they stay legible.
set -euo pipefail
cd "$(dirname "$0")/.."
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
swiftc -O scripts/tools/render-svg.swift -o "$TMP/render" 2>/dev/null
SET="$TMP/AppIcon.iconset"
mkdir -p "$SET"
for spec in 16:icon_16x16 32:icon_16x16@2x 32:icon_32x32 64:icon_32x32@2x 128:icon_128x128 256:icon_128x128@2x \
            256:icon_256x256 512:icon_256x256@2x 512:icon_512x512 1024:icon_512x512@2x; do
  px="${spec%%:*}"; name="${spec#*:}"
  src="brand/icon.svg"; (( px <= 32 )) && src="brand/icon-small.svg"
  "$TMP/render" "$src" "$px" "$SET/$name.png"
done
iconutil -c icns "$SET" -o Resources/AppIcon.icns
cp "$SET/icon_512x512@2x.png" brand/icon-1024.png
echo "Wrote Resources/AppIcon.icns and brand/icon-1024.png"
