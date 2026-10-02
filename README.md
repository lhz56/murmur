# Murmur

A native Mac dictation app with local transcription, a searchable recording library, and automatic insertion into the text box you are using. No subscription, account, API key, analytics, or cloud transcription.

## Features

- Hold **Control** to talk; release to stop. A quick tap starts hands-free recording, and another tap finishes it.
- A floating recording pill with voice animation and start/stop chimes.
- Automatic clipboard copying and insertion into the original focused text box.
- Saved transcripts and audio, search, favorites, editing, export, trash, and interrupted-recording recovery.
- Local Parakeet, Apple, and Whisper speech engines, with vocabulary corrections.
- Microphone selection and input testing, shortcut testing, and a no-audio insertion check.

## Requirements

- An **Apple silicon Mac running macOS 26 or later**.
- Apple Command Line Tools with the macOS 26 SDK and Swift 6 for building.
- Git and CMake to build the optional local speech helpers.
- Internet access for initial dependency and model downloads. Recording and transcription run locally afterward.

## Build

Clone this repository, then run:

```sh
git clone https://github.com/lhz56/murmur.git
cd murmur

# Build Parakeet and Whisper helpers and download the Whisper model.
./Tools/BuildLocalSpeech.sh

# Compile and sign the native app. Quit an existing Murmur process first.
./build.sh
open Murmur.app
```

There is no Xcode project. The app compiles directly from `Sources/` using SwiftUI, AppKit, AVAudioEngine, and Apple's SpeechAnalyzer / SpeechTranscriber APIs. `LocalSpeech/Package.resolved` pins the Parakeet helper's Swift dependencies. Model files, speech helper binaries, app bundles, and build caches are excluded from Git.

For an Apple-only build, skip `Tools/BuildLocalSpeech.sh`, run `./build.sh`, and choose **Apple** in Settings. For Parakeet, use **Download model** in Settings once on a new Mac. Whisper uses the model downloaded by `Tools/BuildLocalSpeech.sh`.

`Tools/SignApp.sh` creates or reuses a private local signing certificate in the login Keychain. macOS may ask you to approve codesign access when building. Reusing the same certificate gives future builds a consistent app identity. The private key stays on your Mac and is not part of this repository. This is local signing, not Developer ID distribution or notarization. `build.sh` builds and verifies a staged app before replacing an existing bundle and refuses to modify a running Murmur app.

## Use

1. Open **Murmur.app** and allow microphone access when macOS asks.
2. In Settings, select your microphone and speech engine. Allow the model to prepare; its first initialization can take longer than later launches.
3. Enable Murmur in **System Settings → Privacy & Security → Accessibility** for automatic insertion and the Fn event tap.
4. Click a text box, hold **Control**, and speak after the start chime. Release to stop capture. Keep the text box focused while transcription finishes.
5. Murmur saves the recording and transcript, copies the finished text, and pastes it into the original text box. If focus changes or insertion cannot be confirmed, the text remains available in the library and clipboard.

A quick Control tap starts hands-free recording. Tap again to finish, or use **Control + Option + Space**. Settings also offers a toggle key mode and **Fn / Globe** shortcuts. Fn must send a standard Mac Fn event; keys handled entirely inside keyboard firmware cannot trigger Murmur. **Test key** checks the physical signal without recording.

**Test microphone** displays the input level without saving audio. **Test insertion** gives you eight seconds to focus a text box, then inserts a test sentence without recording. Closing the library leaves Murmur in the menu bar; **Command + Q** quits.

The floating pill does not take keyboard focus. Capture stops synchronously on key release; final transcription still takes processing time. Very short or uncertain results with weak audio are saved for review rather than automatically inserted. Vocabulary corrections apply explicitly configured replacements; Murmur does not use a language model to rewrite your meaning.

## Storage and privacy

Your library stays in `~/Library/Application Support/Murmur/`:

```text
history.json             Transcripts and metadata
history.backup.json      Last successful history snapshot
Recordings/              Original audio files
```

History writes are atomic and checkpointed during recording. Interrupted sessions keep recoverable audio. Retention settings can remove audio after successful transcription; existing and unfinished recordings remain available.

Automatic insertion uses the clipboard and Accessibility permission. Murmur captures the editable element at recording start, waits for shortcut modifiers to release, checks focus and clipboard contents, then sends Paste without Enter. Recordings are not uploaded. Initial model downloads come from Apple's system service or public model repositories.

## Verification

Run the storage, text processing, Control/Fn shortcut, selection replacement, and recording-state checks:

```sh
./test.sh
```

Additional tests under `Tests/` exercise local audio-file recognition, buffered capture, saved-audio recovery, local workers, and latency using speech fixtures. These require the corresponding helpers, models, and system permissions.

Native checks on the development Mac verified microphone input, automatic insertion into an AppKit text field, replacement of selected text, clipboard matching, and retained Microphone/Accessibility permissions after a full quit and relaunch. `Benchmarks/latency-results.json` records limited local measurements, including model preparation and repeated start/stop cycles. Those measurements do not guarantee accuracy, timing, or insertion compatibility across every Mac or destination app. Personal recordings and their recognition comparisons are excluded from this repository.

## Third-party components

The Parakeet helper uses **FluidAudio 0.12.6**. Whisper uses **whisper.cpp 1.8.7** and **large-v3-turbo Q5_0**. Attribution and dependency license texts are in [Resources/THIRD-PARTY.txt](Resources/THIRD-PARTY.txt) and `Resources/ThirdPartyLicenses/`.
