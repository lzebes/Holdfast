#!/bin/bash
# Builds build/Holdfast.app. Needs only the Xcode Command Line Tools.
set -euo pipefail
cd "$(dirname "$0")"
APP="build/Holdfast.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "Compiling helper…"
swiftc -O -target arm64-apple-macos13.0 -o "$APP/Contents/Resources/holdfast-enforcer" Sources/Shared/*.swift Sources/Enforcer/*.swift
echo "Compiling app…"
swiftc -O -target arm64-apple-macos13.0 -parse-as-library -o "$APP/Contents/MacOS/Holdfast" Sources/Shared/*.swift Sources/App/*.swift

cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/com.holdfast.enforcer.plist Resources/install-helper.sh Resources/uninstall-helper.sh "$APP/Contents/Resources/"

echo "Rendering icon…"
swift Scripts/make-icon.swift build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf build/AppIcon.iconset

codesign --force --deep -s - "$APP" >/dev/null 2>&1
echo "Built $APP"
