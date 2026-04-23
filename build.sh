#!/bin/bash
set -euo pipefail

APP="Untouchable.app"
BIN="Untouchable"
BUNDLE="$APP/Contents"
INSTALL_DIR="/Applications"

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

if [[ "${1:-}" == "install" ]]; then
    echo "Installing to $INSTALL_DIR …"
    killall Untouchable 2>/dev/null || true
    sleep 1
    rm -rf "$INSTALL_DIR/$APP"
    cp -R "$APP" "$INSTALL_DIR/"
    open "$INSTALL_DIR/$APP"
    echo "Installed and relaunched from $INSTALL_DIR/$APP"
else
    echo "Run it:   open $APP"
    echo "Install:  ./build.sh install"
fi
