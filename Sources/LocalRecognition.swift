import Foundation
import AVFoundation

enum RecognitionEngine: String, CaseIterable {
    case apple = "Apple", parakeet = "Parakeet", whisper = "Whisper"
    var subtitle: String {
        switch self {
        case .apple: return "Live transcription using Apple’s on-device model."
        case .parakeet: return "Apple live preview, then Parakeet checks the complete recording locally."
        case .whisper: return "Apple live preview, then Whisper checks the complete recording locally."
        }
    }
}
struct RecognitionResult { let text: String; let confidence: Float? }
enum TranscriptionReview {
    static func reason(text: String, confidence: Float?, signal: InputSignal) -> String? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        // Engine scores are not calibrated accuracy percentages. Require weak audio as well.
        if text.split(whereSeparator: { $0.isWhitespace }).count <= 4,
           let confidence, confidence < 0.55, signal.hasFrames, signal.audibleSeconds < 0.75 {
            return "The microphone captured very little sound, and the recognizer was uncertain. Replay this recording before using its text."
        }
        return nil
    }
}
enum LocalSpeechError: LocalizedError {
    case unavailable(String), failed(String), timeout
    var errorDescription: String? {
        switch self {
        case .unavailable(let message), .failed(let message): return message
        case .timeout: return "Local transcription took too long. Your audio was kept; retry it from the library."
        }
    }
}

@MainActor final class ParakeetWorker {
    private var process: Process?
    private var input: Pipe?
    private var output: Pipe?
    private var errorPipe: Pipe?
    private var buffer = Data()
    private var ready: [CheckedContinuation<Void, Error>] = []
    private var waiting: [String: CheckedContinuation<RecognitionResult, Error>] = [:]
    var isReady = false
    private var session = UUID()
    private var startupDeadline: Task<Void, Never>?
    var startupTimeout: Duration = .seconds(60)
    var onProgress: ((Double) -> Void)?
    static var modelRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Murmur/Models/parakeet-tdt-0.6b-v3-coreml", isDirectory: true)
    }
    func start(install: Bool = false) async throws {
        if isReady, process?.isRunning == true { return }
        if process != nil {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in ready.append(continuation) }
            return
        }
        guard let resources = Bundle.main.resourceURL else { throw LocalSpeechError.unavailable("Murmur’s local speech helper is missing.") }
        let binary = resources.appendingPathComponent("Helpers/MurmurParakeet")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else { throw LocalSpeechError.unavailable("This build doesn’t include Parakeet’s speech helper.") }
        let task = Process(); let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        task.executableURL = binary; task.arguments = [Self.modelRoot.path] + (install ? ["--install"] : [])
        task.standardInput = stdin; task.standardOutput = stdout; task.standardError = stderr
        process = task; input = stdin; output = stdout; errorPipe = stderr; buffer = Data()
        session = UUID(); let current = session
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor in if self?.session == current { self?.receive(data) } }
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in _ = handle.availableData }
        task.terminationHandler = { [weak self] _ in
            Task { @MainActor in if self?.session == current { self?.fail(LocalSpeechError.failed("Parakeet stopped. Your recording was kept; try again.")) } }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            ready.append(continuation)
            do {
                try task.run()
                let timeout = install ? Duration.seconds(300) : startupTimeout
                startupDeadline = Task { [weak self] in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    guard let self, self.session == current, !self.isReady else { return }
                    self.fail(LocalSpeechError.timeout)
                }
            } catch { fail(error) }
        }
    }
    private func receive(_ data: Data) {
        guard !data.isEmpty else { return }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 10) {
            let line = buffer[..<newline]; buffer.removeSubrange(...newline)
            guard let message = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any], let type = message["type"] as? String else { continue }
            if type == "progress" { onProgress?(message["fraction"] as? Double ?? 0) }
            else if type == "ready" {
                startupDeadline?.cancel(); startupDeadline = nil
                isReady = true; let continuations = ready; ready.removeAll(); continuations.forEach { $0.resume() }
            }
            else if let id = message["id"] as? String, let continuation = waiting.removeValue(forKey: id) {
                if type == "result" { continuation.resume(returning: RecognitionResult(text: message["text"] as? String ?? "", confidence: (message["confidence"] as? NSNumber)?.floatValue)) }
                else { continuation.resume(throwing: LocalSpeechError.failed(message["message"] as? String ?? "Local transcription failed.")) }
            } else if type == "error" { fail(LocalSpeechError.failed(message["message"] as? String ?? "Parakeet couldn’t start.")) }
        }
    }
    func transcribe(_ url: URL) async throws -> RecognitionResult {
        try await start()
        let id = UUID().uuidString
        return try await withCheckedThrowingContinuation { continuation in
            waiting[id] = continuation
            do {
                var data = try JSONSerialization.data(withJSONObject: ["id": id, "path": url.path]); data.append(10)
                try input?.fileHandleForWriting.write(contentsOf: data)
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(120))
                    if self?.waiting[id] != nil { self?.fail(LocalSpeechError.timeout) }
                }
            } catch { waiting.removeValue(forKey: id)?.resume(throwing: error) }
        }
    }
    func stop() { fail(LocalSpeechError.failed("Local transcription was stopped.")) }
    private func fail(_ error: Error) {
        startupDeadline?.cancel(); startupDeadline = nil
        isReady = false
        session = UUID()
        let starts = ready; ready.removeAll(); starts.forEach { $0.resume(throwing: error) }
        let requests = waiting; waiting.removeAll()
        for continuation in requests.values { continuation.resume(throwing: error) }
        output?.fileHandleForReading.readabilityHandler = nil; errorPipe?.fileHandleForReading.readabilityHandler = nil
        try? input?.fileHandleForWriting.close()
        let previous = process; process = nil; input = nil; output = nil; errorPipe = nil
        previous?.terminationHandler = nil
        if previous?.isRunning == true { previous?.terminate() }
    }
}

