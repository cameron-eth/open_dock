#!/bin/zsh
# Builds "Mono Dock.app" next to this script.
set -euo pipefail
cd "${0:A:h}"

swift build -c release
APP="Mono Dock.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Fractal "$APP/Contents/MacOS/MonoDock"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Mono Dock</string>
  <key>CFBundleDisplayName</key><string>Mono Dock</string>
  <key>CFBundleIdentifier</key><string>local.fractal.canvas</string>
  <key>CFBundleExecutable</key><string>MonoDock</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.3</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>Mono Dock sends the messages you write in the dock through Messages.</string>
</dict></plist>
PLIST

# Sign with a stable identity so Accessibility permission survives rebuilds.
IDENTITY=$(security find-identity -v -p codesigning | grep -v REVOKED | grep "Apple Development" | tail -1 | awk '{print $2}')
codesign --force --deep -s "${IDENTITY:--}" "$APP"
echo "Built $PWD/$APP (signed with ${IDENTITY:-ad-hoc})"
