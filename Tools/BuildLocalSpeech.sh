#!/bin/zsh
set -euo pipefail
PROJECT_DIR=${0:A:h:h}
RUNTIME_DIR="$PROJECT_DIR/.build/local-speech"
mkdir -p "$RUNTIME_DIR" "$PROJECT_DIR/Resources/Helpers" "$PROJECT_DIR/Resources/Models"
/usr/bin/swift build --package-path "$PROJECT_DIR/LocalSpeech" -c release --jobs 4
cp "$PROJECT_DIR/LocalSpeech/.build/release/MurmurParakeet" "$PROJECT_DIR/Resources/Helpers/"
for bundle in "$PROJECT_DIR"/LocalSpeech/.build/release/*.bundle; do
  ditto "$bundle" "$PROJECT_DIR/Resources/Helpers/${bundle:t}"
done
# --parakeet-only skips whisper.cpp and its ~550 MB model. Parakeet is the
# recommended engine: it runs on the Neural Engine and stays cool.
if [[ "${1:-}" == "--parakeet-only" ]]; then
  print "Parakeet helper is ready. Run ./build.sh to package Murmur."
  exit 0
fi
if [[ ! -d "$RUNTIME_DIR/whisper.cpp" ]]; then
  git clone --depth 1 --branch v1.8.7 https://github.com/ggml-org/whisper.cpp.git "$RUNTIME_DIR/whisper.cpp"
fi
cmake -S "$RUNTIME_DIR/whisper.cpp" -B "$RUNTIME_DIR/whisper.cpp/build" -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DWHISPER_BUILD_TESTS=OFF
cmake --build "$RUNTIME_DIR/whisper.cpp/build" --target whisper-cli -j 4
cp "$RUNTIME_DIR/whisper.cpp/build/bin/whisper-cli" "$PROJECT_DIR/Resources/Helpers/"
sh "$RUNTIME_DIR/whisper.cpp/models/download-ggml-model.sh" large-v3-turbo-q5_0 "$PROJECT_DIR/Resources/Models"
print "Local speech helpers are ready. Run ./build.sh to package Murmur."
