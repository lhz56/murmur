import AppKit
import ApplicationServices
import CoreAudio
import EventKit
import Foundation
import OSLog
import UserNotifications

/// Murmur Commands: press Space + Down Arrow, then type or hold and speak. Opens apps,
/// sites, files and folders, plays music and videos, searches, sets timers
/// and controls the Mac. Everything runs locally; anything the parser can't
/// place is rewritten by a local model into a command it understands.
@MainActor
final class CommandCenter: ObservableObject {
    enum Phase: Equatable { case idle, listening, thinking, running, done(String), failed(String) }

    struct Record: Codable, Identifiable, Equatable {
        var id = UUID()
        var text: String
        var title: String
        var date = Date()
        var ok = true
    }

    struct RunningTimer: Identifiable, Equatable {
        let id = UUID()
        let label: String
        let ends: Date
        let total: Int
    }

    @Published var query = "" {
        didSet {
            guard query != oldValue else { return }
            choices = []; choicePrompt = nil
            // Typing again starts fresh after a result or an error.
            switch phase { case .failed, .done: phase = .idle; default: break }
            pendingConfirmation = nil
            refreshSuggestions()
        }
    }
    @Published private(set) var suggestions: [CommandSuggestion] = []
    @Published var selection = 0
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var liveText = ""
    @Published private(set) var files: [CommandSuggestion] = []
    @Published private(set) var history: [Record] = []
    @Published private(set) var timers: [RunningTimer] = []
    @Published var pendingConfirmation: CommandSuggestion?
    @Published var music: MusicService { didSet { defaults.set(music.rawValue, forKey: "commandMusic"); refreshSuggestions() } }
    @Published var customCommands: [CustomCommand] { didSet { saveCustom() } }
    @Published var useLocalAI: Bool { didSet { defaults.set(useLocalAI, forKey: "commandLocalAI") } }
    @Published private(set) var apps: [AppEntry] = []
    /// Your sites by name ("workloom" → workloom.live): picked when Murmur asked, or added on the Commands page.
    @Published var sites: [String: URL] { didSet { defaults.set(sites.mapValues(\.absoluteString), forKey: "commandSites"); refreshSuggestions() } }
    /// "Which WorkLoom?": the sites to choose between, shown in place of the results.
    @Published private(set) var choices: [CommandSuggestion] = []
    @Published private(set) var choicePrompt: String?
    @Published var learnFromHistory: Bool { didSet { defaults.set(learnFromHistory, forKey: "commandSiteHistory"); reindex() } }
    private var siteHistory: [String: Int] = [:]
    private var projectSites: [String: [String: Int]] = [:]
    private var askedForChoice = false
    /// Bumped when the palette opens or you cancel, so a request still being worked out never acts afterwards.
    private var generation = 0
    private var sitesIndexedAt = Date.distantPast
    private var sitesFromHistory: Bool?
    @Published var isOpen = false

    private let defaults: UserDefaults
    private var shortcutNames: [String] = []
    private var folders: [String: String] = [:]
    private var usage: [String: Int]
    private var learned: [String: String]
    private var selectedText: String?
    private var fileSearch: Task<Void, Never>?
    private var indexedAt = Date.distantPast
    private let log = Logger(subsystem: "app.murmur.mac", category: "Commands")

    /// Wired by AppModel/AppDelegate.
    var startListening: (() async throws -> Void)?
    var finishListening: (() async throws -> String)?
    var cancelListening: (() async -> Void)?
    var liveTranscript: () -> String = { "" }
    var startMeeting: (() -> Void)?
    var stopMeeting: (() -> Void)?
    var openMurmur: ((String) -> Void)?
    var close: (() -> Void)?
    /// Shows the palette again, e.g. to ask which site you meant.
    var reopen: (() -> Void)?
    var flash: ((String, String?) -> Void)?
    var playSound: ((String) -> Void)?
    var selectedTextProvider: () -> String? = { nil }
    /// Inserts text where the keyboard focus is; returns a problem, or nil.
    var typeText: ((String) async -> String?)?

    init(defaults: UserDefaults) {
        self.defaults = defaults
        music = MusicService(rawValue: defaults.string(forKey: "commandMusic") ?? "") ?? .youtube
        useLocalAI = defaults.object(forKey: "commandLocalAI") as? Bool ?? true
        customCommands = defaults.data(forKey: "customCommands").flatMap { try? JSONDecoder().decode([CustomCommand].self, from: $0) } ?? []
        history = defaults.data(forKey: "commandHistory").flatMap { try? JSONDecoder().decode([Record].self, from: $0) } ?? []
        usage = defaults.dictionary(forKey: "commandUsage") as? [String: Int] ?? [:]
        learned = defaults.dictionary(forKey: "commandLearned") as? [String: String] ?? [:]
        sites = (defaults.dictionary(forKey: "commandSites") as? [String: String] ?? [:]).compactMapValues(URL.init(string:))
        learnFromHistory = defaults.object(forKey: "commandSiteHistory") as? Bool ?? true
        // Spotify users get Spotify without asking.
        if defaults.string(forKey: "commandMusic") == nil,
           NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.spotify.client") != nil { music = .spotify }
        reindex()
    }

    var context: CommandContext {
        CommandContext(apps: apps, shortcuts: shortcutNames, folders: folders, selection: selectedText, music: music,
                       customCommands: customCommands, usage: usage, learned: learned,
                       recent: history.filter(\.ok).map(\.text), sites: sites)
    }

