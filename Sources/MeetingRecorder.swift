import AVFoundation
import Foundation
import OSLog

/// Records a meeting from two sides at once: your microphone ("me") and what
/// your Mac plays ("them"). Each side is cut at natural pauses and every piece
/// is transcribed on this Mac while the meeting goes on. Audio is only kept
/// until its words are written down.
@MainActor
final class MeetingRecorder {
    struct Piece { let speaker: MeetingSegment.Speaker; let url: URL; let start: TimeInterval; let length: TimeInterval }

    private(set) var isRunning = false
    private var engine: AVAudioEngine?
    private var tap: SystemAudioTap?
    private let mic = ChunkerBox(), system = ChunkerBox()
    private let folder: URL
    private var startedUptime: TimeInterval = 0
    /// Where each side's audio begins on the meeting's clock: the microphone and
    /// your Mac's sound start at different moments (a permission prompt can take a while).
    private var micOffset: TimeInterval = 0, systemOffset: TimeInterval = 0
    /// Stop was asked for, possibly while still starting.
    private var stopRequested = false
    private let log = Logger(subsystem: "app.murmur.mac", category: "Meetings")
    /// Called on the main actor for each finished piece of audio.
    var onPiece: ((Piece) -> Void)?
    /// Recent loudness of each side, 0…1, for the live meters.
    private(set) var micLevel: Float = 0
    private(set) var systemLevel: Float = 0
    /// Your microphone is left out while you dictate somewhere else. Checked as
    /// the audio arrives, so a dictation never lands in the meeting.
    var micPaused: Bool {
        get { mic.paused }
        set { mic.paused = newValue }
    }
    private(set) var systemAudioError: String?

    init(folder: URL) { self.folder = folder }

    func start(microphoneUID: String, systemAudio: Bool) async throws {
        guard !isRunning else { return }
        stopRequested = false
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        startedUptime = ProcessInfo.processInfo.systemUptime
        mic.reset(); system.reset()
        let audio = AVAudioEngine()
        _ = try await Microphones.configure(audio, uid: microphoneUID)
        // Stopped while the microphone was being set up: don't start it.
        guard !stopRequested else { return }
        let input = audio.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw DictationError.noInput }
        let resampler = MonoResampler(input: format)
        let micBox = mic
        if let error = MurmurInstallAudioTap(input, 0, 4096, format, { [weak self] buffer, _ in
            let samples = resampler.convert(buffer)
            let chunks = micBox.append(samples)
            let level = ChunkerBox.level(samples)
            Task { @MainActor in self?.receive(chunks, from: .me, level: level) }
        }) { throw error }
        audio.prepare()
        try audio.start()
        engine = audio
        micOffset = ProcessInfo.processInfo.systemUptime - startedUptime
        isRunning = true
        if systemAudio {
            let systemTap = SystemAudioTap()
            let systemBox = system
            let deliver: @Sendable ([Float]) -> Void = { [weak self] samples in
                let chunks = systemBox.append(samples)
                let level = ChunkerBox.level(samples)
                Task { @MainActor in self?.receive(chunks, from: .them, level: level) }
            }
            do {
                // The first tap waits on macOS's permission prompt; keep the window responsive meanwhile.
                try await Task.detached(priority: .userInitiated) { try systemTap.start(deliver) }.value
                guard isRunning else { systemTap.stop(); return }
                systemOffset = ProcessInfo.processInfo.systemUptime - startedUptime
                tap = systemTap
            } catch {
                systemAudioError = error.localizedDescription
                log.error("System audio unavailable: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Stops both sides and hands over the last pieces.
    func stop() {
        stopRequested = true
        guard isRunning else { return }
        isRunning = false
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop(); engine = nil
        tap?.stop(); tap = nil
        if let last = mic.flush() { emit(last, from: .me) }
        if let last = system.flush() { emit(last, from: .them) }
        micLevel = 0; systemLevel = 0
    }

    private func receive(_ chunks: [SpeechChunker.Chunk], from speaker: MeetingSegment.Speaker, level: Float) {
        guard isRunning else { return }
        if speaker == .me { micLevel = micLevel * 0.6 + level * 0.4 } else { systemLevel = systemLevel * 0.6 + level * 0.4 }
        for chunk in chunks { emit(chunk, from: speaker) }
    }

    private func emit(_ chunk: SpeechChunker.Chunk, from speaker: MeetingSegment.Speaker) {
        let url = folder.appendingPathComponent("\(speaker.rawValue)-\(UUID().uuidString).wav")
        do {
            try Self.writeWave(chunk.samples, to: url)
            // Both sides on one clock, so they interleave in the order they were said.
            let start = chunk.start + (speaker == .me ? micOffset : systemOffset)
            onPiece?(Piece(speaker: speaker, url: url, start: start, length: Double(chunk.samples.count) / SpeechChunker.rate))
        } catch { log.error("Couldn’t save a meeting piece: \(error.localizedDescription, privacy: .public)") }
    }

    static func writeWave(_ samples: [Float], to url: URL) throws {
        // Very short pieces are padded; the recognizer wants at least a second.
        let minimum = Int(SpeechChunker.rate * 1.2)
        let padded = samples.count < minimum ? samples + [Float](repeating: 0, count: minimum - samples.count) : samples
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: SpeechChunker.rate, channels: 1, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: SpeechChunker.rate,
                                                              AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                                                              AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false],
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(padded.count)) else { throw DictationError.conversion }
        buffer.frameLength = AVAudioFrameCount(padded.count)
        padded.withUnsafeBufferPointer { source in buffer.floatChannelData![0].update(from: source.baseAddress!, count: padded.count) }
        try file.write(from: buffer)
    }
}

/// A chunker shared between an audio thread and the main actor.
final class ChunkerBox: @unchecked Sendable {
    private var chunker = SpeechChunker()
    private let lock = NSLock()
    private var isPaused = false
    /// While paused, audio is replaced with silence: nothing is heard, and the clock keeps time.
    var paused: Bool {
        get { lock.withLock { isPaused } }
        set { lock.withLock { isPaused = newValue } }
    }
    func append(_ samples: [Float]) -> [SpeechChunker.Chunk] {
        lock.withLock { chunker.append(isPaused ? [Float](repeating: 0, count: samples.count) : samples) }
    }
    func flush() -> SpeechChunker.Chunk? { lock.withLock { chunker.flush() } }
    func reset() { lock.withLock { chunker = SpeechChunker() } }
    static func level(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let rms = (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
        let decibels = 20 * log10(max(rms, 1e-6))
        return min(1, max(0, (decibels + 55) / 45))
    }
}
