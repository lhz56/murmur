import AVFoundation
import Foundation
import OSLog

/// Ask's natural voice: a neural speech model (Kokoro) running in Murmur's
/// `MurmurVoice` helper, on this Mac. Sentences are made one at a time and
/// played back to back, so the first one starts while the rest are still
/// being written.
@MainActor
final class NaturalVoice: NSObject, ObservableObject, AVAudioPlayerDelegate {
    struct Choice: Identifiable, Hashable {
        let id: String
        let name: String
        let note: String
    }

    /// A few of Kokoro's most natural English voices.
    static let choices: [Choice] = [
        .init(id: "af_heart", name: "Heart", note: "Warm, American"),
        .init(id: "af_bella", name: "Bella", note: "Bright, American"),
        .init(id: "af_nicole", name: "Nicole", note: "Soft, close, American"),
        .init(id: "am_michael", name: "Michael", note: "Calm, American"),
        .init(id: "am_puck", name: "Puck", note: "Upbeat, American"),
        .init(id: "bf_emma", name: "Emma", note: "British"),
        .init(id: "bm_george", name: "George", note: "British"),
    ]
    static let defaultVoice = "af_heart"

    enum State: Equatable {
        case notInstalled, installing(Double), starting, ready
        case failed(String)
    }

    @Published private(set) var state: State = .notInstalled
    @Published private(set) var isSpeaking = false
    var voice = NaturalVoice.defaultVoice
    /// Called as each sentence starts playing.
    var onPlay: (() -> Void)?
    var onFailure: ((String) -> Void)?
    private var sentences: [String: String] = [:]
    private var deadlines: [String: Task<Void, Never>] = [:]

    private var helper: JSONLineProcess?
    private var nextID = 0
    /// Sentences sent to the helper, in order, waiting for their audio.
    private var pending: [String] = []
    /// Audio that came back early, keyed by request id.
    private var ready: [String: URL] = [:]
    private var player: AVAudioPlayer?
    private let log = Logger(subsystem: "app.murmur.mac", category: "Voice")

    /// For tests: a helper outside the app bundle, and silent playback.
    static var helperOverride: URL?
    static var volume: Float = 1

    static var helperURL: URL? {
        guard let url = helperOverride ?? Bundle.main.resourceURL?.appendingPathComponent("Helpers/MurmurVoice"),
              FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        return url
    }

    override init() {
        super.init()
        if Self.helperURL != nil, Self.modelsInstalled { state = .starting }
    }

    /// The model files are on this Mac.
    static var modelsInstalled: Bool {
        guard let helper = helperURL else { return false }
        return AssistantProcessOutput.read(helper, arguments: ["--check"], environment: ProcessInfo.processInfo.environment, timeout: 3) != nil
    }

    var isAvailable: Bool { Self.helperURL != nil }
    var canSpeak: Bool { state == .ready || state == .starting }

    /// Starts the helper so the first answer doesn't wait for the model to load.
    func warm() { if state == .starting || state == .ready { launch(install: false) } }

    /// Downloads the voice model (once), then loads it.
    func install() { launch(install: true) }

