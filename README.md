# Murmur

A native Mac dictation app with local transcription, a searchable recording library, and automatic insertion into the text box you are using. No subscription, account, API key, analytics, or cloud transcription.

## Features

- Hold **Control** to talk; release to stop. Release during startup cancels immediately, and short taps are ignored in hold mode.
- A floating recording pill with a waveform that follows your voice, live words, and start/stop chimes.
- Automatic insertion into the original focused text box. With clipboard copying off, Murmur restores your previous clipboard after a confirmed insertion.
- **Control + Option + V** pastes your last transcript into any text box; the menu bar can also copy it.
- Saved transcripts and audio, search, favorites, editing, export, trash, and interrupted-recording recovery, with keyboard navigation and context menus.
- Light and dark appearance that follows macOS.
- Local Parakeet, Apple, and Whisper speech engines, with vocabulary corrections.
- Context-aware words: names and unusual words on screen in the app you're dictating into, plus words you've corrected before, bias recognition for that recording. Parakeet uses FluidAudio's CTC word spotter (a 110M-parameter model on the Neural Engine, downloaded once) and only swaps a word when the audio supports it. Nothing is stored or uploaded.
- Optional filler-word cleanup (um, uh, erm) for English, and automatic spacing when you dictate right after existing text.
- Open at login: Murmur starts quietly in the menu bar.
- Voice commands: say "new line" or "new paragraph" (English).
- Fix changes of mind: "scratch that" drops the last sentence; "no wait" / "I mean" are resolved by Apple's on-device model when Apple Intelligence is on.
- Smart formatting (spoken emails and domains, numbered lists), per-app style (no closing period in chats and terminals), and voice snippets ("insert my email").
- Edit selection by voice (Control-Option-E) and Ask your notes, using Apple's on-device model.
- Learns from your fixes: correct a misheard word right after Murmur types it and the fix is remembered. Optional names from Contacts and words from the project you're working in.
- Lowers other audio while you record, then fades it back.
- Dictation key: Control, Right Option, Right Command, or Fn.
- A first-run welcome guide for permissions and a live try-it step (Murmur menu → Welcome Guide).
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

# Build the Parakeet helper (recommended). Omit --parakeet-only to also
# build Whisper and download its ~550 MB model.
./Tools/BuildLocalSpeech.sh --parakeet-only

