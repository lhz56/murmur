import AVFoundation
import Speech
import Combine
import OSLog
import os

enum RecordingPhase: Equatable {
    case idle, preparing, downloading, recording, finishing
    var isBusy: Bool { self != .idle }
    var label: String {
        switch self {
        case .idle: return "Ready when you are"
        case .preparing: return "Getting ready…"
        case .downloading: return "Downloading speech model…"
        case .recording: return "Listening"
        case .finishing: return "Wrapping up…"
        }
    }
}

enum DictationError: LocalizedError {
    case microphone, noInput, missingMicrophone, unsupportedLanguage, unavailable, conversion, cancelled, setupDelay
    var errorDescription: String? {
        switch self {
        case .microphone: return "Murmur needs microphone access. Enable it in System Settings → Privacy & Security → Microphone, then try again."
        case .noInput: return "The microphone didn’t send audio. Check the selected input with Make it yours → Test microphone, then try again."
        case .missingMicrophone: return "Your selected microphone is disconnected. Choose an available microphone in Murmur’s settings."
        case .unsupportedLanguage: return "Apple’s on-device engine doesn’t support this language yet. Choose a different language in Murmur’s settings."
        case .unavailable: return "On-device speech isn’t available on this Mac. Murmur requires an Apple silicon Mac with macOS 26 or later."
        case .conversion: return "The microphone’s audio couldn’t be converted. Try a different input in System Settings → Sound. Your recording has been kept."
        case .cancelled: return "Setup was cancelled."
        case .setupDelay: return "Speech setup took too long. Your audio was kept; retry transcription from the library after the model is ready."
        }
    }
}

/// One notification from the first copied buffer, independent of file I/O and
/// meter throttling. Finishing or cancellation cannot reopen the stream.
final class FirstAudioBuffer: @unchecked Sendable {
    private let first = OSAllocatedUnfairLock(initialState: false)
    private let channel = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))

    func receive() {
        let notify = first.withLock { sent in
            if sent { return false }
            sent = true
            return true
        }
        if notify { channel.continuation.yield(()); channel.continuation.finish() }
    }
    func finish() { channel.continuation.finish() }

    func wait(timeout: Duration = .seconds(3)) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { [self] in
                var iterator = channel.stream.makeAsyncIterator()
                guard await iterator.next() != nil else {
                    try Task.checkCancellation()
                    throw DictationError.cancelled
                }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw DictationError.noInput
            }
            defer { group.cancelAll() }
            try await group.next()
        }
    }
}

