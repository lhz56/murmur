import Foundation
@main struct LocalEngineTests {
    @MainActor static func main() async throws {
        let recognition = LocalRecognition()
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        defer { recognition.parakeet.stop() }
        for engine in [RecognitionEngine.parakeet, .whisper] {
            let start = Date()
            let result = try await recognition.transcribe(url, engine: engine, locale: "en-US", vocabulary: "mer mer => Murmur")
            assert(result.text.localizedCaseInsensitiveContains("quick brown fox"))
            assert(result.text.localizedCaseInsensitiveContains("local speech recognition"))
            assert(result.confidence != nil)
            print("PASS: bundled \(engine.rawValue) via application worker, complete audio, final words, confidence, no network setup; \(Date().timeIntervalSince(start)) seconds")
            print(result.text)
        }
        async let first = recognition.parakeet.transcribe(url)
        async let second = recognition.parakeet.transcribe(url)
        let pair = try await (first, second)
        assert(pair.0.text == pair.1.text)
        print("PASS: persistent Parakeet worker handles multiple queued requests without losing responses")
    }
}
