# Security and privacy

Murmur handles what you say and type, so privacy problems are treated as security bugs. Examples: audio or text leaving the Mac, transcripts readable by other users, text typed into the wrong app, or secure text fields being read.

**Please report these privately** through [GitHub's private vulnerability reporting](https://github.com/lhz56/murmur/security/advisories/new), not in a public issue. Include steps to reproduce and the macOS version. You'll get a reply as soon as possible, and credit in the fix if you'd like.

## What Murmur accesses

| Data | When | Where it goes |
|---|---|---|
| Microphone audio | Only while recording | Saved in `~/Library/Application Support/Murmur` (optional, with retention settings) and transcribed on this Mac |
| Text in the focused window | While recording, if "Learn words from your screen" is on | Used in memory to pick names and unusual words; the chosen words are listed on the transcript |
| Your project's file names and README | While recording in a code editor or terminal, same setting | Used in memory; protected folders (Documents, Desktop, Downloads) are never read |
| Contacts names | Only if you turn on "Names from Contacts" | Used in memory |
| The text box you dictate into | During insertion, and for 30 seconds after if "Learn from your fixes" is on | Small word fixes are saved to your vocabulary |

Secure text fields and Secure Keyboard Entry are never read. Murmur makes network requests only to download speech models on first use and, if you turn it on, to check GitHub for a newer release.