    /// Spoken commands are complete sentences: no "did you mean" from history.
    var voiceContext: CommandContext { var context = context; context.recent = []; return context }

    // MARK: Palette

    /// Called as the palette opens: remember what's selected in the app you were in.
    func prepare() {
        generation += 1
        selectedText = selectedTextProvider() ?? Self.clipboardLink()
        query = ""; selection = 0; liveText = ""; pendingConfirmation = nil
        if case .listening = phase {} else { phase = .idle }
        if Date().timeIntervalSince(indexedAt) > 300 { reindex() }
        refreshSuggestions()
    }

    private static func clipboardLink() -> String? {
        guard let text = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              text.hasPrefix("http"), !text.contains(" "), text.count < 2000 else { return nil }
        return text
    }

    var hasSelection: Bool { selectedText?.isEmpty == false }
    var selectionPreview: String? { selectedText.map { String($0.prefix(60)) } }

    func refreshSuggestions() {
        let text = query.trimmingCharacters(in: .whitespaces)
        suggestions = text.isEmpty ? [] : CommandParser.suggestions(for: text, context: context)
        selection = 0
        searchFiles(text)
    }

    /// Files whose names match what you typed, from Spotlight, shown under the commands.
    private func searchFiles(_ text: String) {
        fileSearch?.cancel(); files = []
        let target = CommandParser.strip(CommandParser.normalize(text), prefixes: ["open", "find", "show"]) ?? CommandParser.normalize(text)
        guard target.count >= 3, phase == .idle || phase == .running else { return }
        fileSearch = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled else { return }
            let found = await Self.spotlight(target, limit: 4)
            guard !Task.isCancelled, let self else { return }
            files = found.map { url in
                CommandSuggestion(title: url.lastPathComponent, subtitle: Self.abbreviate(url.deletingLastPathComponent().path),
                                  icon: .app(url.path), action: .openPath(url.path, in: nil), confidence: 0.5)
            }
        }
    }

    var rows: [CommandSuggestion] {
        if !choices.isEmpty { return choices }
        let commands = suggestions
        let strong = commands.prefix { $0.confidence >= 0.5 }
        return Array(strong) + files.filter { file in !commands.contains { $0.action == file.action } } + commands.dropFirst(strong.count)
    }

    func move(_ offset: Int) {
        let count = rows.count
        guard count > 0 else { return }
        selection = (selection + offset + count) % count
    }

    /// Return in the palette.
    func submit() {
        let rows = rows
        if let pending = pendingConfirmation { pendingConfirmation = nil; run(pending, text: query); return }
        // Return on a sentence the parser only half understands: let the local model read it.
        if selection == 0, useLocalAI, query.split(separator: " ").count >= 3, !(rows.first.map { CommandParser.isSure($0, for: query) } ?? false),
           (rows.first?.confidence ?? 0) < 0.9 || query.split(separator: " ").count > 6 {
            let text = query
            phase = .thinking; liveText = text
            let asked = generation
            Task {
                let planned = await plan(text)
                guard asked == generation else { return }
                if let planned {
                    if planned.action.needsConfirmation { pendingConfirmation = planned; phase = .idle; return }
                    run(planned, text: text)
                } else if let first = rows.first { learn(first); run(first, text: text) }
                else { phase = .failed("Murmur couldn’t tell what to do with that.") }
            }
            return
        }
        guard !rows.isEmpty else { return }
        let chosen = rows[min(selection, rows.count - 1)]
        if chosen.action.needsConfirmation { pendingConfirmation = chosen; return }
        learn(chosen)
        run(chosen, text: query)
    }

    func choose(_ suggestion: CommandSuggestion) {
        if suggestion.action.needsConfirmation, pendingConfirmation != suggestion { pendingConfirmation = suggestion; return }
        pendingConfirmation = nil
        learn(suggestion)
        run(suggestion, text: query.isEmpty ? suggestion.title : query)
    }

    /// Remembers a pick that wasn't the first row, so it's first next time.
    private func learn(_ chosen: CommandSuggestion) {
        let said = CommandParser.normalize(query)
        guard !said.isEmpty else { return }
        if suggestions.first?.title == chosen.title, learned[said] == nil { return }
        learned[said] = chosen.title
        if learned.count > 300 { learned.removeValue(forKey: learned.keys.first!) }
        defaults.set(learned, forKey: "commandLearned")
    }

    // MARK: Voice

    func beginListening() {
        guard phase != .listening, let startListening else { return }
        phase = .listening; liveText = ""; query = ""
        // Load the small model while you talk, in case the request needs it.
        if useLocalAI {
            let names = apps.map(\.name), service = music
            Task.detached(priority: .utility) {
                await LocalLLM.preload()
                // Reading the instructions and examples once now means the real request only reads your words.
                guard case .ollama(let model) = (await Writer.forCommands()).kind else { return }
                _ = await CommandPlanner.calls(for: "open notes", apps: names, music: service, model: model)
            }
        }
        Task {
            do { try await startListening() }
            catch { phase = .failed(error.localizedDescription) }
        }
    }

    /// Ends listening and runs what was said.
    func endListening() {
        guard phase == .listening, let finishListening else { return }
        // Instant path: "open Slack", "next song", "timer 10 minutes" don't depend on
        // exact spelling, so the live transcript is enough. Skip the final speech pass.
        let live = liveTranscript().trimmingCharacters(in: .whitespacesAndNewlines)
        if let quick = CommandParser.best(for: live, context: voiceContext), CommandParser.isTrivial(quick, for: live),
           CommandParser.isInstant(quick.action), !quick.action.needsConfirmation {
            liveText = live
            playSound?("finish")
            Task { await cancelListening?() }
            run(quick, text: live)
            return
        }
        phase = .thinking
        // Work out the plan from the live words while the final transcript is
        // made; if they match, the plan is ready the moment the words are.
        let early = rulesAreSure(live) ? nil : Task { await self.plan(live) }
        Task {
            do {
                let heard = try await finishListening().trimmingCharacters(in: .whitespacesAndNewlines)
                guard !heard.isEmpty else { early?.cancel(); phase = .failed("Didn’t catch that. Hold Space + ↓ and try again."); return }
                liveText = heard
                let same = CommandParser.normalize(heard) == CommandParser.normalize(live)
                let planned = same ? await early?.value ?? nil : nil
                await runSpoken(heard, planned: planned)
                if !same { early?.cancel() }
            } catch { early?.cancel(); phase = .failed(error.localizedDescription) }
        }
    }

    func cancel() {
        generation += 1
        if phase == .listening { Task { await cancelListening?() } }
        phase = .idle; liveText = ""
    }

    func updateLive() { if phase == .listening { liveText = liveTranscript() } }

    /// Short, clear commands ("open slack", "next song") don't need the model.
    private func rulesAreSure(_ text: String) -> Bool {
        CommandParser.best(for: text, context: voiceContext).map { CommandParser.isTrivial($0, for: text) } ?? false
    }

    /// Spoken commands: the parser when it's sure, otherwise the local model
    /// reads the whole request in plain language and plans the steps.
    func runSpoken(_ heard: String, planned: CommandSuggestion? = nil) async {
        let asked = generation
        let rules = CommandParser.best(for: heard, context: voiceContext)
        var best = rules.flatMap { CommandParser.isTrivial($0, for: heard) ? $0 : nil }
        if best == nil, useLocalAI {
            if let planned { best = planned } else { best = await plan(heard) }
            // When the rules understood every part and the model's plan dropped something you named, the rules win.
            if let model = best, let rules, CommandParser.isSure(rules, for: heard),
               CommandPlanner.coverage(rules, of: heard, context: voiceContext) > CommandPlanner.coverage(model, of: heard, context: voiceContext) {
                best = rules
            }
        }
        if best == nil, let rules, rules.confidence >= 0.6 { best = rules }
        // Cancelled or closed while the model was thinking: do nothing.
        guard asked == generation else { return }
        guard let best else {
            // Leave the words in the box, with searching them as the first choice. Nothing you
            // said goes to a website unless you pick it: it could be a password or a private note.
            query = heard
            phase = .failed("Not sure what to do with that. Pick a result, or edit it and press Return.")
            return
        }
        if best.action.needsConfirmation { query = heard; pendingConfirmation = best; phase = .idle; return }
        run(best, text: heard)
    }

    /// The local model's plan for a request in plain language, as one command.
    func plan(_ request: String) async -> CommandSuggestion? {
        guard useLocalAI, !request.isEmpty else { return nil }
        // A small, quick model; a big one only if it's already loaded. Never a cold 5 GB load for one command.
        guard case .ollama(let model) = (await Writer.forCommands()).kind, !Task.isCancelled else { return nil }
        let started = Date()
        guard let calls = await CommandPlanner.calls(for: request, apps: apps.map(\.name), music: music, model: model), !calls.isEmpty,
              let suggestion = CommandPlanner.action(for: calls, request: request, context: voiceContext) else {
            log.notice("The local model had no plan")
            return nil
        }
        log.notice("Planned \(calls.count) step(s) in \(Date().timeIntervalSince(started), format: .fixed(precision: 2)) s")
        return suggestion
    }

    // MARK: Running

    func run(_ suggestion: CommandSuggestion, text: String) {
        // One command at a time: Return pressed twice, or a new command while one runs, doesn't start another.
        guard phase != .running else { return }
        phase = .running
        Task {
            // Typing goes to the app you were in, so the palette steps out of the way first.
            if Self.types(suggestion.action) { close?(); try? await Task.sleep(for: .milliseconds(90)) }
            let outcome = await perform(suggestion.action)
            if askedForChoice {
                // Murmur asked which site you mean; the palette stays open with the choices.
                askedForChoice = false
                phase = .idle
                if !isOpen { reopen?() }
                return
            }
            record(text: text.isEmpty ? suggestion.title : text, title: suggestion.title, ok: outcome == nil)
            if case .openApp(let app) = suggestion.action { usage[app.name, default: 0] += 1; defaults.set(usage, forKey: "commandUsage") }
            if let problem = outcome {
                phase = .failed(problem)
                playSound?("finish")
                // The palette may already have closed as another app came forward.
                if !isOpen { flash?("Couldn’t do that", problem) }
            } else {
                phase = .done(Self.pastTense(suggestion.title))
                try? await Task.sleep(for: .milliseconds(420))
                if case .done = phase { close?(); phase = .idle }
            }
        }
    }

    static func types(_ action: CommandAction) -> Bool {
        if case .type = action { return true }
        if case .system(let system) = action, system.isKeystroke { return true }
        if case .sequence(let steps) = action { return steps.contains(where: types) }
        if case .inBrowser(let inner, _) = action { return types(inner) }
        return false
    }

    static func pastTense(_ title: String) -> String {
        for (verb, past) in [("Open ", "Opened "), ("Play ", "Playing "), ("Search ", "Searched "), ("Quit ", "Quit "), ("Hide ", "Hid "),
                             ("Run ", "Ran "), ("Ask ", "Asked "), ("Add ", "Added "), ("New note", "Added note"), ("Find ", "Found "), ("Timer for ", "Timer set for ")] where title.hasPrefix(verb) {
            return past + title.dropFirst(verb.count)
        }
        return title
    }

    private func record(text: String, title: String, ok: Bool) {
        history.removeAll { $0.text.lowercased() == text.lowercased() }
        history.insert(Record(text: text, title: title, ok: ok), at: 0)
        if history.count > 40 { history.removeLast(history.count - 40) }
        defaults.set(try? JSONEncoder().encode(history), forKey: "commandHistory")
    }

    func clearHistory() {
        history = []; learned = [:]
        defaults.removeObject(forKey: "commandHistory"); defaults.removeObject(forKey: "commandLearned")
    }

    private func saveCustom() { defaults.set(try? JSONEncoder().encode(customCommands), forKey: "customCommands") }

    /// Performs an action; returns a problem to show, or nil when it worked.
    func perform(_ action: CommandAction) async -> String? {
        switch action {
        case .openApp(let app):
            let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = true
            do {
                let running = try await NSWorkspace.shared.openApplication(at: app.url, configuration: configuration)
                // Done means it's actually in front, so the next step lands in the right place.
                await Self.waitUntilFront(running, timeout: 6)
                return nil
            } catch { return "Couldn’t open \(app.name)." }
        case .openSite(let name):
            return await openSite(name)
        case .addReminder(let title, let notes, let due):
            return await Organizer.addReminder(title, notes: notes, due: due)
        case .addEvent(let title, let start, let minutes):
            return await Organizer.addEvent(title, start: start, minutes: minutes)
        case .addNote(let text):
            return Organizer.addNote(text)
        case .learnSite(let key, let url):
            sites[key] = url; return nil
        case .openURL(let url):
            if url.scheme == "http" || url.scheme == "https" {
                return await BrowserLaunch.open(url) ? nil : "Couldn’t open \(url.host ?? url.absoluteString)."
            }
            return NSWorkspace.shared.open(url) ? nil : "Couldn’t open \(url.host ?? url.absoluteString)."
        case .openPath(let path, let app):
            let url = path.hasPrefix("http") ? URL(string: path)! : URL(fileURLWithPath: path)
            if let app {
                let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = true
                do { _ = try await NSWorkspace.shared.open([url], withApplicationAt: app.url, configuration: configuration); return nil }
                catch { return "\(app.name) couldn’t open that." }
            }
            return NSWorkspace.shared.open(url) ? nil : "Couldn’t open \(url.lastPathComponent)."
        case .findFile(let name, let app):
            guard let found = await Self.spotlight(name, limit: 1).first else { return "No file or folder named “\(name)”." }
            return await perform(.openPath(found.path, in: app))
        case .quitApp(let name):
            let running = runningApp(named: name)
            guard !running.isEmpty else { return "\(name) isn’t open." }
            running.forEach { $0.terminate() }; return nil
        case .hideApp(let name):
            let running = runningApp(named: name)
            guard !running.isEmpty else { return "\(name) isn’t open." }
            running.forEach { $0.hide() }; return nil
        case .play(let query, let service):
            return await MediaPlayer.play(query, on: service)
        case .media(let key):
            MediaPlayer.press(key); return nil
        case .volume(let change):
            return SystemVolume.apply(change)
        case .timer(let seconds, let label):
            startTimer(seconds: seconds, label: label); return nil
        case .shortcut(let name):
            return await Self.runShortcut(name)
        case .type(let words, let app):
            // Writing in Notes or Reminders means a new note or reminder, added directly.
            if app?.name == "Notes" { return Organizer.addNote(words) }
            if app?.name == "Reminders" { return await Organizer.addReminder(words, notes: nil, due: nil) }
            return await typeWords(words, in: app)
        case .system(let action):
            return await SystemControl.perform(action)
        case .meeting(let what):
            if what == .start { startMeeting?() } else { stopMeeting?() }
            return nil
        case .murmur(let target):
            openMurmur?(target); return nil
        case .sequence(let steps):
            for (index, step) in steps.enumerated() {
                if let problem = await perform(step) { return problem }
                if askedForChoice {
                    // Wait for your pick; the steps after it run once you've chosen.
                    let rest = Array(steps[(index + 1)...])
                    if !rest.isEmpty {
                        choices = choices.map { choice in
                            // Your sites (not "search the web") carry the rest of the request.
                            guard choice.confidence == 1 else { return choice }
                            return CommandSuggestion(title: choice.title, subtitle: choice.subtitle, icon: choice.icon,
                                                     action: .sequence([choice.action] + rest), confidence: choice.confidence)
                        }
                    }
                    return nil
                }
                guard index < steps.count - 1 else { break }
                // Each step waits for the last one to land, not a fixed delay:
                // apps are already confirmed in front; a page needs its browser in front.
                if case .openURL(let url) = step, url.scheme?.hasPrefix("http") == true,
                   let browser = BrowserLaunch.browser(for: url).flatMap({ Bundle(url: $0)?.bundleIdentifier }) {
                    await Self.waitUntilFront(bundleID: browser, timeout: 4)
                    try? await Task.sleep(for: .milliseconds(350))
                } else if case .openApp = step {
                    try? await Task.sleep(for: .milliseconds(120))
                }
            }
            return nil
        case .inBrowser(let inner, let browser):
            BrowserLaunch.preferred = browser.url
            defer { BrowserLaunch.preferred = nil }
            return await perform(inner)
        case .none:
            return nil
        }
    }

    /// Waits until an app has finished launching and is frontmost.
    static func waitUntilFront(_ app: NSRunningApplication, timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if app.isFinishedLaunching && NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier { return }
            try? await Task.sleep(for: .milliseconds(40))
        }
    }

    static func waitUntilFront(bundleID: String, timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID { return }
            try? await Task.sleep(for: .milliseconds(40))
        }
    }

    /// Types your words into the named app's message box, or where you were typing.
    /// Murmur never presses Return, so nothing is sent without you.
    private func typeWords(_ words: String, in app: AppEntry?) async -> String? {
        if let app {
            let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = true
            guard let running = try? await NSWorkspace.shared.openApplication(at: app.url, configuration: configuration) else { return "Couldn’t open \(app.name)." }
            await Self.waitUntilFront(running, timeout: 6)
            // Chat apps take a moment to put their message box on screen.
            for attempt in 0..<12 {
                if Composer.focus(pid: running.processIdentifier) { break }
                try? await Task.sleep(for: .milliseconds(attempt < 4 ? 120 : 250))
            }
        }
        guard let typeText else { return "Typing isn’t available." }
        return await typeText(words)
    }

    private func runningApp(named name: String) -> [NSRunningApplication] {
        let lower = name.lowercased()
        let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        // The app with that exact name; only when there's none, the closest sound-alike, and just one.
        let exact = running.filter { $0.localizedName?.lowercased() == lower }
        if !exact.isEmpty { return exact }
        let scored = running.compactMap { app -> (NSRunningApplication, Double)? in
            guard let appName = app.localizedName?.lowercased() else { return nil }
            let score = CommandParser.appScore(lower, appName)
            return score >= 0.8 ? (app, score) : nil
        }.sorted { $0.1 > $1.1 }
        guard let best = scored.first else { return [] }
        return running.filter { $0.localizedName == best.0.localizedName }
    }

    // MARK: Timers

    private func startTimer(seconds: Int, label: String) {
        let timer = RunningTimer(label: label, ends: Date().addingTimeInterval(Double(seconds)), total: seconds)
        timers.append(timer)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        let content = UNMutableNotificationContent()
        content.title = label == "Timer" ? "Timer done" : label
        content.body = "\(CommandParser.duration(seconds)) timer from Murmur"
        content.sound = .default
        let request = UNNotificationRequest(identifier: timer.id.uuidString, content: content,
                                            trigger: UNTimeIntervalNotificationTrigger(timeInterval: Double(max(seconds, 1)), repeats: false))
        UNUserNotificationCenter.current().add(request)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, timers.contains(where: { $0.id == timer.id }) else { return }
            timers.removeAll { $0.id == timer.id }
            NSSound(named: "Glass")?.play()
            flash?(label == "Timer" ? "Timer done" : label, "\(CommandParser.duration(seconds)) is up")
        }
    }

    func cancelTimer(_ id: UUID) {
        timers.removeAll { $0.id == id }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id.uuidString])
    }

    // MARK: Indexing

    /// Finds installed apps, your Shortcuts and project folders, off the main thread.
    func reindex() {
        indexedAt = Date()
        let history = learnFromHistory
        Task.detached(priority: .utility) {
            let apps = Self.installedApps()
            let folders = Self.projectFolders()
            let shortcuts = Self.shortcutList()
            await MainActor.run { [weak self] in
                self?.apps = apps; self?.folders = folders; self?.shortcutNames = shortcuts
                self?.refreshSuggestions()
            }
            // Your sites, for "open workloom": slower, so after everything else is ready, and at most every half hour.
            guard await MainActor.run(body: { [weak self] in
                guard let self, Date().timeIntervalSince(self.sitesIndexedAt) > 1_800 || self.sitesFromHistory != history else { return false }
                self.sitesIndexedAt = Date(); self.sitesFromHistory = history
                return true
            }) else { return }
            let visited = history ? SiteBook.history() : [:]
            let projects = SiteBook.projects(folders, appNames: Set(apps.map { $0.name.lowercased() }))
            await MainActor.run { [weak self] in self?.siteHistory = visited; self?.projectSites = projects }
        }
    }

    /// Opens a site known by name, or asks which one when several could be yours.
    private func openSite(_ name: String) async -> String? {
        if let url = sites[SiteBook.key(name)] { return await perform(.openURL(url)) }
        let candidates = SiteBook.candidates(for: name, history: siteHistory, projects: projectSites)
        switch SiteBook.decide(candidates) {
        case .open(let url):
            return await perform(.openURL(url))
        case .ask(let options):
            // Keep the browser you asked for with each choice.
            let browser = BrowserLaunch.preferred.flatMap { url in apps.first { $0.url == url } }
            let key = SiteBook.key(name)
            choices = options.map { option in
                let open = CommandAction.sequence([.learnSite(key, option.url), .openURL(option.url)])
                return CommandSuggestion(title: option.host, subtitle: option.fromHistory ? "You’ve visited it \(option.weight) time\(option.weight == 1 ? "" : "s")" : "Named in your \(name) project",
                                         icon: .symbol("globe", tint: .blue), action: browser.map { .inBrowser(open, $0) } ?? open, confidence: 1)
            } + [CommandSuggestion(title: "Search the web for “\(name)”", subtitle: "Google", icon: .symbol("magnifyingglass", tint: .neutral),
                                   action: .openURL(URL(string: "https://www.google.com/search?q=" + CommandParser.encode(name))!), confidence: 0.5)]
            choicePrompt = "Which \(name.capitalizedFirst)? Murmur will remember."
            selection = 0
            askedForChoice = true
            return nil
        case .unknown:
            // Nothing of yours: the web's best match for the name.
            return await perform(.openURL(URL(string: "https://duckduckgo.com/?q=" + CommandParser.encode("!ducky " + name))!))
        }
    }

    nonisolated static func installedApps() -> [AppEntry] {
        let home = NSHomeDirectory()
        let roots = ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
                     home + "/Applications", "/System/Library/CoreServices/Applications"]
        var seen = Set<String>(), apps: [AppEntry] = []
        func add(_ path: String) {
            let name = FileManager.default.displayName(atPath: path).replacingOccurrences(of: ".app", with: "")
            guard seen.insert(name.lowercased()).inserted else { return }
            apps.append(AppEntry(name: name, path: path, bundleID: Bundle(path: path)?.bundleIdentifier))
        }
        for root in roots {
            for item in (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? [] {
                let path = root + "/" + item
                if item.hasSuffix(".app") { add(path) }
                else if !item.hasPrefix("."), root == "/Applications" || root == home + "/Applications" {
                    // One level of folders, e.g. /Applications/Adobe Photoshop/…app
                    for inner in (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? [] where inner.hasSuffix(".app") { add(path + "/" + inner) }
                }
            }
        }
        add("/System/Library/CoreServices/Finder.app")
        return apps
    }

    /// Folders you'd open by name: what's in your home folder and common project folders.
    /// Documents, Desktop and Downloads are left to Spotlight, so macOS never asks for access to them.
    nonisolated static func projectFolders() -> [String: String] {
        let home = NSHomeDirectory()
        var folders: [String: String] = [:]
        for root in [home, home + "/Projects", home + "/Developer", home + "/src", home + "/code", home + "/Code", home + "/GitHub"] {
            guard let items = try? FileManager.default.contentsOfDirectory(atPath: root) else { continue }
            for item in items where !item.hasPrefix(".") && item != "Library" && item != "Applications" {
                var isDirectory: ObjCBool = false
                let path = root + "/" + item
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue, !item.hasSuffix(".app") else { continue }
                if folders[item] == nil { folders[item] = path }
            }
        }
        return folders
    }

    nonisolated static func shortcutList() -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = ["list"]
        let pipe = Pipe()
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    nonisolated static func runShortcut(_ name: String) async -> String? {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
            process.arguments = ["run", name]
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            process.terminationHandler = { finished in
                continuation.resume(returning: finished.terminationStatus == 0 ? nil : "The “\(name)” shortcut didn’t run.")
            }
            if (try? process.run()) == nil { continuation.resume(returning: "Couldn’t run Shortcuts.") }
        }
    }

    /// Files and folders in your home folder whose names match, most recently used first.
    nonisolated static func spotlight(_ name: String, limit: Int) async -> [URL] {
        await Task.detached(priority: .userInitiated) { () -> [URL] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
            process.arguments = ["-onlyin", NSHomeDirectory(), "kMDItemDisplayName == '*\(name.replacingOccurrences(of: "'", with: ""))*'cd"]
            let pipe = Pipe()
            process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return [] }
            let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 2, execute: timeout)
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit(); timeout.cancel()
            let paths = String(decoding: data, as: UTF8.self).components(separatedBy: .newlines).filter {
                !$0.isEmpty && !$0.contains("/Library/") && !$0.contains("/node_modules/") && !$0.contains("/.") && !$0.contains("/.build/")
            }.prefix(200)
            let query = name.lowercased()
            let ranked = paths.map { path -> (String, Double) in
                let file = (path as NSString).lastPathComponent.lowercased()
                let base = (file as NSString).deletingPathExtension
                var score = base == query ? 3.0 : base.hasPrefix(query) ? 2.0 : 1.0
                score -= Double(path.components(separatedBy: "/").count) * 0.03
                if let used = (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.contentAccessDateKey]))?.contentAccessDate {
                    score += max(0, 1 - Date().timeIntervalSince(used) / (86_400 * 60))
                }
                return (path, score)
            }.sorted { $0.1 > $1.1 }
            return ranked.prefix(limit).map { URL(fileURLWithPath: $0.0) }
        }.value
    }

    nonisolated static func abbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

