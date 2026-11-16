import AppKit
import ApplicationServices
import AVFoundation
import Combine
import OSLog

/// Ask: hold Space + Up Arrow and talk. Murmur hears you on your Mac, takes one
/// screenshot of the screen you're on, and asks ChatGPT or Claude (your own
/// subscription, through Codex or Claude Code). The answer is spoken, points at
/// things on screen, and can run Commands or type for you.
@MainActor
final class AssistantCenter: NSObject, ObservableObject {
    enum Phase: Equatable {
        case idle, listening, thinking, answering, done
        /// A walkthrough step is on screen: waiting for you to click it.
        case waiting
        case failed(String)
        var isWorking: Bool { self == .thinking || self == .answering }
    }

    struct Ask: Codable, Identifiable, Equatable {
        var id = UUID()
        var question: String
        var answer: String
        var date = Date()
        var provider: String
    }

    /// Something Ask did for you, shown under the answer.
    struct Outcome: Identifiable, Equatable {
        let id = UUID()
        let title: String
        let problem: String?
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var heard = ""
    @Published private(set) var answer = ""
    @Published private(set) var outcomes: [Outcome] = []
    /// Listening keeps going until you tap again (you tapped instead of holding).
    @Published private(set) var handsFree = false
    @Published private(set) var sawScreen = false
    /// Murmur opened the microphone itself after an answer, so you can just keep talking.
    @Published private(set) var autoListening = false
    /// Which step of a walkthrough this is (0 when it isn't one).
    @Published private(set) var walkStep = 0
    @Published private(set) var recent: [Ask]
    @Published var provider: AssistantProvider { didSet { defaults.set(provider.rawValue, forKey: "assistantProvider"); replaceBrain() } }
    @Published var chatgptModel: String { didSet { defaults.set(chatgptModel, forKey: "assistantChatGPTModel"); replaceBrain() } }
    @Published var claudeModel: String { didSet { defaults.set(claudeModel, forKey: "assistantClaudeModel"); replaceBrain() } }
    @Published var speaks: Bool { didSet { defaults.set(speaks, forKey: "assistantSpeaks"); if !speaks { stopVoices() } } }
    @Published var voiceID: String { didSet { defaults.set(voiceID, forKey: "assistantVoice") } }
    /// Speak with Murmur's natural voice (on this Mac) instead of the Mac's system voice.
    @Published var naturalVoice: Bool { didSet { defaults.set(naturalVoice, forKey: "assistantNaturalVoice") } }
    @Published var naturalVoiceID: String { didSet { defaults.set(naturalVoiceID, forKey: "assistantNaturalVoiceID"); natural.voice = naturalVoiceID } }
    let natural = NaturalVoice()
    @Published var enabled: Bool { didSet { defaults.set(enabled, forKey: "assistantEnabled"); if !enabled { cancel() } } }
    /// Ask may click buttons for you when you ask it to.
    @Published var clicks: Bool { didSet { defaults.set(clicks, forKey: "assistantClicks") } }
    /// After an answer, listen a few seconds more for a follow-up.
    @Published var keepsListening: Bool { didSet { defaults.set(keepsListening, forKey: "assistantKeepsListening") } }

    var model: String {
        get { provider == .chatgpt ? chatgptModel : claudeModel }
        set { if provider == .chatgpt { chatgptModel = newValue } else { claudeModel = newValue } }
    }
    var modelName: String { provider.models.first { $0.id == model }?.name ?? model }

    // Wired by AppModel and AppDelegate.
    var startListening: (() async throws -> Void)?
    var finishListening: (() async throws -> String)?
    var cancelListening: (() async -> Void)?
    var liveTranscript: () -> String = { "" }
    var inputLevel: () -> Float = { 0 }
    var click: @MainActor (CGPoint, String, ScreenClick.Observation?) async -> String? = { await ScreenClick.click(at: $0, label: $1, observation: $2) }
    var captureTypingDestination: (() -> Void)?
    /// Runs a command Ask proposed, checked against what you actually said.
    var runCommand: ((_ command: String, _ request: String) async -> (title: String, problem: String?))?
    var typeText: ((String) async -> String?)?
    var selectedText: () -> String? = { nil }
    var show: (() -> Void)?
    var hide: (() -> Void)?
    var pointAt: (([(CGPoint, String)]) -> Void)?
    var clearPoints: (() -> Void)?
    /// Murmur pressed a control (true) or left it for you (false), at this spot.
    var showClick: ((CGPoint, Bool) -> Void)?
    var playSound: ((String) -> Void)?
    /// Space + ↓: the on-Mac model's plan for what Murmur can do itself (open, press, type, play…),
    /// already checked against your words. Nil goes to Ask. About half a second, no internet.
    var planWithModel: ((String) async -> CommandAction?)?
    /// Runs that plan. Nil means Commands took it over (it asks before something that can't be undone).
    /// The last argument hears each step as it starts, so the checklist ticks off live.
    var runLocally: ((CommandAction, String, (() async -> Bool)?, @escaping (Int) -> Void) async -> (title: String, problem: String?)?)?
    /// This turn ran on this Mac, with no AI round trip.
    @Published private(set) var ranLocally = false
    /// The plan made on this Mac, shown before it runs ("Open T3 Code", "Click “launch notes”", "Type “…”").
    @Published private(set) var plannedSteps: [String] = []
    /// While set, the plan is on screen and Esc still stops it: it runs at this moment.
    @Published private(set) var runsAt: Date?
    /// The step of the plan that's running now (the ones before it are done).
    @Published private(set) var stepAt = 0
    /// The step that waits for the countdown (the first click or typing).
    @Published private(set) var gateIndex: Int?
    /// How long a plan stays on screen before it runs.
    static let previewTime: TimeInterval = 0.9

