#!/bin/sh
# Builds build/PresenceBar.app. Pass --run to (re)launch it afterwards.
set -eu
cd "$(dirname "$0")"
APP=build/PresenceBar.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -swift-version 5 -parse-as-library -target arm64-apple-macos14.0 \
    Sources/*.swift -o "$APP/Contents/MacOS/PresenceBar"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
echo "Built $APP"
if [ "${1:-}" = "--run" ]; then
    pkill -x PresenceBar 2>/dev/null || true
    open "$APP"
fi