// MARK: Media

enum MediaPlayer {
    /// Plays a song or video: finds the actual track or video and starts it.
    @MainActor static func play(_ query: String, on service: MusicService) async -> String? {
        switch service {
        case .spotify:
            guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.spotify.client") != nil else { return await play(query, on: .youtube) }
            if let track = await spotifyTrack(query) {
                if runScript("tell application \"Spotify\" to play track \"spotify:track:\(track)\"") { return nil }
                return NSWorkspace.shared.open(URL(string: "spotify:track:\(track)")!) ? nil : "Couldn’t open Spotify."
            }
            return NSWorkspace.shared.open(URL(string: "spotify:search:" + CommandParser.encode(query))!) ? nil : "Couldn’t open Spotify."
        case .appleMusic:
            let escaped = query.replacingOccurrences(of: "\"", with: "")
            let script = """
            tell application "Music"
                set found to (search playlist "Library" for "\(escaped)")
                if found is {} then error "none"
                play item 1 of found
            end tell
            """
            if runScript(script) { return nil }
            return NSWorkspace.shared.open(URL(string: "music://music.apple.com/search?term=" + CommandParser.encode(query))!) ? nil : "Couldn’t open Music."
        case .youtube, .youtubeMusic:
            let host = service == .youtubeMusic ? "https://music.youtube.com" : "https://www.youtube.com"
            if let video = await youtubeVideo(query) { return await BrowserLaunch.open(URL(string: "\(host)/watch?v=\(video)")!) ? nil : "Couldn’t open YouTube." }
            let search = service == .youtubeMusic ? "\(host)/search?q=" : "\(host)/results?search_query="
            return await BrowserLaunch.open(URL(string: search + CommandParser.encode(query))!) ? nil : "Couldn’t open YouTube."
        }
    }

