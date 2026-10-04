import Foundation
import AVFAudio

@main struct AudioStartupTests {
    static func main() async throws {
        let early = FirstAudioBuffer()
        early.receive() // Hardware can deliver a frame before start awaits it.
        try await early.wait(timeout: .milliseconds(100))

        let concurrent = FirstAudioBuffer()
        DispatchQueue.concurrentPerform(iterations: 100) { _ in concurrent.receive() }
        try await concurrent.wait(timeout: .milliseconds(100))

        let missing = FirstAudioBuffer()
        do {
            try await missing.wait(timeout: .milliseconds(15))
            assertionFailure("A microphone that sent no frames became ready")
        } catch DictationError.noInput { }

        let cancelled = FirstAudioBuffer()
        let waiter = Task { try await cancelled.wait() }
        waiter.cancel()
        do { try await waiter.value; assertionFailure("Cancelled readiness succeeded") }
        catch is CancellationError { }
        cancelled.receive()

        let sealed = FirstAudioBuffer()
        sealed.finish(); sealed.receive()
        do { try await sealed.wait(); assertionFailure("A sealed capture reopened") }
        catch DictationError.cancelled { }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Murmur-startup-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
        buffer.frameLength = 1024
        buffer.floatChannelData![0].initialize(repeating: 0, count: 1024)
        let capture = try AudioPipeline(inputFormat: format, audioURL: root.appendingPathComponent("frames.m4a"),
                                        onMeter: { _ in }, onError: { assertionFailure($0.localizedDescription) })
        capture.append(buffer)
        try await capture.firstAudio.wait()
        capture.append(buffer)
        let signal = await capture.finish()
        assert(signal.samples == 2048 && signal.hasFrames)
        let saved = try AVAudioFile(forReading: root.appendingPathComponent("frames.m4a"))
        assert(saved.length == 2048)

        // A real native exception must become a Swift error, not strand a start.
        // Tapping a mixer uses no microphone, and a second tap on its occupied
        // bus is invalid on every supported engine.
        let audio = AVAudioEngine()
        let mixer = audio.mainMixerNode
        assert(MurmurInstallAudioTap(mixer, 0, 1024, format, { _, _ in }) == nil)
        assert(MurmurInstallAudioTap(mixer, 0, 1024, format, { _, _ in }) != nil)
        mixer.removeTap(onBus: 0)
        print("PASS: first-frame readiness handles early frames, concurrent delivery, timeout, cancellation, and sealed capture")
        print("PASS: readiness preserves complete saved audio and native tap exceptions return ordinary errors")
    }
}
