import AppKit
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
        // A rich editor may expose its complete value but no native AX range.
        assert(confirmed("", "Hello.", nil, nil, "Hello."))
        assert(confirmed("\n", "Hello.\n", nil, nil, "Hello."))
        assert(!confirmed("", "Hello.Hello.", nil, nil, "Hello."))
        assert(!confirmed(nil, "Hello.", nil, nil, "Hello."))
        assert(!confirmed("Existing text", "Hello.", nil, nil, "Hello."))
        assert(!confirmed("", "Hello.", NSRange(location: NSNotFound, length: 0), nil, "Hello."))
        assert(!confirmed("", "", nil, nil, ""))
        assert(!confirmed("\n", "\n", nil, nil, "\n"))

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

        // Custom editors need a positive editing capability. A selection in a
        // read-only page must never turn its web area into a paste destination.
        assert(!TextInsertion.isTextEditor(role: "AXWebArea", subrole: nil, enabled: true,
                                          hasSelectedRange: true, selectedTextWritable: false, valueWritable: false))
        assert(TextInsertion.isTextEditor(role: "AXGroup", subrole: nil, enabled: true,
                                         hasSelectedRange: true, selectedTextWritable: true, valueWritable: false))
        assert(TextInsertion.isTextEditor(role: "AXGroup", subrole: nil, enabled: true,
                                         hasSelectedRange: true, selectedTextWritable: false, valueWritable: true))
        assert(!TextInsertion.isTextEditor(role: "AXSlider", subrole: nil, enabled: true,
                                          hasSelectedRange: false, selectedTextWritable: false, valueWritable: true))
        // Secure and disabled controls remain excluded even if they report a
        // standard text role or a writable text attribute.
        assert(!TextInsertion.isTextEditor(role: "AXTextField", subrole: "AXSecureTextField", enabled: true,
                                          hasSelectedRange: true, selectedTextWritable: true, valueWritable: true))
        assert(!TextInsertion.isTextEditor(role: "AXTextArea", subrole: nil, enabled: false,
                                          hasSelectedRange: true, selectedTextWritable: true, valueWritable: true))
        assert(TextInsertion.isTextEditor(role: "AXTextArea", subrole: nil, enabled: nil,
                                         hasSelectedRange: false, selectedTextWritable: false, valueWritable: false))

        typealias Focus = TextInsertion.FocusSnapshot<String>
        func focus(_ pid: Int32 = 1, _ window: String? = "window", _ raw: String? = "field", _ editor: String? = "field",
                   _ signature: TextInsertion.EditorSignature? = nil, allowed: Bool = true) -> Focus {
            Focus(pid: pid, window: window, focused: raw, editor: editor, signature: signature, allowsPaste: allowed)
        }
        let originalField = focus()
        // A rich editor's focused child can change while its editing container stays the same.
        assert(TextInsertion.matchesFocus(originalField, focus(1, "window", "text-child", "field")))
        assert(!TextInsertion.matchesFocus(originalField, focus(1, "window", "other-field", "other-field")))
        assert(!TextInsertion.matchesFocus(originalField, focus(2)))
        assert(!TextInsertion.matchesFocus(originalField, focus(1, "other-window")))
        assert(!TextInsertion.matchesFocus(originalField, focus(allowed: false)))
        let signature = TextInsertion.EditorSignature(identifier: "composer", role: "AXTextArea",
                                                       frame: CGRect(x: 10, y: 20, width: 400, height: 60))
        let namedField = focus(1, "window", "old-node", "old-node", signature)
        assert(TextInsertion.matchesFocus(namedField, focus(1, "window", "new-node", "new-node", signature)))
        assert(!TextInsertion.matchesFocus(namedField, focus(1, "other-window", "new-node", "new-node", signature)))
        let otherSignature = TextInsertion.EditorSignature(identifier: "composer", role: "AXTextArea",
                                                            frame: CGRect(x: 10, y: 120, width: 400, height: 60))
        assert(!TextInsertion.matchesFocus(namedField, focus(1, "window", "new-node", "new-node", otherSignature)))
        assert(!TextInsertion.matchesFocus(namedField, focus(1, "window", "new-node", "new-node")))
        let pageA = TextInsertion.EditorSignature(identifier: "composer", role: "AXTextArea", frame: signature.frame,
                                                   document: "https://example.test/chat-a")
        let pageB = TextInsertion.EditorSignature(identifier: "composer", role: "AXTextArea", frame: signature.frame,
                                                   document: "https://example.test/chat-b")
        assert(!TextInsertion.matchesFocus(focus(1, "window", "old-node", "old-node", pageA),
                                           focus(1, "window", "new-node", "new-node", pageB)))
        // Some web apps reuse the same composer node when navigating to another chat.
        assert(!TextInsertion.matchesFocus(focus(1, "window", "same-node", "same-node", pageA),
                                           focus(1, "window", "same-node", "same-node", pageB)))
        assert(!TextInsertion.matchesFocus(focus(1, "window", "same-node", "same-node", pageA),
                                           focus(1, "window", "same-node", "same-node")))
        let opaque = focus(1, "window", "custom-editor", nil)
        assert(TextInsertion.matchesFocus(opaque, focus(1, "window", "custom-editor", nil)))
        assert(!TextInsertion.matchesFocus(opaque, focus(1, "window", "different-custom-editor", nil)))
        // With no AX field available, compatibility paste still requires a known window.
        let inaccessible = focus(1, "window", nil, nil)
        assert(TextInsertion.matchesFocus(inaccessible, focus(1, "window", nil, nil)))
        assert(!TextInsertion.matchesFocus(inaccessible, focus(1, "other-window", nil, nil)))
        assert(!TextInsertion.matchesFocus(focus(1, nil, nil, nil), focus(1, nil, nil, nil)))
        assert(TextInsertion.allowsCompatibilityPaste(role: "AXGroup", subrole: nil, enabled: true))
        assert(TextInsertion.allowsCompatibilityPaste(role: nil, subrole: nil, enabled: nil))
        assert(!TextInsertion.allowsCompatibilityPaste(role: "AXButton", subrole: nil, enabled: true))
        assert(!TextInsertion.allowsCompatibilityPaste(role: "AXStaticText", subrole: nil, enabled: true))
        assert(!TextInsertion.allowsCompatibilityPaste(role: "AXGroup", subrole: "AXSecureTextField", enabled: true))
        assert(!TextInsertion.allowsCompatibilityPaste(role: "AXGroup", subrole: nil, enabled: false))
        assert(TextInsertion.isPasteMenuCommand(character: "V", modifiers: 0, enabled: true, pressSupported: true))
        assert(!TextInsertion.isPasteMenuCommand(character: "v", modifiers: 1, enabled: true, pressSupported: true))
        assert(!TextInsertion.isPasteMenuCommand(character: "v", modifiers: 8, enabled: true, pressSupported: true))
        assert(!TextInsertion.isPasteMenuCommand(character: "v", modifiers: 0, enabled: false, pressSupported: true))
        assert(!TextInsertion.isPasteMenuCommand(character: "v", modifiers: 0, enabled: true, pressSupported: false))
        assert(!TextInsertion.isPasteMenuCommand(character: "v", modifiers: nil, enabled: true, pressSupported: true))
        assert(!TextInsertion.isPasteMenuCommand(character: "c", modifiers: 0, enabled: true, pressSupported: true))

        // Borrowing the clipboard for a paste restores every item and type afterward.
        let board = NSPasteboard(name: NSPasteboard.Name("app.murmur.tests.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let custom = NSPasteboard.PasteboardType("app.murmur.tests.custom")
        let first = NSPasteboardItem(); first.setString("Original clipboard", forType: .string)
        first.setData(Data([1, 2, 3]), forType: custom)
        let second = NSPasteboardItem(); second.setString("https://example.com", forType: .URL)
        board.clearContents(); board.writeObjects([first, second])
        let snapshot = PasteboardSnapshot(board)!
        board.clearContents(); board.setString("Dictated text", forType: .string)
        snapshot.restore(to: board)
        let restored = board.pasteboardItems ?? []
        assert(restored.count == 2)
        assert(restored[0].string(forType: .string) == "Original clipboard" && restored[0].data(forType: custom) == Data([1, 2, 3]))
        assert(restored[1].string(forType: .URL) == "https://example.com")
        assert(PasteboardSnapshot(board, byteLimit: 4) == nil, "Oversized clipboards are left alone rather than duplicated")
        board.clearContents()
        PasteboardSnapshot(board)!.restore(to: board)
        assert((board.pasteboardItems ?? []).isEmpty, "An empty clipboard is restored as empty")

        print("PASS: insertion expectations honor UTF-16 caret and selection offsets")
        print("PASS: missing, negative, out-of-bounds, and overflowing AX ranges are rejected")
        print("PASS: receiver content takes precedence over caret-only insertion confirmation")
        print("PASS: caret-only confirmation uses UTF-16 offsets and rejects unavailable ranges")
        print("PASS: custom editor eligibility requires writable text and excludes secure, disabled, and read-only controls")
        print("PASS: compatibility paste stays in the original app, window, and editor; named replacements require matching geometry")
        print("PASS: only enabled standard Command-V menu actions are eligible for a single paste attempt")
        let element = AXUIElementCreateSystemWide()
        let watched = TextInsertion.InsertedText(element: element, before: "Hi Sam. ", selection: NSRange(location: 8, length: 0), text: "recaller ships")!
        assert(watched.current(in: "Hi Sam. Recallr ships") == "Recallr ships")
        assert(watched.current(in: "") == nil) // Sent: the field was cleared.
        assert(TextInsertion.InsertedText(element: element, before: nil, selection: NSRange(location: 0, length: 0), text: "x") == nil)
        let middle = TextInsertion.InsertedText(element: element, before: "A  B", selection: NSRange(location: 2, length: 0), text: "x")!
        assert(middle.current(in: "A yes B") == "yes" && middle.current(in: "Z yes B") == nil)
        print("PASS: inserted text is found again between its original neighbors, and lost once the field changes around it")
        print("PASS: borrowed clipboard contents restore every item and type; oversized contents are skipped")
    }
}
