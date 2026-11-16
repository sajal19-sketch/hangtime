#!/bin/bash
# Double-click this file to build Hangtime and start it.
#
# Keep macOS permissions between builds (do this once, about a minute):
#   1. Open Keychain Access. In the menu bar choose
#      Keychain Access > Certificate Assistant > Create a Certificate…
#   2. Name: Hangtime Developer   Identity Type: Self Signed Root   Certificate Type: Code Signing
#   3. Click Create, then Done.
# From then on every build is signed with that certificate, so macOS remembers
# what you allowed instead of asking again after each rebuild.
cd "$(dirname "$0")" || exit 1
IDENTITY="Hangtime Developer"

if ! xcrun --find swiftc >/dev/null 2>&1; then
    echo "Apple's developer tools are not installed yet."
    echo "A window will open to install them. When it finishes, double-click build.command again."
    xcode-select --install
    exit 1
fi

# The finished app is installed in your personal Applications folder.
mkdir -p "$HOME/Applications"
APP="$HOME/Applications/Hangtime.app"
BUILD="$(mktemp -d)"
mkdir -p "$BUILD/Hangtime.app/Contents/MacOS" "$BUILD/Hangtime.app/Contents/Resources"
cp Info.plist "$BUILD/Hangtime.app/Contents/Info.plist"

# App icon (made from icon.png)
if [ -f icon.png ]; then
    ICONSET="$BUILD/AppIcon.iconset"
    mkdir -p "$ICONSET"
    for size in 16 32 128 256 512; do
        sips -z $size $size icon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null 2>&1
        double=$((size * 2))
        sips -z $double $double icon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null 2>&1
    done
    iconutil -c icns "$ICONSET" -o "$BUILD/Hangtime.app/Contents/Resources/AppIcon.icns" 2>/dev/null
fi

echo "Building Hangtime..."
xcrun swiftc -O -swift-version 5 \
    -target "$(uname -m)-apple-macos13.0" \
    Sources/*.swift \
    -o "$BUILD/Hangtime.app/Contents/MacOS/Hangtime" 2>&1 | grep -v "warning:" | tee build.log

if [ ! -f "$BUILD/Hangtime.app/Contents/MacOS/Hangtime" ]; then
    echo
    echo "Build failed. The errors are saved in build.log in this folder."
    exit 1
fi

pkill -x Hangtime 2>/dev/null
pkill -x Deckhand 2>/dev/null        # earlier names of this app
pkill -x MyDock 2>/dev/null
sleep 0.5
rm -rf "$APP" "./Hangtime.app" "$HOME/Applications/MyDock.app" "$HOME/Applications/Deckhand.app"
mv "$BUILD/Hangtime.app" "$APP"
if security find-identity -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
    codesign --force --sign "$IDENTITY" "$APP" >/dev/null 2>&1 && echo "Signed with \"$IDENTITY\"."
else
    codesign --force --sign - "$APP" >/dev/null 2>&1
    echo "Note: no \"$IDENTITY\" certificate yet, so macOS may ask for permissions again after"
    echo "each build. The steps to create it are at the top of build.command."
fi
touch "$APP"

open "$APP"
echo
echo "Hangtime is running. You can close this window."
