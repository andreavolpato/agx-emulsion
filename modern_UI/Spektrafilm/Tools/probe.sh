#!/bin/sh
# Headless decode-path probe. Needs no Metal toolchain (no .metal is compiled).
cd "$(dirname "$0")/.."
xcrun swiftc -O \
  -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
  -target arm64-apple-macos15.0 -swift-version 6 \
  Spektrafilm/Canvas/ImageDecoder.swift Tools/main.swift \
  -o /tmp/DecodeProbe && /tmp/DecodeProbe "$@"
