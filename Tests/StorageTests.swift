import Foundation

@main struct StorageTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Murmur-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStorage(root: root)
        func primaryDecodes() -> Bool {
            guard let data = try? Data(contentsOf: store.historyURL) else { return false }
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            return (try? decoder.decode(HistoryDocument.self, from: data)) != nil
        }
        let empty = try store.load()
        assert(empty.isEmpty)
        var first = Transcript()
        first.text = "A little thought, safely stored."
        first.originalText = first.text
        first.duration = 12.7
        first.audioFile = "\(first.id).m4a"
        try store.save([first])
        let recovered = try store.load()
        assert(recovered.count == 1 && recovered[0].id == first.id)
        assert(recovered[0].text == first.text && recovered[0].duration == first.duration)
        assert(recovered[0].status == .interrupted)
        first.status = .complete; first.text = "An edited thought."; first.isFavorite = true
        try store.save([first])
        let roundTrip = try store.load()
        assert(roundTrip[0].status == .complete && roundTrip[0].isFavorite)
        assert(roundTrip[0].originalText == "A little thought, safely stored.")
        try Data("broken-json".utf8).write(to: store.historyURL)
        let fallback = try store.load()
        assert(fallback.count == 1 && fallback[0].id == first.id)
        let damagedCopies = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix("history-damaged-") }
        assert(damagedCopies.count == 1)
        try store.save(fallback)
        assert(primaryDecodes(), "Saving unchanged history recovered from backup must still repair the primary file")
        let restored = try store.load()
        assert(restored.count == 1)
        try FileManager.default.removeItem(at: store.historyURL)
        let missingPrimary = try store.load()
        assert(missingPrimary.count == 1 && missingPrimary[0].id == first.id,
               "A missing primary history must recover the last-good backup")
        try store.save(missingPrimary)
        assert(primaryDecodes(), "Saving unchanged history recovered from backup must recreate a missing primary file")
        // Repeated identical checkpoints skip the write; a change still lands and
        // the backup holds the previous good version.
        var changed = missingPrimary[0]; changed.text = "A newer thought."
        try store.save([changed])
        let backupDecoder = JSONDecoder(); backupDecoder.dateDecodingStrategy = .iso8601
        let backup = try backupDecoder.decode(HistoryDocument.self, from: Data(contentsOf: store.backupURL))
        let reloaded = try store.load()
        assert(backup.transcripts[0].text == missingPrimary[0].text && reloaded[0].text == "A newer thought.")
        try store.save(try store.load())
        assert(primaryDecodes())
        var unsafe = first; unsafe.audioFile = "../../secret"
        assert(store.audioURL(for: unsafe) == nil)
        assert(TextTools.clean("  Hello\t  world.  ") == "Hello world.")
        assert(TextTools.clean("fig ma and Fig ma. notfig ma!", replacements: "fig ma => Figma") == "Figma and Figma. notfig ma!")
        assert(TextTools.clean("cost", replacements: "cost => $1.00") == "$1.00")
        assert(TextTools.clean("東京", replacements: "東京 => Kyoto") == "Kyoto")
        assert(TextTools.clean("Keep um and like as spoken.") == "Keep um and like as spoken.")
        assert(TextTools.clean("Um, so I think, uh, we should go.", removeFillers: true) == "So I think we should go.")
        assert(TextTools.clean("It works. Uh let me check umm the build.", removeFillers: true) == "It works. Let me check the build.")
        assert(TextTools.clean("So, um.", removeFillers: true) == "So.")
        assert(TextTools.clean("Uh-huh, the umbrella is here, hmm?", removeFillers: true) == "Uh-huh, the umbrella is here?")
        assert(TextTools.clean("Um.", removeFillers: true) == "")
        assert(TextTools.clean("Dear Sam, new paragraph. thanks for the notes. New line. Best, Lin", voiceCommands: true) == "Dear Sam\n\nThanks for the notes.\nBest, Lin")
        assert(TextTools.clean("Buy milk new line eggs new line", voiceCommands: true) == "Buy milk\nEggs\n")
        assert(TextTools.clean("A brand new liner arrived.", voiceCommands: true) == "A brand new liner arrived.")
        assert(TextTools.clean("Buy milk new line eggs") == "Buy milk new line eggs")
        do {
            let now = Date()
            var a = Transcript(); a.status = .complete; a.text = Array(repeating: "word", count: 120).joined(separator: " "); a.duration = 60; a.createdAt = now
            var b = a; b.id = UUID(); b.createdAt = now.addingTimeInterval(-10 * 86_400)
            var trashed = a; trashed.id = UUID(); trashed.deletedAt = now
            var failed = a; failed.id = UUID(); failed.status = .failed
            let stats = LibraryStats([a, b, trashed, failed], typingSpeed: 40, now: now)
            assert(stats.totalWords == 240 && stats.weekWords == 120 && stats.dictations == 2)
            assert(stats.speakingPace == 120)
            assert(stats.minutesSaved == 4) // 240 words typed at 40 wpm = 6 min, spoken in 2 min.
            assert(stats.days.count == 14 && stats.days.last?.words == 120 && stats.days.reduce(0) { $0 + $1.words } == 240)
            assert(LibraryStats([], typingSpeed: 40, now: now).speakingPace == nil)
        }
        let applied = TextTools.appliedReplacements(in: "ask mer mer about fig ma", replacements: "mer mer => Murmur\nfig ma => Figma\nzzz => Q")
        assert(applied.map(\.desired) == ["Murmur", "Figma"])
        assert(LibrarySearch.terms("what did I say about pricing?") == ["pric"])
        assert(LibrarySearch.matches("Users think the price is too high", terms: LibrarySearch.terms("what did I say about pricing")))
        assert(LibrarySearch.matches("We launched Recallr", terms: LibrarySearch.terms("Recallr launches")))
        assert(!LibrarySearch.matches("Buy milk", terms: LibrarySearch.terms("pricing")))
        assert(LibrarySearch.terms("the") == ["the"] && LibrarySearch.stem("stories") == "story")
        assert(LibrarySearch.isQuestion("when is the launch") && !LibrarySearch.isQuestion("launch"))
        assert(TextTools.spaced("How are you", after: ".") == " How are you")
        assert(TextTools.spaced("How are you", after: " ") == "How are you")
        assert(TextTools.spaced("How are you", after: nil) == "How are you")
        assert(TextTools.spaced("How are you", after: "(") == "How are you")
        assert(TextTools.spaced(", then", after: "a") == ", then")
        let exported = try store.exportData(roundTrip)
        assert(String(data: exported, encoding: .utf8)!.contains("An edited thought."))
        assert(String(data: exported, encoding: .utf8)!.contains("\n"), "Exports stay human-readable")
        var titled = Transcript(); titled.status = .complete
        titled.text = "What if I left my phone in the kitchen tonight and put a book on my bedside table instead?"
        assert(titled.title == "What if I left my phone in the kitchen tonight and put a…")
        assert(titled.preview == "book on my bedside table instead?")
        titled.text = "Groceries\n\neggs   and milk"
        assert(titled.title == "Groceries" && titled.preview == "eggs and milk")
        titled.text = "Remember to book a table for Friday, pick up coffee beans, and send the photos"
        assert(titled.title == "Remember to book a table for Friday, pick up coffee beans…")
        titled.text = "Short thought."
        assert(titled.title == "Short thought." && titled.preview.isEmpty)
        titled.text = String(repeating: "x", count: 80)
        assert(titled.title == String(repeating: "x", count: 61) + "…" && titled.preview == String(repeating: "x", count: 19))
        titled.text = ""
        assert(titled.title == "Untitled recording" && titled.preview.isEmpty)
        print("PASS: atomic persistence, crash recovery, last-good backup, original text, favorites, safe paths, vocabulary, export")
    }
}