    private let defaults: UserDefaults
    private let makeBrain: ((AssistantProvider, String) -> AssistantBrain)?
    var captureScreen: @MainActor () async -> ScreenShot? = {
        guard ScreenGrab.allowed else { return nil }
        return try? await AssistantDeadline.run(timeout: .seconds(8)) { try await ScreenGrab.capture() }
    }
    private var brain: AssistantBrain?
    private var work: Task<Void, Never>?
    private var shot: Task<ScreenShot?, Never>?
    private var context = (app: "", window: "", selection: String?.none)
    private var spokenOffset = 0
    private var shownPoints = 0
    private var intent = AssistantIntent("")
    private var originalRequest = ""
    private var waitingPoints: [CGPoint] = []
    /// The controls the step pointed at, so a click anywhere on them counts.
    private var waitingControls: [AXUIElement] = []
    private var lastScreenData: Data?
    private var waitingObservation: ScreenClick.Observation?
    private var actionObservation: ScreenClick.Observation?
    private var lastAnswerAt = Date.distantPast
    private var hideTask: Task<Void, Never>?
    /// The follow-up microphone, and waiting out a walkthrough step.
    private var afterTask: Task<Void, Never>?
    private var clickWatcher: Any?
    private var murmurClickedAt = Date.distantPast
    private var clickedThisTurn = false
    /// Walkthrough steps Murmur clicked through in a row, without you.
    private var autoTurns = 0
    /// Bumped by every new question or cancel, so a late answer never shows up under a newer one.
    private var generation = 0
    private let synthesizer = AVSpeechSynthesizer()
    private var subscriptions = Set<AnyCancellable>()
    /// Talking right now, in either voice.
    var isSpeaking: Bool { synthesizer.isSpeaking || natural.isSpeaking }
    private var usesNatural: Bool { naturalVoice && natural.canSpeak }
    private let log = Logger(subsystem: "app.murmur.mac", category: "Assistant")

    init(defaults: UserDefaults, makeBrain: ((AssistantProvider, String) -> AssistantBrain)? = nil) {
        self.makeBrain = makeBrain
        self.defaults = defaults
        provider = AssistantProvider(rawValue: defaults.string(forKey: "assistantProvider") ?? "") ?? .chatgpt
        chatgptModel = defaults.string(forKey: "assistantChatGPTModel") ?? AssistantProvider.chatgpt.defaultModel
        claudeModel = defaults.string(forKey: "assistantClaudeModel") ?? AssistantProvider.claude.defaultModel
        speaks = defaults.object(forKey: "assistantSpeaks") as? Bool ?? true
        voiceID = defaults.string(forKey: "assistantVoice") ?? ""
        naturalVoice = defaults.object(forKey: "assistantNaturalVoice") as? Bool ?? true
        naturalVoiceID = defaults.string(forKey: "assistantNaturalVoiceID") ?? NaturalVoice.defaultVoice
        enabled = defaults.object(forKey: "assistantEnabled") as? Bool ?? true
        clicks = defaults.object(forKey: "assistantClicks") as? Bool ?? true
        keepsListening = defaults.object(forKey: "assistantKeepsListening") as? Bool ?? true
        recent = defaults.data(forKey: "assistantRecent").flatMap { try? JSONDecoder().decode([Ask].self, from: $0) } ?? []
        super.init()
        synthesizer.delegate = self
        if !NaturalVoice.choices.contains(where: { $0.id == naturalVoiceID }) { naturalVoiceID = NaturalVoice.defaultVoice }
        natural.voice = naturalVoiceID
        natural.onFailure = { [weak self] sentence in self?.sayWithSystemVoice(sentence) }
        natural.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        // A model taken off the menu (or a typo in defaults) falls back to the recommended one.
        if !AssistantProvider.chatgpt.models.contains(where: { $0.id == chatgptModel }) { chatgptModel = AssistantProvider.chatgpt.defaultModel }
        if !AssistantProvider.claude.models.contains(where: { $0.id == claudeModel }) { claudeModel = AssistantProvider.claude.defaultModel }
    }

    var isActive: Bool { phase != .idle }
    var isListening: Bool { phase == .listening }

    private func currentBrain() -> AssistantBrain {
        if let brain { return brain }
        let made: AssistantBrain
        if let makeBrain { made = makeBrain(provider, model) }
        else if provider == .chatgpt { made = CodexBrain(model: chatgptModel) }
        else { made = ClaudeBrain(model: claudeModel) }
        brain = made
        return made
    }

