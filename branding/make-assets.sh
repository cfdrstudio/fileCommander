#!/bin/zsh
# Regenerates every fileCommander brand asset from the SVG sources in this folder:
#   icon.svg (app icon), favicon.svg (small sizes), mark.svg (icon body).
# Output: app/AppIcon.icns, web/ (favicons, touch icon, manifest), logo-*.png/svg.
# Uses only macOS tools: Swift/AppKit for rendering, iconutil for .icns, python3 for .ico.
set -euo pipefail
cd "$(dirname "$0")"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
swiftc -O tools/Render.swift -o "$TMP/render"
R="$TMP/render"

# App icon (.icns). The 16/32 px slots use the simplified favicon art so they stay legible.
SET="$TMP/AppIcon.iconset"; mkdir -p "$SET" app
"$R" png favicon.svg "$SET/icon_16x16.png" 16
"$R" png favicon.svg "$SET/icon_16x16@2x.png" 32
"$R" png favicon.svg "$SET/icon_32x32.png" 32
"$R" png icon.svg "$SET/icon_32x32@2x.png" 64
for s in 128 256 512; do
  "$R" png icon.svg "$SET/icon_${s}x${s}.png" $s
  "$R" png icon.svg "$SET/icon_${s}x${s}@2x.png" $((s * 2))
done
iconutil -c icns "$SET" -o app/AppIcon.icns
"$R" png icon.svg app/icon-1024.png 1024

# Web: favicon.ico (16/32/48), SVG favicon, touch icon, manifest icons.
mkdir -p web
for s in 16 32 48; do "$R" png favicon.svg "$TMP/fav-$s.png" $s; done
python3 tools/make_ico.py web/favicon.ico "$TMP/fav-16.png" "$TMP/fav-32.png" "$TMP/fav-48.png"
cp favicon.svg web/favicon.svg
"$R" png favicon.svg web/favicon-32.png 32
"$R" png mark.svg web/icon-192.png 192
"$R" png mark.svg web/icon-512.png 512
# Apple touch icons must be opaque (iOS rounds the corners itself): mark on the brand blue.
"$R" opaque mark.svg web/apple-touch-icon.png 180 "#2A3BC4"
cat > web/site.webmanifest <<'JSON'
{
  "name": "fileCommander",
  "short_name": "fileCommander",
  "icons": [
    { "src": "icon-192.png", "sizes": "192x192", "type": "image/png" },
    { "src": "icon-512.png", "sizes": "512x512", "type": "image/png" }
  ],
  "theme_color": "#2A3BC4",
  "background_color": "#151C5E",
  "display": "standalone"
}
JSON

# Logos (mark + wordmark), for light and dark backgrounds.
"$R" wordmark mark.svg light logo-light.png logo-light.svg
"$R" wordmark mark.svg dark logo-dark.png logo-dark.svg

echo "Generated: app/AppIcon.icns, app/icon-1024.png, web/*, logo-light/dark.{png,svg}"
