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
    @Published var removeFillers: Bool { didSet { defaults.set(removeFillers, forKey: "removeFillers") } }
    @Published var voiceCommands: Bool { didSet { defaults.set(voiceCommands, forKey: "voiceCommands") } }
    @Published var duckAudio: Bool { didSet { defaults.set(duckAudio, forKey: "duckAudio") } }
    @Published var contextWords: Bool { didSet { defaults.set(contextWords, forKey: "contextWords") } }
    @Published var selfCorrections: Bool { didSet { defaults.set(selfCorrections, forKey: "selfCorrections") } }
    @Published var smartFormatting: Bool { didSet { defaults.set(smartFormatting, forKey: "smartFormatting") } }
    @Published var appStyle: Bool { didSet { defaults.set(appStyle, forKey: "appStyle") } }
    @Published var learnFromEdits: Bool { didSet { defaults.set(learnFromEdits, forKey: "learnFromEdits") } }
    @Published var contactNames: Bool { didSet { defaults.set(contactNames, forKey: "contactNames") } }
    @Published var snippets: [TextPolish.Snippet] { didSet { defaults.set(try? JSONEncoder().encode(snippets), forKey: "snippets") } }
    @Published var onboarded: Bool { didSet { defaults.set(onboarded, forKey: "onboarded") } }
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
        removeFillers = defaults.object(forKey: "removeFillers") as? Bool ?? true
        voiceCommands = defaults.object(forKey: "voiceCommands") as? Bool ?? true
        duckAudio = defaults.object(forKey: "duckAudio") as? Bool ?? true
        contextWords = defaults.object(forKey: "contextWords") as? Bool ?? true
        selfCorrections = defaults.object(forKey: "selfCorrections") as? Bool ?? true
        smartFormatting = defaults.object(forKey: "smartFormatting") as? Bool ?? true
        appStyle = defaults.object(forKey: "appStyle") as? Bool ?? true
        learnFromEdits = defaults.object(forKey: "learnFromEdits") as? Bool ?? true
        contactNames = defaults.bool(forKey: "contactNames")
        snippets = defaults.data(forKey: "snippets").flatMap { try? JSONDecoder().decode([TextPolish.Snippet].self, from: $0) } ?? []
        onboarded = defaults.bool(forKey: "onboarded")
        fnEnabled = defaults.object(forKey: "fnEnabled") as? Bool ?? true
        fnBehavior = FnBehavior(rawValue: defaults.string(forKey: "fnBehavior") ?? "") ?? .hold
        dictationKey = DictationKey(rawValue: defaults.string(forKey: "dictationKey") ?? "") ?? .control
        microphoneUID = defaults.string(forKey: "microphoneUID") ?? ""
        recognitionEngine = RecognitionEngine(rawValue: defaults.string(forKey: "recognitionEngine") ?? "") ?? (preview ? .apple : .parakeet)
    }
    /// Filler cleanup is English-only: "um" is a real word in German.
    var cleansFillers: Bool { removeFillers && locale.hasPrefix("en") }
    var usesVoiceCommands: Bool { voiceCommands && locale.hasPrefix("en") }
}

@MainActor
final class AppModel: ObservableObject {
    let speech: DictationEngine
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
    @Published var showOnboarding = false
    /// Answer from Ask, shown above the list while the question is unchanged.
    @Published var answer: (question: String, text: String)?
    @Published var answering = false
    /// Shown in the recording pill while the on-device model works.
    @Published var hudWorking: String?
    /// Text selected when an edit-by-voice recording started.
    private var editSelection: String?
    private var contextTask: Task<Void, Never>?
    private var fixWatch: Task<Void, Never>?
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
    @Published var hudDetail: String?
    var onRecordingChanged: ((Bool) -> Void)?
    var showWindow: (() -> Void)?
    /// Shows the floating pill. `true` also captures Escape to cancel recording.
    var showHUD: ((_ capturesEscape: Bool) -> Void)?
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
    @Published private(set) var deliveryResult: InsertionResult?
    private var writesEnabled = true
    private var historyFailure: String?
    private var recordingTask: Task<Void, Never>?
    private var startingID: UUID?
    private var startupCleanupTasks: [UUID: Task<Void, Never>] = [:]
    private var toastTask: Task<Void, Never>?
    private var editSaveTask: Task<Void, Never>?
    private var hudTask: Task<Void, Never>?
    @Published private(set) var fnHoldInProgress = false
    private var stopRequestedAt: TimeInterval?
    private let timingLog = Logger(subsystem: "app.murmur.mac", category: "Timing")
    private var cachedSounds: [String: NSSound] = [:]