    /// A checkup of the Mac from its readings, by the AI account Ask uses. It runs in a
    /// helper of its own, so it never mixes with a conversation, and gets words only:
    /// no screenshot, and nothing it says is run.
    func checkup(_ readings: String, onText: @escaping @MainActor (String) -> Void) async throws -> String {
        let helper: AssistantBrain
        if let makeBrain { helper = makeBrain(provider, model) }
        else if provider == .chatgpt { helper = CodexBrain(model: chatgptModel, timeout: .seconds(60)) }
        else { helper = ClaudeBrain(model: claudeModel, timeout: .seconds(60)) }
        defer { helper.shutDown() }
        let question = AssistantQuestion(text: """
            Give my Mac a quick checkup from the readings below. In three or four short sentences: how it's doing overall, \
            the one thing that matters most right now, and exactly what I should do about it. If all is well, say so and \
            name one small thing worth knowing. Plain words, no numbers I can already see unless they matter. No tags.

            \(readings)
            """)
        let reply = try await helper.ask(question, followUp: false) { text in onText(AssistantReply(text).spoken) }
        return AssistantReply(reply).spoken
    }

    private func replaceBrain() {
        cancel()
        brain?.shutDown(); brain = nil
        lastAnswerAt = .distantPast
    }

    // MARK: Asking

    /// Space + Up Arrow went down: start listening (or stop, when tapped hands-free).
    func begin(handsFree: Bool = false, showAfter delay: Double = 0) {
        guard enabled else { return }
        if phase == .listening { if autoListening { takeOver() }; return }
        generation += 1
        work?.cancel(); work = nil
        stopAfter()
        brain?.interrupt()
        stopVoices()
        hideTask?.cancel()
        clearPoints?()
        heard = ""; answer = ""; outcomes = []; spokenOffset = 0; shownPoints = 0; ranLocally = false; plannedSteps = []; runsAt = nil; stepAt = 0; gateIndex = nil
        walkStep = 0; autoTurns = 0
        self.handsFree = handsFree
        // What you're looking at as you start talking, before anything moves.
        context = Self.frontContext()
        context.selection = selectedText()
        captureTypingDestination?()
        actionObservation = ScreenClick.observe()
        sawScreen = ScreenGrab.allowed
        discardShot()
        shot = Task { await captureScreen() }
        let brain = currentBrain()
        let asked = generation
        Task {
            guard asked == generation else { return }
            await brain.warm()
        }
        if speaks, usesNatural { natural.warm() }
        warmPlanner?()
        phase = .listening
        // A quick tap may turn out to be "open the palette": the bubble waits a beat before it shows.
        if delay <= 0 { show?() } else {
            Task {
                try? await Task.sleep(for: .seconds(delay))
                if asked == generation, phase != .idle { show?() }
            }
        }
        Task {
            guard asked == generation, phase == .listening else { return }
            do { try await startListening?() }
            catch { if asked == generation { fail(error.localizedDescription) } }
        }
    }

    /// Hands-free from now on: the tap was short, so listening continues until the next tap.
    func keepListening() { if phase == .listening { handsFree = true } }

    /// You pressed Space + Up Arrow while Murmur was listening on its own: it's yours now.
    func takeOver() {
        guard phase == .listening, autoListening else { return }
        autoListening = false; handsFree = false
    }

    /// Dictation wants the microphone: stop listening for a follow-up.
    func yieldMicrophone() async {
        guard phase == .listening, autoListening else { return }
        autoListening = false; handsFree = false
        await cancelListening?()
        if phase == .listening { phase = walkStep > 0 && clickWatcher != nil ? .waiting : .done }
        if phase == .done { scheduleHide(after: 0.3) }
    }

    /// Let go (or tapped again): send what you said.
    func end() {
        guard phase == .listening else { return }
        let wasAuto = autoListening
        handsFree = false; autoListening = false
        stopWatchingClicks()
        afterTask?.cancel(); afterTask = nil
        phase = .thinking
        let asked = generation
        // The model starts on the live words the moment you let go, while the final
        // speech pass runs; when the final words are the same, its plan is already there.
        let live = liveTranscript().trimmingCharacters(in: .whitespacesAndNewlines)
        let early: Task<CommandAction?, Never>? = !wasAuto && walkStep == 0 && !live.isEmpty && !AssistantIntent.isQuestion(live)
            ? Task { @MainActor [weak self] in
                guard let plan = await self?.planWithModel?(live) else { return nil }
                // "open T3 Code, open the thread…": the app starts opening while the final words come in.
                if case .sequence(let steps) = plan, case .openApp(let app)? = steps.first, !Task.isCancelled {
                    RequestTrace.log("opening \(app.name) early, from the live words")
                    self?.prelaunch?(app)
                }
                return plan
            } : nil
        work = Task {
            do {
                let words = try await finishListening?() ?? ""
                guard asked == generation else { early?.cancel(); return }
                let said = words.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !said.isEmpty else {
                    early?.cancel()
                    // Heard a noise, not a question: just close.
                    if wasAuto { phase = .done; scheduleHide(after: 0.5) } else { fail("Didn’t catch that. Hold Space + ↓ and try again.") }
                    return
                }
                let same = AssistantIntent.plain(said) == AssistantIntent.plain(live)
                if !same { early?.cancel() }
                try await handle(said, asked: asked, planned: same ? early : nil)
            } catch is CancellationError {
            } catch {
                guard asked == generation else { return }
                RequestTrace.log("failed: \(error.localizedDescription)")
                fail(error.localizedDescription)
            }
        }
    }

