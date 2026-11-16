#!/bin/zsh
# Scores Commands on everyday spoken requests: Tools/CommandEval.sh [model]
set -euo pipefail
PROJECT_DIR=${0:A:h:h}
cd "$PROJECT_DIR"
mkdir -p .build
swiftc -swift-version 5 -parse-as-library -target arm64-apple-macos26.0 -module-name h \
  Sources/ContextVocabulary.swift Sources/Meetings.swift Sources/Models.swift Sources/CommandParser.swift Sources/CommandPlanner.swift \
  Sources/SiteBook.swift Sources/LocalLLM.swift Sources/LocalModel.swift Sources/TextPolish.swift Tools/CommandEval.swift -o .build/command-eval
.build/command-eval "${1:-qwen3:1.7b}"
