#!/bin/sh
# check-engine-resources.sh -- a pre-build check, run by the app target.
#
# The engine's baked constants, film profiles and Metal library are produced by
# `engine/build.sh bundle` and ride into the app in the Resources folder
# reference. Baking them needs Python, so this does not build them: making an
# Xcode build depend on a virtualenv would put back exactly the thing RFC-014
# exists to remove. It only says what to run.
set -eu
root=${SRCROOT:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}
res="$root/Spektrafilm/Resources/engine"

missing=""
for f in spektrafilm_constants.bin spektrafilm.metallib neutral_print_filters.json; do
  [ -f "$res/$f" ] || missing="$missing $f"
done
[ -d "$res/profiles" ] || missing="$missing profiles/"

if [ -n "$missing" ]; then
  echo "error: the engine's resources are incomplete under $res" >&2
  echo "error: missing:$missing" >&2
  echo "error: run \`engine/build.sh bundle\` (and, if engine/resources itself is" >&2
  echo "error: absent, \`PYTHONPATH=src .venv/bin/python engine/tools/bake_resources.py\` first)" >&2
  exit 1
fi
