import Foundation
import CoreGraphics

@main struct FnIntegrationTests {
    @MainActor static func main() async throws {
        let model = AppModel(preview: true)
        let root = model.storage.root
        defer { try? FileManager.default.removeItem(at: root) }
        let initialCount = model.transcripts.count
        let shortcut = FnShortcut()
        shortcut.onAction = { model.handleFn($0) }
        model.resetFnInput = { shortcut.resetInput() }
        model.startFnTest()
        model.toggleRecording() // The fallback shortcut must also respect key-test mode.
        let down = CGEvent(keyboardEventSource: nil, virtualKey: 63, keyDown: true)!
        down.flags = .maskSecondaryFn
        let up = CGEvent(keyboardEventSource: nil, virtualKey: 63, keyDown: false)!
        up.flags = []
        assert(shortcut.handle(type: .flagsChanged, event: down))
        // Exercise the real delayed hold callback through the application model.
        try await Task.sleep(for: .milliseconds(250))
        assert(shortcut.handle(type: .flagsChanged, event: up))
        let space = CGEvent(keyboardEventSource: nil, virtualKey: 49, keyDown: true)!
        space.flags = .maskSecondaryFn
        assert(shortcut.handle(type: .keyDown, event: space))
        try await Task.sleep(for: .milliseconds(50))
        assert(model.speech.phase == .idle)
        assert(model.activeID == nil && !model.fnHoldInProgress)
        assert(model.transcripts.count == initialCount)
        let audioFiles = (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Recordings").path)) ?? []
        assert(audioFiles.isEmpty)
        model.endFnTest()
        assert(!model.isTestingFn)
        // Release must switch out of recording in this same synchronous call,
        // before its Task runs or any recognizer returns a final result.
        model.speech.phase = .recording
        model.handleFn(.finishHold)
        assert(model.speech.phase == .finishing)
        try await Task.sleep(for: .milliseconds(50))
        assert(model.speech.phase == .idle)
        // A hold released before the start Task executes must never open a mic.
        model.handleFn(.startHold)
        model.handleFn(.finishHold)
        try await Task.sleep(for: .milliseconds(50))
        assert(model.speech.phase == .idle && model.activeID == nil)
        assert(model.transcripts.count == initialCount)
        shortcut.stop()
        print("PASS: physical-key test routes hold and hands-free actions without starting speech, audio capture, or a transcript")
        print("PASS: release stops synchronously; release before startup never captures audio or creates a transcript")
    }
}