    /// What you said, once it's final: the on-Mac model plans it if Murmur can do it
    /// itself, and the plan is checked against your words; anything else goes to Ask.
    private func handle(_ said: String, asked: Int, planned: Task<CommandAction?, Never>? = nil) async throws {
        let started = Date()
        RequestTrace.begin(said)
        if walkStep == 0, !AssistantIntent.isQuestion(said) {
            let action: CommandAction?
            if let planned { action = await planned.value } else { action = await planWithModel?(said) }
            guard asked == generation else { return }
            if let action {
                RequestTrace.log("route on-Mac model (\(RequestTrace.ms(since: started))\(planned == nil ? "" : ", planned from the live words")): \(QuickPlan.describe(action).joined(separator: " → "))")
                await runLocal(action, words: said, asked: asked)
                return
            }
        }
        guard asked == generation else { return }
        RequestTrace.log("route Ask (\(RequestTrace.ms(since: started)))")
        heard = said
        intent = AssistantIntent(said)
        originalRequest = said
        try await respond(asked, words: said, note: nil)
        RequestTrace.log("Ask finished (\(RequestTrace.ms(since: started))): \(answer.prefix(160))")
    }

    /// Testing only (Murmur started with --debug-requests): runs typed words as if
    /// they'd been said with Space + ↓, from the screen as it is now.
    func debugRun(_ text: String) {
        generation += 1
        work?.cancel(); work = nil
        stopAfter(); brain?.interrupt(); stopVoices(); hideTask?.cancel(); clearPoints?()
        heard = ""; answer = ""; outcomes = []; spokenOffset = 0; shownPoints = 0; ranLocally = false; plannedSteps = []; runsAt = nil; stepAt = 0; gateIndex = nil
        walkStep = 0; autoTurns = 0; handsFree = false
        context = Self.frontContext()
        context.selection = selectedText()
        captureTypingDestination?()
        actionObservation = ScreenClick.observe()
        sawScreen = ScreenGrab.allowed
        discardShot()
        shot = Task { await captureScreen() }
        phase = .thinking
        show?()
        warmPlanner?()
        let asked = generation
        work = Task {
            // As if you'd spent a moment saying it: the model loads meanwhile.
            try? await Task.sleep(for: .seconds(2))
            do { try await handle(text, asked: asked) }
            catch is CancellationError {}
            catch {
                guard asked == generation else { return }
                RequestTrace.log("failed: \(error.localizedDescription)")
                fail(error.localizedDescription)
            }
        }
    }

    /// Runs a plan made on this Mac, and shows what was done.
    private func runLocal(_ action: CommandAction, words: String, asked: Int) async {
        heard = words; answer = ""; outcomes = []; ranLocally = true
        discardShot()
        guard let runLocally else { return }
        let steps: [CommandAction]
        if case .sequence(let parts) = action { steps = parts } else { steps = [action] }
        plannedSteps = steps.map { QuickPlan.describe($0).joined(separator: " ") }
        stepAt = 0
        gateIndex = steps.firstIndex(where: QuickPlan.needsPreview)
        // Clicking and typing are shown first, exactly as heard, so a misheard word
        // can be stopped with Esc. Opening and searching just go.
        // Opening the app or page doesn't wait: it happens while you read the plan.
        var gate: (() async -> Bool)?
        if QuickPlan.needsPreview(action), !QuickPlan.asksFirst(action) {
            show?()
            let deadline = Date().addingTimeInterval(Self.previewTime)
            runsAt = deadline
            gate = { [weak self] in
                let left = deadline.timeIntervalSinceNow
                if left > 0 { try? await Task.sleep(for: .seconds(left)) }
                guard let self else { return false }
                self.runsAt = nil
                return asked == self.generation && !Task.isCancelled
            }
        }
        let ranAt = Date()
        let result = await runLocally(action, words, gate) { [weak self] index in
            guard let self, asked == self.generation else { return }
            self.stepAt = index
        }
        runsAt = nil
        RequestTrace.log("ran in \(RequestTrace.ms(since: ranAt)): " + (result.map { $0.problem.map { "PROBLEM \($0)" } ?? "ok — \($0.title)" } ?? "handed to the palette to confirm"))
        guard asked == generation else { return }
        guard let result else {
            // Commands asks first (it can't be undone): the palette takes it from here.
            phase = .idle; hide?(); return
        }
        // A step that needs the screen didn't land (the thread isn't in view, the box
        // isn't where it usually is): the AI looks at the screen and finishes the rest.
        if let problem = result.problem, Self.needsScreen(action), Self.screenCanHelp(problem), canFinishOnScreen?() == true {
            log.notice("Local plan stopped (\(problem, privacy: .public)); finishing from the screen")
            RequestTrace.log("handing over to Ask to finish from the screen")
            ranLocally = false
            heard = words; originalRequest = words
            var allowed = AssistantIntent(words)
            allowed.clicks = allowed.clicks || Self.has(action) { if case .press = $0 { return true }; return false }
            allowed.types = allowed.types || Self.has(action) { if case .type = $0 { return true }; return false }
            allowed.commands = true
            intent = allowed
            sawScreen = ScreenGrab.allowed
            shot = Task { await captureScreen() }
            let plan = plannedSteps.joined(separator: "; ")
            do {
                try await respond(asked, words: words, note: "Murmur already started this itself. Its plan was: \(plan). It stopped with: \(problem). "
                    + "Look at the screen as it is now and finish only what's left, one step at a time. Click only what the user named.")
            } catch {
                guard asked == generation else { return }
                outcomes = [Outcome(title: result.title, problem: problem)]
                phase = .done
                scheduleHide(after: 3)
            }
            return
        }
        outcomes = [Outcome(title: result.title, problem: result.problem)]
        phase = .done
        playSound?("finish")
        // Done: the ticks show for a moment, then it gets out of the way.
        if result.problem == nil { scheduleHide(after: 0.7, linger: 0) } else { scheduleHide(after: 3) }
    }

