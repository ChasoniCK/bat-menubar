#!/bin/bash
# Builds Bat.app (menu bar power meter). Run: ./build.sh
set -euo pipefail
cd "$(dirname "$0")"

# Installed outside ~/Documents: iCloud adds xattrs that break codesign, and a synced
# bundle is a bad login item.
APP="$HOME/Applications/Bat.app"
# Version comes from the latest tag (v1.7 -> 1.7), build number from the commit count.
VERSION=$(git describe --tags --abbrev=0 | sed 's/^v//')
BUILD=$(git rev-list --count HEAD)
pkill -f "$APP/Contents/MacOS/Bat" 2>/dev/null || true
mkdir -p "$HOME/Applications"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Bat.icns "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>Bat</string>
	<key>CFBundleIconFile</key><string>Bat</string>
	<key>CFBundleIdentifier</key><string>com.chasonick.bat</string>
	<key>CFBundleName</key><string>Bat</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>$VERSION</string>
	<key>CFBundleVersion</key><string>$BUILD</string>
	<key>LSMinimumSystemVersion</key><string>26.0</string>
	<key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

swiftc -O -target arm64-apple-macos26.0 -parse-as-library \
	Bat.swift -o "$APP/Contents/MacOS/Bat"

xattr -cr "$APP"
codesign --force --sign - --identifier com.chasonick.bat "$APP"
echo "built $APP"
