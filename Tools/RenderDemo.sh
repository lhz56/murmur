#!/bin/zsh
# Renders docs/demo.gif from Murmur's real recording pill over a staged scene.
# Needs ffmpeg (brew install ffmpeg).
set -euo pipefail
PROJECT_DIR=${0:A:h:h}
cd "$PROJECT_DIR"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p .build
clang -fobjc-arc -target arm64-apple-macos26.0 -c Sources/AudioTapBridge.m -o .build/AudioTapBridge.o
sources=(${(f)"$(ls Sources/*.swift | grep -v MurmurApp.swift)"})
swiftc -O -swift-version 5 -parse-as-library -target arm64-apple-macos26.0 -import-objc-header Sources/AudioTapBridge.h \
  $sources Tools/RenderDemo.swift .build/AudioTapBridge.o -o "$WORK/render-demo"
"$WORK/render-demo" "$WORK/frames"
ffmpeg -loglevel error -y -framerate 15 -i "$WORK/frames/frame-%04d.png" \
  -vf "scale=720:-1:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff:max_colors=128[p];[b][p]paletteuse=dither=sierra2_4a:diff_mode=rectangle" \
  -loop 0 docs/demo.gif
print "Wrote docs/demo.gif ($(du -h docs/demo.gif | cut -f1))"