    /// Is Ask set up, so it can take over from a plan that got stuck?
    var canFinishOnScreen: (() -> Bool)?
    /// Starts opening an app before the plan runs.
    var prelaunch: ((AppEntry) -> Void)?
    /// Loads the on-Mac model while you talk.
    var warmPlanner: (() -> Void)?

    private static func has(_ action: CommandAction, _ test: (CommandAction) -> Bool) -> Bool {
        switch action {
        case .sequence(let steps): return steps.contains { has($0, test) }
        case .inBrowser(let inner, _): return has(inner, test)
        default: return test(action)
        }
    }

    /// Only "it isn't where Murmur looked" problems: looking at the screen can find it.
    /// An app that didn't come to the front, or a stop, isn't something to work around.
    static func screenCanHelp(_ problem: String) -> Bool {
        problem.hasPrefix("Couldn’t find") || problem.hasPrefix("Couldn’t press") || problem.hasPrefix("Click into a text box")
    }

    /// Clicking and typing depend on what's on screen; opening and searching don't.
    private static func needsScreen(_ action: CommandAction) -> Bool {
        has(action) { step in
            switch step { case .press, .type: return true; default: return false }
        }
    }

    /// Sends one turn (what you said, or Murmur's own note in a walkthrough) and plays the answer.
    private func respond(_ asked: Int, words: String, note: String?) async throws {
        let pendingShot = shot
        shot = nil
        let picture = await pendingShot?.value
        defer { if let picture { try? FileManager.default.removeItem(at: picture.url) } }
        guard asked == generation, !Task.isCancelled else { return }
        sawScreen = picture != nil
        answer = ""; outcomes = []; spokenOffset = 0; shownPoints = 0; clickedThisTurn = false
        clearPoints?()
        var question = AssistantQuestion(text: words, app: context.app, window: context.window, selection: context.selection, note: note.map { "Original request: \(originalRequest). \($0)" })
        if let picture { question.image = picture.url; question.imageSize = picture.pixelSize }
        let followUp = note != nil || walkStep > 0 || Date().timeIntervalSince(lastAnswerAt) < 240
        let started = Date()
        let reply = try await currentBrain().ask(question, followUp: followUp) { [weak self] text in
            guard let self, asked == self.generation else { return }
            self.receive(text, shot: picture, final: false)
        }
        guard asked == generation else { return }
        log.notice("Answered in \(Date().timeIntervalSince(started), format: .fixed(precision: 2)) s")
        receive(reply, shot: picture, final: true)
        lastAnswerAt = Date()
        if note == nil { remember(words, answer) }
        // Clicks and commands finish before Murmur decides what comes next.
        let parsed = AssistantReply(reply)
        await execute(parsed.steps, shot: picture, generation: asked)
        guard asked == generation else { return }
        phase = .done
        waitingPoints = parsed.points.filter { picture?.contains($0) == true }.map { picture!.point($0) }
        waitingControls = parsed.waits ? waitingPoints.compactMap { ScreenClick.control(at: $0) } : []
        waitingObservation = picture?.observation
        lastScreenData = picture.flatMap { try? Data(contentsOf: $0.url) }
        afterAnswer(asked, waits: parsed.waits)
    }

    // MARK: After an answer

    private func afterAnswer(_ asked: Int, waits: Bool) {
        guard waits || clickedThisTurn else {
            autoTurns = 0
            scheduleHide()
            guard keepsListening else { return }
            afterTask = Task {
                await untilQuiet()
                guard !Task.isCancelled, asked == generation, phase == .done else { return }
                await listenAgain(asked, seconds: 5, otherwise: .done)
            }
            return
        }
        walkStep += 1
        // Murmur clicked this step itself: look again and keep going (a few steps at most).
        if clickedThisTurn, autoTurns < 8 {
            autoTurns += 1
            carryOn(after: 0.9, note: "A press was dispatched. Verify the resulting screen before claiming success. If unchanged, explain that it did not work and point for the user. Otherwise give the next step or confirm completion.")
            return
        }
        autoTurns = 0
        hideTask?.cancel()
        phase = .waiting
        watchForClick(asked)
        afterTask = Task {
            await untilQuiet()
            guard !Task.isCancelled, asked == generation, phase == .waiting else { return }
            if keepsListening { await listenAgain(asked, seconds: 6, otherwise: .waiting) }
            // Still on this step after a few minutes: let it go.
            try? await Task.sleep(for: .seconds(180))
            guard !Task.isCancelled, asked == generation, phase == .waiting else { return }
            stopWatchingClicks()
            phase = .done
            scheduleHide(after: 0)
        }
    }

