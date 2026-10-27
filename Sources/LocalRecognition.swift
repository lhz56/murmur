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
    private var ready: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var waiting: [String: CheckedContinuation<RecognitionResult, Error>] = [:]
    private var requestDeadlines: [String: Task<Void, Never>] = [:]
    var isReady = false
    private var session = UUID()
    private var startupDeadline: Task<Void, Never>?
    var startupTimeout: Duration = .seconds(60)
    var requestTimeout: Duration = .seconds(120)
    var onProgress: ((Double) -> Void)?
    var onReadiness: ((Bool) -> Void)?
    private let executable: URL?
    private let modelDirectory: URL?
    init(executable: URL? = nil, modelDirectory: URL? = nil) {
        self.executable = executable; self.modelDirectory = modelDirectory
    }
    static var modelRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Murmur/Models/parakeet-tdt-0.6b-v3-coreml", isDirectory: true)
    }
    func start(install: Bool = false) async throws {
        try Task.checkCancellation()
        if isReady, process?.isRunning == true { return }
        let waiter = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                ready[waiter] = continuation
                if process != nil { return }
                do { try launch(install: install) } catch { fail(error) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.ready.removeValue(forKey: waiter)?.resume(throwing: CancellationError()) }
        }
    }

    private func launch(install: Bool) throws {
        guard let binary = executable ?? Bundle.main.resourceURL?.appendingPathComponent("Helpers/MurmurParakeet"),
              FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw LocalSpeechError.unavailable("This build doesn’t include Parakeet’s speech helper.")
        }
        let task = Process(); let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        task.executableURL = binary; task.arguments = [(modelDirectory ?? Self.modelRoot).path] + (install ? ["--install"] : [])
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
        try task.run()
        let timeout = install ? Duration.seconds(300) : startupTimeout
        startupDeadline = Task { [weak self] in
            do { try await Task.sleep(for: timeout) } catch { return }
            guard let self, self.session == current, !self.isReady else { return }
            self.fail(LocalSpeechError.timeout)
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
                isReady = true; onReadiness?(true)
                let continuations = ready; ready.removeAll(); continuations.values.forEach { $0.resume() }
            }
            else if let id = message["id"] as? String {
                // A cancelled request can finish later. Its result or error must
                // not terminate the shared worker or another pending request.
                guard let continuation = waiting.removeValue(forKey: id) else { continue }
                requestDeadlines.removeValue(forKey: id)?.cancel()
                if type == "result" { continuation.resume(returning: RecognitionResult(text: message["text"] as? String ?? "", confidence: (message["confidence"] as? NSNumber)?.floatValue)) }
                else { continuation.resume(throwing: LocalSpeechError.failed(message["message"] as? String ?? "Local transcription failed.")) }
            } else if type == "error" { fail(LocalSpeechError.failed(message["message"] as? String ?? "Parakeet couldn’t start.")) }
        }
    }
    func transcribe(_ url: URL) async throws -> RecognitionResult {
        try await start()
        try Task.checkCancellation()
        let id = UUID().uuidString
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                waiting[id] = continuation
                do {
                    guard let input else { throw LocalSpeechError.failed("Local transcription was stopped.") }
                    var data = try JSONSerialization.data(withJSONObject: ["id": id, "path": url.path]); data.append(10)
                    try input.fileHandleForWriting.write(contentsOf: data)
                    let timeout = requestTimeout
                    requestDeadlines[id] = Task { [weak self] in
                        do { try await Task.sleep(for: timeout) } catch { return }
                        if self?.waiting[id] != nil { self?.fail(LocalSpeechError.timeout) }
                    }
                } catch { waiting.removeValue(forKey: id)?.resume(throwing: error) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.requestDeadlines.removeValue(forKey: id)?.cancel()
                self?.waiting.removeValue(forKey: id)?.resume(throwing: CancellationError())
            }
        }
    }
    func stop() { fail(LocalSpeechError.failed("Local transcription was stopped.")) }
    private func fail(_ error: Error) {
        startupDeadline?.cancel(); startupDeadline = nil
        isReady = false
        onReadiness?(false)
        session = UUID()
        let starts = ready; ready.removeAll(); starts.values.forEach { $0.resume(throwing: error) }
        requestDeadlines.values.forEach { $0.cancel() }; requestDeadlines.removeAll()
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
        let recognition = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent("Murmur-whisper-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: temp) }
            let wave = temp.appendingPathComponent("input.wav"), result = temp.appendingPathComponent("result")
            try AudioFileConversion.writeWave(url, to: wave)
            let task = Process(); task.executableURL = binary
            task.arguments = ["-m", model.path, "-f", wave.path, "-l", String(locale.prefix(2)), "-ojf", "-of", result.path,
                              "-np", "-nt", "-t", String(WhisperThreads.count), "-bs", "5"]
            if !terms.isEmpty { task.arguments! += ["--prompt", "Vocabulary: " + terms.joined(separator: ", ")] }
            let logURL = temp.appendingPathComponent("recognition.log")
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
            let log = try FileHandle(forWritingTo: logURL); defer { try? log.close() }
            task.standardOutput = log; task.standardError = log
            // Resume the moment the helper exits instead of polling for it.
            let exited = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
            task.terminationHandler = { _ in exited.continuation.yield(()); exited.continuation.finish() }
            try task.run()
            defer { if task.isRunning { task.terminate() } }
            let finished = try await withThrowingTaskGroup(of: Bool.self) { group in
                group.addTask { for await _ in exited.stream { return true }; return true }
                group.addTask { try await Task.sleep(for: .seconds(180)); return false }
                defer { group.cancelAll() }
                return try await group.next() ?? false
            }
            try Task.checkCancellation()
            if !finished || task.isRunning { task.terminate(); throw LocalSpeechError.timeout }
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
        }
        return try await withTaskCancellationHandler { try await recognition.value } onCancel: { recognition.cancel() }
    }
}

enum AudioFileConversion {
    static func signal(_ source: URL) throws -> InputSignal {
        let input = try AVAudioFile(forReading: source)
        var result = InputSignal()
        while input.framePosition < input.length {
            try Task.checkCancellation()
            let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 4096)!
            try input.read(into: buffer)
            guard buffer.frameLength > 0 else { break }
            result.observe(buffer)
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
            try Task.checkCancellation()
            let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 4096)!
            try input.read(into: buffer)
            guard buffer.frameLength > 0 else { break }
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

enum WhisperThreads {
    /// whisper.cpp scales with performance cores; efficiency cores slow it down.
    static let count: Int = {
        var cores: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.perflevel0.physicalcpu", &cores, &size, nil, 0) == 0, cores > 0 {
            return min(max(Int(cores), 4), 12)
        }
        return min(max(ProcessInfo.processInfo.activeProcessorCount / 2, 4), 8)
    }()
}
