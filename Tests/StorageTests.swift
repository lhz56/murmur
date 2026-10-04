import Foundation

@main struct StorageTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Murmur-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStorage(root: root)
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
        let restored = try store.load()
        assert(restored.count == 1)
        try FileManager.default.removeItem(at: store.historyURL)
        let missingPrimary = try store.load()
        assert(missingPrimary.count == 1 && missingPrimary[0].id == first.id,
               "A missing primary history must recover the last-good backup")
        try store.save(missingPrimary)
        var unsafe = first; unsafe.audioFile = "../../secret"
        assert(store.audioURL(for: unsafe) == nil)
        assert(TextTools.clean("  Hello\t  world.  ") == "Hello world.")
        assert(TextTools.clean("fig ma and Fig ma. notfig ma!", replacements: "fig ma => Figma") == "Figma and Figma. notfig ma!")
        assert(TextTools.clean("cost", replacements: "cost => $1.00") == "$1.00")
        assert(TextTools.clean("東京", replacements: "東京 => Kyoto") == "Kyoto")
        assert(TextTools.clean("Keep um and like as spoken.") == "Keep um and like as spoken.")
        let exported = try store.exportData(roundTrip)
        assert(String(data: exported, encoding: .utf8)!.contains("An edited thought."))
        print("PASS: atomic persistence, crash recovery, last-good backup, original text, favorites, safe paths, vocabulary, export")
    }
}