    /// Looks at the screen again and asks for the next step.
    private func carryOn(after delay: Double, note: String) {
        generation += 1
        let asked = generation
        stopWatchingClicks()
        afterTask?.cancel(); afterTask = nil
        hideTask?.cancel()
        phase = .thinking
        work = Task {
            // Give the click a moment to open whatever it opens.
            try? await Task.sleep(for: .seconds(delay))
            guard asked == generation else { return }
            let previous = lastScreenData
            // Wait (briefly) for the screen to change and stop moving. Video or a spinner never
            // stops, so after a couple of seconds the latest picture is used anyway.
            var settled: ScreenShot?
            var latest: ScreenShot?
            var priorData: Data?
            for _ in 0..<8 {
                guard asked == generation, !Task.isCancelled else { break }
                guard let candidate = await captureScreen() else { break }
                let data = try? Data(contentsOf: candidate.url)
                if let latest { try? FileManager.default.removeItem(at: latest.url) }
                latest = candidate
                if let data, data != previous, data == priorData { settled = candidate; break }
                priorData = data
                do { try await Task.sleep(for: .milliseconds(250)) } catch { break }
            }
            if settled == nil { settled = latest }
            guard asked == generation, !Task.isCancelled else {
                if let settled { try? FileManager.default.removeItem(at: settled.url) }; return
            }
            guard let settled else {
                phase = .waiting; autoTurns = 0
                outcomes.append(Outcome(title: "", problem: "Couldn’t look at the screen again. Say “next” when you’re ready."))
                watchForClick(asked)
                return
            }
            context = Self.frontContext()
            sawScreen = true
            discardShot()
            shot = Task { settled }
            do { try await respond(asked, words: "", note: note) }
            catch is CancellationError {}
            catch { if asked == generation { fail(error.localizedDescription) } }
        }
    }

    private func watchForClick(_ asked: Int) {
        stopWatchingClicks()
        clickWatcher = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            MainActor.assumeIsolated { self?.userClicked(asked) }
        }
    }

    private func stopWatchingClicks() {
        if let clickWatcher { NSEvent.removeMonitor(clickWatcher) }
        clickWatcher = nil
    }

    /// You did the step: on to the next one.
    private func userClicked(_ asked: Int) {
        let spot = NSEvent.mouseLocation
        guard asked == generation, Date().timeIntervalSince(murmurClickedAt) > 1,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == waitingObservation?.pid else { return }
        // On the control it pointed at (anywhere on it), near the spot, or anywhere in the app if it didn't point.
        let onControl = ScreenClick.control(at: spot).map { clicked in waitingControls.contains { CFEqual($0, clicked) } } ?? false
        guard waitingPoints.isEmpty || onControl || Self.isWalkthroughClick(spot, targets: waitingPoints) else { return }
        let listening = phase == .listening && autoListening
        guard phase == .waiting || (listening && liveTranscript().isEmpty) else { return }
        stopWatchingClicks()
        showClick?(spot, true)
        afterTask?.cancel()
        afterTask = Task {
            if listening { autoListening = false; handsFree = false; await cancelListening?() }
            guard asked == generation, !Task.isCancelled else { return }
            carryOn(after: 0.8, note: "They clicked near the indicated target. Verify whether the expected change actually happened before advancing. If still loading, ask them to wait and say next.")
        }
    }

    private func stopAfter() {
        afterTask?.cancel(); afterTask = nil
        stopWatchingClicks()
        autoListening = false
    }

    /// Waits for Murmur to finish talking, so the microphone doesn't hear it.
    private func untilQuiet() async {
        let started = Date()
        while isSpeaking, !Task.isCancelled, Date().timeIntervalSince(started) < 90 { try? await Task.sleep(for: .milliseconds(150)) }
        try? await Task.sleep(for: .milliseconds(250))
    }

