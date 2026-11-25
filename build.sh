#!/bin/zsh
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$TASK_ROOT/dist/极简状态.app"
BUILD_WORK="$TASK_ROOT/.build"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$BUILD_WORK"
swiftc -O -swift-version 6 -strict-concurrency=complete -warnings-as-errors -target arm64-apple-macosx13.0 \
  "$TASK_ROOT/Sources/MiniStatus.swift" -o "$BUILD_WORK/MiniStatus.next" \
  -framework AppKit -framework SwiftUI
mv "$BUILD_WORK/MiniStatus.next" "$APP/Contents/MacOS/MiniStatus"
ICONSET="$BUILD_WORK/ministatus.iconset"
mkdir -p "$ICONSET"
swift "$TASK_ROOT/Sources/MakeIcon.swift" "$BUILD_WORK/ministatus-icon.png"
for ICON_SIZE in 16 32 128 256 512; do
  sips -z "$ICON_SIZE" "$ICON_SIZE" "$BUILD_WORK/ministatus-icon.png" --out "$ICONSET/icon_${ICON_SIZE}x${ICON_SIZE}.png" >/dev/null
  ICON_DOUBLE=$((ICON_SIZE * 2))
  sips -z "$ICON_DOUBLE" "$ICON_DOUBLE" "$BUILD_WORK/ministatus-icon.png" --out "$ICONSET/icon_${ICON_SIZE}x${ICON_SIZE}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/MiniStatus.icns"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>极简状态</string>
<key>CFBundleDisplayName</key><string>极简状态</string>
<key>CFBundleIdentifier</key><string>local.ministatus.app</string>
<key>CFBundleExecutable</key><string>MiniStatus</string>
<key>CFBundleIconFile</key><string>MiniStatus.icns</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.3</string>
<key>CFBundleVersion</key><string>4</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
print -r -- "$APP"
