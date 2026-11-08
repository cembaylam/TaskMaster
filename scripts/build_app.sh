#!/bin/zsh
# Builds TaskMaster.app (release, arm64) into ./build
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --arch arm64
BIN=$(swift build -c release --arch arm64 --show-bin-path)/TaskMaster
APP=build/TaskMaster.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/TaskMaster"

ICONSET=build/AppIcon.iconset
mkdir -p "$ICONSET"
swiftc -O scripts/make_icon.swift -o build/make_icon
build/make_icon build/icon_1024.png
for s in 16 32 128 256 512; do
  sips -z $s $s build/icon_1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) build/icon_1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>TaskMaster</string>
  <key>CFBundleDisplayName</key><string>TaskMaster</string>
  <key>CFBundleIdentifier</key><string>consulting.cider.TaskMaster</string>
  <key>CFBundleExecutable</key><string>TaskMaster</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>27.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSAppleEventsUsageDescription</key><string>TaskMaster reads and changes your login items, and runs tasks with administrator privileges, through System Events.</string>
  <key>NSLocationWhenInUseUsageDescription</key><string>TaskMaster shows the name of the Wi-Fi network you are connected to.</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
echo "Built $APP"
