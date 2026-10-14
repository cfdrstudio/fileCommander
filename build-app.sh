#!/bin/zsh
# Builds "fileCommander.app" into ./dist
set -e
cd "$(dirname "$0")"
swift build -c release
APP="dist/fileCommander.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/FileCommander "$APP/Contents/MacOS/FileCommander"
cp branding/app/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>fileCommander</string>
  <key>CFBundleDisplayName</key><string>fileCommander</string>
  <key>CFBundleIdentifier</key><string>local.filecommander.mac</string>
  <key>CFBundleExecutable</key><string>FileCommander</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
# Sign with the stable local certificate if setup-signing.sh created one (keeps macOS
# privacy permissions across rebuilds); otherwise ad hoc.
IDENTITY="fileCommander Local Signing"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
  codesign --force --deep -s "$IDENTITY" "$APP"
  echo "Signed with \"$IDENTITY\""
else
  codesign --force --deep -s - "$APP"
  echo "Signed ad hoc (run ./setup-signing.sh once to stop macOS re-asking for folder access after rebuilds)"
fi
echo "Built $APP"
