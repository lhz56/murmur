import Foundation
@main struct VoiceFailureTests {
    @MainActor static func main() async throws {
        NaturalVoice.helperOverride = URL(fileURLWithPath: CommandLine.arguments[1])
        defer { NaturalVoice.helperOverride = nil }
        let voice = NaturalVoice()
        var fallback: [String] = []
        voice.onFailure = { fallback.append($0) }
        assert(voice.speak("Keep this sentence."))
        for _ in 0..<200 {
            if !fallback.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        assert(fallback == ["Keep this sentence."] && !voice.isSpeaking)
        assert(voice.speak("Cancelled speech."))
        voice.stop()
        try await Task.sleep(for: .milliseconds(100))
        assert(fallback == ["Keep this sentence."] && !voice.isSpeaking, "Late failure must not speak cancelled text")
        voice.shutDown()
        print("PASS: natural voice failure preserves speech for fallback; cancellation suppresses late speech")
    }
}
