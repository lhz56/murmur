<p align="center">
  <img src="docs/icon.png" width="128" height="128" alt="Murmur icon">
</p>

<h1 align="center">Murmur</h1>

<p align="center">
  <b>Talk, and it types.</b> Private, on-device dictation, meeting notes and voice commands for the Mac.<br>
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

**🧠 Knows your words.** Murmur notices the names and made-up words on your screen and in the project you're working on, and remembers the ones you keep running into. After a while it just knows them, even when they aren't on screen: say "recaller" and it writes **Recallr**. Ordinary words you say clearly are never swapped out. It can also learn names from your Contacts.

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

**📝 Notes for every meeting.** When a call starts in Zoom, Google Meet, Teams, Slack, FaceTime, Discord or anywhere else, Murmur asks if you'd like notes. It listens to both sides (you through the microphone, everyone else through your Mac's sound), shows the words as people talk, and when the call ends the notes start appearing within seconds: a summary, the topics, decisions, and action items with who's doing what by when. Jot your own notes while you listen and Murmur builds on them; the agenda from your calendar invite helps too. During the call, ask "catch me up" or "what should I ask?"; afterwards, "what did I promise?" or "write a follow-up email." Long meetings are summarized as they go, so the notes don't take longer at the end. You get a notification when they're ready. No bot joins your call, and nothing leaves your Mac. Connect your calendar and meetings get their real names, and a minute before a call you get a "Join & take notes" button.

**⌘ Commands: just say what you want.** Press **Space + Down Arrow** together and type, or hold them and talk: "open Spotify and play Drake", "open murmur in Cursor", "play lofi on YouTube", "search Amazon for desk lamps", "timer 25 minutes", "volume 30", "lock screen", "take meeting notes". It opens apps, websites, files and folders, plays the actual song or video (not just a search page), runs your Shortcuts, and controls your Mac. Select a song name and say "play this." It can also type for you in other apps: "tell Claude to fix the login bug" or "open Slack and write on my way" puts your exact words in the message box, but never presses Send. Simple commands run the moment you let go. Murmur learns from you: pick a different result once and it comes first next time, and typing the start of something you've run before offers it again. **⌘1–⌘9** runs any row. It knows your own sites: "open WorkLoom" goes to your WorkLoom, found in your browser history and project folders, and if it isn't sure it asks once and remembers. Make your own: "work mode" can open everything you need at once.

**📚 Remembers everything you've said.** Every dictation is saved in a searchable library on your Mac, so you can find, copy, or fix anything later. You can also see how many words you've spoken and how much time you've saved compared to typing.

**🎧 Small touches.** It turns your music down while you talk, can start when your Mac starts, and works in light and dark mode.

## Install

You need a Mac with Apple silicon (M1 or newer) running macOS 26. Open the Terminal app and paste:

```sh
xcode-select --install
git clone https://github.com/lhz56/murmur.git && cd murmur && ./install.sh
```

The first line installs Apple's free developer tools (skip it if you already have them). The second downloads Murmur, builds it, and puts it in your Applications folder. A short welcome guide then walks you through the two permissions it needs (microphone and Accessibility, so it can type for you), downloads the free models with one click, and has you try dictation and Commands. To update later, run `git pull && ./install.sh` in the same folder.

## How to use it

| To do this | Press |
|---|---|
| Talk and type (hold, talk, let go) | **Control** (you can pick a different key or a mouse button) |
| Talk without holding a key | **⌃ ⌥ Space** to start, again to finish |
| Cancel | **Esc** |
| Paste what you last said again | **⌃ ⌥ V** |
| Type what you last said (for apps that block pasting) | **⌃ ⌥ T** |
| Rewrite selected text by voice | **⌃ ⌥ E** |
| Commands: type, or hold and talk | **Space + ↓** |
| Meeting notes | Click **Take notes** when Murmur spots a call, or **Take meeting notes** in the sidebar |

A quick tap of Control does nothing, so your usual keyboard shortcuts still work.

## Meeting notes use a free AI model on your Mac

The best notes come from [Ollama](https://ollama.com), a free app that runs AI models on your Mac. Install it, run `ollama pull qwen3:8b` once, and Murmur uses it automatically (on Macs with 32 GB or more it prefers bigger models when you have them). Without Ollama, Murmur uses Apple Intelligence if it's on, and otherwise writes simpler notes on its own. It never uses a paid service.

For Commands, a tiny model is enough: `ollama pull qwen3:1.7b` (1.4 GB) lets Murmur understand loose requests like "put on something chill" in about a fifth of a second. Murmur loads models only when needed and lets them go within a minute, so they don't sit in memory or warm up your Mac.

## Privacy

Everything Murmur hears, writes, and saves stays on your Mac, in `~/Library/Application Support/Murmur/`. Meeting audio is transcribed as it goes and never saved. Murmur only goes online to download the speech model the first time, if you turn it on to check for a new version, and when you ask Commands to play something: then just the song or video name is looked up on YouTube or Brave Search, the same as if you'd searched it yourself. There's no tracking of any kind. [SECURITY.md](SECURITY.md) lists exactly what Murmur reads and when.

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
