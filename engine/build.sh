#!/bin/bash
# build.sh -- the C++ render engine, its Metal library, and the test drivers.
#
#   engine/build.sh            everything
#   engine/build.sh lib        the static library + the metallib
#   engine/build.sh dylib      the shared library the ctypes parity harness loads
#   engine/build.sh tests      the setup/schema dump drivers
#   engine/build.sh metallib   just the kernels
#
# bash, and arrays throughout, because the repository path contains a space
# ("Summer 2026") and every unquoted expansion of a path list is a build that
# works on the author's other checkout and not on this one.
#
# Two flags below are load-bearing and must not be dropped (RFC-014 §5.1 trap 1):
#
#   -fmetal-math-mode=safe
#   -fmetal-math-fp32-functions=precise
#
# Metal's offline compiler defaults to fast math, and `MTLCompileOptions`
# defaults to `MathModeFast` (measured on Xcode 26.6: `mathMode` reads 2).
# MLX -- the reference the kernels were held to float32 epsilon against --
# compiles `MathModeSafe`. Under fast math `exp` and fma contraction drift by
# up to 1.1e-5, which is past the float32 bar and silent.
#
# Setting them here is necessary but not sufficient, because a build flag is
# exactly the kind of guard that stops being checked. `spk_math_probe` in
# `shaders/probe.metal` computes `a*b - a*b`, which is *zero* under fast math
# and the fma error term under safe math, and `spk_engine_create` asserts it.
set -euo pipefail

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
out="$here/build"
mkdir -p "$out"

CXX=${CXX:-clang++}
cxxflags=(-std=c++20 -O2 -Wall -Wextra)
includes=(-I"$here/include" -I"$here/src" -I"$here/src/core" -I"$here/third_party/metal-cpp")
frameworks=(-framework Metal -framework Foundation -framework QuartzCore)
math_flags=(-fmetal-math-mode=safe -fmetal-math-fp32-functions=precise)

sources=()
collect_sources() {
  sources=()
  local f
  # nullglob, so a directory that does not exist yet (src/gpu before the GPU
  # layer landed) contributes nothing rather than contributing the literal
  # pattern -- and so the `-f` test that would otherwise trip `set -e` on the
  # loop's last iteration is not needed at all.
  shopt -s nullglob
  for f in "$here"/src/core/*.cpp "$here"/src/gpu/*.cpp "$here"/src/pipeline/*.cpp; do
    sources+=("$f")
  done
  shopt -u nullglob
  if [[ ${#sources[@]} -eq 0 ]]; then
    echo "build.sh: no C++ sources found under $here/src" >&2
    exit 1
  fi
}

build_metallib() {
  local airs=() m air
  shopt -s nullglob
  for m in "$here"/src/shaders/*.metal; do
    air="$out/$(basename "$m" .metal).air"
    xcrun -sdk macosx metal "${math_flags[@]}" -Werror -c "$m" -o "$air"
    airs+=("$air")
  done
  shopt -u nullglob
  if [[ ${#airs[@]} -eq 0 ]]; then echo "no shaders yet"; return 0; fi
  xcrun -sdk macosx metallib "${airs[@]}" -o "$out/spektrafilm.metallib"
  cp "$out/spektrafilm.metallib" "$here/resources/spektrafilm.metallib"
  echo "metallib   -> $here/resources/spektrafilm.metallib"
}

objects=()
build_objects() {
  collect_sources
  objects=()
  local src obj
  for src in "${sources[@]}"; do
    obj="$out/$(basename "$src" .cpp).o"
    "$CXX" "${cxxflags[@]}" "${includes[@]}" -c "$src" -o "$obj"
    objects+=("$obj")
  done
}

build_lib() {
  build_objects
  ar rcs "$out/libspektrafilm_engine.a" "${objects[@]}"
  echo "static lib -> $out/libspektrafilm_engine.a"
}

build_dylib() {
  build_objects
  "$CXX" -dynamiclib -install_name @rpath/libspektrafilm_engine.dylib \
    "${objects[@]}" "${frameworks[@]}" -o "$out/libspektrafilm_engine.dylib"
  echo "dylib      -> $out/libspektrafilm_engine.dylib"
}

build_tests() {
  collect_sources
  local driver
  for driver in dump_setup dump_json gpu_smoke; do
    [[ -f "$here/tests/$driver.cpp" ]] || continue
    "$CXX" "${cxxflags[@]}" "${includes[@]}" -I"$here/tests" \
      "$here/tests/$driver.cpp" "${sources[@]}" "${frameworks[@]}" -o "$out/$driver"
    echo "driver     -> $out/$driver"
  done
}

case "${1:-all}" in
  metallib) build_metallib ;;
  lib)      build_metallib; build_lib ;;
  dylib)    build_metallib; build_dylib ;;
  tests)    build_tests ;;
  all)      build_metallib; build_lib; build_dylib; build_tests ;;
  *) echo "usage: build.sh [all|lib|dylib|tests|metallib]" >&2; exit 2 ;;
esac
