#!/bin/sh
#  Tools/capture-live.sh — capture the REAL window, through the window server.
#
#      Tools/capture-live.sh [image.NEF] [out.png]
#
#  Why this exists, and why it is not the same thing as `snapshot.sh`:
#  `snapshot.sh` renders the interface through `cacheDisplay`, which cannot
#  see a `CAMetalLayer` at all — so it substitutes an offscreen render of the
#  canvas. That blind spot hid two real defects at once: a drawable pixel
#  format `CAMetalLayer` rejects (the app crashed on launch), and a redraw
#  that never reached the view (the canvas stayed blank while every number
#  behind it was right). This script launches the app for real, opens a frame,
#  waits for the print, and asks the window server for the pixels. It is the
#  only capture that proves the canvas draws.
#
#  Needs Screen Recording permission for the terminal. Set
#  SPEKTRAFILM_CANVAS_LOG=1 in the environment to also get a per-draw log.
set -e
cd "$(dirname "$0")/.."
APP="build/DerivedData/Build/Products/Debug/Spektrafilm.app"
IMG="$1"
OUT="${2:-$(cd .. && pwd)/design/snapshots/live-window.png}"
[ -x "$APP/Contents/MacOS/Spektrafilm" ] || xcodebuild -project Spektrafilm.xcodeproj -scheme Spektrafilm \
    -configuration Debug -derivedDataPath build/DerivedData build 2>&1 | grep -E "error:|BUILD"
BIN=/tmp/spektrafilm-live-window
[ -x "$BIN" ] || xcrun swiftc -O Tools/live-window.swift -o "$BIN"

# One instance, launched with the file in the same command. Launching with
# `open -n` and then sending the file with a second `open -a` starts a
# *second* copy of the app, and the capture then photographs whichever window
# the window server lists first — which is how a window showing the empty-strip
# placeholder was captured while another instance held the frame.
pkill -9 -f "MacOS/Spektrafilm" 2>/dev/null || true
sleep 1
if [ -n "$IMG" ]; then open -n "$APP" --args "$IMG"; else open -n "$APP"; fi

# Wait for a window, then for the render to settle.
for _ in $(seq 1 60); do
  ID=$("$BIN" 2>/dev/null | head -1 | cut -d' ' -f1) && [ -n "$ID" ] && break
  sleep 1
done
[ -n "$ID" ] || { echo "capture-live: no window appeared"; exit 1; }
[ -n "$IMG" ] && sleep 25 || sleep 2
screencapture -x -o -l"$ID" "$OUT"
pkill -9 -f "MacOS/Spektrafilm" 2>/dev/null || true
echo "live window $ID → $OUT"
