# Insertion compatibility fixtures

These fixtures receive test text only. They never send a message, request audio access, or save a transcript.

Open `editors.html` in Chrome or Safari to exercise plain inputs, multiline textareas, contenteditable editors, nested rich text, and a custom paste handler. The page displays the exact received value and number of paste events. Reset between checks.

`NativeFixture.swift` provides an AppKit text field, a second field, and a multiline text view. Its visible status reports received values and multiline paste calls. Compile it into a local test application with Swift and an `Info.plist`; it is not bundled in Murmur.

Use the installed Murmur's **Settings → Test insertion**, then focus the intended field within eight seconds. Expect exactly `Murmur insertion test.` once. Repeat with selected existing text, a caret inside existing text, and a multiline or Unicode transcript when exercising the full dictation path.

For a focus-change check, start dictation in one field and move to the second before finishing. Murmur should keep the finished text in the clipboard without pasting into the new field. Switching apps or windows must behave the same way. Test insertion captures its destination after the eight-second countdown, so it does not itself exercise recording-time focus changes.

Fixtures verify editor classes; real application checks are still needed for Claude and other custom desktop apps. A passing fixture is not a promise that every third-party app accepts synthetic paste. Secure, disabled, and clearly non-text controls are deliberately excluded.
