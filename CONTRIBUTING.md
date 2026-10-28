# Contributing to Murmur

Thanks for helping. Murmur is a small, native Mac app with one rule above the rest: **your voice and text stay on your Mac.** Contributions that send audio, text, or usage data to a server won't be merged.

## Getting set up

You need an Apple silicon Mac on macOS 26 or later and Apple's Command Line Tools (`xcode-select --install`). There is no Xcode project.

```sh
git clone https://github.com/lhz56/murmur.git && cd murmur
./install.sh        # builds the Parakeet helper once, builds Murmur, installs and opens it
./test.sh           # runs every test suite
```

During development, `./build.sh` rebuilds `Murmur.app` in place (quit Murmur first), and `open Murmur.app` runs it.

## Where things live

| Area | Files |
|---|---|
| App lifecycle, menus, hotkeys | `Sources/MurmurApp.swift` |
| Recording flow, cleanup pipeline, library state | `Sources/AppModel.swift` |
| Microphone capture and Apple's live preview | `Sources/DictationEngine.swift`, `Sources/Microphones.swift` |
| Parakeet and Whisper engines | `Sources/LocalRecognition.swift`, `LocalSpeech/` (helper process) |
| Inserting text into other apps | `Sources/TextInsertion.swift` |
| Key and mouse shortcuts | `Sources/FnShortcut.swift` |
| Text cleanup rules | `Sources/Models.swift` (`TextTools`), `Sources/TextPolish.swift` |
| Screen, project, and contact words | `Sources/ContextVocabulary.swift` |
| Apple Intelligence features | `Sources/LocalModel.swift` |
| Interface | `Sources/LibraryView.swift`, `Sources/SettingsView.swift`, `Sources/OnboardingView.swift`, `Sources/RecorderHUD.swift`, `Sources/StatsView.swift`, `Sources/Theme.swift` |

## Guidelines

- **Keep it local and light.** Prefer rules over models, and the Neural Engine over the GPU. Murmur should use almost no CPU while idle.
- **Never surprise the user.** Anything that reads more of their Mac (screen text, Contacts, files) must be explainable in one sentence in Settings, and optional when it goes beyond the app being dictated into.
- **Add a test** for logic you change. Pure functions (text rules, matching, stats) are easy to cover; see `Tests/`. New test files are added to `test.sh`.
- **Match the code around you.** Small, well-named functions, comments that explain *why*, and no new dependencies without discussion.
- Run `./test.sh` before opening a pull request. CI runs the same script on macOS 26.

## Reporting bugs

Open an issue with what you said, what Murmur typed, and what you expected. The **Processing** row on a transcript ("What Murmur did") usually shows where things went wrong; include it. Please remove anything private first.

For security or privacy issues, see [SECURITY.md](SECURITY.md).