/// Copies the realtime microphone buffer, then does disk I/O and conversion off the audio thread.
final class AudioPipeline: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.murmur.audio", qos: .userInitiated)
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var pending: [AVAudioPCMBuffer] = []
    private var pendingSeconds: Double = 0
    private var buffering = true
    private var signal = InputSignal()
    private var file: AVAudioFile?
    private let audioURL: URL
    private let expectedInputFormat: AVAudioFormat
    private var lastMeterTime: TimeInterval = 0
    private var failed = false
    private var finished = false
    let onMeter: (Float) -> Void
    let onError: (Error) -> Void
    private let onPreviewError: (Error) -> Void
    var onSignal: ((InputSignal) -> Void)?
    let firstAudio = FirstAudioBuffer()

    convenience init(inputFormat: AVAudioFormat, targetFormat: AVAudioFormat, audioURL: URL,
         continuation: AsyncStream<AnalyzerInput>.Continuation,
         onMeter: @escaping (Float) -> Void, onError: @escaping (Error) -> Void) throws {
        try self.init(inputFormat: inputFormat, audioURL: audioURL, onMeter: onMeter, onError: onError)
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else { throw DictationError.conversion }
        self.converter = converter
        self.targetFormat = targetFormat
        self.continuation = continuation
    }

    init(inputFormat: AVAudioFormat, audioURL: URL, onMeter: @escaping (Float) -> Void, onError: @escaping (Error) -> Void,
         onPreviewError: ((Error) -> Void)? = nil) throws {
        self.onMeter = onMeter; self.onError = onError
        self.onPreviewError = onPreviewError ?? onError
        self.audioURL = audioURL; self.expectedInputFormat = inputFormat
    }

    private func openFile(_ format: AVAudioFormat) throws {
        file = try AVAudioFile(forWriting: audioURL, settings: [
            AVFormatIDKey: kAudioFormatAppleLossless,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVEncoderBitDepthHintKey: 16
        ], commonFormat: format.commonFormat, interleaved: format.isInterleaved)
    }

    /// Capture starts first. Replay every early buffer in order when the model becomes ready.
    func attach(target: AVAudioFormat, stream: AsyncStream<AnalyzerInput>.Continuation) async throws {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do {
                    guard !finished else { throw DictationError.cancelled }
                    let first = pending.first?.format ?? file?.processingFormat ?? expectedInputFormat
                    guard let created = AVAudioConverter(from: first, to: target) else { throw DictationError.conversion }
                    created.primeMethod = .none
                    converter = created; targetFormat = target; continuation = stream
                    for buffer in pending { try convert(buffer) }
                    pending.removeAll(); pendingSeconds = 0; buffering = false
                    done.resume()
                } catch { done.resume(throwing: error) }
            }
        }
    }

    func discardPreviewBuffers() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.async { [self] in disablePreview(); done.resume() }
        }
    }

    private func disablePreview() {
        continuation?.finish(); continuation = nil
        converter = nil; targetFormat = nil
        pending.removeAll(); pendingSeconds = 0; buffering = false
    }

    private func convert(_ copy: AVAudioPCMBuffer) throws {
        guard let targetFormat, let continuation else { return }
        if converter?.inputFormat != copy.format {
            guard let replacement = AVAudioConverter(from: copy.format, to: targetFormat) else { throw DictationError.conversion }
            replacement.primeMethod = .none; converter = replacement
        }
        guard let converter else { throw DictationError.conversion }
        let capacity = AVAudioFrameCount(ceil(Double(copy.frameLength) * targetFormat.sampleRate / copy.format.sampleRate)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { throw DictationError.conversion }
        var conversionError: NSError?; var supplied = false
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if supplied { inputStatus.pointee = .noDataNow; return nil }
            supplied = true; inputStatus.pointee = .haveData; return copy
        }
        if let conversionError { throw conversionError }
        if status == .error { throw DictationError.conversion }
        if output.frameLength > 0 { continuation.yield(AnalyzerInput(buffer: output)) }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0,
              let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return }
        copy.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for index in 0..<source.count {
            if let src = source[index].mData, let dst = destination[index].mData {
                memcpy(dst, src, Int(source[index].mDataByteSize))
            }
        }
        firstAudio.receive()
        queue.async { [self] in
            guard !failed, !finished else { return }
            do {
                if file == nil { try openFile(copy.format) }
                try file?.write(from: copy)
                do {
                    if converter != nil { try convert(copy) }
                    else if buffering {
                        pendingSeconds += Double(copy.frameLength) / copy.format.sampleRate
                        if pendingSeconds > 120 { throw DictationError.setupDelay }
                        pending.append(copy)
                    }
                } catch {
                    // Losing an optional live preview must never seal the saved
                    // microphone audio needed by the final local recognizer.
                    disablePreview()
                    DispatchQueue.main.async { self.onPreviewError(error) }
                }
                signal.observe(copy)
                let now = Date.timeIntervalSinceReferenceDate
                if now - lastMeterTime > 0.055 {
                    let value = signal
                    lastMeterTime = now
                    DispatchQueue.main.async { self.onMeter(value.level); self.onSignal?(value) }
                }
            } catch {
                failed = true
                DispatchQueue.main.async { self.onError(error) }
            }
        }
    }

    @discardableResult func finish() async -> InputSignal {
        firstAudio.finish()
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                file = nil // Flush the lossless container before saved audio can be played.
                continuation?.finish()
                continuation = nil; converter = nil; targetFormat = nil
                finished = true; buffering = false
                pending.removeAll()
                done.resume()
            }
        }
        return signal
    }
}

