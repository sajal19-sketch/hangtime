#!/bin/bash
# Double-click to (re)make the Hangtime Instagram reel: promo/Hangtime-reel.mp4
cd "$(dirname "$0")" || exit 1
xcrun swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos13.0" main.swift -o /tmp/hangtime-promo 2>&1 | grep -v "warning:"
/tmp/hangtime-promo "$PWD/Hangtime-reel.mp4" "$@" && open -R "$PWD/Hangtime-reel.mp4"
