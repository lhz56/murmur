import SwiftUI
import AppKit
import AVFoundation
import ApplicationServices
import Combine
import OSLog

enum LibraryFilter: String, CaseIterable { case all = "All transcripts", favorites = "Favorites", trash = "Trash" }

@MainActor
final class Preferences: ObservableObject {
    let defaults: UserDefaults
    @Published var locale: String { didSet { defaults.set(locale, forKey: "locale") } }
    @Published var autoCopy: Bool { didSet { defaults.set(autoCopy, forKey: "autoCopy") } }
    @Published var autoPaste: Bool { didSet { defaults.set(autoPaste, forKey: "autoPaste") } }
    @Published var keepAudio: Bool { didSet { defaults.set(keepAudio, forKey: "keepAudio") } }
    @Published var sounds: Bool { didSet { defaults.set(sounds, forKey: "sounds") } }
    @Published var vocabulary: String { didSet { defaults.set(vocabulary, forKey: "vocabulary") } }
    @Published var fnEnabled: Bool { didSet { defaults.set(fnEnabled, forKey: "fnEnabled") } }
    @Published var fnBehavior: FnBehavior { didSet { defaults.set(fnBehavior.rawValue, forKey: "fnBehavior") } }
    @Published var dictationKey: DictationKey { didSet { defaults.set(dictationKey.rawValue, forKey: "dictationKey") } }
    @Published var microphoneUID: String { didSet { defaults.set(microphoneUID, forKey: "microphoneUID") } }
    @Published var recognitionEngine: RecognitionEngine { didSet { defaults.set(recognitionEngine.rawValue, forKey: "recognitionEngine") } }
    init(preview: Bool) {
        defaults = preview ? UserDefaults(suiteName: "app.murmur.preview")! : .standard
        locale = defaults.string(forKey: "locale") ?? "en-US"
        autoCopy = defaults.object(forKey: "autoCopy") as? Bool ?? true
        autoPaste = defaults.object(forKey: "autoPaste") as? Bool ?? true
        keepAudio = defaults.object(forKey: "keepAudio") as? Bool ?? true
        sounds = defaults.object(forKey: "sounds") as? Bool ?? true
        vocabulary = defaults.string(forKey: "vocabulary") ?? ""
        fnEnabled = defaults.object(forKey: "fnEnabled") as? Bool ?? true
        fnBehavior = FnBehavior(rawValue: defaults.string(forKey: "fnBehavior") ?? "") ?? .hold
        dictationKey = DictationKey(rawValue: defaults.string(forKey: "dictationKey") ?? "") ?? .control
        microphoneUID = defaults.string(forKey: "microphoneUID") ?? ""
        recognitionEngine = RecognitionEngine(rawValue: defaults.string(forKey: "recognitionEngine") ?? "") ?? (preview ? .apple : .parakeet)
    }
}

@MainActor
final class AppModel: ObservableObject {
    let speech = DictationEngine()
    let microphoneCheck = MicrophoneCheck()
    let preferences: Preferences
    let storage: HistoryStorage
    let isPreview: Bool
    @Published var transcripts: [Transcript] = []
    @Published var filter: LibraryFilter = .all
    @Published var search = "" {
        didSet {
            if let selectedID, !visibleTranscripts.contains(where: { $0.id == selectedID }) { self.selectedID = nil }
        }
    }
    @Published var selectedID: UUID?
    @Published var activeID: UUID?
    @Published var showSettings = false
    @Published var errorMessage: String?
    @Published var toast: String?
    @Published var playingID: UUID?
    @Published var playbackProgress: Double = 0
    @Published var accessibilityEnabled = AXIsProcessTrusted()
    @Published var fnAvailable = false
    @Published var fnSignalSeen = false
    @Published var isTestingFn = false
    @Published var fnTestPresses = 0
    @Published var keyboardNames = KeyboardInfo.connectedNames()
    @Published var microphones = Microphones.devices()
    @Published var parakeetInstalling = false
    @Published var parakeetProgress: Double = 0
    @Published var parakeetReady = false
    @Published var parakeetPreparationError: String?
    @Published var hudVisible = false
    @Published var hudMessage: String?
    var onRecordingChanged: ((Bool) -> Void)?
    var showWindow: (() -> Void)?
    var showHUD: (() -> Void)?
    var hideHUD: (() -> Void)?
    var refreshFn: (() -> Void)?
    var resetFnInput: (() -> Void)?
    private var subscriptions = Set<AnyCancellable>()
    private var checkpointTimer: Timer?
    private var playbackTimer: Timer?
    private var player: AVAudioPlayer?
    private var pasteTarget: TextInsertion.Destination?
    private let textInsertion = TextInsertion()
    private var insertionTestTask: Task<Void, Never>?
    private var deliveryResult: InsertionResult?
    private var writesEnabled = true
    private var recordingTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private var editSaveTask: Task<Void, Never>?
    private var hudTask: Task<Void, Never>?
    @Published private(set) var fnHoldInProgress = false
    private var stopAfterSetup = false
    private var stopRequestedAt: TimeInterval?
    private let timingLog = Logger(subsystem: "app.murmur.mac", category: "Timing")
    private var cachedSounds: [String: NSSound] = [:]

