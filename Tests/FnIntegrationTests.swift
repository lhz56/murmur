import Foundation
import CoreGraphics

@MainActor final class DelayedMicrophoneAuthorization {
    var requests: [CheckedContinuation<Bool, Never>] = []
    func request() async -> Bool {
        await withCheckedContinuation { requests.append($0) }
    }
}

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

        // Suspend a real start at its asynchronous authorization boundary. This
        // reproduces slow microphone setup without opening or recording a mic.
        let authorization = DelayedMicrophoneAuthorization()
        let delayedSpeech = DictationEngine(authorizeMicrophone: { await authorization.request() })
        let delayedModel = AppModel(preview: true, speech: delayedSpeech)
        let delayedRoot = delayedModel.storage.root
        defer { try? FileManager.default.removeItem(at: delayedRoot) }
        let savedCount = delayedModel.transcripts.count
        delayedModel.preferences.sounds = false
        var hidden = 0
        var recordingStarts = 0
        delayedModel.hideHUD = { hidden += 1 }
        delayedModel.onRecordingChanged = { if $0 { recordingStarts += 1 } }
        let control = FnShortcut()
        control.trigger = { .control }; control.behavior = { .hold }
        control.isBusy = { delayedSpeech.phase.isBusy }
        control.onAction = { delayedModel.handleFn($0) }
        var now: TimeInterval = 100
        control.clock = { now }
        func hold() {
            control.sampleControl(flags: .maskControl, keyDownCount: 10)
            now += FnShortcut.controlHoldDelay + 0.001
            control.sampleControl(flags: .maskControl, keyDownCount: 10)
        }
        func release() { control.sampleControl(flags: [], keyDownCount: 10) }
        func waitFor(_ condition: () -> Bool) async throws {
            for _ in 0..<300 {
                if condition() { return }
                try await Task.sleep(for: .milliseconds(2))
            }
            preconditionFailure("Startup regression check timed out")
        }

        // A sub-threshold tap must not start an asynchronous recording at all.
        control.sampleControl(flags: .maskControl, keyDownCount: 10)
        now += 0.05
        release()
        try await Task.sleep(for: .milliseconds(20))
        assert(authorization.requests.isEmpty && !delayedModel.hudVisible)
        assert(delayedModel.activeID == nil && delayedModel.transcripts.count == savedCount)

        hold()
        try await waitFor { authorization.requests.count == 1 }
        assert(delayedSpeech.phase == .preparing && delayedModel.hudVisible)
        let cancelledID = delayedModel.activeID!
        release()
        // These assertions happen before the held authorization is resumed.
        assert(delayedSpeech.phase == .idle && !delayedModel.hudVisible)
        assert(delayedModel.activeID == nil && !delayedModel.fnHoldInProgress && hidden == 1)
        try await waitFor { delayedModel.transcripts.count == savedCount }

        // Start again while the first, uncooperative OS operation is still pending.
        hold()
        try await waitFor { authorization.requests.count == 2 }
        let nextID = delayedModel.activeID!
        assert(nextID != cancelledID && delayedModel.hudVisible)
        authorization.requests[0].resume(returning: true)
        try await Task.sleep(for: .milliseconds(30))
        assert(delayedSpeech.phase == .preparing && delayedModel.activeID == nextID)
        assert(delayedModel.hudVisible && hidden == 1 && recordingStarts == 0)
        assert(delayedModel.transcripts.contains { $0.id == nextID })

        // The downloading startup phase follows the same immediate release path.
        delayedSpeech.phase = .downloading
        release()
        assert(delayedSpeech.phase == .idle && delayedModel.activeID == nil)
        assert(!delayedModel.hudVisible && hidden == 2)
        authorization.requests[1].resume(returning: false)
        try await waitFor { delayedModel.transcripts.count == savedCount }

        // An accidental Control chord during startup must cancel, not later record.
        hold()
        try await waitFor { authorization.requests.count == 3 }
        control.sampleControl(flags: .maskControl, keyDownCount: 11)
        assert(delayedSpeech.phase == .idle && !delayedModel.hudVisible)
        assert(delayedModel.activeID == nil && hidden == 3)
        control.sampleControl(flags: [], keyDownCount: 11)
        authorization.requests[2].resume(returning: true)
        try await waitFor { delayedModel.transcripts.count == savedCount }
        assert(recordingStarts == 0 && delayedModel.errorMessage == nil)
        let savedHistory = try delayedModel.storage.load()
        assert(savedHistory.count == savedCount)
        let cancelledAudio = (try? FileManager.default.contentsOfDirectory(atPath: delayedRoot.appendingPathComponent("Recordings").path)) ?? []
        assert(cancelledAudio.isEmpty)
        control.stop()
        print("PASS: physical-key test routes hold and hands-free actions without starting speech, audio capture, or a transcript")
        print("PASS: release stops synchronously; release before startup never captures audio or creates a transcript")
        print("PASS: release hides startup and frees the app before slow microphone setup returns")
        print("PASS: cancelled startup cannot reopen the pill, capture audio, or tear down a newer session")
        print("PASS: downloading and late Control chords cancel immediately without empty saved recordings")
    }
}
