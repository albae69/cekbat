#!/bin/sh
# Build CekBat.app without Xcode project.
set -eu
cd "$(dirname "$0")"

APP=build/CekBat.app
ICONSET=build/icon.iconset
rm -rf "$APP" "$ICONSET"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$ICONSET"
cp Info.plist "$APP/Contents/Info.plist"
if [ -f assets/icon.png ]; then
    for s in 16 32 128 256 512; do
        sips -z "$s" "$s" assets/icon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
        sips -z "$((s * 2))" "$((s * 2))" assets/icon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/CekBat.icns"
fi
swiftc -O -parse-as-library CekBat.swift -o "$APP/Contents/MacOS/CekBat"
echo "built: $APP"