    init(preview: Bool = false, speech engine: DictationEngine? = nil, storageRoot: URL? = nil) {
        self.speech = engine ?? DictationEngine()
        isPreview = preview
        preferences = Preferences(preview: preview)
        let root = storageRoot ?? (preview ? FileManager.default.temporaryDirectory.appendingPathComponent("Murmur-preview-\(UUID().uuidString)") :
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Murmur", isDirectory: true))
        do { storage = try HistoryStorage(root: root) }
        catch {
            storage = HistoryStorage(unpreparedRoot: root)
            writesEnabled = false
            historyFailure = "Murmur couldn’t open its storage folder. Your files have been preserved at \(root.path). \(error.localizedDescription)"
            errorMessage = historyFailure
        }
        if writesEnabled {
            do { transcripts = try storage.load(); try storage.save(transcripts) }
            catch {
                writesEnabled = false
                historyFailure = "History couldn’t be opened. Your files have been preserved at \(root.path). \(error.localizedDescription)"
                errorMessage = historyFailure
            }
        }
        // Only the recording phase affects library-wide controls. Meter, clock and
        // live-text updates arrive many times per second; the views that show them
        // observe `speech` and `microphoneCheck` directly, so the library list and
        // detail pane don't re-render while you talk.
        speech.$phase.removeDuplicates().sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
        preferences.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        speech.onText = { [weak self] text in
            guard let self, let entry = self.selectedActive, entry.status == .recording else { return }
            self.updateActive(text: text)
        }
        speech.onError = { [weak self] error in
            guard let self else { return }
            self.errorMessage = error.localizedDescription
            if self.speech.phase == .recording { self.toggleRecording() }
        }
        speech.localSpeech.parakeet.onReadiness = { [weak self] ready in self?.parakeetReady = ready }
        if preview && storageRoot == nil { seedPreview() }
        Task { await speech.refreshLanguages() }
        if !preview { Task { await speech.warmMicrophone(uid: preferences.microphoneUID) } }
        preferences.$microphoneUID.dropFirst().sink { [weak self] uid in
            Task { @MainActor in await self?.speech.warmMicrophone(uid: uid) }
        }.store(in: &subscriptions)
        if !preview, preferences.recognitionEngine == .parakeet { prepareParakeet(install: false) }
    }

    var visibleTranscripts: [Transcript] {
        let terms = LibrarySearch.terms(search)
        return transcripts.filter { entry in
            let allowed: Bool
            switch filter {
            case .all: allowed = entry.deletedAt == nil
            case .favorites: allowed = entry.deletedAt == nil && entry.isFavorite
            case .trash: allowed = entry.deletedAt != nil
            }
            return allowed && (search.isEmpty || LibrarySearch.matches(entry.text, terms: terms)
                               || entry.sourceApp.localizedCaseInsensitiveContains(search))
        }
    }
    var savedTranscripts: [Transcript] { transcripts.filter { $0.deletedAt == nil && $0.status != .recording } }
    var savedCount: Int { transcripts.reduce(0) { $0 + ($1.deletedAt == nil && $1.status != .recording ? 1 : 0) } }
    var lastTranscript: Transcript? {
        transcripts.first { $0.deletedAt == nil && $0.status == .complete && !$0.text.isEmpty }
    }
    var selected: Transcript? { transcripts.first { $0.id == selectedID } }
    private var selectedActive: Transcript? { transcripts.first { $0.id == activeID } }

    @discardableResult
    private func persist() -> Bool {
        guard writesEnabled else { return false }
        do { try storage.save(transcripts); return true }
        catch { errorMessage = "Couldn’t save history: \(error.localizedDescription). The audio remains in your Murmur folder."; return false }
    }

    private func requireWritableLibrary() -> Bool {
        guard writesEnabled else { errorMessage = historyFailure; return false }
        return true
    }

    func toggleRecording() {
        guard !isTestingFn else { return }
        if speech.phase == .recording {
            queueFinish()
        } else if startingID != nil {
            cancelRecordingStartup()
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
            fnHoldInProgress = true
            if speech.phase == .idle { toggleRecording() }
        case .finishHold:
            let wasFnHeld = fnHoldInProgress
            fnHoldInProgress = false
            if speech.phase == .recording { toggleRecording() }
            else if speech.phase == .preparing || speech.phase == .downloading || (speech.phase == .idle && wasFnHeld) {
                cancelRecordingStartup()
            }
        case .toggle:
            fnHoldInProgress = false; toggleRecording()
        case .latchHold:
            fnHoldInProgress = false
        case .cancelHold:
            fnHoldInProgress = false
            if speech.phase == .recording { cancelRecording() }
            else { cancelRecordingStartup() }
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
        guard !Task.isCancelled else { return }
        guard activeID == nil, speech.phase == .idle else { return }
        guard requireWritableLibrary() else { showWindow?(); return }
        let requestedAt = ProcessInfo.processInfo.systemUptime
        insertionTestTask?.cancel()
        errorMessage = nil
        stopPlayback()
        microphoneCheck.stop()
        pasteTarget = textInsertion.captureDestination()
        deliveryResult = nil
        gatherContext()
        var entry = Transcript()
        entry.locale = preferences.locale
        entry.engineName = preferences.recognitionEngine.rawValue
        entry.sourceApp = pasteTarget?.application.localizedName ?? "Murmur"
        entry.audioFile = "\(entry.id.uuidString).m4a"
        transcripts.insert(entry, at: 0)
        activeID = entry.id
        selectedID = entry.id
        filter = .all; search = ""
        guard persist(), let audioURL = storage.audioURL(for: entry) else {
            transcripts.removeAll { $0.id == entry.id }
            activeID = nil; selectedID = nil; pasteTarget = nil; fnHoldInProgress = false
            return
        }
        hudTask?.cancel(); hudMessage = nil; hudDetail = nil; hudVisible = true; showHUD?(true)
        startingID = entry.id
        do {
            try await speech.start(audioURL: audioURL, localeID: entry.locale, microphoneUID: preferences.microphoneUID,
                                   recognitionEngine: preferences.recognitionEngine, vocabulary: preferences.vocabulary)
            guard !Task.isCancelled, activeID == entry.id, startingID == entry.id else { return }
            startingID = nil
            if let i = index(entry.id) { transcripts[i].microphoneName = speech.inputName }
            onRecordingChanged?(true)
            playSound("start")
            timingLog.info("Recording ready in \((ProcessInfo.processInfo.systemUptime - requestedAt) * 1000, privacy: .public) ms from start request")
            checkpointTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.checkpoint() }
            }
        } catch {
            guard activeID == entry.id, startingID == entry.id else { return }
            startingID = nil
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
            fnHoldInProgress = false
            hudVisible = false; hideHUD?(); onRecordingChanged?(false)
            if !cancelled { errorMessage = error.localizedDescription; showWindow?() }
        }
    }

