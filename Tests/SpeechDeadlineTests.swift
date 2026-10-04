import Foundation

@MainActor final class DeferredSpeech {
    var continuation: CheckedContinuation<Int, Never>?
    var finished = false
    func result() async -> Int {
        let value = await withCheckedContinuation { continuation = $0 }
        finished = true
        return value
    }
}

@main struct SpeechDeadlineTests {
    @MainActor static func main() async throws {
        let immediate = try await SpeechDeadline.run(timeout: .seconds(1)) { 42 }
        assert(immediate == 42)
        let stalled = DeferredSpeech()
        do {
            _ = try await SpeechDeadline.run(timeout: .milliseconds(20)) { await stalled.result() }
            assertionFailure("An uncooperative operation bypassed its deadline")
        } catch LocalSpeechError.timeout { }
        assert(!stalled.finished && stalled.continuation != nil)
        stalled.continuation?.resume(returning: 7)
        for _ in 0..<100 { if stalled.finished { break }; await Task.yield() }
        assert(stalled.finished)
        let next = try await SpeechDeadline.run(timeout: .seconds(1)) { 99 }
        assert(next == 99, "A late completion affected the next operation")

        let uncooperative = DeferredSpeech()
        let cancelled = Task { try await SpeechDeadline.run(timeout: .seconds(5)) { await uncooperative.result() } }
        for _ in 0..<100 { if uncooperative.continuation != nil { break }; await Task.yield() }
        assert(uncooperative.continuation != nil)
        cancelled.cancel()
        do { _ = try await cancelled.value; assertionFailure("Cancellation returned success") }
        catch is CancellationError { }
        assert(!uncooperative.finished)
        uncooperative.continuation?.resume(returning: 12)
        print("PASS: speech deadlines and cancellation return before uncooperative operations; late results cannot resume old callers")
    }
}
