#!/bin/zsh
set -euo pipefail
PROJECT_DIR=${0:A:h}
mkdir -p "$PROJECT_DIR/.build"
/usr/bin/swiftc -swift-version 5 "$PROJECT_DIR/Sources/Models.swift" "$PROJECT_DIR/Tests/StorageTests.swift" -o "$PROJECT_DIR/.build/storage-tests"
"$PROJECT_DIR/.build/storage-tests"
/usr/bin/swiftc -swift-version 5 "$PROJECT_DIR/Sources/FnShortcut.swift" "$PROJECT_DIR/Tests/FnTests.swift" -o "$PROJECT_DIR/.build/fn-tests"
"$PROJECT_DIR/.build/fn-tests"
/usr/bin/swiftc -swift-version 5 -parse-as-library -target arm64-apple-macos26.0 "$PROJECT_DIR/Sources/TextInsertion.swift" "$PROJECT_DIR/Tests/TextInsertionTests.swift" -o "$PROJECT_DIR/.build/insertion-tests"
"$PROJECT_DIR/.build/insertion-tests"
/usr/bin/swiftc -swift-version 5 -parse-as-library -target arm64-apple-macos26.0 "$PROJECT_DIR/Sources/Models.swift" "$PROJECT_DIR/Sources/FnShortcut.swift" "$PROJECT_DIR/Sources/KeyboardInfo.swift" "$PROJECT_DIR/Sources/Microphones.swift" "$PROJECT_DIR/Sources/LocalRecognition.swift" "$PROJECT_DIR/Sources/DictationEngine.swift" "$PROJECT_DIR/Sources/TextInsertion.swift" "$PROJECT_DIR/Sources/AppModel.swift" "$PROJECT_DIR/Tests/FnIntegrationTests.swift" -o "$PROJECT_DIR/.build/fn-integration-tests"
"$PROJECT_DIR/.build/fn-integration-tests"