    /// Opens the microphone for a few seconds. Talk and it's a follow-up; stay quiet and it closes.
    private func listenAgain(_ asked: Int, seconds: Double, otherwise: Phase) async {
        guard enabled, asked == generation else { return }
        context = Self.frontContext()
        context.selection = selectedText()
        captureTypingDestination?()
        actionObservation = ScreenClick.observe()
        phase = .listening; autoListening = true; handsFree = true
        do { try await startListening?() } catch {
            guard asked == generation, autoListening else { return }
            autoListening = false; handsFree = false; phase = otherwise
            if otherwise == .done { scheduleHide(after: 0.5) }
            return
        }
        let opened = Date()
        var lastText = "", changed = opened, loud = Date.distantPast, loudFor = 0.0, spoke = false
        while asked == generation, phase == .listening, autoListening, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(150))
            let text = liveTranscript().trimmingCharacters(in: .whitespacesAndNewlines)
            if inputLevel() > 0.5 { loud = Date(); loudFor += 0.15 }
            if text != lastText { lastText = text; changed = Date() }
            if !spoke, !text.isEmpty || loudFor > 1 {
                spoke = true
                // Look at the screen as it is when you start the follow-up.
                sawScreen = ScreenGrab.allowed
                discardShot()
                shot = Task { await captureScreen() }
            }
            if spoke {
                let quiet = min(Date().timeIntervalSince(changed), Date().timeIntervalSince(loud))
                if quiet > 1.4 || Date().timeIntervalSince(opened) > 60 { end(); return }
            } else if Date().timeIntervalSince(opened) > seconds {
                autoListening = false; handsFree = false
                await cancelListening?()
                guard asked == generation, phase == .listening else { return }
                phase = otherwise
                if otherwise == .done { scheduleHide(after: 0.3) }
                return
            }
        }
    }

    /// Esc, or the close button: stop listening, talking and pointing.
    func cancel() {
        generation += 1
        if phase == .listening { Task { await cancelListening?() } }
        work?.cancel(); work = nil
        stopAfter()
        brain?.interrupt()
        stopVoices()
        hideTask?.cancel()
        clearPoints?()
        phase = .idle; handsFree = false; walkStep = 0; autoTurns = 0; runsAt = nil
        discardShot()
        hide?()
    }

    private func discardShot() {
        if let shot {
            shot.cancel()
            Task { if let picture = await shot.value { try? FileManager.default.removeItem(at: picture.url) } }
        }
        shot = nil
    }

    static func isWalkthroughClick(_ point: CGPoint, targets: [CGPoint]) -> Bool {
        targets.contains { hypot(point.x - $0.x, point.y - $0.y) <= 48 }
    }

    /// Starts a fresh conversation next time, instead of following up.
    func forgetConversation() { lastAnswerAt = .distantPast }

    func clearRecent() { recent = []; defaults.removeObject(forKey: "assistantRecent") }

    func shutDown() { cancel(); brain?.shutDown(); brain = nil; natural.shutDown() }

    /// Sample states, for screenshots of the design.
    func seed(phase: Phase, heard: String = "", answer: String = "", outcomes: [Outcome] = [], recent: [Ask]? = nil,
              step: Int = 0, autoListening: Bool = false, plan: [String] = [], planAt: Int = 0) {
        self.phase = phase; self.heard = heard; self.answer = answer; self.outcomes = outcomes; sawScreen = true
        plannedSteps = plan; ranLocally = !plan.isEmpty; stepAt = planAt; gateIndex = nil; runsAt = nil
        walkStep = step; self.autoListening = autoListening; handsFree = autoListening
        if let recent { self.recent = recent }
    }

    private func fail(_ message: String) {
        phase = .failed(message)
        playSound?("finish")
        scheduleHide(after: 7)
    }

    private func receive(_ text: String, shot: ScreenShot?, final: Bool) {
        let reply = AssistantReply(text)
        if phase == .thinking { phase = .answering }
        answer = reply.spoken
        if reply.points.count > shownPoints, let shot {
            shownPoints = reply.points.count
            pointAt?(reply.points.filter { shot.contains($0) }.map { (shot.point($0), $0.label) })
        }
        let (sentence, offset) = AssistantReply.sentences(in: reply.spoken, after: spokenOffset, final: final)
        spokenOffset = offset
        if !sentence.isEmpty { say(sentence) }
    }

    /// A single owned task executes at most one action per observation. Never execute streaming tags.
    private func execute(_ proposed: [AssistantReply.Step], shot: ScreenShot?, generation asked: Int) async {
        guard !proposed.isEmpty else { return }
        guard proposed.count == 1 else {
            outcomes.append(Outcome(title: "", problem: "Ask for one action at a time.")); return
        }
        guard asked == generation, !Task.isCancelled else { return }
        let step = proposed[0]
        switch step {
        case .command:
            guard intent.commands, let runCommand else {
                outcomes.append(Outcome(title: "", problem: "Ask me directly to run a command.")); return
            }
            guard case .command(let command) = step else { return }
            // Commands checks the proposal against your own words before running it.
            let result = await runCommand(command, originalRequest)
            guard asked == generation, !Task.isCancelled else { return }
            outcomes.append(Outcome(title: result.title, problem: result.problem))
        case .type(let text):
            guard intent.types, let typeText, actionObservation?.isCurrent == true else {
                outcomes.append(Outcome(title: "", problem: "Ask me to draft in the original text box.")); return
            }
            let problem = await typeText(text)
            guard asked == generation, !Task.isCancelled else { return }
            outcomes.append(Outcome(title: "Typed it for you", problem: problem))
        case .click(let point):
            guard intent.allowsClick(label: point.label), clicks, let shot, shot.contains(point) else {
                outcomes.append(Outcome(title: "", problem: "Name the control in your request, or click it yourself.")); return
            }
            murmurClickedAt = Date()
            let problem = await click(shot.point(point), point.label, shot.observation)
            guard asked == generation, !Task.isCancelled else { return }
            showClick?(shot.point(point), problem == nil)
            murmurClickedAt = Date()
            clickedThisTurn = problem == nil
            outcomes.append(Outcome(title: "Pressed “\(point.label)” · checking result", problem: problem))
        }
    }

    private func remember(_ question: String, _ answer: String) {
        guard !answer.isEmpty else { return }
        recent.insert(Ask(question: question, answer: answer, provider: "\(provider.rawValue) · \(modelName)"), at: 0)
        if recent.count > 40 { recent.removeLast(recent.count - 40) }
        defaults.set(try? JSONEncoder().encode(recent), forKey: "assistantRecent")
    }

    /// The bubble stays while it talks, then a few seconds more to read.
    private func scheduleHide(after seconds: Double = 5, linger: Double = 1.5) {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(seconds))
            while isSpeaking, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(300)) }
            if linger > 0 { try? await Task.sleep(for: .seconds(linger)) }
            guard !Task.isCancelled, phase == .done || { if case .failed = phase { return true }; return false }() else { return }
            clearPoints?()
            phase = .idle
            hide?()
        }
    }

    // MARK: Speaking

    private func say(_ sentence: String) {
        guard speaks else { return }
        if usesNatural, natural.speak(sentence) { return }
        sayWithSystemVoice(sentence)
    }

    private func sayWithSystemVoice(_ sentence: String) {
        guard speaks else { return }
        let utterance = AVSpeechUtterance(string: sentence)
        utterance.voice = Self.voice(id: voiceID)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.04
        utterance.prefersAssistiveTechnologySettings = false
        synthesizer.speak(utterance)
    }

    func stopSpeaking() { stopVoices() }

    private func stopVoices() {
        synthesizer.stopSpeaking(at: .immediate)
        natural.stop()
    }

    /// Says a sample line in Murmur's natural voice.
    func previewNatural(_ id: String) {
        stopVoices()
        natural.voice = id
        natural.speak("Hi, I’m Murmur. Ask me about anything on your screen, and I’ll point you to it.")
        natural.voice = naturalVoiceID
    }

    /// Your pick, or the best-sounding voice for your language that's installed.
    static func voice(id: String) -> AVSpeechSynthesisVoice? {
        if !id.isEmpty, let chosen = AVSpeechSynthesisVoice(identifier: id) { return chosen }
        return voices().first
    }

    /// Voices for your language, best first: Premium, then Enhanced, then the rest.
    static func voices() -> [AVSpeechSynthesisVoice] {
        let language = Locale.preferredLanguages.first ?? "en-US"
        let prefix = String(language.prefix(2))
        let all = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(prefix) && !$0.voiceTraits.contains(.isNoveltyVoice) }
        return all.sorted {
            if $0.quality != $1.quality { return $0.quality.rawValue > $1.quality.rawValue }
            if ($0.language == language) != ($1.language == language) { return $0.language == language }
            return $0.name < $1.name
        }
    }

    func preview(voice id: String) {
        stopVoices()
        let utterance = AVSpeechUtterance(string: "Hi, I’m Murmur. Ask me about anything on your screen.")
        utterance.voice = Self.voice(id: id)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.04
        synthesizer.speak(utterance)
    }

    // MARK: Context

    /// The front app and its window title.
    static func frontContext() -> (app: String, window: String, selection: String?) {
        guard let app = NSWorkspace.shared.frontmostApplication else { return ("", "", nil) }
        var title = ""
        let element = AXUIElementCreateApplication(app.processIdentifier)
        var window: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &window) == .success, let window {
            var value: CFTypeRef?
            // The value is an AXUIElement when the call succeeds.
            if AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &value) == .success {
                title = value as? String ?? ""
            }
        }
        return (app.localizedName ?? "", title, nil)
    }
}

