import Foundation

final class FakeAssistantTransport: AssistantTransport {
    var onMessage: (([String: Any]) -> Void)?
    var onExit: ((String) -> Void)?
    var isRunning = false
    var sent: [[String: Any]] = []
    var respond: (([String: Any], FakeAssistantTransport) -> Void)?
    func start() throws { isRunning = true }
    func terminate() { isRunning = false }
    func send(_ message: [String: Any]) { sent.append(message); respond?(message, self) }
    func result(_ request: [String: Any], _ value: [String: Any]) {
        onMessage?(["id": request["id"]!, "result": value])
    }
    func codex(_ message: [String: Any], stall: String? = nil, account: String = "chatgpt") {
        let method = message["method"] as? String ?? ""
        if method == stall { return }
        switch method {
        case "initialize": result(message, [:])
        case "account/read": result(message, ["account": ["type": account]])
        case "thread/start": result(message, ["thread": ["id": "thread"]])
        case "turn/start": result(message, ["turn": ["id": "turn"]])
        default: break
        }
    }
    func complete(failed: Bool = false) {
        onMessage?(["method": "item/agentMessage/delta", "params": ["threadId": "thread", "turnId": "turn", "delta": "A partial answer."]])
        var turn: [String: Any] = ["id": "turn", "status": failed ? "failed" : "completed"]
        if failed { turn["error"] = ["message": "fixture failure"] }
        onMessage?(["method": "turn/completed", "params": ["threadId": "thread", "turn": turn]])
    }
}

@main struct AssistantProviderTests {
    @MainActor static func main() async throws {
        let question = AssistantQuestion(text: "hello")
        // Timeouts cover initialize, account lookup, thread creation and a silent generation.
        for stage in ["initialize", "account/read", "thread/start", "turn/start", "silent"] {
            let transport = FakeAssistantTransport()
            transport.respond = { message, transport in transport.codex(message, stall: stage) }
            let brain = CodexBrain(model: "fixture", timeout: .milliseconds(80), transport: { transport })
            let started = Date()
            do { _ = try await brain.ask(question, followUp: false) { _ in }; assertionFailure("Expected timeout at \(stage)") }
            catch { assert(Date().timeIntervalSince(started) < 2); assert(!transport.isRunning) }
        }
        // Cancellation before the initial RPC returns releases the entire lifecycle.
        do {
            let transport = FakeAssistantTransport()
            let brain = CodexBrain(model: "fixture", transport: { transport })
            let task = Task { try await brain.ask(question, followUp: false) { _ in } }
            try await Task.sleep(for: .milliseconds(20)); task.cancel()
            do { _ = try await task.value; assertionFailure("Expected cancellation") } catch is CancellationError {} catch { assertionFailure("\(error)") }
            assert(!transport.isRunning)
        }
        // API-key accounts never get as far as a model turn.
        do {
            let transport = FakeAssistantTransport()
            transport.respond = { message, transport in transport.codex(message, account: "apiKey") }
            let brain = CodexBrain(model: "fixture", transport: { transport })
            do { _ = try await brain.ask(question, followUp: false) { _ in }; assertionFailure("Expected subscription check") } catch {}
            assert(!transport.sent.contains { $0["method"] as? String == "turn/start" })
        }
        // Partial text followed by an error must not become a successful actionable reply.
        do {
            let transport = FakeAssistantTransport()
            transport.respond = { message, transport in
                transport.codex(message)
                if message["method"] as? String == "turn/start" { transport.complete(failed: true) }
            }
            let brain = CodexBrain(model: "fixture", transport: { transport })
            do { _ = try await brain.ask(question, followUp: false) { _ in }; assertionFailure("Expected terminal failure") } catch {}
        }
        // A disconnected provider's late callback cannot finish a new conversation.
        do {
            let first = FakeAssistantTransport(), second = FakeAssistantTransport()
            var launches = 0
            let brain = CodexBrain(model: "fixture", transport: { launches += 1; return launches == 1 ? first : second })
            first.respond = { message, transport in transport.codex(message) }
            let old = Task { try await brain.ask(question, followUp: false) { _ in } }
            try await Task.sleep(for: .milliseconds(30))
            let lateExit = first.onExit
            brain.interrupt()
            _ = try? await old.value
            second.respond = { message, transport in
                transport.codex(message)
                if message["method"] as? String == "turn/start" { lateExit?("old exit"); transport.complete() }
            }
            let answer = try await brain.ask(question, followUp: false) { _ in }
            assert(answer == "A partial answer."); brain.shutDown()
        }
        // Starting another user utterance must preserve a completed conversation for follow-ups.
        do {
            let transport = FakeAssistantTransport()
            transport.respond = { message, transport in
                transport.codex(message)
                if message["method"] as? String == "turn/start" { transport.complete() }
            }
            let brain = CodexBrain(model: "fixture", transport: { transport })
            _ = try await brain.ask(question, followUp: false) { _ in }
            brain.interrupt()
            assert(transport.isRunning)
            _ = try await brain.ask(question, followUp: true) { _ in }
            assert(transport.sent.filter { $0["method"] as? String == "thread/start" }.count == 1)
            brain.shutDown()
        }
        do {
            let transport = FakeAssistantTransport()
            transport.respond = { message, transport in
                if message["type"] as? String == "user" { transport.onMessage?(["type": "result", "result": "Answer", "is_error": false]) }
            }
            var launches = 0
            let brain = ClaudeBrain(model: "fixture", transport: { launches += 1; return transport })
            _ = try await brain.ask(question, followUp: false) { _ in }
            brain.interrupt()
            assert(transport.isRunning)
            _ = try await brain.ask(question, followUp: true) { _ in }
            assert(launches == 1)
            brain.shutDown()
        }
        // Claude receives the same bounded lifecycle and cancellation behavior.
        do {
            let transport = FakeAssistantTransport()
            let brain = ClaudeBrain(model: "fixture", timeout: .milliseconds(60), transport: { transport })
            do { _ = try await brain.ask(question, followUp: false) { _ in }; assertionFailure("Expected Claude timeout") } catch {}
            assert(!transport.isRunning)
        }
        print("PASS: assistant provider deadlines, startup cancellation, account gating, partial failure, stale process callbacks and follow-up continuity")
    }
}
