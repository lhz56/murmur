import AppKit
import ApplicationServices
import EventKit
import Foundation
import OSLog
import UserNotifications

/// Meetings: detecting calls, recording and transcribing them live, writing
/// notes afterwards, and the calendar. Owned by `AppModel`.
@MainActor
final class MeetingCenter: ObservableObject {
    enum AutoStart: String, CaseIterable, Identifiable {
        case ask = "Ask me", always = "Start automatically", never = "Don’t detect calls"
        var id: String { rawValue }
    }

    /// A call another app started that Murmur could take notes for.
    struct DetectedCall: Equatable {
        let app: String
        let bundleID: String
        var event: CalendarEvent?
    }

    struct CalendarEvent: Equatable, Identifiable {
        let id: String
        let title: String
        let start: Date
        let end: Date
        let attendees: [String]
        let joinURL: URL?
        var agenda: String? = nil
        var isNow: Bool { start.addingTimeInterval(-300) <= Date() && end > Date() }
    }

    @Published private(set) var meetings: [Meeting] = []
    @Published var selectedID: UUID?
    @Published private(set) var liveID: UUID?
    @Published private(set) var micLevel: Float = 0
    @Published private(set) var systemLevel: Float = 0
    @Published private(set) var writing: [UUID: String] = [:]
    /// Notes as they're being written, shown live in place of a spinner.
    @Published private(set) var drafts: [UUID: MeetingNotes] = [:]
    @Published private(set) var asking: Set<UUID> = []
    /// Answers as they're written.
    @Published private(set) var answerDrafts: [UUID: String] = [:]
    @Published var detected: DetectedCall?
    @Published private(set) var upcoming: [CalendarEvent] = []
    @Published private(set) var calendarConnected = EKEventStore.authorizationStatus(for: .event) == .fullAccess
    @Published private(set) var writerName = ""
    @Published private(set) var pendingPieces = 0
    @Published var search = ""
    @Published var errorMessage: String?
    @Published private(set) var systemAudioWarning: String?

    @Published var autoStart: AutoStart { didSet { defaults.set(autoStart.rawValue, forKey: "meetingAutoStart"); refreshDetection() } }
    @Published var autoStop: Bool { didSet { defaults.set(autoStop, forKey: "meetingAutoStop") } }
    @Published var captureSystemAudio: Bool { didSet { defaults.set(captureSystemAudio, forKey: "meetingSystemAudio") } }
    @Published var defaultTemplate: MeetingTemplate { didSet { defaults.set(defaultTemplate.rawValue, forKey: "meetingTemplate") } }
    @Published var notesModel: String { didSet { defaults.set(notesModel, forKey: "meetingModel") } }

    private let defaults: UserDefaults
    private let storeURL: URL
    private let audioFolder: URL
    private let canWrite: Bool
    private var recorder: MeetingRecorder?
    /// Pieces waiting to be transcribed, each with the meeting it belongs to.
    private var queue: [(piece: MeetingRecorder.Piece, meeting: UUID)] = []
    /// The meeting whose piece is being transcribed right now.
    private var transcribingMeeting: UUID?
    /// Characters transcribed so far per live meeting, and when long-meeting digests were last checked.
    private var liveCharacters: [UUID: Int] = [:]
    private var digestCheckedAt: [UUID: Int] = [:]
    private let saveGate = SaveGate()
    private var transcribing = false
    private var piecesHeard: [MeetingSegment.Speaker: Int] = [:]
    private var calendarTicks = 0
    /// Parts of long meetings already condensed, keyed by the part's text.
    private var digests: [String: String] = [:]
    private var digesting = false
    /// A piece failed to transcribe; told once, cleared when the next piece works.
    private var transcriptionTrouble = false
    @Published private(set) var pendingQuestion: [UUID: String] = [:]
    /// The context size the notes model was loaded with when the meeting ended.
    private var warmContexts: [UUID: Int] = [:]
    /// You're being heard but the other side isn't: system audio is probably not allowed.
    @Published private(set) var otherSideSilent = false
    private var saveTask: Task<Void, Never>?
    private var detectionTimer: Timer?
    private var levelTimer: Timer?
    private var callSeen: [String: Int] = [:]
    private var dismissed: Set<String> = []
    private var startedFromCall: String?
    private var callGoneSince: Date?
    private var eventStore: EKEventStore?
    private let log = Logger(subsystem: "app.murmur.mac", category: "Meetings")