    /// The first video in YouTube's results, so "play" starts playing instead of listing.
    static func youtubeVideo(_ query: String) async -> String? {
        guard let url = URL(string: "https://www.youtube.com/results?search_query=" + CommandParser.encode(query)) else { return nil }
        guard let html = await fetch(url) else { return nil }
        return CommandParser.capture(html, "\"videoRenderer\":\\{\"videoId\":\"([A-Za-z0-9_-]{11})\"")?[1]
            ?? CommandParser.capture(html, "\"videoId\":\"([A-Za-z0-9_-]{11})\"")?[1]
    }

    /// A Spotify track for a search, found through a public web search (no account or key needed).
    static func spotifyTrack(_ query: String) async -> String? {
        let search = CommandParser.encode("site:open.spotify.com/track " + query)
        for engine in ["https://search.brave.com/search?q=", "https://html.duckduckgo.com/html/?q="] {
            guard let url = URL(string: engine + search), let html = await fetch(url) else { continue }
            if let track = CommandParser.capture(html, "spotify\\.com(?:%2F|/)track(?:%2F|/)([A-Za-z0-9]{22})")?[1] { return track }
        }
        return nil
    }

    private static func fetch(_ url: URL) async -> String? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 4
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    @MainActor static func runScript(_ source: String) -> Bool {
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        return error == nil
    }