# Compile and sign the native app. Quit an existing Murmur process first.
./build.sh
open Murmur.app
```

There is no Xcode project. The app compiles directly from `Sources/` using SwiftUI, AppKit, AVAudioEngine, and Apple's SpeechAnalyzer / SpeechTranscriber APIs. `LocalSpeech/Package.resolved` pins the Parakeet helper's Swift dependencies. Model files, speech helper binaries, app bundles, and build caches are excluded from Git.

Parakeet is the recommended engine: it runs on the Neural Engine rather than the GPU, transcribes a typical dictation in about 0.1 seconds, and keeps a fanless or quiet Mac cool. Whisper runs on the GPU and is slower and warmer. If the selected engine's helper or model is missing, Murmur finishes with Apple's on-device result instead of failing.

While idle, Murmur receives Control presses as events once Accessibility is allowed, rather than polling the keyboard. It falls back to polling only without that permission or while Secure Keyboard Entry is on.

For an Apple-only build, skip `Tools/BuildLocalSpeech.sh`, run `./build.sh`, and choose **Apple** in Settings. For Parakeet, use **Download model** in Settings once on a new Mac. Whisper uses the model downloaded by `Tools/BuildLocalSpeech.sh`.

`Tools/SignApp.sh` creates or reuses a private local signing certificate in the login Keychain. macOS may ask you to approve codesign access when building. Reusing the same certificate gives future builds a consistent app identity. The private key stays on your Mac and is not part of this repository. This is local signing, not Developer ID distribution or notarization. `build.sh` builds and verifies a staged app before replacing an existing bundle and refuses to modify a running Murmur app.

## Use

1. Open **Murmur.app** and allow microphone access when macOS asks.
2. In Settings, select your microphone and speech engine. Allow the model to prepare; its first initialization can take longer than later launches.
3. Enable Murmur in **System Settings → Privacy & Security → Accessibility** for automatic insertion and the Fn event tap.
4. Click a text box, hold **Control**, and speak after the start chime. Release to stop capture. Keep the text box focused while transcription finishes.
5. Murmur saves the recording and transcript, copies the finished text, and pastes it into the original text box. If focus changes or insertion cannot be confirmed, the text remains available in the library and clipboard.

Choose **Press to toggle** in Settings for hands-free Control recording, or use **Control + Option + Space**. Settings also offers **Fn / Globe** shortcuts. Fn must send a standard Mac Fn event; keys handled entirely inside keyboard firmware cannot trigger Murmur. **Test key** checks the physical signal without recording.

In the library, use ↑/↓ to move between transcripts, ⌘C to copy the selected one, Delete to move it to Trash, and Esc to close it. Right-click a transcript for more actions.

**Test microphone** displays the input level without saving audio. **Test insertion** gives you eight seconds to focus a text box, then inserts a test sentence without recording. Closing the library leaves Murmur in the menu bar; **Command + Q** quits.

The floating pill does not take keyboard focus. Capture stops synchronously on key release; final transcription still takes processing time. Very short or uncertain results with weak audio are saved for review rather than automatically inserted. Vocabulary corrections apply explicitly configured replacements; Murmur does not use a language model to rewrite your meaning.

The recording cue follows the first copied microphone buffer, without waiting for disk writes or meter updates. Murmur prepares a stopped microphone graph ahead of use and reuses it after recording; it captures no audio while idle. Input taps use the microphone's current hardware format. A small Objective-C bridge converts native tap exceptions into recoverable errors because Swift cannot catch those exceptions directly.

Escape cancels startup as well as active recording. Disabling or restarting the shortcut hook finishes an active hold and waits for the physical key to be released before accepting another hold. Saved-audio retries reserve the recording immediately, so repeated clicks cannot start overlapping jobs or replace another recording's text. Restore a recording from Trash before retrying it.

Quitting stops capture, flushes unfinished audio, and cancels recognition instead of waiting for a model to finish. Local worker requests can be cancelled independently; late results cannot update a newer recording. Recognition has bounded waits: 30 seconds for Apple recording finalization, 180 seconds for audio-file jobs, and 120 seconds for a Parakeet recognition request. A timeout preserves the recording for another attempt. Losing an optional live preview does not stop the saved-audio capture used by Parakeet and Whisper.

In four installed-app EarPods tests, recording setup took 0.33–0.51 seconds from the app's start request to its cue, and microphone stops took 25–63 ms. These are local measurements, not guarantees; the Control gesture adds a 100-ms chord-detection delay. [Measurement scope and regression checks](Benchmarks/startup-results.json).

## Storage and privacy

Your library stays in `~/Library/Application Support/Murmur/`:

```text
history.json             Transcripts and metadata
history.backup.json      Last successful history snapshot
Recordings/              Original audio files
```

History writes are atomic and checkpointed during recording. Unchanged checkpoints are skipped, and the backup reuses the last verified snapshot instead of re-reading it from disk. A missing primary history file can recover from its backup. Interrupted sessions keep recoverable audio. With **Save audio** off, Murmur removes audio only after a nonempty transcription that does not need review; failed, empty, and uncertain recordings keep their audio. An unavailable storage folder or an unsupported history version produces a recoverable error and blocks library changes rather than crashing or overwriting the existing files.

Automatic insertion uses the clipboard and Accessibility permission. Murmur resolves focused editor children to their editable parent and captures the destination at recording start. It waits for shortcut modifiers to release, checks the foreground app, window, editor, and clipboard, then invokes the app's standard Paste menu command when available. Otherwise it sends one complete Command-V key sequence. Custom editors without a usable accessibility text node can receive Paste while their original focus or known window remains unchanged. Secure input, disabled controls, and clearly non-text controls are excluded. Murmur never presses Enter or retries an unconfirmed paste. Settings shows whether insertion was confirmed, Paste was sent without confirmation, or text was only copied. Recordings are not uploaded. Initial model downloads come from Apple's system service or public model repositories.

## Verification

Run the storage, text processing, Control/Fn shortcut, selection replacement, recording-state, worker cancellation, and recognition-deadline checks:

```sh
./test.sh
```

The standard suite also checks overlapping retries, audio retention, unavailable storage, quit during a queued retry, preview failure with continued capture, and worker timeout/crash recovery. Additional tests under `Tests/` exercise actual local audio-file recognition, buffered capture, saved-audio recovery, and latency using generated speech fixtures. These require the corresponding helpers, models, and system permissions.

`Tools/Compatibility/` contains local browser and AppKit editor fixtures for checking exact received text and duplicate paste events. These supplement real destination-app checks; they do not establish compatibility with every application.

The [October 4 audit](Benchmarks/audit-results.json) passed the standard suite and generated speech fixtures through Apple, Parakeet, and Whisper, preserving the fixture's first and last words. Installed-app checks verified real microphone capture, audio retention with **Save audio** off, quit/reopen recovery, native text-field insertion, replacement of selected Unicode text, and exactly one Paste call in a native multiline editor. Microphone and Accessibility permissions remained usable after the signed update and relaunch. Recording preferences were restored after these checks.

`Benchmarks/latency-results.json` records limited local measurements, including model preparation and repeated start/stop cycles. These checks do not guarantee accuracy, timing, absence of every bug, or insertion compatibility across every Mac or destination app. Personal recordings and their recognition comparisons are excluded from this repository.

## Third-party components

The Parakeet helper uses **FluidAudio 0.12.6**. Whisper uses **whisper.cpp 1.8.7** and **large-v3-turbo Q5_0**. Attribution and dependency license texts are in [Resources/THIRD-PARTY.txt](Resources/THIRD-PARTY.txt) and `Resources/ThirdPartyLicenses/`.