enum SpeechVocabulary {
    static func terms(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.components(separatedBy: .newlines).compactMap { line in
            let value = line.components(separatedBy: "=>").last!.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, value.count <= 80, seen.insert(value.lowercased()).inserted else { return nil }
            return value
        }.prefix(64).map { $0 }
    }
}

@MainActor final class LocalRecognition {
    let parakeet = ParakeetWorker()
    func transcribe(_ url: URL, engine: RecognitionEngine, locale: String, vocabulary: String) async throws -> RecognitionResult {
        if engine == .parakeet {
            let supported = ["bg", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "de", "el", "hu", "it", "lv", "lt", "mt", "pl", "pt", "ro", "sk", "sl", "es", "sv", "ru", "uk"]
            guard supported.contains(String(locale.prefix(2))) else { throw LocalSpeechError.unavailable("Parakeet doesn’t support this language. Choose Apple or Whisper in settings.") }
            return try await parakeet.transcribe(url)
        }
        guard engine == .whisper, let resources = Bundle.main.resourceURL else { throw LocalSpeechError.unavailable("Choose an available local speech engine.") }
        let binary = resources.appendingPathComponent("Helpers/whisper-cli")
        let model = resources.appendingPathComponent("Models/ggml-large-v3-turbo-q5_0.bin")
        guard FileManager.default.isExecutableFile(atPath: binary.path), FileManager.default.fileExists(atPath: model.path) else { throw LocalSpeechError.unavailable("Whisper’s local model is missing from this build.") }
        let terms = SpeechVocabulary.terms(vocabulary)
        return try await Task.detached(priority: .userInitiated) {
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent("Murmur-whisper-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: temp) }
            let wave = temp.appendingPathComponent("input.wav"), result = temp.appendingPathComponent("result")
            try AudioFileConversion.writeWave(url, to: wave)
            let task = Process(); task.executableURL = binary
            task.arguments = ["-m", model.path, "-f", wave.path, "-l", String(locale.prefix(2)), "-ojf", "-of", result.path, "-np", "-nt", "-t", "4", "-bs", "5"]
            if !terms.isEmpty { task.arguments! += ["--prompt", "Vocabulary: " + terms.joined(separator: ", ")] }
            let logURL = temp.appendingPathComponent("recognition.log")
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
            let log = try FileHandle(forWritingTo: logURL); defer { try? log.close() }
            task.standardOutput = log; task.standardError = log
            try task.run()
            let deadline = Date().addingTimeInterval(180)
            while task.isRunning, Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
            if task.isRunning { task.terminate(); throw LocalSpeechError.timeout }
            guard task.terminationStatus == 0 else { throw LocalSpeechError.failed("Whisper couldn’t transcribe this recording. Your audio was kept.") }
            let data = try Data(contentsOf: result.appendingPathExtension("json"))
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let segments = json?["transcription"] as? [[String: Any]] ?? []
            let text = segments.compactMap { $0["text"] as? String }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
            let probabilities = segments.flatMap { $0["tokens"] as? [[String: Any]] ?? [] }.compactMap { token -> Float? in
                guard let tokenText = token["text"] as? String, !tokenText.hasPrefix("[_") else { return nil }
                return (token["p"] as? NSNumber)?.floatValue
            }
            return RecognitionResult(text: text, confidence: probabilities.isEmpty ? nil : probabilities.reduce(0, +) / Float(probabilities.count))
        }.value
    }
}

enum AudioFileConversion {
    static func signal(_ source: URL) throws -> InputSignal {
        let input = try AVAudioFile(forReading: source)
        var result = InputSignal()
        while input.framePosition < input.length {
            let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 4096)!
            try input.read(into: buffer); result.observe(buffer)
        }
        return result
    }
    static func writeWave(_ source: URL, to destination: URL) throws {
        let input = try AVAudioFile(forReading: source)
        let target = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        guard let converter = AVAudioConverter(from: input.processingFormat, to: target) else { throw DictationError.conversion }
        converter.primeMethod = .none
        let output = try AVAudioFile(forWriting: destination, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false], commonFormat: .pcmFormatFloat32, interleaved: false)
        while input.framePosition < input.length {
            let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 4096)!
            try input.read(into: buffer)
            let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(ceil(Double(buffer.frameLength) * 16000 / input.processingFormat.sampleRate)) + 64)!
            var supplied = false; var error: NSError?
            let status = converter.convert(to: converted, error: &error) { _, state in
                if supplied { state.pointee = .noDataNow; return nil }; supplied = true; state.pointee = .haveData; return buffer
            }
            if let error { throw error }; if status == .error { throw DictationError.conversion }
            if converted.frameLength > 0 { try output.write(from: converted) }
        }
    }
}
