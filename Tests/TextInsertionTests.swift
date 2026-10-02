import Foundation

@main struct TextInsertionTests {
    @MainActor static func main() {
        func replacement(_ value: String, _ range: NSRange?, _ text: String) -> String? {
            TextInsertion.replacingSelection(in: value, range: range, with: text)
        }

        assert(replacement("", NSRange(location: 0, length: 0), "Hello.") == "Hello.")
        assert(replacement("Hello world", NSRange(location: 6, length: 5), "Murmur") == "Hello Murmur")
        assert(replacement("Before after", NSRange(location: 7, length: 0), "spoken ") == "Before spoken after")
        assert(replacement("End", NSRange(location: 3, length: 0), " 🎙️") == "End 🎙️")
        assert(replacement("Old sentence", NSRange(location: 0, length: 12), "New sentence.") == "New sentence.")

        // Accessibility offsets count UTF-16 code units, not Swift Characters.
        let emoji = "A😀B"
        assert((emoji as NSString).length == 4)
        assert(replacement(emoji, NSRange(location: 1, length: 2), "voice") == "AvoiceB")
        assert(replacement(emoji, NSRange(location: 3, length: 0), "!") == "A😀!B")
        assert(replacement(emoji, NSRange(location: 4, length: 0), " end") == "A😀B end")

        let joinedEmoji = "Before 👩🏽‍💻 after"
        let joinedRange = (joinedEmoji as NSString).range(of: "👩🏽‍💻")
        assert(joinedRange.length > 1)
        assert(replacement(joinedEmoji, joinedRange, "Murmur") == "Before Murmur after")

        let combining = "A e\u{0301} Z"
        let combiningRange = (combining as NSString).range(of: "e\u{0301}")
        assert(combiningRange.length == 2)
        assert(replacement(combining, combiningRange, "é") == "A é Z")

        // Invalid or missing AX selections must not crash or invent an expected value.
        assert(replacement("abc", nil, "voice") == nil)
        assert(replacement("abc", NSRange(location: NSNotFound, length: 0), "voice") == nil)
        assert(replacement("abc", NSRange(location: -1, length: 0), "voice") == nil)
        assert(replacement("abc", NSRange(location: 0, length: -1), "voice") == nil)
        assert(replacement("abc", NSRange(location: 4, length: 0), "voice") == nil)
        assert(replacement("abc", NSRange(location: 2, length: 2), "voice") == nil)
        assert(replacement("abc", NSRange(location: 0, length: Int.max), "voice") == nil)
        assert(replacement("abc", NSRange(location: Int.max - 1, length: Int.max), "voice") == nil)

        func confirmed(_ before: String?, _ after: String?, _ selection: NSRange?,
                       _ finalSelection: NSRange?, _ text: String) -> Bool {
            TextInsertion.insertionConfirmed(before: before, after: after, selection: selection,
                                             finalSelection: finalSelection, text: text)
        }

        let oldSelection = NSRange(location: 6, length: 5)
        let insertedCaret = NSRange(location: 12, length: 0)
        assert(confirmed("Hello world", "Hello Murmur", oldSelection, insertedCaret, "Murmur"))
        // A formatter or rejected paste can advance the caret without inserting the text.
        assert(!confirmed("Hello world", "Hello WORLD!", oldSelection, insertedCaret, "Murmur"))
        assert(!confirmed("Hello world", "Hello world", oldSelection, insertedCaret, "Murmur"))
        // Exact receiver text is stronger evidence than a missing or stale caret range.
        assert(confirmed("Hello world", "Hello Murmur", oldSelection, nil, "Murmur"))

        let emojiCaret = NSRange(location: 3, length: 0)
        let advancedEmojiCaret = NSRange(location: 5, length: 0)
        assert(confirmed(nil, nil, emojiCaret, advancedEmojiCaret, "😀"))
        assert(confirmed(nil, "Unknown before text", emojiCaret, advancedEmojiCaret, "😀"))
        assert(!confirmed(nil, nil, emojiCaret, NSRange(location: 4, length: 0), "😀"))
        assert(!confirmed(nil, nil, emojiCaret, NSRange(location: 5, length: 2), "😀"))
        assert(!confirmed(nil, nil, nil, advancedEmojiCaret, "😀"))
        assert(!confirmed(nil, nil, emojiCaret, nil, "😀"))
        assert(!confirmed(nil, nil, NSRange(location: NSNotFound, length: 0),
                          NSRange(location: NSNotFound, length: 0), "voice"))
        assert(!confirmed(nil, nil, NSRange(location: -1, length: 0),
                          NSRange(location: 4, length: 0), "voice"))
        assert(!confirmed(nil, nil, NSRange(location: 0, length: -1),
                          NSRange(location: 5, length: 0), "voice"))
        assert(!confirmed(nil, nil, NSRange(location: Int.max - 1, length: 0),
                          NSRange(location: 0, length: 0), "voice"))
        // NSNotFound must never become a valid destination through arithmetic.
        assert(!confirmed(nil, nil, NSRange(location: Int.max - 1, length: 0),
                          NSRange(location: NSNotFound, length: 0), "x"))
        // A known invalid AX range cannot fall back to a coincidentally matching caret.
        assert(!confirmed("abc", "abc", NSRange(location: 4, length: 0),
                          NSRange(location: 5, length: 0), "x"))

        print("PASS: insertion expectations honor UTF-16 caret and selection offsets")
        print("PASS: missing, negative, out-of-bounds, and overflowing AX ranges are rejected")
        print("PASS: receiver content takes precedence over caret-only insertion confirmation")
        print("PASS: caret-only confirmation uses UTF-16 offsets and rejects unavailable ranges")
    }
}
