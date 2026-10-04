import Foundation

/// A framework operation may ignore cancellation. Resume its caller on time,
/// then ignore any late completion; the engine checks session ownership too.
@MainActor private final class SpeechDeadlineRace<Value> {
    var continuation: CheckedContinuation<Value, Error>?
    var operation: Task<Void, Never>?
    var timer: Task<Void, Never>?
    func finish(_ result: Result<Value, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        operation?.cancel(); operation = nil
        timer?.cancel(); timer = nil
        continuation.resume(with: result)
    }
}

@MainActor enum SpeechDeadline {
    static func run<Value>(timeout: Duration, operation: @escaping @MainActor () async throws -> Value) async throws -> Value {
        let race = SpeechDeadlineRace<Value>()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                race.continuation = continuation
                race.operation = Task { [weak race] in
                    do { let value = try await operation(); race?.finish(.success(value)) }
                    catch { race?.finish(.failure(error)) }
                }
                race.timer = Task { [weak race] in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    race?.finish(.failure(LocalSpeechError.timeout))
                }
            }
        } onCancel: {
            Task { @MainActor in race.finish(.failure(CancellationError())) }
        }
    }
}