    /// The keyboard's play/pause, next and previous keys: works with any player.
    static func press(_ key: CommandAction.Media) {
        let code: Int32 = key == .playPause ? 16 : key == .next ? 17 : 18
        for down in [true, false] {
            let flags = NSEvent.ModifierFlags(rawValue: down ? 0xA00 : 0xB00)
            let data1 = Int((code << 16) | ((down ? 0xA : 0xB) << 8))
            NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                               context: nil, subtype: 8, data1: data1, data2: -1)?.cgEvent?.post(tap: .cghidEventTap)
        }
    }
}

enum SystemVolume {
    private static func device() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id = AudioObjectID(0); var size = UInt32(MemoryLayout<AudioObjectID>.size)
        return AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr ? id : nil
    }
    private static var volumeAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    private static var muteAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)

    static func apply(_ change: CommandAction.Volume) -> String? {
        guard let device = device() else { return "No speakers found." }
        switch change {
        case .mute, .unmute:
            var value: UInt32 = change == .mute ? 1 : 0
            return AudioObjectSetPropertyData(device, &muteAddress, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr ? nil : "This output can’t be muted."
        case .up, .down, .set:
            var current: Float32 = 0; var size = UInt32(MemoryLayout<Float32>.size)
            AudioObjectGetPropertyData(device, &volumeAddress, 0, nil, &size, &current)
            var target: Float32
            switch change {
            case .up: target = min(1, current + 0.125)
            case .down: target = max(0, current - 0.125)
            case .set(let level): target = Float32(level) / 100
            default: target = current
            }
            var unmute: UInt32 = 0
            AudioObjectSetPropertyData(device, &muteAddress, 0, nil, UInt32(MemoryLayout<UInt32>.size), &unmute)
            return AudioObjectSetPropertyData(device, &volumeAddress, 0, nil, size, &target) == noErr ? nil : "This output’s volume can’t be changed."
        }
    }
}

