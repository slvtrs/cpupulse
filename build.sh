#!/bin/zsh
# Build CPUPulse.app — a native menu-bar CPU monitor.
set -e
cd "$(dirname "$0")"

APP="CPUPulse.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"

echo "Compiling…"
swiftc -O CPUPulse.swift -o CPUPulse

echo "Packaging $APP…"
rm -rf "$APP"
mkdir -p "$MACOS"
mv CPUPulse "$MACOS/CPUPulse"

cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>CPUPulse</string>
    <key>CFBundleDisplayName</key>     <string>CPUPulse</string>
    <key>CFBundleIdentifier</key>      <string>com.slvtrs.cpupulse</string>
    <key>CFBundleVersion</key>         <string>1.0</string>
    <key>CFBundleShortVersionString</key> <string>1.0</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleExecutable</key>      <string>CPUPulse</string>
    <key>LSMinimumSystemVersion</key>  <string>12.0</string>
    <key>LSUIElement</key>             <true/>
    <key>NSHighResolutionCapable</key> <true/>
</dict>
</plist>
PLIST

# Ad-hoc codesign so Gatekeeper/launchd are happy with a local build.
codesign --force --sign - "$APP" 2>/dev/null || echo "(codesign skipped)"

echo "Built: $PWD/$APP"
echo "Run it with:  open $PWD/$APP"