    private func cancelRecordingStartup() {
        editSelection = nil
        guard startingID != nil || (speech.phase == .idle && activeID == nil) else { return }
        recordingTask?.cancel()
        guard let id = startingID, activeID == id else { return }
        let capturedSignal = speech.signal
        let cleanup = speech.cancelStartup()
        startingID = nil; activeID = nil; pasteTarget = nil
        checkpointTimer?.invalidate(); checkpointTimer = nil
        hudTask?.cancel(); hudTask = nil; hudMessage = nil; hudVisible = false
        hideHUD?(); onRecordingChanged?(false)
        fnHoldInProgress = false
        if let i = index(id) { transcripts[i].status = .interrupted }
        persist()
        startupCleanupTasks[id] = Task { [weak self] in
            let finalSignal = await cleanup?.value ?? capturedSignal
            guard let self else { return }
            defer { self.startupCleanupTasks[id] = nil }
            guard let i = self.index(id) else { return }
            let audioURL = self.storage.audioURL(for: self.transcripts[i])
            if !finalSignal.hasFrames {
                if let audioURL { try? FileManager.default.removeItem(at: audioURL) }
                self.transcripts.remove(at: i)
                if self.selectedID == id { self.selectedID = nil }
            } else {
                self.transcripts[i].duration = max(self.transcripts[i].duration, finalSignal.seconds)
            }
            self.persist()
        }
    }