    /// Set by AppModel: the speech helper, cleanup, vocabulary and the mic in use.
    var transcribe: ((URL) async throws -> String)?
    /// Starts loading the speech model, so the first words aren't delayed.
    var prewarm: () -> Void = {}
    var cleanup: ((String) -> String) = { $0 }
    var vocabulary: () -> [String] = { [] }
    var microphoneUID: () -> String = { "" }
    var isDictating: () -> Bool = { false }
    var onLiveChanged: ((Bool) -> Void)?
    var onDetectedChanged: ((DetectedCall?) -> Void)?
    var showMeeting: (() -> Void)?
    var userName: String = {
        let full = NSFullUserName().trimmingCharacters(in: .whitespaces)
        return full.split(separator: " ").first.map(String.init) ?? (full.isEmpty ? "Me" : full)
    }()

    init(root: URL, defaults: UserDefaults, canWrite: Bool) {
        self.defaults = defaults
        self.canWrite = canWrite
        storeURL = root.appendingPathComponent("meetings.json")
        audioFolder = FileManager.default.temporaryDirectory.appendingPathComponent("Murmur-meeting-audio", isDirectory: true)
        autoStart = AutoStart(rawValue: defaults.string(forKey: "meetingAutoStart") ?? "") ?? .ask
        autoStop = defaults.object(forKey: "meetingAutoStop") as? Bool ?? true
        captureSystemAudio = defaults.object(forKey: "meetingSystemAudio") as? Bool ?? true
        defaultTemplate = MeetingTemplate(rawValue: defaults.string(forKey: "meetingTemplate") ?? "") ?? .auto
        notesModel = defaults.string(forKey: "meetingModel") ?? ""
        load()
        try? FileManager.default.removeItem(at: audioFolder)
        // A meeting that was live when Murmur quit gets its notes written now.
        for meeting in meetings where meeting.status == .live || meeting.status == .writing {
            if let i = index(meeting.id) { meetings[i].status = .writing; meetings[i].endedAt = meetings[i].endedAt ?? meetings[i].segments.last.map { meetings[i].createdAt.addingTimeInterval($0.end) } ?? meetings[i].createdAt }
            let id = meeting.id
            Task { [weak self] in try? await Task.sleep(for: .seconds(3)); self?.writeNotes(id) }
        }
    }

    /// Sample meetings for preview mode and screenshots.
    func seed(_ samples: [Meeting]) { meetings = samples; selectedID = samples.first?.id }

    // MARK: Library

