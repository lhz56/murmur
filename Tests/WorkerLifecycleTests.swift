import Foundation

@main struct WorkerLifecycleTests {
    @MainActor static func main() async throws {
        let binary = URL(fileURLWithPath: CommandLine.arguments[1])
        let worker = ParakeetWorker(executable: binary, modelDirectory: URL(fileURLWithPath: "/fixture/delayed"))
        defer { worker.stop() }
        var readyStates: [Bool] = []
        worker.onReadiness = { readyStates.append($0) }
        let cancelledStart = Task { try await worker.start() }
        let sharedStart = Task { try await worker.start() }
        try await Task.sleep(for: .milliseconds(20))
        cancelledStart.cancel()
        do { try await cancelledStart.value; assertionFailure("Cancelled startup returned success") }
        catch is CancellationError { }
        assert(!worker.isReady, "Cancellation must not wait for the worker to become ready")
        try await sharedStart.value
        assert(worker.isReady && readyStates.last == true)

        let cancelledRequest = Task { try await worker.transcribe(URL(fileURLWithPath: "/fixture/cancelled.wav")) }
        try await Task.sleep(for: .milliseconds(20))
        cancelledRequest.cancel()
        do { _ = try await cancelledRequest.value; assertionFailure("Cancelled request returned success") }
        catch is CancellationError { }
        async let first = worker.transcribe(URL(fileURLWithPath: "/fixture/first.wav"))
        async let second = worker.transcribe(URL(fileURLWithPath: "/fixture/second.wav"))
        let results = try await (first, second)
        assert(results.0.text == "Fixture result" && results.1.text == results.0.text)
        assert(worker.isReady, "A late error from a cancelled request must not kill the shared worker")

        worker.requestTimeout = .milliseconds(20)
        do { _ = try await worker.transcribe(URL(fileURLWithPath: "/fixture/timeout.wav")); assertionFailure("Timeout returned success") }
        catch LocalSpeechError.timeout { }
        assert(!worker.isReady && readyStates.last == false)
        worker.requestTimeout = .seconds(2)
        let recovered = try await worker.transcribe(URL(fileURLWithPath: "/fixture/recovered.wav"))
        assert(recovered.text == "Fixture result" && worker.isReady)
        do { _ = try await worker.transcribe(URL(fileURLWithPath: "/fixture/crash.wav")); assertionFailure("Dead helper returned success") }
        catch LocalSpeechError.failed { }
        assert(!worker.isReady && readyStates.last == false)
        let restarted = try await worker.transcribe(URL(fileURLWithPath: "/fixture/restarted.wav"))
        assert(restarted.text == "Fixture result")
        worker.stop()
        assert(readyStates.last == false)
        print("PASS: cancelled startup, shared readiness, cancelled requests, late errors, concurrent results, timeout recovery, helper crash recovery and readiness state")
    }
}
