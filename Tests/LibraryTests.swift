import Foundation
import AppKit

@main struct LibraryTests {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let model = AppModel(preview: true)
        defer { try? FileManager.default.removeItem(at: model.storage.root) }
        var entry = Transcript()
        entry.status = .interrupted; entry.sourceApp = "Test audio"
        entry.audioFile = "\(entry.id.uuidString).m4a"
        let audio = model.storage.audioURL(for: entry)!
        try FileManager.default.copyItem(at: URL(fileURLWithPath: CommandLine.arguments[1]), to: audio)
        model.transcripts.insert(entry, at: 0)
        try model.storage.save(model.transcripts)
        model.retry(entry)
        try await Task.sleep(for: .milliseconds(50))
        for _ in 0..<800 {
            if model.activeID == nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        assert(model.errorMessage == nil && model.activeID == nil)
        let result = model.transcripts.first { $0.id == entry.id }!
        assert(result.status == .complete && result.text.localizedCaseInsensitiveContains("quick brown fox"))
        assert(result.originalText == result.text && result.duration > 7)
        model.favorite(entry.id)
        model.filter = .favorites; model.search = "brown fox"
        assert(model.visibleTranscripts.count == 1)
        model.edit(entry.id, text: "An edited local transcript.")
        try await Task.sleep(for: .milliseconds(450))
        let edited = try model.storage.load().first { $0.id == entry.id }!
        assert(edited.text == "An edited local transcript." && edited.originalText == result.originalText)
        model.trash(entry.id)
        assert(model.transcripts.first { $0.id == entry.id }!.deletedAt != nil)
        model.restore(entry.id)
        assert(model.transcripts.first { $0.id == entry.id }!.deletedAt == nil)
        model.trash(entry.id)
        model.permanentlyDelete(entry.id)
        assert(!FileManager.default.fileExists(atPath: audio.path))
        let historyText = String(data: try Data(contentsOf: model.storage.historyURL), encoding: .utf8)!
        let backupText = String(data: try Data(contentsOf: model.storage.backupURL), encoding: .utf8)!
        assert(!historyText.contains(entry.id.uuidString))
        assert(!backupText.contains(entry.id.uuidString))
        print("PASS: saved-audio recovery, finalized history, search, favorites, debounced editing, original text, trash, restore, permanent cleanup")
    }
}