    var visible: [Meeting] {
        let active = meetings.filter { $0.deletedAt == nil }
        guard !search.isEmpty else { return active }
        let terms = LibrarySearch.terms(search)
        return active.filter { meeting in
            let haystack = [meeting.displayTitle, meeting.myNotes, meeting.attendees.joined(separator: " "),
                            meeting.notes.map { $0.markdown(title: "", date: meeting.createdAt) } ?? "",
                            meeting.segments.map(\.text).joined(separator: " ")].joined(separator: "\n")
            return LibrarySearch.matches(haystack, terms: terms)
        }
    }
    var selected: Meeting? { meetings.first { $0.id == selectedID } }
    var live: Meeting? { meetings.first { $0.id == liveID } }
    func index(_ id: UUID?) -> Int? { meetings.firstIndex { $0.id == id } }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL) else { return }
        meetings = (try? JSONDecoder.iso.decode([Meeting].self, from: data)) ?? []
    }

    /// Saves soon; several quick changes are written once.
    func save(now: Bool = false) {
        guard canWrite else { return }
        saveTask?.cancel()
        let url = storeURL
        let snapshot = meetings
        // Writes happen one at a time, and an older snapshot never lands after a newer one.
        let gate = saveGate, version = gate.next()
        let write = { gate.commit(version) { guard let data = try? JSONEncoder.iso.encode(snapshot) else { return }; try? data.write(to: url, options: .atomic) } }
        if now { write(); return }
        saveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            write()
        }
    }

    func update(_ id: UUID, _ change: (inout Meeting) -> Void) {
        guard let i = index(id) else { return }
        change(&meetings[i]); save()
    }

    func trash(_ id: UUID) {
        guard id != liveID else { return }
        update(id) { $0.deletedAt = Date() }
        if selectedID == id { selectedID = visible.first?.id }
    }

    // MARK: Recording

    /// Starts taking notes. `call` names the app the call is in, when known.
    func start(app: String = "", event: CalendarEvent? = nil, fromCall bundleID: String? = nil) {
        guard liveID == nil else { selectedID = liveID; showMeeting?(); return }
        guard transcribe != nil else { errorMessage = "Meeting notes need the Parakeet speech model. Install it in Settings → Transcription."; return }
        var meeting = Meeting()
        meeting.app = app
        meeting.template = defaultTemplate
        let current = event ?? upcoming.first { $0.isNow }
        if let current {
            meeting.title = current.title; meeting.attendees = current.attendees; meeting.eventID = current.id
            meeting.agenda = current.agenda
        }
        meetings.insert(meeting, at: 0)
        liveID = meeting.id; selectedID = meeting.id
        startedFromCall = bundleID; callGoneSince = nil
        detected = nil; onDetectedChanged?(nil)
        save(now: true)
        prewarm()
        piecesHeard = [:]
        let recorder = MeetingRecorder(folder: audioFolder.appendingPathComponent(meeting.id.uuidString, isDirectory: true))
        liveCharacters[meeting.id] = 0; digestCheckedAt[meeting.id] = 0
        recorder.onPiece = { [weak self] piece in self?.enqueue(piece, for: meeting.id) }
        self.recorder = recorder
        onLiveChanged?(true)
        Task {
            do {
                try await recorder.start(microphoneUID: microphoneUID(), systemAudio: captureSystemAudio)
                systemAudioWarning = recorder.systemAudioError
            } catch {
                errorMessage = "Murmur couldn’t start recording the meeting. \(error.localizedDescription)"
                stop(discardIfEmpty: true)
            }
        }
        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let recorder = self.recorder else { return }
                self.micLevel = recorder.micLevel; self.systemLevel = recorder.systemLevel
                // Your microphone is left out while you dictate somewhere else.
                recorder.micPaused = self.isDictating()
            }
        }
        refreshDetection()
    }

    /// Ends the meeting; notes are written once the last words are transcribed.
    func stop(discardIfEmpty: Bool = false) {
        guard let id = liveID else { return }
        recorder?.stop()
        levelTimer?.invalidate(); levelTimer = nil
        micLevel = 0; systemLevel = 0
        liveID = nil; startedFromCall = nil; callGoneSince = nil; otherSideSilent = false
        onLiveChanged?(false)
        update(id) { $0.endedAt = Date(); $0.status = .writing }
        if discardIfEmpty, let i = index(id), meetings[i].segments.isEmpty, meetings[i].myNotes.isEmpty {
            meetings.remove(at: i); save(); selectedID = meetings.first?.id; recorder = nil; return
        }
        // Load the notes model while the last words are transcribed, so writing starts at once.
        if let meeting = meetings.first(where: { $0.id == id }) {
            let me = userName, words = vocabulary(), model = notesModel
            let context = MeetingWriter.contextSize(for: meeting, me: me, vocabulary: words, extra: 3_000 + pending(for: id) * 400)
            warmContexts[id] = context
            Task.detached(priority: .userInitiated) {
                if case .ollama(let name) = (await Writer.best(saved: model)).kind,
                   MeetingTranscript.formatted(meeting.segments, me: me).count <= Writer(kind: .ollama(name)).budget {
                    await LocalLLM.warm(name, context: context)
                }
            }
        }
        let stopped = recorder
        Task {
            // Let this meeting's last pieces finish transcribing before writing, however long that takes
            // (the speech model may still be loading); a newer meeting can start meanwhile.
            await drain(id, upTo: 900)
            if recorder === stopped { recorder = nil }
            writeNotes(id)
        }
        refreshDetection()
    }

    /// Pieces of a meeting not yet transcribed, including the one in progress.
    private func pending(for id: UUID) -> Int {
        queue.filter { $0.meeting == id }.count + (transcribingMeeting == id ? 1 : 0)
    }

    /// Waits until a meeting's audio is all transcribed, for at most `seconds`.
    private func drain(_ id: UUID, upTo seconds: Int) async {
        for _ in 0..<(seconds * 4) where pending(for: id) > 0 { try? await Task.sleep(for: .milliseconds(250)) }
    }

    private func enqueue(_ piece: MeetingRecorder.Piece, for id: UUID) {
        queue.append((piece, id)); pendingPieces = queue.count
        guard !transcribing else { return }
        transcribing = true
        Task {
            while !queue.isEmpty {
                let (next, id) = queue.removeFirst(); pendingPieces = queue.count
                transcribingMeeting = id
                defer { try? FileManager.default.removeItem(at: next.url); transcribingMeeting = nil }
                guard let transcribe else { continue }
                do {
                    piecesHeard[next.speaker, default: 0] += 1
                    otherSideSilent = captureSystemAudio && (piecesHeard[.me] ?? 0) >= 4 && (piecesHeard[.them] ?? 0) == 0
                    let raw: String
                    do { raw = try await transcribe(next.url) }
                    catch {
                        // One more try: the speech helper restarts itself after a crash.
                        try? await Task.sleep(for: .seconds(2))
                        do { raw = try await transcribe(next.url) }
                        catch {
                            if !transcriptionTrouble {
                                transcriptionTrouble = true
                                errorMessage = "Part of the meeting couldn’t be transcribed (\(error.localizedDescription)). Murmur keeps listening and will retry the next part."
                            }
                            throw error
                        }
                    }
                    transcriptionTrouble = false
                    let text = cleanup(raw).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty, text.contains(where: \.isLetter), let i = index(id) else { continue }
                    let segment = MeetingSegment(speaker: next.speaker, start: next.start, end: next.start + next.length, text: text)
                    if segment.speaker == .me, MeetingTranscript.isEcho(segment, among: meetings[i].segments) { continue }
                    // Keep the transcript in spoken order across both sides.
                    let position = meetings[i].segments.lastIndex { $0.start <= segment.start }.map { $0 + 1 } ?? 0
                    meetings[i].segments.insert(segment, at: position)
                    // An echo heard on the mic before the other side's copy arrived.
                    if segment.speaker == .them {
                        meetings[i].segments.removeAll { $0.speaker == .me && MeetingTranscript.isEcho($0, among: [segment]) }
                    }
                    save()
                    liveCharacters[id, default: 0] += text.count + 12
                    digestFinishedParts(of: id)
                } catch {
                    log.error("Meeting piece failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            transcribing = false
        }
    }

    // MARK: Notes

    /// In a long meeting, each finished part of the transcript is condensed
    /// while the meeting goes on, one at a time, so the notes take seconds
    /// at the end instead of minutes. Short meetings never get here.
    private func digestFinishedParts(of id: UUID) {
        guard !digesting, id == liveID, let meeting = meetings.first(where: { $0.id == id }) else { return }
        // Formatting the whole transcript costs more as the meeting grows: only look again after
        // a few more minutes of talk, and never before there's enough to split into parts.
        let characters = liveCharacters[id] ?? 0
        guard characters > 7_000, characters - (digestCheckedAt[id] ?? 0) >= 2_500 else { return }
        digestCheckedAt[id] = characters
        let me = userName
        let transcript = MeetingTranscript.formatted(meeting.segments, me: me, them: MeetingWriter.othersLabel(meeting))
        // Cheap check first: nothing to do until the transcript passes the smallest budget.
        guard transcript.count > 7_000 else { return }
        digesting = true
        let model = notesModel, known = digests
        Task {
            defer { digesting = false }
            let writer = await Writer.best(saved: model, wake: false)
            guard writer.kind != .none else { return }
            let parts = MeetingTranscript.parts(transcript, limit: writer.budget)
            // The last part is still growing; the one before it is settled once more talk follows.
            guard parts.count > 1, (parts.last?.count ?? 0) > 3_000 else { return }
            for part in parts.dropLast() where known[part] == nil {
                guard liveID == id, let digest = try? await MeetingWriter.digest(part, me: me, writer: writer) else { return }
                digests[part] = digest
            }
        }
    }

    func writeNotes(_ id: UUID, template: MeetingTemplate? = nil) {
        guard let i = index(id), writing[id] == nil else { return }
        if let template { meetings[i].template = template }
        meetings[i].status = .writing
        writing[id] = "Getting ready…"
        drafts[id] = nil
        let meeting = meetings[i]
        let me = userName, words = vocabulary(), model = notesModel, known = digests
        let warm = warmContexts.removeValue(forKey: id)
        Task {
            let notes = await MeetingWriter.write(meeting, me: me, vocabulary: words, savedModel: model, warmContext: warm, digests: known,
                                                  progress: { [weak self] step in self?.writing[id] = step },
                                                  draft: { [weak self] draft in self?.drafts[id] = draft })
            writing[id] = nil
            drafts[id] = nil
            update(id) { meeting in
                // Keep checked-off action items checked when notes are rewritten.
                let done = Set((meeting.notes?.actionItems ?? []).filter(\.done).map(\.task))
                var notes = notes
                for index in notes.actionItems.indices where done.contains(notes.actionItems[index].task) { notes.actionItems[index].done = true }
                meeting.notes = notes
                if meeting.title.isEmpty, !notes.title.isEmpty { meeting.title = notes.title }
                meeting.status = .done
            }
            save(now: true)
            writerName = notes.writer
            if !NSApp.isActive { announce(id, notes: notes) }
        }
    }

    /// "Notes ready" when you've moved on to something else; clicking it opens Murmur on the meeting.
    private func announce(_ id: UUID, notes: MeetingNotes) {
        guard let meeting = meetings.first(where: { $0.id == id }), !meeting.segments.isEmpty else { return }
        selectedID = id
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        let content = UNMutableNotificationContent()
        content.title = "Notes ready · \(meeting.displayTitle)"
        let tasks = notes.actionItems.count
        content.body = notes.summary.isEmpty ? "\(tasks) action items" : String(notes.summary.prefix(160)) + (tasks > 0 ? " · \(tasks) action item\(tasks == 1 ? "" : "s")" : "")
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "meeting-\(id.uuidString)", content: content, trigger: nil))
    }

    /// `label` is what the chat shows for a one-click question ("Catch me up").
    func ask(_ question: String, in id: UUID, label: String? = nil) {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, let meeting = meetings.first(where: { $0.id == id }), !asking.contains(id) else { return }
        asking.insert(id)
        answerDrafts[id] = ""
        pendingQuestion[id] = label ?? question
        let me = userName, model = notesModel
        Task {
            let show: @MainActor (String) -> Void = { [weak self] text in self?.answerDrafts[id] = text }
            let answer = await MeetingWriter.answer(question, about: meeting, me: me, savedModel: model) { text in await show(text) }
            asking.remove(id)
            answerDrafts[id] = nil
            pendingQuestion[id] = nil
            update(id) { $0.chat.append(.init(question: label ?? question, answer: answer)) }
        }
    }

    func toggleAction(_ meetingID: UUID, _ itemID: UUID) {
        update(meetingID) { meeting in
            guard let i = meeting.notes?.actionItems.firstIndex(where: { $0.id == itemID }) else { return }
            meeting.notes?.actionItems[i].done.toggle()
        }
    }

    /// Checks which model will write notes, for the Meetings settings.
    func refreshWriter() {
        Task { writerName = (await Writer.best(saved: notesModel, wake: false)).name }
    }

    // MARK: Call detection

    func refreshDetection() {
        let wanted = autoStart != .never || liveID != nil
        if wanted, detectionTimer == nil {
            detectionTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.checkCalls() }
            }
            detectionTimer?.tolerance = 1
        } else if !wanted {
            detectionTimer?.invalidate(); detectionTimer = nil
            if detected != nil { detected = nil; onDetectedChanged?(nil) }
        }
    }

    func dismissDetected() {
        if let detected { dismissed.insert(detected.bundleID) }
        detected = nil; onDetectedChanged?(nil)
    }

    private func checkCalls() {
        // Keep "Coming up" current without asking the calendar every few seconds.
        calendarTicks += 1
        if calendarConnected, calendarTicks % 60 == 1 { refreshCalendar() }
        let clients = AudioProcesses.microphoneClients()
        var calls: [(name: String, bundleID: String, pid: pid_t)] = []
        for client in clients {
            if let call = Self.call(for: client) { calls.append(call) }
        }
        let active = Set(calls.map(\.bundleID))
        // Notes started by hand or from the calendar follow the call app that joins.
        if liveID != nil, startedFromCall == nil, let first = calls.first { startedFromCall = first.bundleID }
        // Auto-stop: the call app let go of the microphone and stayed quiet.
        if liveID != nil, let source = startedFromCall {
            if active.contains(source) { callGoneSince = nil }
            else if autoStop {
                callGoneSince = callGoneSince ?? Date()
                if let since = callGoneSince, Date().timeIntervalSince(since) > 15, systemLevel < 0.05 { stop() }
            }
            return
        }
        guard liveID == nil, autoStart != .never else { return }
        callSeen = callSeen.filter { active.contains($0.key) }
        dismissed = dismissed.filter { active.contains($0) || $0.hasPrefix("event:") }
        for call in calls { callSeen[call.bundleID, default: 0] += 1 }
        if let detected, !detected.bundleID.hasPrefix("event:"), !active.contains(detected.bundleID) { self.detected = nil; onDetectedChanged?(nil) }
        if detected == nil, calls.isEmpty, let soon = upcoming.first(where: { $0.joinURL != nil && abs($0.start.timeIntervalSinceNow) < 60 }),
           !dismissed.contains("event:" + soon.id) {
            // A calendar call is about to start: offer to join it and take notes in one click.
            detected = DetectedCall(app: soon.joinURL.flatMap { MeetingApps.site(fromTitle: $0.host ?? "") } ?? "Calendar",
                                    bundleID: "event:" + soon.id, event: soon)
            onDetectedChanged?(detected)
            return
        }
        if let detected, detected.bundleID.hasPrefix("event:") {
            // Once the call app picks up the microphone, the event offer becomes a call offer.
            if !calls.isEmpty { self.detected = nil } else { return }
        }
        guard detected == nil, let call = calls.first(where: { (callSeen[$0.bundleID] ?? 0) >= 2 && !dismissed.contains($0.bundleID) }) else { return }
        var name = call.name
        if MeetingApps.isBrowser(name) {
            // A browser using the mic is only a call if a call site is open, or it keeps going.
            if let site = Self.windowTitles(pid: call.pid).lazy.compactMap(MeetingApps.site).first { name = site }
            else if (callSeen[call.bundleID] ?? 0) < 10 { return }
        }
        let event = upcoming.first { $0.isNow }
        if autoStart == .always { start(app: name, event: event, fromCall: call.bundleID); return }
        detected = DetectedCall(app: name, bundleID: call.bundleID, event: event)
        onDetectedChanged?(detected)
    }

    /// The app behind a microphone user, if it's one people take calls in.
    private static func call(for client: AudioProcesses.Client) -> (name: String, bundleID: String, pid: pid_t)? {
        let app = NSRunningApplication(processIdentifier: client.pid)
        let bundleID = client.bundleID.isEmpty ? app?.bundleIdentifier ?? "" : client.bundleID
        if let name = MeetingApps.name(for: bundleID) {
            // Use the main app's process for helpers (e.g. Chrome's audio helper).
            let main = NSWorkspace.shared.runningApplications.first { running in
                guard let id = running.bundleIdentifier, running.activationPolicy == .regular else { return false }
                return bundleID.hasPrefix(id)
            }
            return (name, main?.bundleIdentifier ?? bundleID, main?.processIdentifier ?? client.pid)
        }
        // Any other regular app using the mic (a new call app), but not system services.
        guard let app, app.activationPolicy == .regular, let id = app.bundleIdentifier, MeetingApps.name(for: id) == nil,
              !id.hasPrefix("com.apple."), !id.hasPrefix("app.murmur") else { return nil }
        let ignored = ["com.wispr", "com.superwhisper", "com.obsproject", "com.loom.desktop", "com.voicememos"]
        guard !ignored.contains(where: id.hasPrefix) else { return nil }
        return (app.localizedName ?? "Call", id, client.pid)
    }

    private static func windowTitles(pid: pid_t) -> [String] {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return [] }
        return windows.prefix(12).compactMap { window in
            var title: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title) == .success else { return nil }
            return title as? String
        }
    }

    // MARK: Calendar

    func connectCalendar() {
        let store = EKEventStore()
        Task {
            do {
                calendarConnected = try await store.requestFullAccessToEvents()
                if calendarConnected { eventStore = store; refreshCalendar() }
                else { errorMessage = "Calendar access is off. Turn it on in System Settings → Privacy & Security → Calendars." }
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func refreshCalendar() {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { calendarConnected = false; upcoming = []; return }
        calendarConnected = true
        let store = eventStore ?? EKEventStore()
        eventStore = store
        let start = Date().addingTimeInterval(-3600)
        let end = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date()))!.addingTimeInterval(6 * 3600)
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        upcoming = store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.endDate > Date() && $0.status != .canceled }
            .sorted { $0.startDate < $1.startDate }
            .prefix(8)
            .map { event in
                let people = (event.attendees ?? []).filter { !$0.isCurrentUser }.compactMap { $0.name ?? $0.url.absoluteString.replacingOccurrences(of: "mailto:", with: "") }
                return CalendarEvent(id: event.eventIdentifier ?? UUID().uuidString, title: event.title ?? "Untitled event",
                                     start: event.startDate, end: event.endDate, attendees: Array(people.prefix(12)),
                                     joinURL: Self.joinLink(event), agenda: MeetingAgenda.clean(event.notes))
            }
    }

    private static let linkPattern = try! NSRegularExpression(pattern:
        "https://(?:[\\w-]+\\.)?(?:zoom\\.us/[jw]/\\S+|meet\\.google\\.com/[a-z-]+|teams\\.microsoft\\.com/l/meetup-join/\\S+|teams\\.live\\.com/\\S+|whereby\\.com/\\S+|[\\w-]+\\.webex\\.com/\\S+|discord\\.gg/\\S+)", options: [.caseInsensitive])

    static func joinLink(_ event: EKEvent) -> URL? {
        if let url = event.url, url.scheme?.hasPrefix("http") == true, linkMatch(url.absoluteString) != nil { return url }
        for text in [event.location, event.notes, event.url?.absoluteString].compactMap({ $0 }) {
            if let link = linkMatch(text) { return URL(string: link) }
        }
        return nil
    }

    static func linkMatch(_ text: String) -> String? {
        guard let match = linkPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text) else { return nil }
        return String(text[range]).trimmingCharacters(in: CharacterSet(charactersIn: ">)\"'.,"))
    }

    /// Opens the event's call link and starts taking notes.
    func join(_ event: CalendarEvent) {
        if let url = event.joinURL { NSWorkspace.shared.open(url) }
        start(app: event.joinURL.flatMap { MeetingApps.site(fromTitle: $0.host ?? "") } ?? "", event: event)
    }

    /// Something would be lost by quitting right now: a live meeting, or audio not yet transcribed.
    var hasUnsavedAudio: Bool { liveID != nil || !queue.isEmpty || transcribingMeeting != nil }

    /// Before quitting: stop recording and let the last words be transcribed (up to 20 seconds),
    /// so the notes written at the next launch have the end of the meeting too.
    func prepareToQuit() async {
        let id = liveID
        if id != nil {
            recorder?.stop()
            if let id { update(id) { $0.endedAt = Date(); $0.status = .writing } }
            liveID = nil
        }
        for _ in 0..<80 where !queue.isEmpty || transcribingMeeting != nil { try? await Task.sleep(for: .milliseconds(250)) }
        save(now: true)
    }

    func saveForQuit() { save(now: true) }
}


/// Serializes meeting saves: each save gets a number, and a write only lands
/// if no newer save has been asked for since.
final class SaveGate: @unchecked Sendable {
    private let lock = NSLock()
    private var latest = 0
    func next() -> Int { lock.withLock { latest += 1; return latest } }
    func commit(_ version: Int, _ write: () -> Void) {
        lock.withLock { if version == latest { write() } }
    }
}