    init(preview: Bool = false) {
        isPreview = preview
        preferences = Preferences(preview: preview)
        let root = preview ? FileManager.default.temporaryDirectory.appendingPathComponent("Murmur-preview-\(UUID().uuidString)") :
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Murmur", isDirectory: true)
        do { storage = try HistoryStorage(root: root) }
        catch { fatalError("Cannot create Murmur’s storage folder: \(error.localizedDescription)") }
        do { transcripts = try storage.load(); try storage.save(transcripts) }
        catch { writesEnabled = false; errorMessage = "History couldn’t be opened. Your files have been preserved at \(root.path). \(error.localizedDescription)" }
        speech.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        microphoneCheck.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        preferences.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        speech.onText = { [weak self] text in self?.updateActive(text: text) }
        speech.onError = { [weak self] error in
            guard let self else { return }
            self.errorMessage = error.localizedDescription
            if self.speech.phase == .recording { self.toggleRecording() }
        }
        if preview { seedPreview() }
        Task { await speech.refreshLanguages() }
        if !preview { Task { await speech.warmMicrophone(uid: preferences.microphoneUID) } }
        preferences.$microphoneUID.dropFirst().sink { [weak self] uid in
            Task { @MainActor in await self?.speech.warmMicrophone(uid: uid) }
        }.store(in: &subscriptions)
        if !preview, preferences.recognitionEngine == .parakeet { prepareParakeet(install: false) }
    }

    var visibleTranscripts: [Transcript] {
        transcripts.filter { entry in
            let allowed: Bool
            switch filter {
            case .all: allowed = entry.deletedAt == nil
            case .favorites: allowed = entry.deletedAt == nil && entry.isFavorite
            case .trash: allowed = entry.deletedAt != nil
            }
            return allowed && (search.isEmpty || entry.text.localizedCaseInsensitiveContains(search) || entry.sourceApp.localizedCaseInsensitiveContains(search))
        }
    }
    var savedTranscripts: [Transcript] { transcripts.filter { $0.deletedAt == nil && $0.status != .recording } }
    var wordCount: Int { savedTranscripts.reduce(0) { $0 + $1.wordCount } }
    var totalDuration: TimeInterval { savedTranscripts.reduce(0) { $0 + $1.duration } }
    var selected: Transcript? { transcripts.first { $0.id == selectedID } }
    var recordingTime: String { String(format: "%02d:%02d", Int(speech.elapsed) / 60, Int(speech.elapsed) % 60) }

    @discardableResult
    private func persist() -> Bool {
        guard writesEnabled else { return false }
        do { try storage.save(transcripts); return true }
        catch { errorMessage = "Couldn’t save history: \(error.localizedDescription). The audio remains in your Murmur folder."; return false }
    }

    func toggleRecording() {
        guard !isTestingFn else { return }
        if speech.phase == .recording {
            queueFinish()
        } else if speech.phase == .idle, activeID == nil {
            recordingTask = Task { await beginRecording() }
        }
    }

    private func queueFinish() {
        let requestedAt = ProcessInfo.processInfo.systemUptime
        guard speech.requestStop() else { return }
        stopRequestedAt = requestedAt
        onRecordingChanged?(false)
        checkpointTimer?.invalidate(); checkpointTimer = nil
        playSound("finish")
        recordingTask = Task { await finishRecording() }
    }

