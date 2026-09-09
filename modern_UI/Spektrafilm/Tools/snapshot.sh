#!/bin/sh
#  Tools/snapshot.sh — capture the real app window at the three display
#  shapes that matter, optionally with an image open and rendered.
#
#      Tools/snapshot.sh                       # empty window, three sizes
#      Tools/snapshot.sh /path/to/image.NEF    # with that frame open (waits for the print)
#
#  Output: ../design/snapshots/window-<name>.png. The app is launched with
#  `--snapshot WxH out.png [--open file --wait s]`; see SpektrafilmApp.swift.
set -e
cd "$(dirname "$0")/.."
OUT="$(cd .. && pwd)/design/snapshots"
mkdir -p "$OUT"
APP="build/DerivedData/Build/Products/Debug/Spektrafilm.app/Contents/MacOS/Spektrafilm"
if [ ! -x "$APP" ]; then
  xcodebuild -project Spektrafilm.xcodeproj -scheme Spektrafilm -configuration Debug \
    -derivedDataPath build/DerivedData build 2>&1 | grep -E "error:|BUILD"
fi
IMG="$1"
for spec in "macbook-pro-14:1512x982" "16x9:1920x1080" "21x9:3360x1418"; do
  name="${spec%%:*}"; size="${spec##*:}"
  if [ -n "$IMG" ]; then
    "$APP" --snapshot "$size" "$OUT/window-$name.png" --open "$IMG" --wait 60 2>&1 | grep -v "^$" | tail -1
  else
    "$APP" --snapshot "$size" "$OUT/window-$name.png" --wait 1.5 2>&1 | tail -1
  fi
done
echo "→ $OUT"
