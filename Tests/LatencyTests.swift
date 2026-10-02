import Foundation
import AppKit

@main struct LatencyTests {
    @MainActor static func main() async throws {
        let worker = ParakeetWorker()
        defer { worker.stop() }
        _ = NSApplication.shared
        let model = AppModel(preview: true)
        defer { try? FileManager.default.removeItem(at: model.storage.root) }
        model.preferences.autoCopy = true; model.preferences.autoPaste = false
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1])
        worker.startupTimeout = .milliseconds(1)
        do {
            try await worker.start()
            assertionFailure("A stalled startup bypassed its deadline")
        } catch LocalSpeechError.timeout { }
        assert(!worker.isReady)
        worker.startupTimeout = .seconds(15)
        let start = ProcessInfo.processInfo.systemUptime
        async let firstReady: Void = worker.start()
        async let secondReady: Void = worker.start()
        _ = try await (firstReady, secondReady)
        let warmup = ProcessInfo.processInfo.systemUptime - start
        var timings: [Double] = []
        var clipboardTimings: [Double] = []
        for _ in 0..<3 {
            let requested = ProcessInfo.processInfo.systemUptime
            let result = try await worker.transcribe(fixture)
            timings.append(ProcessInfo.processInfo.systemUptime - requested)
            assert(result.text.localizedCaseInsensitiveContains("quick brown fox"))
            assert(result.text.localizedCaseInsensitiveContains("local speech recognition"))
            let text = TextTools.clean(result.text)
            let copyStart = ProcessInfo.processInfo.systemUptime
            await model.deliver(text)
            clipboardTimings.append(ProcessInfo.processInfo.systemUptime - copyStart)
            assert(NSPasteboard.general.string(forType: .string) == text)
        }
        print("PASS: warmed bundled model preserves first and final words on repeated requests")
        print("PASS: startup deadline returns an error, then a new worker resumes all ready waiters")
        print("MODEL WARMUP SECONDS: \(warmup)")
        print("FINAL PASS SECONDS: \(timings)")
        print("CLIPBOARD DELIVERY SECONDS: \(clipboardTimings)")
        print("PASS: finished model text reaches the clipboard through the real app delivery path")
    }
}
