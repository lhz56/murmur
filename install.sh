#!/bin/zsh
# One command to build Murmur and install it in Applications:
#   ./install.sh            build the speech and voice helpers if missing, build, install, open
#   ./install.sh --rebuild  also rebuild the helpers (after updating dependencies)
# Run it again after `git pull` to update.
set -euo pipefail
PROJECT_DIR=${0:A:h}
cd "$PROJECT_DIR"

fail() { print -u2 "✗ $1"; exit 1; }
step() { print "\n→ $1"; }

[[ $(uname -m) == arm64 ]] || fail "Murmur needs an Apple silicon Mac."
[[ ${$(sw_vers -productVersion)%%.*} -ge 26 ]] || fail "Murmur needs macOS 26 or later."
command -v swiftc >/dev/null || fail "Install Apple's Command Line Tools first: xcode-select --install"

if [[ "${1:-}" == "--rebuild" || ! -x Resources/Helpers/MurmurParakeet || ! -x Resources/Helpers/MurmurVoice ]]; then
  step "Building the speech and voice helpers (first time takes a few minutes)"
  ./Tools/BuildLocalSpeech.sh --parakeet-only
fi

if pgrep -xq Murmur; then
  step "Quitting the running Murmur"
  osascript -e 'quit app "Murmur"' >/dev/null 2>&1 || true
  for _ in {1..50}; do pgrep -xq Murmur || break; sleep 0.1; done
  pgrep -xq Murmur && fail "Murmur is still running. Quit it from the menu bar and run this again."
fi

step "Building Murmur"
./build.sh

TARGET=/Applications
[[ -w $TARGET ]] || { TARGET="$HOME/Applications"; mkdir -p "$TARGET"; }
step "Installing to $TARGET"
ditto Murmur.app "$TARGET/Murmur.app"
open "$TARGET/Murmur.app"

print "\n✓ Murmur is installed and running."
print "  The welcome guide takes it from here: permissions, the free models, and a first try."
