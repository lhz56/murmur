#!/bin/zsh
# Runs real Space + ↓ requests through Murmur and shows what happened at each step.
# Run with the screen unlocked. Testing only: starts Murmur with --debug-requests,
# then restarts it normally at the end.
set -u
cd "$(dirname "$0")/.."
swiftc -O Tools/AskMurmur.swift -o .build/ask-murmur 2>/dev/null
osascript -e 'quit app "Murmur"' 2>/dev/null; sleep 1
open Murmur.app --args --debug-requests; sleep 3
run() { : > /tmp/murmur-requests.log; ./.build/ask-murmur "$@"; sleep ${WAIT:-9}; sed '/^$/d' /tmp/murmur-requests.log; echo; }
run "open chrome, open a new tab and go to github"
run "open system settings and go to bluetooth"
run "open finder and click downloads"
run "open textedit and type hello from murmur"
run "Um, open Chrome, open Instagram and search for Messi's profile please"
run --survey "T3 Code (Beta)"
run --survey "Google Chrome"
osascript -e 'quit app "Murmur"'; sleep 1; open Murmur.app