    private func checkpoint() {
        updateActive(text: speech.liveText, duration: speech.elapsed)
        persist()
    }

    /// Answers a question from the user's own notes with the on-device model,
    /// using matching notes, or the most recent ones when nothing matches.
    func ask(_ question: String) {
        guard !answering else { return }
        let matches = visibleTranscripts.filter { !$0.text.isEmpty }
        let pool = (matches.isEmpty ? savedTranscripts.filter { !$0.text.isEmpty } : matches).prefix(12)
        answering = true
        Task {
            defer { answering = false }
            do {
                let text = try await LocalModel.answer(question, from: pool.map { (date: $0.createdAt, text: $0.text) })
                answer = (question, text)
            } catch { answer = (question, error.localizedDescription) }
        }
    }

    /// Edit by voice: select text in any app, press Control-Option-E, say what
    /// to change ("make this friendlier"), and press it again.
    func toggleEditRecording() {
        guard !isTestingFn else { return }
        if speech.phase == .recording || startingID != nil { toggleRecording(); return }
        guard speech.phase == .idle, activeID == nil else { return }
        if let reason = LocalModel.unavailableReason { flashHUD("Edit by voice needs Apple Intelligence", detail: reason); return }
        let destination = textInsertion.captureDestination()
        guard let selection = textInsertion.selectedText(in: destination), !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            flashHUD("Select some text first", detail: "Then press ⌃⌥E and say how to change it"); return
        }
        editSelection = selection
        toggleRecording()
    }

    /// Turns raw recognizer output into finished text: fillers, replacements and
    /// voice commands, then "scratch that" and self-corrections, addresses and
    /// lists, per-app style, and snippets. Only a heard correction phrase
    /// reaches the on-device model.
    func polish(_ original: String, bundleID: String?, vocabulary: String? = nil,
                removeFillers: Bool? = nil, voiceCommands: Bool? = nil) async -> String {
        var text = TextTools.clean(original, replacements: vocabulary ?? preferences.vocabulary,
                                   removeFillers: removeFillers ?? preferences.cleansFillers,
                                   voiceCommands: voiceCommands ?? preferences.usesVoiceCommands)
        if preferences.locale.hasPrefix("en") {
            if preferences.selfCorrections {
                text = TextPolish.applyingScratchThat(text)
                if TextPolish.hasCorrectionCue(text), let fixed = await LocalModel.resolveSelfCorrections(text) { text = fixed }
            }
            if preferences.smartFormatting { text = TextPolish.formattingLists(TextPolish.formattingAddresses(text)) }
            if preferences.appStyle { text = TextPolish.styled(text, for: .init(bundleID: bundleID)) }
        }
        return TextPolish.expandingSnippets(text, snippets: preferences.snippets)
    }

    /// Collects names and unusual words from the app being dictated into, plus
    /// words corrected in past transcripts, while the user is speaking.
    private func gatherContext() {
        contextTask?.cancel()
        speech.updateContext([])
        guard preferences.contextWords else { contextTask = nil; return }
        let pid = pasteTarget?.application.processIdentifier
        let contacts = preferences.contactNames
        let edits = transcripts.lazy.filter { $0.deletedAt == nil && !$0.originalText.isEmpty && $0.text != $0.originalText }
            .prefix(200).map { (original: $0.originalText, corrected: $0.text) }
        contextTask = Task { [weak self] in
            let terms = await ContextVocabulary.gather(pid: pid, edits: Array(edits), contacts: contacts)
            guard !Task.isCancelled, let self else { return }
            speech.updateContext(terms)
            timingLog.info("Context terms: \(terms.count, privacy: .public)")
        }
    }

    private func finishRecording() async {
        if speech.phase == .recording {
            stopRequestedAt = ProcessInfo.processInfo.systemUptime
            speech.requestStop(); playSound("finish")
        }
        guard speech.phase == .finishing else { return }
        // Context gathering is bounded (~0.3 s) and normally finished long before stop.
        await contextTask?.value
        onRecordingChanged?(false)
        checkpointTimer?.invalidate(); checkpointTimer = nil
        let id = activeID
        do {
            let original = try await speech.stop()
            guard activeID == id, !Task.isCancelled else { return }
            var text = await polish(original, bundleID: pasteTarget?.application.bundleIdentifier)
            guard activeID == id, !Task.isCancelled else { return }
            var editFailed = false
            if let selection = editSelection, !text.isEmpty {
                editSelection = nil
                hudWorking = "Rewriting…"
                defer { hudWorking = nil }
                do { text = try await LocalModel.edit(selection, instruction: text) }
                catch {
                    errorMessage = "Your instruction was saved, but the edit didn’t finish. \(error.localizedDescription)"
                    editFailed = true
                }
                guard activeID == id, !Task.isCancelled else { return }
            }
            editSelection = nil
            updateActive(text: text, duration: speech.elapsed, status: text.isEmpty ? .failed : .complete)
            if let i = index(id) { transcripts[i].originalText = original }
            let review = TranscriptionReview.reason(text: original, confidence: speech.confidence, signal: speech.signal)
            if let i = index(id) {
                transcripts[i].confidence = speech.confidence; transcripts[i].reviewReason = review
                transcripts[i].engineName = speech.selectedEngine.rawValue
            }
            // Deliver immediately when final text exists; history writes and audio
            // retention cleanup should never stand between stop and the clipboard.
            if review == nil, !text.isEmpty, !editFailed { await deliver(text) }
            guard activeID == id, !Task.isCancelled else { return }
            if let requestedAt = stopRequestedAt {
                timingLog.info("Final text ready in \((ProcessInfo.processInfo.systemUptime - requestedAt) * 1000, privacy: .public) ms; clipboard enabled: \(self.preferences.autoCopy, privacy: .public)")
            }
            guard persist() else {
                activeID = nil; onRecordingChanged?(false); dismissHUD(message: "Recording kept"); return
            }
            // Audio is captured for crash recovery even when retention is disabled.
            if !preferences.keepAudio, !text.isEmpty, review == nil,
               let i = index(id), let url = storage.audioURL(for: transcripts[i]) {
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
            guard activeID == id else { return }
            updateActive(text: speech.liveText, duration: speech.elapsed, status: .interrupted)
            persist()
            errorMessage = "Your recording was kept. \(error.localizedDescription)"
            showWindow?()
        }
        activeID = nil
        stopRequestedAt = nil
        fnHoldInProgress = false
        onRecordingChanged?(false)
        let finished = transcripts.first { $0.id == id }
        let heardNothing = speech.liveText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let message: String
        if finished?.reviewReason != nil { message = "Saved · check this thought" }
        else if heardNothing { message = "No clear speech · audio kept" }
        else if errorMessage != nil { message = "Recording kept" }
        else { message = deliveryResult?.hudMessage ?? (preferences.autoCopy ? "Copied · ready to paste" : "Saved · ready to copy") }
        if let words = finished?.wordCount, words > 0, errorMessage == nil {
            hudDetail = "\(words) word\(words == 1 ? "" : "s") · saved to your library"
        }
        dismissHUD(message: message)
    }

    func cancelRecording() {
        editSelection = nil
        if startingID != nil { cancelRecordingStartup(); return }
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
            fnHoldInProgress = false
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
        guard requireWritableLibrary(), let i = index(id), id != activeID, transcripts[i].deletedAt == nil else { return }
        transcripts[i].text = text
        editSaveTask?.cancel()
        editSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.persist()
        }
    }
    func favorite(_ id: UUID) {
        guard requireWritableLibrary(), let i = index(id) else { return }
        transcripts[i].isFavorite.toggle(); persist()
    }
    func trash(_ id: UUID) {
        guard requireWritableLibrary(), let i = index(id), id != activeID else { return }
        if playingID == id { stopPlayback() }
        transcripts[i].deletedAt = Date(); selectedID = nil; persist()
        notify("Moved to Trash · restore it anytime")
    }
    func restore(_ id: UUID) {
        guard requireWritableLibrary(), let i = index(id), id != activeID else { return }
        transcripts[i].deletedAt = nil; persist(); notify("Restored to your library")
    }
    func permanentlyDelete(_ id: UUID) {
        guard requireWritableLibrary(), let i = index(id), id != activeID, transcripts[i].deletedAt != nil else { return }
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

    /// Copies and/or pastes finished text. `paste` overrides the Insert preference
    /// for explicit commands such as Paste Last Transcript.
    func deliver(_ text: String, paste: Bool? = nil) async {
        let shouldPaste = paste ?? preferences.autoPaste
        let destination = pasteTarget
        pasteTarget = nil
        deliveryResult = nil
        accessibilityEnabled = AXIsProcessTrusted()
        let pasteboard = NSPasteboard.general
        // Without "Copy to clipboard", insertion only borrows the clipboard and
        // restores the user's previous contents once the paste is confirmed.
        let borrowed = shouldPaste && !preferences.autoCopy ? PasteboardSnapshot(pasteboard) : nil
        let text = shouldPaste ? TextTools.spaced(text, after: textInsertion.characterBeforeCaret(in: destination)) : text
        if preferences.autoCopy || shouldPaste {
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }
        let written = pasteboard.changeCount
        if shouldPaste {
            let result = await textInsertion.insert(text, into: destination)
            guard !Task.isCancelled else { return }
            deliveryResult = result
            // Unconfirmed pastes keep the transcript on the clipboard as a fallback.
            if case .inserted = result, let borrowed, pasteboard.changeCount == written { borrowed.restore(to: pasteboard) }
            if case .inserted = result, preferences.learnFromEdits, let insertion = textInsertion.lastInsertion { watchForFixes(insertion) }
            notify(result.message)
        } else { notify(preferences.autoCopy ? "Saved & copied to clipboard" : "Saved to your library") }
    }

    /// Pastes the most recent transcript into the focused text box.
    func pasteLastTranscript() {
        guard !speech.phase.isBusy, activeID == nil, !isTestingFn else { return }
        guard let entry = lastTranscript else { flashHUD("Nothing to paste yet"); return }
        insertionTestTask?.cancel()
        insertionTestTask = Task { [weak self] in
            guard let self else { return }
            pasteTarget = textInsertion.captureDestination()
            await deliver(entry.text, paste: true)
            guard !Task.isCancelled, let result = deliveryResult else { return }
            flashHUD(result.hudMessage, detail: entry.title)
        }
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

    /// After Murmur types, watch that spot briefly. If you fix a misheard word
    /// before sending or moving on, the fix is learned as a correction.
    private func watchForFixes(_ insertion: TextInsertion.InsertedText) {
        fixWatch?.cancel()
        fixWatch = Task { [weak self] in
            var latest = insertion.text
            for _ in 0..<15 {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self else { return }
                guard let value = textInsertion.value(of: insertion.element), let region = insertion.current(in: value) else { break }
                latest = region
            }
            guard !Task.isCancelled, let self else { return }
            let pairs = CorrectionLearner.pairs(original: insertion.text, edited: latest)
            for pair in pairs { rememberCorrection(heard: pair.heard, desired: pair.desired, announce: false) }
            if let first = pairs.first { notify("Learned “\(first.desired)”") }
        }
    }

    func rememberCorrection(heard: String, desired: String) { rememberCorrection(heard: heard, desired: desired, announce: true) }

    private func rememberCorrection(heard: String, desired: String, announce: Bool) {
        let from = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        let to = desired.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !from.isEmpty, !to.isEmpty, from != to, !from.contains("=>"), !to.contains("=>"),
              !from.contains("\n"), !to.contains("\n"), from.count <= 100, to.count <= 100 else { return }
        let pair = "\(from) => \(to)"
        if !preferences.vocabulary.components(separatedBy: .newlines).contains(pair) {
            preferences.vocabulary += (preferences.vocabulary.isEmpty ? "" : "\n") + pair
        }
        if announce { notify("Correction remembered") }
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
        guard requireWritableLibrary(), speech.phase == .idle, activeID == nil,
              let i = index(entry.id), transcripts[i].deletedAt == nil,
              let url = storage.audioURL(for: transcripts[i]) else { return }
        stopPlayback()
        let locale = transcripts[i].locale
        let engine = preferences.recognitionEngine
        let vocabulary = preferences.vocabulary
        let removeFillers = preferences.cleansFillers
        let voiceCommands = preferences.usesVoiceCommands
        activeID = entry.id; selectedID = entry.id
        errorMessage = nil
        recordingTask = Task {
            defer { if activeID == entry.id { activeID = nil } }
            guard !Task.isCancelled, activeID == entry.id else { return }
            do {
                let original = try await speech.transcribeFile(url, localeID: locale, recognitionEngine: engine, vocabulary: vocabulary)
                guard !Task.isCancelled, activeID == entry.id else { return }
                let text = await polish(original, bundleID: nil, vocabulary: vocabulary, removeFillers: removeFillers, voiceCommands: voiceCommands)
                guard !Task.isCancelled, activeID == entry.id else { return }
                updateActive(text: text, duration: speech.elapsed,
                             status: original.isEmpty ? .failed : .complete)
                if let i = index(entry.id) { transcripts[i].originalText = original }
                if let i = index(entry.id) {
                    transcripts[i].engineName = speech.selectedEngine.rawValue; transcripts[i].confidence = speech.confidence
                    transcripts[i].reviewReason = TranscriptionReview.reason(text: original, confidence: speech.confidence, signal: speech.signal)
                }
                persist(); notify(original.isEmpty ? "No words heard · recording saved" : "Recording transcribed")
            } catch { if !Task.isCancelled, activeID == entry.id { errorMessage = error.localizedDescription } }
        }
    }

    func importAudio() {
        guard requireWritableLibrary(), !speech.phase.isBusy, activeID == nil else { return }
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
            transcripts.insert(entry, at: 0)
            guard persist() else {
                transcripts.removeAll { $0.id == entry.id }
                try? FileManager.default.removeItem(at: destination)
                return
            }
            filter = .all; search = ""
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
            hideHUD?(); hudMessage = nil; hudDetail = nil
        }
    }

    /// Briefly shows a result in the pill when no recording is in progress.
    private func flashHUD(_ message: String, detail: String? = nil) {
        guard activeID == nil, !speech.phase.isBusy else { return }
        hudDetail = detail; hudVisible = true; showHUD?(false)
        dismissHUD(message: message)
    }

    func prepareToQuit() async {
        insertionTestTask?.cancel()
        microphoneCheck.stop()
        editSaveTask?.cancel(); persist()
        if startingID != nil { cancelRecordingStartup() }
        else if speech.phase.isBusy || activeID != nil {
            recordingTask?.cancel()
            if speech.phase == .recording { speech.requestStop() }
            if selectedActive?.status == .recording { checkpoint(); updateActive(status: .interrupted) }
            await speech.abort(); persist(); activeID = nil
        }
        startingID = nil; fnHoldInProgress = false; pasteTarget = nil
        checkpointTimer?.invalidate(); checkpointTimer = nil
        hudTask?.cancel(); hudTask = nil; hudVisible = false; hideHUD?()
        onRecordingChanged?(false)
        speech.localSpeech.parakeet.stop()
        for task in Array(startupCleanupTasks.values) { await task.value }
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