    private func launch(install: Bool) {
        if helper?.isRunning == true { return }
        guard let url = Self.helperURL else { state = .failed("This build of Murmur doesn’t include the voice helper."); return }
        let process = JSONLineProcess(url, arguments: install ? ["--install"] : [], directory: FileManager.default.temporaryDirectory)
        process.onMessage = { [weak self] message in DispatchQueue.main.async { MainActor.assumeIsolated { self?.handle(message) } } }
        process.onExit = { [weak self, weak process] tail in
            DispatchQueue.main.async { MainActor.assumeIsolated {
                guard let self, let process, process === self.helper else { return }
                self.helper = nil
                self.log.error("Voice helper exited: \(tail, privacy: .private)")
                if case .installing = self.state { self.state = .failed("The voice download stopped. Check your internet connection and free disk space, then try again.") }
                else if self.state == .ready { self.state = .starting }
                self.fallbackPending()
                self.dropQueue()
            } }
        }
        do {
            try process.start()
            helper = process
            state = install ? .installing(0) : .starting
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func handle(_ message: [String: Any]) {
        switch message["type"] as? String {
        case "progress":
            state = .installing(message["fraction"] as? Double ?? 0)
        case "ready":
            state = .ready
        case "audio":
            guard let id = message["id"] as? String, let path = message["path"] as? String else { return }
            let url = URL(fileURLWithPath: path)
            guard pending.contains(id) else { try? FileManager.default.removeItem(at: url); return }
            deadlines.removeValue(forKey: id)?.cancel()
            ready[id] = url
            playNext()
        case "error":
            let text = message["message"] as? String ?? "The voice couldn’t speak."
            if let id = message["id"] as? String {
                // One sentence failed; skip it and keep going.
                fallback(id)
                pending.removeAll { $0 == id }
                playNext()
            } else {
                state = .failed(text)
                fallbackPending(); dropQueue()
            }
        default: break
        }
    }

    /// Queues one sentence. Returns false if the natural voice can't take it.
    @discardableResult
    func speak(_ sentence: String) -> Bool {
        guard canSpeak else { return false }
        if helper?.isRunning != true { launch(install: false) }
        guard let helper else { return false }
        nextID += 1
        let id = "\(nextID)"
        pending.append(id)
        sentences[id] = sentence
        deadlines[id] = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            guard let self, self.pending.contains(id) else { return }
            self.fallback(id)
            self.pending.removeAll { $0 == id }
            self.playNext()
        }
        isSpeaking = true
        helper.send(["id": id, "text": Self.spoken(sentence), "voice": voice])
        return true
    }

    /// Stops talking now, and forgets the sentences still being made.
    func stop() {
        player?.stop(); player = nil
        dropQueue()
    }

    private func fallback(_ id: String) {
        deadlines.removeValue(forKey: id)?.cancel()
        if let sentence = sentences.removeValue(forKey: id) { onFailure?(sentence) }
    }

    private func fallbackPending() { for id in pending { fallback(id) } }

    private func dropQueue() {
        for task in deadlines.values { task.cancel() }; deadlines = [:]; sentences = [:]
        pending = []
        for url in ready.values { try? FileManager.default.removeItem(at: url) }
        ready = [:]
        if player == nil { isSpeaking = false }
    }

    /// Plays the next sentence in order once its audio is ready.
    private func playNext() {
        guard player == nil else { return }
        guard let id = pending.first else { isSpeaking = false; return }
        guard let url = ready.removeValue(forKey: id) else { return }
        pending.removeFirst()
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let next = try AVAudioPlayer(contentsOf: url)
            next.delegate = self
            next.volume = Self.volume
            player = next
            guard next.play() else { player = nil; fallback(id); playNext(); return }
            sentences.removeValue(forKey: id)
            onPlay?()
        } catch {
            fallback(id)
            playNext()
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let finished = ObjectIdentifier(player)
        DispatchQueue.main.async { MainActor.assumeIsolated {
            guard let current = self.player, ObjectIdentifier(current) == finished else { return }
            self.player = nil
            self.playNext()
        } }
    }

    func shutDown() { stop(); helper?.terminate(); helper = nil }

    /// Spells out words the model says wrong ("Xcode" isn't "Exode").
    static func spoken(_ text: String) -> String {
        var text = text
        for (word, said) in pronunciations {
            text = TextScan.replacing(word, with: said, in: text, extra: "_", caseSensitive: true)
        }
        return text
    }

    static let pronunciations: [(String, String)] = [
        ("Xcode", "X code"), ("macOS", "mac O S"), ("iOS", "eye O S"), ("iPadOS", "eye pad O S"), ("SwiftUI", "Swift U I"),
        ("UIKit", "U I kit"), ("npm", "N P M"), ("JSON", "jason"), ("CLI", "C L I"), ("UI", "U I"), ("URL", "U R L"),
        ("API", "A P I"), ("SQL", "sequel"), ("GPT", "G P T"), ("ChatGPT", "chat G P T"), ("WWDC", "W W D C"),
    ]
}
