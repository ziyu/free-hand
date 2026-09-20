#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --product FreeHandPlayground
BIN="$(swift build --show-bin-path)"
APP="$PWD/.build/Free Hand Playground.app"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN/FreeHandPlayground" "$APP/Contents/MacOS/FreeHandPlayground"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.feibai.freehand.playground</string>
<key>CFBundleName</key><string>Free Hand Playground</string>
<key>CFBundleExecutable</key><string>FreeHandPlayground</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>0.1.0</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
open "$APP"