extension AssistantCenter: AVSpeechSynthesizerDelegate {}

/// What Ask can tell you about its connection, for Settings.
struct AssistantStatus: Equatable {
    var ready: Bool
    var title: String
    var detail: String

    /// Check through the provider, rather than depending on a credentials file's location or format.
    @MainActor static func check(_ provider: AssistantProvider) async -> AssistantStatus {
        guard ShellEnvironment.find(provider.tool) != nil else {
            return AssistantStatus(ready: false, title: "\(provider.appName) isn’t installed", detail: AssistantError.missingTool(provider).localizedDescription)
        }
        switch provider {
        case .chatgpt:
            let brain = CodexBrain(model: provider.defaultModel)
            defer { brain.shutDown() }
            do {
                let type = try await brain.accountType()
                if type == "chatgpt" {
                    return AssistantStatus(ready: true, title: "Signed in with ChatGPT", detail: "Uses your ChatGPT plan through Codex, subject to its usage limits.")
                }
                return AssistantStatus(ready: false, title: type == "apiKey" ? "Codex uses an API key" : "Codex needs a ChatGPT sign-in",
                                       detail: "Run “codex login” to use your ChatGPT plan. Ask won’t send a separately billed API-key request.")
            } catch {
                return AssistantStatus(ready: false, title: "Couldn’t check Codex", detail: error.localizedDescription)
            }
        case .claude:
            let subscribed = await ClaudeBrain.subscriptionStatus()
            return AssistantStatus(ready: subscribed, title: subscribed ? "Signed in with Claude" : "Check Claude Code sign-in",
                                   detail: subscribed ? "Uses your Claude Code account, subject to its usage limits and terms." : "Run “claude” and check your subscription sign-in. Ask won’t send a model request without it.")
        }
    }
}
