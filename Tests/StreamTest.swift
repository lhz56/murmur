import Foundation
import Speech
import AVFoundation

@main struct StreamTest {
    @MainActor static func main() async throws {
        let input = try AVAudioFile(forReading: URL(fileURLWithPath: CommandLine.arguments[1]))
        let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
        let transcriber = SpeechTranscriber(locale: Locale(identifier: "en-US"), preset: .transcription)
        try await AssetInventory.reserve(locale: Locale(identifier: "en-US"))
        let target = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber], considering: input.processingFormat)!
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let stream = AsyncStream<AnalyzerInput>.makeStream()
        let results = Task { () throws -> String in
            var transcript = ""
            for try await result in transcriber.results { transcript += String(result.text.characters) }
            return transcript
        }
        try await analyzer.prepareToAnalyze(in: target)
        try await analyzer.start(inputSequence: stream.stream)
        var meters = 0
        var error: Error?
        let pipeline = try AudioPipeline(inputFormat: input.processingFormat, targetFormat: target, audioURL: outputURL,
                                         continuation: stream.continuation, onMeter: { _ in meters += 1 }, onError: { error = $0 })
        while input.framePosition < input.length {
            let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 2048)!
            try input.read(into: buffer)
            pipeline.append(buffer)
        }
        await pipeline.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        let text = try await results.value
        if let error { throw error }
        let output = try AVAudioFile(forReading: outputURL)
        let inputDuration = Double(input.length) / input.processingFormat.sampleRate
        let outputDuration = Double(output.length) / output.processingFormat.sampleRate
        assert(abs(inputDuration - outputDuration) < 0.2)
        assert(text.localizedCaseInsensitiveContains("quick brown fox"))
        assert(meters > 0)
        print("TRANSCRIPT: \(text)")
        print("PASS: realtime buffer copy, AAC recording, sample-rate conversion, metering, streaming transcription, finalization; duration=\(outputDuration)")
    }
}
