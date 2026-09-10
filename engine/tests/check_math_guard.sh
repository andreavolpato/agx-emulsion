#!/bin/bash
# check_math_guard.sh -- prove the fast-math guard can fire.
#
# `spk_engine_create` refuses to start when the loaded metallib was compiled
# with fast math (RFC-014 §5.1 trap 1). A guard nobody has seen fail is a
# guard that may not be able to, so this builds a deliberately fast-math
# library and asserts the engine rejects it.
set -euo pipefail
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
engine=$(CDPATH= cd -- "$here/.." && pwd)
out="$engine/build/fastmath-check"
mkdir -p "$out"
trap 'rm -rf "$out"' EXIT

airs=()
for m in "$engine"/src/shaders/*.metal; do
  air="$out/$(basename "$m" .metal).air"
  xcrun -sdk macosx metal -fmetal-math-mode=fast -fmetal-math-fp32-functions=fast -c "$m" -o "$air"
  airs+=("$air")
done
xcrun -sdk macosx metallib "${airs[@]}" -o "$out/fastmath.metallib"

if "$engine/build/gpu_smoke" "$out/fastmath.metallib" > "$out/log" 2>&1; then
  echo "FAIL: gpu_smoke accepted a fast-math library"
  cat "$out/log"
  exit 1
fi
if ! grep -q "compiled with fast math" "$out/log"; then
  echo "FAIL: gpu_smoke rejected the fast-math library, but not for the expected reason:"
  cat "$out/log"
  exit 1
fi
echo "ok   the fast-math guard fires on a fast-math library"
echo "ok   and passes on the shipped one:"
"$engine/build/gpu_smoke" "$engine/resources/spektrafilm.metallib" | grep "math mode"
