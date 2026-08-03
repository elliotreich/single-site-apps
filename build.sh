#!/bin/bash
# Build & install a single-site WebKit wrapper app.
# Usage: ./build.sh Spectrum "Spectrum"        (dir, /Applications name)
#        ./build.sh AppleTV  "Apple TV Web"
set -e
DIR="$1"; APPNAME="${2:-$1}"
cd "$(dirname "$0")/$DIR"
EXEC=$(/usr/libexec/PlistBuddy -c "Print CFBundleExecutable" Info.plist)
APP="/Applications/$APPNAME.app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
# icon (either AppIcon.icns or <Name>.icns)
ICNS=$(ls *.icns 2>/dev/null | head -1); [ -n "$ICNS" ] && cp "$ICNS" "$APP/Contents/Resources/"
swiftc -O -framework Cocoa -framework WebKit -o "$APP/Contents/MacOS/$EXEC" main.swift
codesign --force --deep --sign - --entitlements entitlements.plist --options runtime "$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
echo "Installed: $APP"
