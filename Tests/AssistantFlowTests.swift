import Foundation
import AppKit

@MainActor final class FakeAssistantBrain: AssistantBrain {
    var stream: (@MainActor (String) -> Void)?
    var pending: CheckedContinuation<String, Error>?
    var questions: [AssistantQuestion] = []
    func warm() async {}
    func ask(_ question: AssistantQuestion, followUp: Bool, onText: @escaping @MainActor (String) -> Void) async throws -> String {
        questions.append(question); stream = onText
        return try await withCheckedThrowingContinuation { pending = $0 }
    }
    func complete(_ text: String) { let old = pending; pending = nil; old?.resume(returning: text) }
    func interrupt() { let old = pending; pending = nil; old?.resume(throwing: CancellationError()) }
    func shutDown() { interrupt() }
}

@main struct AssistantFlowTests {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let suite = "Murmur.AssistantTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "assistantSpeaks")
        defaults.set(false, forKey: "assistantKeepsListening")
        let brain = FakeAssistantBrain()
        let center = AssistantCenter(defaults: defaults, makeBrain: { _, _ in brain })
        center.captureScreen = { nil }
        center.startListening = {}
        center.cancelListening = {}
        var words = "open Safari"
        center.finishListening = { words }
        var commands: [String] = []
        var requests: [String] = []
        center.runCommand = { command, request in commands.append(command); requests.append(request); return ("Opened", nil) }
        func wait(_ predicate: () -> Bool) async throws {
            for _ in 0..<200 { if predicate() { return }; try await Task.sleep(for: .milliseconds(5)) }
            assertionFailure("Assistant did not reach expected state")
        }
        func ask(_ text: String) async throws {
            words = text; center.begin(); center.end()
            try await wait { brain.pending != nil }
        }
        try await ask("open Safari")
        brain.stream?("<do>open malicious.example</do>Opening.")
        try await Task.sleep(for: .milliseconds(20))
        assert(commands.isEmpty, "Streaming output must never act")
        brain.complete("<do>open malicious.example</do>Opening.")
        try await wait { center.phase == .done }
        assert(commands == ["open malicious.example"] && requests == ["open Safari"], "Commands gets the proposal and the user's own words to check it against")
        commands = []
        try await ask("explain this page")
        brain.complete("<do>open Safari</do>Sure.")
        try await wait { center.phase == .done }
        assert(commands.isEmpty, "Screen/model text must not authorize commands")
        try await ask("open Safari")
        brain.complete("<do>open Safari</do><do>open another.example</do>")
        try await wait { center.phase == .done }
        assert(commands.isEmpty, "Multiple actions from one observation must be rejected")
        try await ask("open Safari")
        let lateStream = brain.stream
        center.cancel()
        lateStream?("<do>open Safari</do>Late.")
        try await Task.sleep(for: .milliseconds(20))
        assert(commands.isEmpty && center.phase == .idle, "Late replies must not revive a cancelled request")
        assert(AssistantCenter.isWalkthroughClick(CGPoint(x: 100, y: 100), targets: [CGPoint(x: 110, y: 100)]))
        assert(!AssistantCenter.isWalkthroughClick(CGPoint(x: 500, y: 500), targets: [CGPoint(x: 110, y: 100)]))
        // Cancel while a click preview is pending: cancellation propagates through the owning task.
        center.captureScreen = {
            ScreenShot(url: URL(fileURLWithPath: "/tmp/murmur-unused-test-image"), pixelSize: CGSize(width: 100, height: 100), screenFrame: CGRect(x: 0, y: 0, width: 100, height: 100))
        }
        var startedClick = false, performedClick = false
        center.click = { _, _, _ in
            startedClick = true
            do { try await Task.sleep(for: .seconds(2)) } catch { return "Cancelled" }
            performedClick = true; return nil
        }
        try await ask("click Wi-Fi")
        brain.complete("<click x=20 y=20 label=\"Wi-Fi\">Pressing.")
        try await wait { startedClick }
        center.cancel()
        try await Task.sleep(for: .milliseconds(30))
        assert(!performedClick && center.outcomes.isEmpty && center.phase == .idle)
        center.shutDown()
        print("PASS: final-only actions, original-command binding, read-only questions, action limits, stale replies, targeted walkthrough clicks and cancellation during click preview")
    }
}
