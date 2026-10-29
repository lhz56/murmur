<p align="center">
  <img src="docs/icon.png" width="128" height="128" alt="Murmur icon">
</p>

<h1 align="center">Murmur</h1>

<p align="center">
  <b>Talk, and it types.</b> Private, on-device dictation for the Mac.<br>
  Free and open source. No account, no subscription, no cloud.
</p>

<p align="center">
  <a href="https://github.com/lhz56/murmur/actions/workflows/tests.yml"><img src="https://github.com/lhz56/murmur/actions/workflows/tests.yml/badge.svg" alt="Tests"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="MIT License"></a>
  <img src="https://img.shields.io/badge/macOS-26%2B-black.svg" alt="macOS 26+">
  <img src="https://img.shields.io/badge/Apple%20silicon-required-black.svg" alt="Apple silicon">
</p>

<p align="center">
  <img src="docs/demo.gif" width="720" alt="Holding Control in a note, saying a sentence, and Murmur typing it with Recallr and Nkechi spelled correctly">
</p>

---

Murmur lets you type with your voice, in any app on your Mac. Hold down the **Control** key, say what you want to write, and let go. Your words show up where you were typing, cleaned up and spelled right.

It's free, and everything happens on your own computer. Nothing you say is sent anywhere.

## Why I built this

I love dictating instead of typing, but the good dictation apps, like Wispr Flow, cost a monthly subscription and send your voice to their servers. Macs today are fast enough to do all of that themselves, so I built Murmur: the same idea, free forever, open source, and private by design.

## What it does

**🎙️ Talk anywhere, it types for you.** Email, Slack, Notes, your code editor, a browser. If you can type there, you can talk there. You see your words appear while you speak.

**🔒 Private.** Your voice never leaves your Mac. No account, no sign-up, no internet needed once it's set up.

**🧠 Knows your words.** Murmur looks at what's on your screen and the project you're working on, so names and made-up words come out right. Say "recaller" and it writes **Recallr** if that's what's on your screen. It can also learn names from your Contacts.

**✍️ Learns from your fixes.** If Murmur gets a word wrong and you fix it, it remembers for next time.

**🧹 Cleans up as you go.**
- Takes out "um" and "uh."
- Say "scratch that" to delete what you just said.
- Say "new line" or "new paragraph" to start one.
- "lin at gmail dot com" becomes lin@gmail.com, and "one… two… three…" becomes a numbered list.
- Fits the app: casual in chats, no stray periods in the terminal.

**⚡ Shortcuts for things you type a lot.** Say "insert my email" and it types your email address. You set these up yourself.

**✨ Extra smarts with Apple Intelligence** (optional, also on your Mac)
- Fixes your mid-sentence changes: "Tuesday, no wait, Wednesday" becomes "Wednesday."
- Rewrite selected text by voice: select a paragraph and say "make this shorter."
- Ask questions about everything you've dictated before.

**📚 Remembers everything you've said.** Every dictation is saved in a searchable library on your Mac, so you can find, copy, or fix anything later. You can also see how many words you've spoken and how much time you've saved compared to typing.

**🎧 Small touches.** It turns your music down while you talk, can start when your Mac starts, and works in light and dark mode.

## Install

You need a Mac with Apple silicon (M1 or newer) running macOS 26. Open the Terminal app and paste:

```sh
xcode-select --install
git clone https://github.com/lhz56/murmur.git && cd murmur && ./install.sh
```

The first line installs Apple's free developer tools (skip it if you already have them). The second downloads Murmur, builds it, and puts it in your Applications folder. A short welcome guide then walks you through the two permissions it needs (microphone and Accessibility, so it can type for you) and trying your first dictation. To update later, run `git pull && ./install.sh` in the same folder.

## How to use it

| To do this | Press |
|---|---|
| Talk and type (hold, talk, let go) | **Control** (you can pick a different key or a mouse button) |
| Talk without holding a key | **⌃ ⌥ Space** to start, again to finish |
| Cancel | **Esc** |
| Paste what you last said again | **⌃ ⌥ V** |
| Type what you last said (for apps that block pasting) | **⌃ ⌥ T** |
| Rewrite selected text by voice | **⌃ ⌥ E** |

A quick tap of Control does nothing, so your usual keyboard shortcuts still work.

## Privacy

Everything Murmur hears, writes, and saves stays on your Mac, in `~/Library/Application Support/Murmur/`. It only goes online to download the speech model the first time, and, if you turn it on, to check for a new version. There's no tracking of any kind. [SECURITY.md](SECURITY.md) lists exactly what Murmur reads and when.

## For developers

Murmur runs NVIDIA's Parakeet speech model on the Mac's Neural Engine, so it's fast and stays cool, with Apple's built-in recognizer for the live preview. A second small model listens for your on-screen words and swaps them in only when the audio supports it.

### Build from source

```sh
./Tools/BuildLocalSpeech.sh --parakeet-only   # once: the Parakeet helper (omit the flag to also build Whisper)
./build.sh                                    # build and locally sign Murmur.app (quit Murmur first)
./test.sh                                     # run the test suites
```

There's no Xcode project; Murmur compiles straight from `Sources/` with `swiftc`. See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for how recording, insertion, storage, and recovery work, and [CONTRIBUTING.md](CONTRIBUTING.md) to get involved.

`Tools/Release.sh 1.1` packages a release zip. Builds are signed locally, not notarized, so on another Mac the first launch needs right-click → **Open**.

## Credits

Murmur stands on [FluidAudio](https://github.com/FluidInference/FluidAudio) (Apache 2.0) and NVIDIA's [Parakeet](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) models (CC BY 4.0, Core ML conversions by FluidInference), with optional [whisper.cpp](https://github.com/ggml-org/whisper.cpp) and OpenAI Whisper (MIT). Full notices are in [Resources/THIRD-PARTY.txt](Resources/THIRD-PARTY.txt).

## License

[MIT](LICENSE) © 2026 Lin Zaw
