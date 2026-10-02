import Foundation
import AVFoundation
import Speech

@main struct CaptureTests {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Murmur-capture-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1])
        let input = try AVAudioFile(forReading: fixture)
        let transcriber = SpeechTranscriber(locale: Locale(identifier: "en-US"), preset: .transcription)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let target = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber], considering: input.processingFormat)!
        let stream = AsyncStream<AnalyzerInput>.makeStream()
        let results = Task { () throws -> String in
            var text = ""
            for try await result in transcriber.results { if result.isFinal { text += String(result.text.characters) } }
            return text
        }
        let saved = root.appendingPathComponent("early-audio.m4a")
        // A device switch can leave a cached 48-kHz format while the actual mic
        // sends another rate. Both saving and recognition must follow real buffers.
        let cachedFormat = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        assert(cachedFormat.sampleRate != input.processingFormat.sampleRate)
        let pipeline = try AudioPipeline(inputFormat: cachedFormat, audioURL: saved, onMeter: { _ in }, onError: { error in assertionFailure(error.localizedDescription) })
        // Capture the entire utterance BEFORE a recognition engine exists.
        while input.framePosition < input.length {
            let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 2048)!
            try input.read(into: buffer); pipeline.append(buffer)
        }
        try await analyzer.prepareToAnalyze(in: target)
        try await analyzer.start(inputSequence: stream.stream)
        try await pipeline.attach(target: target, stream: stream.continuation)
        let signal = await pipeline.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        let text = try await results.value
        assert(text.lowercased().hasPrefix("the quick brown fox"), "First words were lost: \(text)")
        assert(text.localizedCaseInsensitiveContains("local speech recognition"), "Last words were lost")
        let recording = try AVAudioFile(forReading: saved)
        assert(recording.processingFormat.sampleRate == input.processingFormat.sampleRate, "Saved audio used a stale device format")
        assert(abs(Double(recording.length) / recording.processingFormat.sampleRate - Double(input.length) / input.processingFormat.sampleRate) < 0.15)
        assert(signal.hasFrames && signal.audibleSeconds > 1)
        let converted = root.appendingPathComponent("converted.wav")
        try AudioFileConversion.writeWave(saved, to: converted)
        let wave = try AVAudioFile(forReading: converted)
        assert(wave.processingFormat.sampleRate == 16000 && wave.processingFormat.channelCount == 1)
        assert(abs(Double(wave.length) / 16000 - signal.seconds) < 0.15)
        // A tap callback queued around release cannot append to a sealed session,
        // and a delayed preview cannot reopen it after final transcription starts.
        let trailing = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 2048)!
        trailing.frameLength = 2048
        pipeline.append(trailing)
        let sealedSignal = await pipeline.finish()
        assert(sealedSignal.seconds == signal.seconds)
        let lateStream = AsyncStream<AnalyzerInput>.makeStream()
        do {
            try await pipeline.attach(target: target, stream: lateStream.continuation)
            assertionFailure("Late recognition reopened a stopped recording")
        } catch DictationError.cancelled { }
        var quiet = InputSignal(); quiet.seconds = 10; quiet.audibleSeconds = 0.2
        assert(TranscriptionReview.reason(text: "Huh.", confidence: 0.44, signal: quiet) != nil)
        assert(TranscriptionReview.reason(text: "Hello.", confidence: 0.9, signal: quiet) == nil)
        assert(TranscriptionReview.reason(text: "Hello.", confidence: 0.44, signal: signal) == nil)
        assert(SpeechVocabulary.terms("mer mer => Murmur\nFigma\nfig ma => Figma") == ["Murmur", "Figma"])
        let devices = Microphones.devices()
        assert(Set(devices.map(\.id)).count == devices.count)
        print("PASS: stale startup format and delayed recognition preserve first/last words, full saved audio, 16-kHz conversion, signal metering, cautious review, vocabulary and microphone discovery")
        print("TRANSCRIPT: \(text)")
        print("MICROPHONES: \(devices.map(\.name))")
    }
}