enum SystemControl {
    @MainActor static func perform(_ action: CommandAction.System) async -> String? {
        switch action {
        case .lock:
            // Control-Command-Q, the system's own lock shortcut.
            let source = CGEventSource(stateID: .hidSystemState)
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: 12, keyDown: down)
                event?.flags = [.maskCommand, .maskControl]
                event?.post(tap: .cghidEventTap)
            }
            return nil
        case .sleep:
            return run("/usr/bin/pmset", ["sleepnow"]) ? nil : "Couldn’t put the Mac to sleep."
        case .darkMode, .lightMode, .toggleAppearance:
            let value = action == .darkMode ? "true" : action == .lightMode ? "false" : "not dark mode"
            return MediaPlayer.runScript("tell application \"System Events\" to tell appearance preferences to set dark mode to \(value)")
                ? nil : "Allow Murmur to control System Events in System Settings → Privacy & Security → Automation."
        case .emptyTrash:
            return MediaPlayer.runScript("tell application \"Finder\" to empty trash") ? nil : "Allow Murmur to control Finder in System Settings → Privacy & Security → Automation."
        case .screenshot:
            return NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Screenshot.app")) ? nil : "Couldn’t open Screenshot."
        case .closeTab, .newTab, .reopenTab, .goBack:
            // The palette has already stepped aside, so the app you were in gets the shortcut.
            let key: CGKeyCode = action == .closeTab ? 13 : action == .goBack ? 33 : 17
            let source = CGEventSource(stateID: .hidSystemState)
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)
                event?.flags = action == .reopenTab ? [.maskCommand, .maskShift] : .maskCommand
                event?.post(tap: .cghidEventTap)
            }
            return nil
        case .showDesktop:
            // F11-style "show desktop" via Mission Control's hot key isn't scriptable; hide other apps instead.
            NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0 != NSRunningApplication.current }.forEach { $0.hide() }
            return nil
        }
    }

    private static func run(_ path: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path); process.arguments = arguments
        return (try? process.run()) != nil
    }
}

