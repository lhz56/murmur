#!/bin/zsh
# Renders the Ask pointer frame by frame: Tools/RenderPointer.sh BACKDROP.png OUTPUT_DIR
set -euo pipefail
PROJECT_DIR=${0:A:h:h}
cd "$PROJECT_DIR"
BACKDROP=$1; OUTPUT=${2:-$PROJECT_DIR/.build/pointer}
mkdir -p .build
clang -fobjc-arc -target arm64-apple-macos26.0 -c Sources/AudioTapBridge.m -o .build/AudioTapBridge.o
sources=(${(f)"$(ls Sources/*.swift | grep -v MurmurApp.swift)"})
swiftc -swift-version 5 -parse-as-library -target arm64-apple-macos26.0 -import-objc-header Sources/AudioTapBridge.h \
  $sources Tools/RenderPointer.swift .build/AudioTapBridge.o -o .build/render-pointer
.build/render-pointer "$BACKDROP" "$OUTPUT"
