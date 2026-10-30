# Security and privacy

Murmur handles what you say and type, so privacy problems are treated as security bugs. Examples: audio or text leaving the Mac, transcripts readable by other users, text typed into the wrong app, or secure text fields being read.

**Please report these privately** through [GitHub's private vulnerability reporting](https://github.com/lhz56/murmur/security/advisories/new), not in a public issue. Include steps to reproduce and the macOS version. You'll get a reply as soon as possible, and credit in the fix if you'd like.

## What Murmur accesses

| Data | When | Where it goes |
|---|---|---|
| Microphone audio | Only while recording | Saved in `~/Library/Application Support/Murmur` (optional, with retention settings) and transcribed on this Mac |
| Text in the focused window | While recording, if "Learn words from your screen" is on | Used in memory to pick names and unusual words; the chosen words are listed on the transcript, and counted in `lexicon.json` (words only, never the surrounding text) so Murmur remembers the ones you use. Settings → Vocabulary shows them, and you can remove any |
| Your project's file names and README | While recording in a code editor or terminal, same setting | Used in memory; protected folders (Documents, Desktop, Downloads) are never read |
| Contacts names | Only if you turn on "Names from Contacts" | Used in memory |
| Meeting audio: your microphone and what your Mac plays | Only while a meeting is being recorded, which you start (or confirm when Murmur spots a call) | Cut into short pieces, transcribed on this Mac, and each piece deleted right after. Only the transcript and notes are kept, in `meetings.json` |
| Which apps are using a microphone | Every few seconds, unless "When a call starts" is set to "Don't detect calls" | Checked in memory to offer meeting notes; nothing is stored |
| Window titles of a browser using the microphone | When a browser is using the mic | Read in memory to tell a Meet or Zoom call from other uses |
| Calendar events | Only if you connect your calendar | Titles, times, attendee names and call links of today's events, used in memory |
| Selected text or a copied link | When you open Commands (Space + Down Arrow) | Used only if you say "this", e.g. "play this" |
| Site names and visit counts from browser history (Chrome, Arc, Brave, Edge; Safari only with Full Disk Access) | When Commands builds its list of your sites, at most every 30 minutes; can be turned off on the Commands page | To open your own site for a name ("workloom" → workloom.live). Pages, titles and searches aren't read; nothing leaves your Mac |
| Website names mentioned in your project folders (docs, config, code; never `.env` files or dependencies) | Same as above | Same as above |
| Reminders (add only) | When you ask Commands to add a reminder | Saves the reminder you asked for; nothing is read or sent |
| Calendar (add) | When you ask Commands to put something on your calendar | Saves the event you asked for |
| Notes, via Automation | When you ask Commands to make a note | Creates the note you asked for |
| An app's message box | When you ask Commands to type into an app | Found through Accessibility and focused; your words are pasted in. Murmur never presses Send or Return |
| Chrome's launch arguments | When opening a link while Chrome is running | Checked in memory only for `--headless`, so links open in a window you can see; never stored |
| Meeting transcripts and notes sent to a language model | When notes are written or you ask about a meeting | Ollama on this Mac (`127.0.0.1`), or Apple Intelligence on device. Never a cloud service |
| The text box you dictate into | During insertion, and for 30 seconds after if "Learn from your fixes" is on | Small word fixes are saved to your vocabulary |

Secure text fields and Secure Keyboard Entry are never read. Murmur makes network requests only to download speech models on first use, if you turn it on to check GitHub for a newer release, and when you ask Commands to play something: the song or video name (nothing else) is looked up on youtube.com, or on search.brave.com to find a Spotify track. Searches and websites you ask for open in your browser as usual.