/// Finds and focuses an app's message box (ChatGPT, Claude, Slack, T3 Code…)
/// through Accessibility, when nothing editable has focus yet.
enum Composer {
    private static let names = ["message", "ask anything", "send a message", "reply", "how can i help", "write a message",
                                "type a message", "chat", "prompt", "ask", "compose", "jot something down"]

    static func focus(pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        if let focused = element(app, kAXFocusedUIElementAttribute), isEditable(focused) { return true }
        guard let window = element(app, kAXFocusedWindowAttribute) ?? element(app, kAXMainWindowAttribute) else { return false }
        var candidates: [(element: AXUIElement, score: Int)] = []
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var index = 0
        // Breadth-first and bounded: big web apps have thousands of elements.
        while index < queue.count, index < 1500 {
            let (node, depth) = queue[index]; index += 1
            if isEditable(node) {
                let label = [kAXPlaceholderValueAttribute, kAXDescriptionAttribute, kAXTitleAttribute, kAXHelpAttribute]
                    .compactMap { string(node, $0)?.lowercased() }.joined(separator: " ")
                let named = names.contains { label.contains($0) }
                let isSearch = label.contains("search") || string(node, kAXSubroleAttribute) == "AXSearchField"
                if !isSearch { candidates.append((node, (named ? 100 : 0) + (string(node, kAXRoleAttribute) == "AXTextArea" ? 10 : 0) + depth)) }
            }
            guard depth < 40 else { continue }
            for child in children(node) { queue.append((child, depth + 1)) }
        }
        guard let best = candidates.max(by: { $0.score < $1.score })?.element else { return false }
        return AXUIElementSetAttributeValue(best, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success
    }

    private static func element(_ parent: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parent, attribute as CFString, &value) == .success, let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func children(_ node: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(node, kAXChildrenAttribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private static func string(_ node: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(node, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func isEditable(_ node: AXUIElement) -> Bool {
        let role = string(node, kAXRoleAttribute) ?? ""
        let editable = boolean(node, "AXEditable") == true
        guard ["AXTextArea", "AXTextField", "AXComboBox"].contains(role) || editable else { return false }
        if string(node, kAXSubroleAttribute) == "AXSecureTextField" { return false }
        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(node, kAXValueAttribute as CFString, &settable)
        return settable.boolValue || editable
    }

    private static func boolean(_ node: AXUIElement, _ attribute: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(node, attribute as CFString, &value) == .success else { return nil }
        return value as? Bool
    }
}


/// Reminders, calendar events and notes, added directly instead of by
/// clicking through each app: EventKit for Reminders and Calendar, and
/// Notes' own scripting for notes. Asks for access the first time.
@MainActor
enum Organizer {
    private static let store = EKEventStore()

    static func addReminder(_ title: String, notes: String?, due: Date?) async -> String? {
        guard (try? await store.requestFullAccessToReminders()) == true else {
            return "Allow Murmur to use Reminders in System Settings → Privacy & Security → Reminders."
        }
        guard let list = store.defaultCalendarForNewReminders() else { return "Reminders has no list to add to." }
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.notes = notes
        reminder.calendar = list
        if let due {
            // Midnight means a day without a time: an all-day reminder.
            let allDay = Calendar.current.startOfDay(for: due) == due
            reminder.dueDateComponents = Calendar.current.dateComponents(allDay ? [.year, .month, .day] : [.year, .month, .day, .hour, .minute], from: due)
            if !allDay { reminder.addAlarm(EKAlarm(absoluteDate: due)) }
        }
        do { try store.save(reminder, commit: true); return nil }
        catch { return "Couldn’t add the reminder: \(error.localizedDescription)" }
    }

    static func addEvent(_ title: String, start: Date, minutes: Int) async -> String? {
        guard (try? await store.requestFullAccessToEvents()) == true else {
            return "Allow Murmur to use Calendars in System Settings → Privacy & Security → Calendars."
        }
        guard let calendar = store.defaultCalendarForNewEvents else { return "There’s no calendar to add to." }
        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = start
        event.endDate = start.addingTimeInterval(TimeInterval(minutes * 60))
        event.calendar = calendar
        do { try store.save(event, span: .thisEvent, commit: true); return nil }
        catch { return "Couldn’t add the event: \(error.localizedDescription)" }
    }

    static func addNote(_ text: String) -> String? {
        func quoted(_ value: String) -> String {
            "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let html = text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: "\n", with: "<br>")
        let script = "tell application \"Notes\" to make new note with properties {body:\(quoted("<div>" + html + "</div>"))}"
        return MediaPlayer.runScript(script) ? nil : "Allow Murmur to control Notes in System Settings → Privacy & Security → Automation."
    }
}
