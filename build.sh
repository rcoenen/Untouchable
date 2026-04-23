#!/bin/bash
set -euo pipefail

APP="Untouchable.app"
BIN="Untouchable"
BUNDLE="$APP/Contents"
DFR="/System/Library/PrivateFrameworks/DFRFoundation.framework"

rm -rf "$APP"
mkdir -p "$BUNDLE/MacOS" "$BUNDLE/Resources"
cp Info.plist "$BUNDLE/Info.plist"

swiftc \
    -O \
    -target arm64-apple-macos11 \
    -F /System/Library/PrivateFrameworks \
    -framework DFRFoundation \
    -framework Cocoa \
    Sources/main.swift \
    -o "$BUNDLE/MacOS/$BIN"

codesign --force --sign - "$APP"

echo ""
echo "Built $APP"
echo "Run it:  open $APP"
echo "Or:      ./$BUNDLE/MacOS/$BIN"
