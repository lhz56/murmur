import Foundation
import AppKit

@main struct LibraryStateTests {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let model = AppModel(preview: true)
        defer { try? FileManager.default.removeItem(at: model.storage.root) }
        model.preferences.sounds = false
        model.preferences.autoCopy = false; model.preferences.autoPaste = false
        model.preferences.keepAudio = false
        var failures: [String] = []
        func check(_ condition: Bool, _ message: String) {
            if !condition { failures.append(message); print("FAIL: \(message)") }
        }
        func waitUntilIdle() async throws {
            for _ in 0..<300 {
                if model.activeID == nil && model.speech.phase == .idle { return }
                try await Task.sleep(for: .milliseconds(5))
            }
            throw NSError(domain: "Murmur.Tests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Operation did not return to idle"])
        }

        // Neither missing source may capture a microphone or launch a model.
        // A second synchronous click must not reserve a different transcript.
        var first = Transcript(); first.status = .interrupted; first.audioFile = "missing-first.m4a"
        var second = Transcript(); second.status = .interrupted; second.audioFile = "missing-second.m4a"
        model.transcripts = [first, second]
        model.transcripts[0].text = "Edited surviving thought."
        model.transcripts[0].originalText = "Original surviving thought."
        model.retry(first)
        check(model.activeID == first.id, "Retry must reserve its transcript before returning to the event loop")
        model.retry(second)
        check(model.activeID == first.id, "A second retry must not replace the active transcript")
        model.speech.onText?("Unfinished retry preview")
        check(model.transcripts[0].text == "Edited surviving thought." && model.transcripts[0].originalText == "Original surviving thought.",
              "Retry previews must not overwrite existing edited or original text")
        try await Task.sleep(for: .milliseconds(50))
        try await waitUntilIdle()

        // Exercise the production finish controller with no recognizer result.
        // An interrupted/no-speech recording is still recoverable when the user
        // has disabled retention of successfully transcribed audio.
        var quiet = Transcript(); quiet.audioFile = "quiet.m4a"
        let quietURL = model.storage.audioURL(for: quiet)!
        try Data("test-owned audio placeholder".utf8).write(to: quietURL)
        model.transcripts = [quiet]; model.activeID = quiet.id
        model.speech.phase = .recording
        model.handleFn(.finishHold)
        try await waitUntilIdle()
        check(FileManager.default.fileExists(atPath: quietURL.path), "No-speech audio must survive disabled retention")
        check(model.transcripts[0].audioFile != nil, "A failed thought must retain its recovery audio reference")

        // An archived thought cannot be retried while a permanent-delete action
        // is available. The controller also defends against an active deletion.
        var archived = first; archived.deletedAt = Date()
        model.transcripts = [archived]; model.errorMessage = nil
        model.retry(archived)
        check(model.activeID == nil, "A thought in Trash must be restored before retrying")
        try await Task.sleep(for: .milliseconds(50))
        try await waitUntilIdle()
        model.activeID = archived.id
        model.permanentlyDelete(archived.id)
        check(model.transcripts.contains { $0.id == archived.id }, "An active thought must not be permanently deleted")
        model.activeID = nil

        model.transcripts = [first]
        model.retry(first)
        await model.prepareToQuit()
        check(model.activeID == nil && model.speech.phase == .idle, "Quit must release a queued retry immediately")
        check(model.transcripts == [first], "Quit during retry must preserve the existing thought")

        // A storage failure must present an error instead of crashing the app.
        let blockedRoot = model.storage.root.appendingPathComponent("blocked-storage")
        try Data("not a directory".utf8).write(to: blockedRoot)
        let blocked = AppModel(preview: true, storageRoot: blockedRoot)
        check(blocked.errorMessage != nil && blocked.activeID == nil, "Unavailable storage must leave the app usable")
        blocked.toggleRecording()
        try await Task.sleep(for: .milliseconds(20))
        check(blocked.activeID == nil && blocked.speech.phase == .idle, "Unavailable storage must not open a microphone")

        let futureRoot = model.storage.root.appendingPathComponent("future-history")
        let futureStore = try HistoryStorage(root: futureRoot)
        let futureData = Data("{\"version\":99,\"transcripts\":[]}".utf8)
        try futureData.write(to: futureStore.historyURL)
        let readOnly = AppModel(preview: true, storageRoot: futureRoot)
        readOnly.transcripts = [first]
        readOnly.edit(first.id, text: "Must not overwrite future data")
        readOnly.favorite(first.id); readOnly.trash(first.id); readOnly.retry(first)
        check(readOnly.transcripts == [first] && readOnly.activeID == nil, "A newer history format must disable library mutations")
        check(try Data(contentsOf: futureStore.historyURL) == futureData, "A newer history format must remain byte-for-byte intact")

        await model.prepareToQuit()
        if !failures.isEmpty { throw NSError(domain: "Murmur.Tests", code: failures.count,
            userInfo: [NSLocalizedDescriptionKey: failures.joined(separator: "\n")]) }
        print("PASS: retry reservation, overlapping requests, failed-audio retention, Trash retry, active-delete protection, unavailable storage and future-history preservation")
    }
}