@MainActor
final class DictationEngine: ObservableObject {
    @Published var phase: RecordingPhase = .idle
    @Published var liveText = ""
    @Published var level: Float = 0
    @Published var elapsed: TimeInterval = 0
    @Published var downloadProgress: Double = 0
    @Published var supportedLanguages: [Locale] = []
    @Published var inputName = ""
    @Published var signal = InputSignal()
    @Published var recognitionPreparing = false
    @Published var confidence: Float?
    var onText: ((String) -> Void)?
    var onError: ((Error) -> Void)?
    var clockLabel: String { String(format: "%d:%02d", Int(elapsed) / 60, Int(elapsed) % 60) }

    private var engine: AVAudioEngine?
    private var preparedEngine: AVAudioEngine?
    private var preparedDevice: Microphone?
    private var inputPreparation: Task<AVAudioEngine, Error>?
    private var preparingDevice: Microphone?
    private var inputPreparationID: UUID?
    private var selectedMicrophoneUID = ""
    private var pipeline: AudioPipeline?
    private var analyzer: SpeechAnalyzer?
    private var resultsTask: Task<Void, Error>?
    private var clock: Timer?
    private var progressTimer: Timer?
    private var finalized = ""
    private var volatile = ""
    private var startedAt: Date?
    private var generation = UUID()
    private var tapInstalled = false
    private var setupTask: Task<Void, Error>?
    private var recordedURL: URL?
    /// The engine finishing the current job; Apple when the chosen one isn't installed.
    private(set) var selectedEngine: RecognitionEngine = .apple
    private var selectedLocale = "en-US"
    private var selectedVocabulary = ""
    /// Terms gathered from the screen and past corrections for this recording.
    private(set) var contextTerms: [String] = []
    /// Words the last final pass swapped in from the vocabulary or context.
    private(set) var boostedWords: [String] = []
    private var stopRequested = false
    private var captureError: Error?
    private let timingLog = Logger(subsystem: "app.murmur.mac", category: "Timing")
    let localSpeech = LocalRecognition()
    private let authorizeMicrophone: () async -> Bool
    var finalizationTimeout: Duration = .seconds(30)
    var fileRecognitionTimeout: Duration = .seconds(180)

    init(authorizeMicrophone: @escaping () async -> Bool = {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized ? true :
            await AVCaptureDevice.requestAccess(for: .audio)
    }) {
        self.authorizeMicrophone = authorizeMicrophone
    }

    private func preparedInput(uid: String) async throws -> AVAudioEngine {
        let device = try Microphones.selected(uid: uid)
        if preparedDevice == device, let preparedEngine, Microphones.isConfigured(preparedEngine, for: device) {
            return preparedEngine
        }
        preparedEngine = nil; preparedDevice = nil
        let task: Task<AVAudioEngine, Error>
        let preparationID: UUID
        if preparingDevice == device, let pending = inputPreparation, let pendingID = inputPreparationID {
            task = pending; preparationID = pendingID
        } else {
            inputPreparation?.cancel()
            preparationID = UUID()
            task = Task { @MainActor in
                let audio = AVAudioEngine()
                _ = try await Microphones.configure(audio, uid: device.id)
                try Task.checkCancellation()
                audio.prepare()
                return audio
            }
            inputPreparation = task; preparingDevice = device; inputPreparationID = preparationID
        }
        do {
            let audio = try await task.value
            // Shared waiters cannot reinstall a graph after recording consumes it.
            if inputPreparationID == preparationID {
                preparedEngine = audio; preparedDevice = device
                inputPreparation = nil; preparingDevice = nil; inputPreparationID = nil
            }
            return audio
        } catch {
            if inputPreparationID == preparationID {
                inputPreparation = nil; preparingDevice = nil; inputPreparationID = nil
            }
            throw error
        }
    }

    private func takePreparedInput(uid: String) async throws -> AVAudioEngine {
        let audio = try await preparedInput(uid: uid)
        try Task.checkCancellation()
        if preparedEngine === audio { preparedEngine = nil; preparedDevice = nil }
        return audio
    }

