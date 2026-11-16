#!/bin/zsh
# Renders Murmur's screens with sample data to PNGs: Tools/RenderScreens.sh [OUTPUT_DIR]
set -euo pipefail
PROJECT_DIR=${0:A:h:h}
cd "$PROJECT_DIR"
OUTPUT=${1:-$PROJECT_DIR/.build/screens}
mkdir -p .build
clang -fobjc-arc -target arm64-apple-macos26.0 -c Sources/AudioTapBridge.m -o .build/AudioTapBridge.o
sources=(${(f)"$(ls Sources/*.swift | grep -v MurmurApp.swift)"})
swiftc -swift-version 5 -parse-as-library -target arm64-apple-macos26.0 -import-objc-header Sources/AudioTapBridge.h \
  $sources Tools/RenderScreens.swift .build/AudioTapBridge.o -o .build/render-screens
.build/render-screens "$OUTPUT"