    func handleFn(_ action: FnKeyState.Action) {
        guard !isTestingFn else { return }
        switch action {
        case .startHold:
            fnHoldInProgress = true; stopAfterSetup = false
            if speech.phase == .idle { toggleRecording() }
        case .finishHold:
            let wasFnHeld = fnHoldInProgress
            fnHoldInProgress = false
            if speech.phase == .recording { toggleRecording() }
            else if speech.phase == .preparing || speech.phase == .downloading || (speech.phase == .idle && wasFnHeld) {
                stopAfterSetup = true
                speech.requestStop()
            }
        case .toggle:
            fnHoldInProgress = false; stopAfterSetup = false; toggleRecording()
        case .latchHold:
            fnHoldInProgress = false; stopAfterSetup = false
        case .cancelHold:
            fnHoldInProgress = false
            if speech.phase == .recording { cancelRecording() }
            else { stopAfterSetup = true; speech.requestStop() }
        }
    }

    func startFnTest() {
        microphoneCheck.stop()
        resetFnInput?()
        keyboardNames = KeyboardInfo.connectedNames()
        fnTestPresses = 0
        isTestingFn = true
    }

    func endFnTest() {
        resetFnInput?()
        isTestingFn = false
    }

    private func beginRecording() async {
        guard activeID == nil, speech.phase == .idle else { return }
        if stopAfterSetup { stopAfterSetup = false; fnHoldInProgress = false; return }
        guard writesEnabled else { showWindow?(); return }
        insertionTestTask?.cancel()
        errorMessage = nil
        stopPlayback()
        microphoneCheck.stop()
        pasteTarget = textInsertion.captureDestination()
        deliveryResult = nil
        var entry = Transcript()
        entry.locale = preferences.locale
        entry.engineName = preferences.recognitionEngine.rawValue
        entry.sourceApp = pasteTarget?.application.localizedName ?? "Murmur"
        entry.audioFile = "\(entry.id.uuidString).m4a"
        transcripts.insert(entry, at: 0)
        activeID = entry.id
        selectedID = entry.id
        filter = .all; search = ""
        guard persist(), let audioURL = storage.audioURL(for: entry) else { activeID = nil; return }
        hudTask?.cancel(); hudMessage = nil; hudVisible = true; showHUD?()
        do {
            try await speech.start(audioURL: audioURL, localeID: entry.locale, microphoneUID: preferences.microphoneUID,
                                   recognitionEngine: preferences.recognitionEngine, vocabulary: preferences.vocabulary)
            if let i = index(entry.id) { transcripts[i].microphoneName = speech.inputName }
            onRecordingChanged?(true)
            playSound("start")
            if stopAfterSetup {
                stopAfterSetup = false
                queueFinish()
                return
            }
            checkpointTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.checkpoint() }
            }
        } catch {
            checkpointTimer?.invalidate(); checkpointTimer = nil
            let cancelled = (error as? DictationError).map { if case .cancelled = $0 { return true }; return false } ?? false
            if cancelled && !speech.signal.hasFrames {
                transcripts.removeAll { $0.id == entry.id }
                selectedID = nil
            } else {
                updateActive(duration: speech.elapsed, status: cancelled ? .interrupted : .failed)
                if !FileManager.default.fileExists(atPath: audioURL.path), let i = index(activeID) { transcripts[i].audioFile = nil }
            }
            persist(); activeID = nil
            fnHoldInProgress = false; stopAfterSetup = false
            hudVisible = false; hideHUD?(); onRecordingChanged?(false)
            if !cancelled { errorMessage = error.localizedDescription; showWindow?() }
        }
    }

    private func checkpoint() {
        updateActive(text: speech.liveText, duration: speech.elapsed)
        persist()
    }

    private func finishRecording() async {
        if speech.phase == .recording {
            stopRequestedAt = ProcessInfo.processInfo.systemUptime
            speech.requestStop(); playSound("finish")
        }
        guard speech.phase == .finishing else { return }
        onRecordingChanged?(false)
        checkpointTimer?.invalidate(); checkpointTimer = nil
        let id = activeID
        do {
            let original = try await speech.stop()
            let text = TextTools.clean(original, replacements: preferences.vocabulary)
            updateActive(text: text, duration: speech.elapsed, status: text.isEmpty ? .failed : .complete)
            if let i = index(id) { transcripts[i].originalText = original }
            let review = TranscriptionReview.reason(text: original, confidence: speech.confidence, signal: speech.signal)
            if let i = index(id) { transcripts[i].confidence = speech.confidence; transcripts[i].reviewReason = review }
            // Deliver immediately when final text exists; history writes and audio
            // retention cleanup should never stand between stop and the clipboard.
            if review == nil, !text.isEmpty { await deliver(text) }
            if let requestedAt = stopRequestedAt {
                timingLog.info("Final text ready in \((ProcessInfo.processInfo.systemUptime - requestedAt) * 1000, privacy: .public) ms; clipboard enabled: \(self.preferences.autoCopy, privacy: .public)")
            }
            guard persist() else {
                activeID = nil; onRecordingChanged?(false); dismissHUD(message: "Recording kept"); return
            }
            // Audio is captured for crash recovery even when retention is disabled.
            if !preferences.keepAudio, let i = index(id), let url = storage.audioURL(for: transcripts[i]) {
                do {
                    try FileManager.default.removeItem(at: url)
                    transcripts[i].audioFile = nil
                    persist()
                } catch { errorMessage = "Transcript saved, but the audio couldn’t be removed: \(error.localizedDescription)" }
            }
            if let review {
                notify("Saved for review · microphone audio was unclear")
                toast = review
            } else if text.isEmpty { notify("No words heard · recording saved") }
        } catch {
            updateActive(text: speech.liveText, duration: speech.elapsed, status: .interrupted)
            persist()
            errorMessage = "Your recording was kept. \(error.localizedDescription)"
            showWindow?()
        }
        activeID = nil
        stopRequestedAt = nil
        fnHoldInProgress = false; stopAfterSetup = false
        onRecordingChanged?(false)
        let needsReview = transcripts.first { $0.id == id }?.reviewReason != nil
        dismissHUD(message: needsReview ? "Saved · check this thought" : speech.liveText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "No clear speech · audio kept" : errorMessage == nil ? deliveryResult?.hudMessage ?? (preferences.autoCopy ? "Copied · ready to paste" : "Saved · ready to copy") : "Recording kept")
    }

    func cancelRecording() {
        guard speech.phase == .recording else { return }
        speech.requestStop()
        onRecordingChanged?(false)
        recordingTask = Task {
            checkpointTimer?.invalidate(); checkpointTimer = nil
            checkpoint()
            await speech.abort()
            playSound("finish")
            updateActive(status: .interrupted)
            persist(); activeID = nil
            fnHoldInProgress = false; stopAfterSetup = false
            onRecordingChanged?(false); dismissHUD(message: "Recording kept")
            notify("Recording kept in your library")
        }
    }

    private func updateActive(text: String? = nil, duration: TimeInterval? = nil, status: TranscriptStatus? = nil) {
        guard let i = index(activeID) else { return }
        if let text { transcripts[i].text = text; transcripts[i].originalText = text }
        if let duration { transcripts[i].duration = duration }
        if let status { transcripts[i].status = status }
    }
    private func index(_ id: UUID?) -> Int? { transcripts.firstIndex { $0.id == id } }

    func edit(_ id: UUID, text: String) {
        guard let i = index(id), id != activeID else { return }
        transcripts[i].text = text
        editSaveTask?.cancel()
        editSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.persist()
        }
    }
    func favorite(_ id: UUID) {
        guard let i = index(id) else { return }
        transcripts[i].isFavorite.toggle(); persist()
    }
    func trash(_ id: UUID) {
        guard let i = index(id), id != activeID else { return }
        if playingID == id { stopPlayback() }
        transcripts[i].deletedAt = Date(); selectedID = nil; persist()
        notify("Moved to Trash · restore it anytime")
    }
    func restore(_ id: UUID) {
        guard let i = index(id) else { return }
        transcripts[i].deletedAt = nil; persist(); notify("Restored to your library")
    }
    func permanentlyDelete(_ id: UUID) {
        guard let i = index(id), transcripts[i].deletedAt != nil else { return }
        let old = transcripts
        let audioURL = storage.audioURL(for: transcripts[i])
        transcripts.remove(at: i)
        guard persist() else { transcripts = old; return }
        do { try storage.replaceBackup(transcripts) }
        catch {
            transcripts = old; persist()
            errorMessage = "Couldn’t finish removing this transcript from the backup. Please try again."
            return
        }
        if let audioURL, FileManager.default.fileExists(atPath: audioURL.path) {
            do { try FileManager.default.removeItem(at: audioURL) }
            catch { errorMessage = "Transcript removed, but its audio couldn’t be deleted: \(error.localizedDescription)" }
        }
        selectedID = nil
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        notify("Copied. Go make something.")
    }

    func deliver(_ text: String) async {
        let destination = pasteTarget
        pasteTarget = nil
        deliveryResult = nil
        accessibilityEnabled = AXIsProcessTrusted()
        if preferences.autoCopy || preferences.autoPaste {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        if preferences.autoPaste {
            let result = await textInsertion.insert(text, into: destination)
            guard !Task.isCancelled else { return }
            deliveryResult = result
            notify(result.message)
        } else { notify(preferences.autoCopy ? "Saved & copied to clipboard" : "Saved to your library") }
    }

    func testInsertion() {
        guard !speech.phase.isBusy, activeID == nil else { return }
        showSettings = false
        insertionTestTask?.cancel()
        notify("Click a text box within 8 seconds. Murmur will type a test sentence.")
        insertionTestTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            guard let self, !Task.isCancelled, !self.speech.phase.isBusy, self.activeID == nil else { return }
            self.pasteTarget = self.textInsertion.captureDestination()
            await self.deliver("Murmur insertion test.")
        }
    }

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        accessibilityEnabled = AXIsProcessTrustedWithOptions(options)
        if !accessibilityEnabled {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        }
    }

    func refreshPermissions() { accessibilityEnabled = AXIsProcessTrusted(); microphones = Microphones.devices(); refreshFn?() }

    func toggleMicrophoneCheck() {
        guard !speech.phase.isBusy, activeID == nil else { return }
        if microphoneCheck.isRunning { microphoneCheck.stop() }
        else { Task { await microphoneCheck.start(uid: preferences.microphoneUID) } }
    }

    func prepareParakeet(install: Bool = true) {
        guard !parakeetInstalling, !speech.phase.isBusy else { return }
        parakeetInstalling = true; parakeetProgress = 0; parakeetPreparationError = nil
        speech.localSpeech.parakeet.onProgress = { [weak self] value in self?.parakeetProgress = value }
        Task {
            defer { parakeetInstalling = false }
            do { try await speech.localSpeech.parakeet.start(install: install); parakeetReady = true }
            catch {
                parakeetReady = false
                parakeetPreparationError = error.localizedDescription
                if install { errorMessage = error.localizedDescription }
            }
        }
    }

    func rememberCorrection(heard: String, desired: String) {
        let from = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        let to = desired.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !from.isEmpty, !to.isEmpty, from != to, !from.contains("=>"), !to.contains("=>"),
              !from.contains("\n"), !to.contains("\n"), from.count <= 100, to.count <= 100 else { return }
        let pair = "\(from) => \(to)"
        if !preferences.vocabulary.components(separatedBy: .newlines).contains(pair) {
            preferences.vocabulary += (preferences.vocabulary.isEmpty ? "" : "\n") + pair
        }
        notify("Correction remembered")
    }

    func togglePlayback(_ entry: Transcript) {
        if playingID == entry.id { stopPlayback(); return }
        stopPlayback()
        guard let url = storage.audioURL(for: entry) else { return }
        do {
            player = try AVAudioPlayer(contentsOf: url)
            player?.prepareToPlay()
            guard player?.play() == true else { throw DictationError.conversion }
            playingID = entry.id
            playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let player = self.player else { return }
                    if !player.isPlaying { self.stopPlayback() }
                    else { self.playbackProgress = player.currentTime / max(player.duration, 0.01) }
                }
            }
        } catch { errorMessage = "Couldn’t play this recording: \(error.localizedDescription)" }
    }
    func stopPlayback() {
        player?.stop(); player = nil; playingID = nil; playbackProgress = 0
        playbackTimer?.invalidate(); playbackTimer = nil
    }

    func retry(_ entry: Transcript) {
        guard speech.phase == .idle, activeID == nil, let url = storage.audioURL(for: entry) else { return }
        stopPlayback()
        recordingTask = Task {
            activeID = entry.id; selectedID = entry.id
            do {
                let original = try await speech.transcribeFile(url, localeID: entry.locale, recognitionEngine: preferences.recognitionEngine, vocabulary: preferences.vocabulary)
                updateActive(text: TextTools.clean(original, replacements: preferences.vocabulary), duration: speech.elapsed,
                             status: original.isEmpty ? .failed : .complete)
                if let i = index(entry.id) { transcripts[i].originalText = original }
                if let i = index(entry.id) {
                    transcripts[i].engineName = preferences.recognitionEngine.rawValue; transcripts[i].confidence = speech.confidence
                    transcripts[i].reviewReason = TranscriptionReview.reason(text: original, confidence: speech.confidence, signal: speech.signal)
                }
                persist(); notify("Recording transcribed")
            } catch { errorMessage = error.localizedDescription }
            activeID = nil
        }
    }

    func importAudio() {
        guard !speech.phase.isBusy, activeID == nil else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.message = "Turn an audio file into a searchable transcript."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            var entry = Transcript(); entry.status = .interrupted; entry.sourceApp = "Imported audio"; entry.locale = preferences.locale
            entry.audioFile = "\(entry.id.uuidString).\(url.pathExtension.isEmpty ? "m4a" : url.pathExtension)"
            guard let destination = storage.audioURL(for: entry) else { return }
            try FileManager.default.copyItem(at: url, to: destination)
            transcripts.insert(entry, at: 0); persist(); filter = .all; search = ""
            retry(entry)
        } catch { errorMessage = error.localizedDescription }
    }

    func export(_ entry: Transcript? = nil) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = entry == nil ? "Murmur history.json" : "\(entry!.title.prefix(48)).txt"
        panel.allowedContentTypes = entry == nil ? [.json] : [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            if let entry { try entry.text.write(to: url, atomically: true, encoding: .utf8) }
            else { try storage.exportData(savedTranscripts).write(to: url, options: .atomic) }
            notify("Exported")
        } catch { errorMessage = error.localizedDescription }
    }

    func notify(_ message: String) {
        toastTask?.cancel(); toast = message
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }
    func playSound(_ name: String) {
        guard preferences.sounds else { return }
        if cachedSounds[name] == nil, let url = Bundle.main.url(forResource: name, withExtension: "wav") {
            cachedSounds[name] = NSSound(contentsOf: url, byReference: true)
            cachedSounds[name]?.volume = 0.38
        }
        cachedSounds[name]?.stop(); cachedSounds[name]?.play()
    }

    private func dismissHUD(message: String) {
        hudTask?.cancel(); hudMessage = message
        hudTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.1))
            guard let self, !Task.isCancelled else { return }
            hudVisible = false
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            hideHUD?(); hudMessage = nil
        }
    }

    func prepareToQuit() async {
        insertionTestTask?.cancel()
        microphoneCheck.stop()
        editSaveTask?.cancel(); persist()
        if speech.phase == .recording { await finishRecording() }
        else if speech.phase == .finishing || (speech.phase == .idle && activeID != nil) { await recordingTask?.value }
        else if speech.phase.isBusy {
            recordingTask?.cancel()
            checkpoint(); await speech.abort(); updateActive(status: .interrupted); persist(); activeID = nil
        }
        speech.localSpeech.parakeet.stop()
        stopPlayback()
    }

    func flushEdits() { insertionTestTask?.cancel(); editSaveTask?.cancel(); persist() }

    private func seedPreview() {
        let samples: [(String, String, Double, Bool)] = [
            ("A tiny idea for a better morning", "What if I left my phone in the kitchen tonight and put a book on my bedside table instead? Less scrolling, more sleep. A small experiment for the week.", 22, true),
            ("The next version should feel effortless", "The next version should feel effortless. One shortcut, a little moment of magic, and your words land exactly where you need them. Let’s make the everyday things feel good.", 19, false),
            ("Hey, just a quick thought on the project", "Hey, just a quick thought on the project. I think we can simplify the first screen and give people one really clear place to start. Happy to sketch something out this afternoon.", 16, false),
            ("Remember to book a table for Friday", "Remember to book a table for Friday, pick up coffee beans, and send the photos from the weekend. Also, that little bakery on the corner was incredible.", 14, true)
        ]
        for (i, sample) in samples.enumerated() {
            var entry = Transcript()
            entry.text = sample.1; entry.originalText = sample.1; entry.duration = sample.2
            entry.isFavorite = sample.3; entry.status = .complete
            entry.sourceApp = ["Notes", "Slack", "Mail", "Murmur"][i]
            entry.createdAt = Date().addingTimeInterval(Double(-i * 3600))
            transcripts.append(entry)
        }
        selectedID = nil
    }
}
