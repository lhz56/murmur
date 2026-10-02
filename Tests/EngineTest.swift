import Foundation
import Speech

@main struct EngineTest {
    @MainActor static func main() async {
        print("Available: \(SpeechTranscriber.isAvailable)")
        print("Installed locales: \(await SpeechTranscriber.installedLocales.map(\.identifier))")
        guard CommandLine.arguments.count > 1 else { return }
        let engine = DictationEngine()
        do {
            let text = try await engine.transcribeFile(URL(fileURLWithPath: CommandLine.arguments[1]), localeID: "en-US")
            print("TRANSCRIPT: \(text)")
            guard text.localizedCaseInsensitiveContains("quick brown fox"), text.localizedCaseInsensitiveContains("Murmur") else {
                print("FAIL: fixture transcript missing expected words"); exit(1)
            }
            print("PASS: on-device audio-file transcription and finalization")
        } catch { print("FAIL: \(error.localizedDescription)"); exit(1) }
    }
}
