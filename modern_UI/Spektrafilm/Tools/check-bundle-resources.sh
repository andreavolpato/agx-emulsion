#!/bin/sh
# check-bundle-resources.sh -- a pre-build check, run by the app target.
#
# Two things must be in `Spektrafilm/Resources/` before a build is worth
# shipping, and both are produced by a script rather than by Xcode:
#
#   engine/    the baked constants, the film profiles, the print-preview LUT
#              index and the Metal library -- `engine/build.sh bundle`.
#              Baking them needs Python, so this does not build them: making
#              an Xcode build depend on a virtualenv would put back exactly
#              the thing RFC-014 exists to remove. It only says what to run.
#
#   Licenses/  the GPL-3.0, CC BY-SA 4.0 and Apache-2.0 texts the .app is
#              obliged to carry -- `Tools/bundle-licenses.sh`. This is
#              checked here rather than trusted because a bundle that ships
#              without them is not licensed to ship, and nothing else in a
#              build would notice (HANDOFF-DISTRIBUTION §2.3).
#
# The dangerous case for the engine resources is **stale**, not absent: the
# pre-build check cannot tell a re-baked constants file from an old one. Re-run
# `engine/build.sh bundle` after changing anything under `engine/resources`.
set -eu
root=${SRCROOT:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}
res="$root/Spektrafilm/Resources"

missing=""
for f in spektrafilm_constants.bin spektrafilm.metallib neutral_print_filters.json print_luts.json; do
  [ -f "$res/engine/$f" ] || missing="$missing engine/$f"
done
[ -d "$res/engine/profiles" ] || missing="$missing engine/profiles/"

if [ -n "$missing" ]; then
  echo "error: the engine's resources are incomplete under $res" >&2
  echo "error: missing:$missing" >&2
  echo "error: run \`engine/build.sh bundle\` (and, if engine/resources itself is" >&2
  echo "error: absent, \`PYTHONPATH=src .venv/bin/python engine/tools/bake_resources.py\` first)" >&2
  exit 1
fi

licences=""
for f in README.txt Spektrafilm-GPL-3.0.txt Profiles-and-LUTs-CC-BY-SA-4.0.txt \
         Profiles-and-LUTs-CHANGELOG.txt metal-cpp-Apache-2.0.txt; do
  [ -f "$res/Licenses/$f" ] || licences="$licences $f"
done

if [ -n "$licences" ]; then
  echo "error: the bundle is missing licence texts it is obliged to carry:$licences" >&2
  echo "error: run \`Tools/bundle-licenses.sh\`" >&2
  echo "error: (GPL-3.0 for the app and engine, CC BY-SA 4.0 for the profiles and the" >&2
  echo "error:  LUTs derived from them, Apache-2.0 for the vendored metal-cpp)" >&2
  exit 1
fi