    private func discardPreparedInput() {
        cancelInputPreparation()
        preparedEngine = nil; preparedDevice = nil
    }

    private func cancelInputPreparation() {
        inputPreparation?.cancel()
        inputPreparation = nil; preparingDevice = nil; inputPreparationID = nil
    }

    func warmMicrophone(uid: String) async {
        guard (phase == .idle || phase == .finishing), engine == nil,
              AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }
        if let audio = try? await preparedInput(uid: uid), engine == nil,
           phase == .idle || phase == .finishing, preparedEngine === audio {
            audio.prepare()
        }
    }

    func refreshLanguages() async {
        supportedLanguages = await SpeechTranscriber.supportedLocales.sorted { $0.identifier < $1.identifier }
    }

    private func checkSession(_ session: UUID) throws {
        try Task.checkCancellation()
        guard generation == session else { throw DictationError.cancelled }
    }

    private func makeTranscriber(localeID: String, session: UUID) async throws -> SpeechTranscriber {
        guard SpeechTranscriber.isAvailable else { throw DictationError.unavailable }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: localeID)) else {
            throw DictationError.unsupportedLanguage
        }
        try checkSession(session)
        // Keep live provisional text without fastResults, which trades away recognition accuracy.
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                            reportingOptions: [.volatileResults], attributeOptions: [.transcriptionConfidence])
        try checkSession(session)
        try await AssetInventory.reserve(locale: locale)
        try checkSession(session)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try checkSession(session)
            if phase != .recording && phase != .finishing { phase = .downloading }
            downloadProgress = 0
            let timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard self?.generation == session else { return }
                    self?.downloadProgress = request.progress.fractionCompleted
                }
            }
            progressTimer = timer
            defer { timer.invalidate(); if progressTimer === timer { progressTimer = nil } }
            try await request.downloadAndInstall()
            try checkSession(session)
        }
        return transcriber
    }

    func start(audioURL: URL, localeID: String, microphoneUID: String = "", recognitionEngine: RecognitionEngine = .apple, vocabulary: String = "") async throws {
        guard phase == .idle else { return }
        phase = .preparing
        // A missing helper or model must not fail every dictation: finish with
        // Apple's on-device result, which the live preview already provides.
        let recognitionEngine = localSpeech.isInstalled(recognitionEngine) ? recognitionEngine : .apple
        let requestedAt = ProcessInfo.processInfo.systemUptime
        generation = UUID()
        let session = generation
        finalized = ""; volatile = ""; liveText = ""; elapsed = 0; level = 0
        signal = InputSignal(); confidence = nil
        stopRequested = false
        captureError = nil
        recordedURL = audioURL; selectedEngine = recognitionEngine; selectedLocale = localeID; selectedVocabulary = vocabulary
        boostedWords = []
        selectedMicrophoneUID = microphoneUID
        do {
            let granted = await authorizeMicrophone()
            try Task.checkCancellation()
            guard session == generation, !stopRequested else { throw DictationError.cancelled }
            guard granted else { throw DictationError.microphone }
            var audioEngine = try await takePreparedInput(uid: microphoneUID)
            guard session == generation, !stopRequested else { throw DictationError.cancelled }
            timingLog.info("Input graph ready in \((ProcessInfo.processInfo.systemUptime - requestedAt) * 1000, privacy: .public) ms")
            inputName = try Microphones.selected(uid: microphoneUID).name
            var format = audioEngine.inputNode.inputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { throw DictationError.noInput }
            let capture = try AudioPipeline(inputFormat: format, audioURL: audioURL, onMeter: { [weak self] level in
                guard self?.generation == session else { return }
                self?.level = level
            }, onError: { [weak self] error in
                guard self?.generation == session else { return }
                self?.captureError = error
                self?.onError?(error)
            }, onPreviewError: { [weak self] error in
                guard self?.generation == session else { return }
                if recognitionEngine == .apple { self?.onError?(error) }
            })
            capture.onSignal = { [weak self] value in
                guard self?.generation == session else { return }; self?.signal = value
            }
            pipeline = capture
            for attempt in 0..<2 {
                guard session == generation, !stopRequested else { throw DictationError.cancelled }
                engine = audioEngine
                // The input hardware can be 44.1 kHz while the engine's cached
                // output bus is 48 kHz. nil selects that stale bus and raises an
                // Objective-C exception. Apply the current hardware format.
                format = audioEngine.inputNode.inputFormat(forBus: 0)
                guard format.sampleRate > 0, format.channelCount > 0 else { throw DictationError.noInput }
                if let error = MurmurInstallAudioTap(audioEngine.inputNode, 0, 1024, format, { buffer, _ in capture.append(buffer) }) {
                    throw error
                }
                tapInstalled = true
                audioEngine.prepare()
                do { try audioEngine.start(); break }
                catch {
                    stopCapture(); discardPreparedInput()
                    guard attempt == 0, session == generation, !stopRequested else { throw error }
                    // Device changes can race the tap. Retry once with a new graph.
                    audioEngine = try await takePreparedInput(uid: microphoneUID)
                    guard session == generation, !stopRequested else { throw DictationError.cancelled }
                    format = audioEngine.inputNode.inputFormat(forBus: 0)
                    guard format.sampleRate > 0, format.channelCount > 0 else { throw DictationError.noInput }
                }
            }
            timingLog.info("Capture running in \((ProcessInfo.processInfo.systemUptime - requestedAt) * 1000, privacy: .public) ms")
            startedAt = Date()
            clock = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.generation == session, let start = self.startedAt else { return }
                    self.elapsed = Date().timeIntervalSince(start)
                }
            }
            // The start cue is emitted by the app only after actual microphone frames arrive.
            try await capture.firstAudio.wait()
            guard session == generation, !stopRequested, !Task.isCancelled else { throw DictationError.cancelled }
            if let captureError { throw captureError }
            phase = .recording
            recognitionPreparing = true
            // Start the preview after microphone readiness, so its setup cannot delay the cue.
            setupTask = Task { [weak self] in
                guard let self else { return }
                defer { if self.generation == session { self.recognitionPreparing = false } }
                do {
                    let transcriber = try await self.makeTranscriber(localeID: localeID, session: session)
                    guard self.generation == session, !Task.isCancelled else { throw DictationError.cancelled }
                    guard let target = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber], considering: format) else { throw DictationError.conversion }
                    let stream = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .unbounded)
                    let speechAnalyzer = SpeechAnalyzer(modules: [transcriber], options: .init(priority: .userInitiated, modelRetention: .lingering))
                    self.analyzer = speechAnalyzer
                    await Self.setHints(SpeechVocabulary.terms(vocabulary, context: self.contextTerms), on: speechAnalyzer)
                    try await speechAnalyzer.prepareToAnalyze(in: target)
                    guard self.generation == session, !Task.isCancelled else { throw DictationError.cancelled }
                    self.observeResults(transcriber, session: session)
                    try await capture.attach(target: target, stream: stream.continuation)
                    guard self.generation == session, !Task.isCancelled else { throw DictationError.cancelled }
                    try await speechAnalyzer.start(inputSequence: stream.stream)
                } catch {
                    if self.generation != session || recognitionEngine == .apple { throw error }
                    // Other local engines can finish from the saved audio even without Apple preview.
                    await capture.discardPreviewBuffers()
                }
            }
            timingLog.info("Microphone ready in \((ProcessInfo.processInfo.systemUptime - requestedAt) * 1000, privacy: .public) ms")
        } catch {
            // A cancelled start can return after the next session has begun.
            // Only the session that owns the engine may tear it down.
            guard generation == session else { throw DictationError.cancelled }
            discardPreparedInput()
            await abort()
            throw error
        }
    }

    private func observeResults(_ transcriber: SpeechTranscriber, session: UUID) {
        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self, generation == session, !Task.isCancelled else { break }
                    let text = String(result.text.characters)
                    if result.isFinal {
                        let values = result.text.runs.compactMap { $0.transcriptionConfidence }
                        if !values.isEmpty { confidence = Float(values.reduce(0, +) / Double(values.count)) }
                    }
                    if result.isFinal { finalized += text; volatile = "" } else { volatile = text }
                    liveText = finalized + volatile
                    onText?(liveText)
                }
            } catch {
                if self?.generation == session, self?.phase == .recording { self?.onError?(error) }
                throw error
            }
        }
    }

    /// Called synchronously from key release, before scheduling any finalization.
    /// Sets this recording's context terms and passes them to the live preview.
    func updateContext(_ terms: [String]) {
        contextTerms = terms
        guard let analyzer else { return }
        let hints = SpeechVocabulary.terms(selectedVocabulary, context: terms)
        Task { await Self.setHints(hints, on: analyzer) }
    }

    private static func setHints(_ terms: [String], on analyzer: SpeechAnalyzer) async {
        guard !terms.isEmpty else { return }
        let context = AnalysisContext()
        context.contextualStrings = [.general: terms]
        try? await analyzer.setContext(context)
    }

    @discardableResult func requestStop() -> Bool {
        let requestedAt = ProcessInfo.processInfo.systemUptime
        guard phase == .recording else {
            if phase == .preparing || phase == .downloading {
                _ = cancelStartup()
            }
            return false
        }
        phase = .finishing
        clock?.invalidate(); clock = nil
        if let start = startedAt { elapsed = Date().timeIntervalSince(start) }
        stopCapture(reuse: true)
        level = 0
        timingLog.info("Microphone stopped in \((ProcessInfo.processInfo.systemUptime - requestedAt) * 1000, privacy: .public) ms")
        Task { [weak self] in
            guard let self else { return }
            await self.warmMicrophone(uid: self.selectedMicrophoneUID)
        }
        return true
    }

    func stop() async throws -> String {
        if phase == .recording { requestStop() }
        guard phase == .finishing else { return liveText }
        if selectedEngine != .apple, recordedURL != nil { generation = UUID() }
        let session = generation
        do {
            if selectedEngine != .apple, let url = recordedURL {
                // The final model needs only the saved audio. Never hold it up
                // while Apple's provisional preview finishes or downloads.
                setupTask?.cancel(); setupTask = nil; recognitionPreparing = false
                let preview = analyzer; analyzer = nil
                resultsTask?.cancel(); resultsTask = nil
                if let preview { Task { await preview.cancelAndFinishNow() } }
                if let capture = pipeline {
                    let value = await capture.finish(); try checkSession(session); signal = value
                }
                pipeline = nil
                let result = try await localSpeech.transcribe(url, engine: selectedEngine, locale: selectedLocale,
                                                              vocabulary: selectedVocabulary, context: contextTerms)
                try checkSession(session)
                liveText = result.text; confidence = result.confidence; boostedWords = result.vocabularyApplied
            } else {
                let text = try await SpeechDeadline.run(timeout: finalizationTimeout) { [self] in
                    try await setupTask?.value; try checkSession(session); setupTask = nil
                    if let capture = pipeline {
                        let value = await capture.finish(); try checkSession(session); signal = value
                    }
                    pipeline = nil
                    try await analyzer?.finalizeAndFinishThroughEndOfInput(); try checkSession(session)
                    try await resultsTask?.value; try checkSession(session)
                    return finalized + volatile
                }
                try checkSession(session); liveText = text
            }
            try checkSession(session)
            onText?(liveText)
            analyzer = nil; resultsTask = nil
            phase = .idle; level = 0
            return liveText
        } catch {
            guard generation == session else { throw DictationError.cancelled }
            await abort()
            throw error
        }
    }

    func transcribeFile(_ url: URL, localeID: String, recognitionEngine: RecognitionEngine = .apple, vocabulary: String = "") async throws -> String {
        try Task.checkCancellation()
        guard phase == .idle else { throw DictationError.unavailable }
        let recognitionEngine = localSpeech.isInstalled(recognitionEngine) ? recognitionEngine : .apple
        selectedEngine = recognitionEngine
        phase = .preparing
        generation = UUID()
        let session = generation
        finalized = ""; volatile = ""; liveText = ""; elapsed = 0
        confidence = nil
        do {
            return try await SpeechDeadline.run(timeout: fileRecognitionTimeout) { [self] in
                let scan = Task.detached { try AudioFileConversion.signal(url) }
                let value = try await withTaskCancellationHandler { try await scan.value } onCancel: { scan.cancel() }
                try checkSession(session); signal = value
                if recognitionEngine != .apple {
                    let file = try AVAudioFile(forReading: url)
                    elapsed = Double(file.length) / file.processingFormat.sampleRate
                    phase = .finishing
                    let result = try await localSpeech.transcribe(url, engine: recognitionEngine, locale: localeID, vocabulary: vocabulary)
                    try checkSession(session)
                    liveText = result.text; confidence = result.confidence; phase = .idle
                    return result.text
                }
                let transcriber = try await makeTranscriber(localeID: localeID, session: session)
                try checkSession(session)
                let file = try AVAudioFile(forReading: url)
                elapsed = Double(file.length) / file.processingFormat.sampleRate
                let speechAnalyzer = SpeechAnalyzer(modules: [transcriber])
                analyzer = speechAnalyzer
                await Self.setHints(SpeechVocabulary.terms(vocabulary), on: speechAnalyzer)
                observeResults(transcriber, session: session)
                phase = .finishing
                if let last = try await speechAnalyzer.analyzeSequence(from: file) {
                    try checkSession(session)
                    try await speechAnalyzer.finalizeAndFinish(through: last)
                } else { await speechAnalyzer.cancelAndFinishNow() }
                try checkSession(session)
                try await resultsTask?.value
                try checkSession(session)
                let text = finalized + volatile
                phase = .idle; analyzer = nil; resultsTask = nil
                return text
            }
        } catch {
            guard generation == session else { throw DictationError.cancelled }
            await abort(); throw error
        }
    }

    private func stopCapture(reuse: Bool = false) {
        let stopped = engine
        stopped?.stop()
        if tapInstalled { stopped?.inputNode.removeTap(onBus: 0); tapInstalled = false }
        engine = nil
        if reuse, let stopped, let device = try? Microphones.selected(uid: selectedMicrophoneUID),
           Microphones.isConfigured(stopped, for: device) {
            cancelInputPreparation()
            preparedEngine = stopped; preparedDevice = device
        }
    }

    /// Release startup synchronously, even if a permission/device operation
    /// cannot be cancelled. Flush this session's audio separately from the UI.
    func cancelStartup() -> Task<InputSignal, Never>? {
        guard phase == .preparing || phase == .downloading else { return nil }
        stopRequested = true
        cancelInputPreparation()
        let capture = releaseSession(reuseInput: true)
        let capturedSignal = signal
        Task { await warmMicrophone(uid: selectedMicrophoneUID) }
        return Task { await capture?.finish() ?? capturedSignal }
    }

    private func releaseSession(reuseInput: Bool = false) -> AudioPipeline? {
        generation = UUID()
        setupTask?.cancel(); setupTask = nil; recognitionPreparing = false
        clock?.invalidate(); clock = nil
        progressTimer?.invalidate(); progressTimer = nil
        if let start = startedAt { elapsed = Date().timeIntervalSince(start) }
        startedAt = nil
        stopCapture(reuse: reuseInput)
        let capture = pipeline
        pipeline = nil
        let abandonedAnalyzer = analyzer; analyzer = nil
        resultsTask?.cancel(); resultsTask = nil
        phase = .idle; level = 0
        // A recognizer still preparing can delay cancellation indefinitely. Release
        // the recording session now; its generation prevents late results or setup.
        if let abandonedAnalyzer {
            Task { await abandonedAnalyzer.cancelAndFinishNow() }
        }
        return capture
    }

    func abort() async {
        let capture = releaseSession()
        let releasedSession = generation
        if let capture {
            let finalSignal = await capture.finish()
            if generation == releasedSession { signal = finalSignal }
        }
    }
}
