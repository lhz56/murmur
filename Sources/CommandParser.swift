import Foundation

/// An app Murmur can open.
struct AppEntry: Equatable, Hashable, Codable {
    let name: String
    let path: String
    var bundleID: String?
    var url: URL { URL(fileURLWithPath: path) }
}

enum MusicService: String, Codable, CaseIterable, Identifiable {
    case youtube = "YouTube", spotify = "Spotify", appleMusic = "Apple Music", youtubeMusic = "YouTube Music"
    var id: String { rawValue }
}

/// What a command does. Parsing never performs anything; `CommandRunner` does.
enum CommandAction: Equatable {
    enum Media: String { case playPause, next, previous }
    enum Volume: Equatable { case up, down, set(Int), mute, unmute }
    enum System: String {
        case lock, sleep, darkMode, lightMode, toggleAppearance, emptyTrash, screenshot, showDesktop
        /// Keyboard shortcuts sent to the app in front: ⌘W, ⌘T, ⌘⇧T, ⌘[.
        case closeTab, newTab, reopenTab, goBack
        var isKeystroke: Bool { [.closeTab, .newTab, .reopenTab, .goBack].contains(self) }
    }
    enum Meeting: String { case start, stop }

    case openApp(AppEntry)
    case quitApp(String)
    case hideApp(String)
    case openURL(URL)
    /// A website known only by name ("workloom"): Murmur looks it up in your sites when it runs, and asks if it's unsure.
    case openSite(String)
    /// Remembers which site a name means, after you picked it.
    case learnSite(String, URL)
    case openPath(String, in: AppEntry?)
    case findFile(String, in: AppEntry?)
    case play(String, on: MusicService)
    case media(Media)
    case volume(Volume)
    case timer(seconds: Int, label: String)
    case shortcut(String)
    /// Types your exact words into an app's message box (or the current one). Never presses Send.
    case type(String, in: AppEntry?)
    case system(System)
    case meeting(Meeting)
    case murmur(String)
    /// Adds a reminder to Reminders; `due` is when to be reminded.
    case addReminder(String, notes: String?, due: Date?)
    /// Adds an event to your calendar.
    case addEvent(String, start: Date, minutes: Int)
    /// Makes a new note in Notes.
    case addNote(String)
    case sequence([CommandAction])
    /// Web pages in this command open in a particular browser ("…on Safari").
    indirect case inBrowser(CommandAction, AppEntry)
    /// Typed text that isn't a command yet: offer to search or ask.
    case none

    /// Can't be undone, so the palette asks once more.
    var needsConfirmation: Bool {
        if case .system(.emptyTrash) = self { return true }
        if case .sequence(let steps) = self { return steps.contains { $0.needsConfirmation } }
        if case .inBrowser(let inner, _) = self { return inner.needsConfirmation }
        return false
    }
}

/// One row in the palette: what will happen if you press Return.
struct CommandSuggestion: Equatable, Identifiable {
    var id: String { title + "|" + subtitle }
    let title: String
    let subtitle: String
    let icon: Icon
    let action: CommandAction
    /// 0…1: how sure the parser is that this is what you meant.
    let confidence: Double

    enum Icon: Equatable {
        case app(String)  // path, for the real app icon
        case symbol(String, tint: Tint)
        enum Tint: String { case neutral, blue, red, green, orange, purple, pink }
    }
}

/// Things the parser can match against, gathered by `CommandCenter`.
struct CommandContext {
    var apps: [AppEntry] = []
    var shortcuts: [String] = []
    /// Folders worth opening by name: projects, Downloads, etc. Name → path.
    var folders: [String: String] = [:]
    /// Selected text or a copied link, for "play this" and "open this".
    var selection: String?
    var music: MusicService = .youtube
    var customCommands: [CustomCommand] = []
    /// How often each app was opened from Murmur, to rank close matches.
    var usage: [String: Int] = [:]
    /// What you picked last time you typed exactly this: normalized text → title.
    var learned: [String: String] = [:]
    /// Commands that worked before, newest first, offered when you type their start.
    var recent: [String] = []
    /// Your sites by name, from what you picked or added: "workloom" → workloom.live.
    var sites: [String: URL] = [:]
}

/// A phrase you define that runs other commands, e.g. "work mode" → open Cursor, open Slack.
struct CustomCommand: Codable, Equatable, Identifiable {
    var id = UUID()
    var phrase: String
    var steps: [String]
}

/// Understands everyday phrasing ("can you open Spotify and play Drake",
/// "put on some lofi", "open murmur in cursor", "timer 25 minutes") and turns
/// it into ranked suggestions. Pure and fast: it runs on every keystroke.
enum CommandParser {
    static func suggestions(for input: String, context: CommandContext) -> [CommandSuggestion] {
        let said = normalize(input)
        guard !said.isEmpty else { return [] }
        // "open youtube on safari and play linger": the same command, in that browser.
        if let (rest, browser) = browserRequest(said, context: context) {
            var inner = suggestions(for: rest, context: context).filter { usesWeb($0.action) && $0.confidence >= 0.6 }
            // "open workloom on safari": opening a name in a browser is its website.
            if inner.isEmpty, let opened = strip(rephrase(rest), prefixes: openVerbs) {
                inner = open(opened + " in " + browser.name.lowercased(), context: context, explicit: true)
                    .filter { if case .inBrowser = $0.action { return true }; return false }
                if let site = inner.first { return [site] + suggestions(for: input, context: context, browsers: false).filter { $0.title != site.title }.prefix(5) }
            }
            if let first = inner.first {
                var plain = context; plain.recent = []
                let others = suggestions(for: input, context: plain, browsers: false)
                let wrapped = CommandSuggestion(title: first.title + " in \(browser.name)", subtitle: first.subtitle, icon: first.icon,
                                                action: .inBrowser(first.action, browser), confidence: first.confidence)
                return [wrapped] + others.filter { $0.title != wrapped.title }.prefix(5)
            }
        }
        return suggestions(for: input, context: context, browsers: false)
    }

    /// Browsers people name: "on Safari", "in Chrome", "using Arc".
    static let browserNames = ["google chrome", "chrome", "safari", "arc", "firefox", "brave browser", "brave", "microsoft edge", "edge",
                               "opera", "orion", "zen", "dia", "vivaldi", "chromium", "duckduckgo"]

    /// Splits a browser out of the request: what to do, and where.
    static func browserRequest(_ said: String, context: CommandContext) -> (String, AppEntry)? {
        for name in browserNames {
            guard said.contains(name) else { continue }
            guard let app = context.apps.first(where: { $0.name.lowercased() == name })
                    ?? context.apps.first(where: { $0.name.lowercased().hasPrefix(name + " ") || $0.name.lowercased().hasSuffix(" " + name) }) else { continue }
            let escaped = NSRegularExpression.escapedPattern(for: name)
            if let match = capture(said, "^(?:open|launch|go to|use|pull up) (?:the )?\(escaped)(?: browser)?(?:,? (?:and|then|and then)|,|(?= (?:open|go to|search|look up|find|play|pull up) )) (.+)$") {
                return (match[1], app)
            }
            if let match = capture(said, "^(.+?),? (?:on|in|using|with|via|through) (?:the )?\(escaped)(?: browser)?((?:,? and |,? then |, ).+)?$") {
                return (match[1] + (match.count > 2 ? match[2] : ""), app)
            }
        }
        return nil
    }

    /// Opens something in a browser: a page, or a video on YouTube.
    static func usesWeb(_ action: CommandAction) -> Bool {
        switch action {
        case .openURL(let url): return url.scheme == "http" || url.scheme == "https"
        case .openSite: return true
        case .play(_, let service): return service == .youtube || service == .youtubeMusic
        case .sequence(let steps): return steps.contains(where: usesWeb)
        default: return false
        }
    }

    private static func suggestions(for input: String, context: CommandContext, browsers: Bool) -> [CommandSuggestion] {
        let said = normalize(input)
        guard !said.isEmpty else { return [] }
        let text = rephrase(said)
        var results: [CommandSuggestion] = []
        // Dictated words are kept exactly as said, so typing is read from the original input.
        if let typing = typing(input, context: context) { results.append(typing) }
        // "work mode" and other phrases you defined come first.
        if let custom = context.customCommands.first(where: { normalize($0.phrase) == said }) {
            // Steps can't expand your own phrases again, so "work mode" inside "work mode" can't loop.
            var plain = context; plain.customCommands = []
            let steps = custom.steps.compactMap { best(for: $0, context: plain)?.action }
            if !steps.isEmpty {
                results.append(.init(title: custom.phrase.capitalizedFirst, subtitle: custom.steps.joined(separator: " · "),
                                     icon: .symbol("sparkles", tint: .purple), action: .sequence(steps), confidence: 1))
            }
        }
        // "open spotify and play drake": several commands in one breath.
        let parts = splitSequence(text)
        if parts.count > 1 {
            let steps = parts.compactMap { part in single(part, context: context).first.flatMap { $0.confidence >= 0.6 ? $0 : nil } }
            if steps.count == parts.count {
                results.append(.init(title: steps.map(\.title).joined(separator: ", then "), subtitle: "\(steps.count) steps",
                                     icon: steps[0].icon, action: .sequence(steps.map(\.action)),
                                     confidence: steps.map(\.confidence).min() ?? 0.6))
            }
        }
        // When the whole phrase is a sequence, a file named after all of it is noise.
        let hasSequence = results.contains { if case .sequence = $0.action { return true }; return false }
        results += single(text, context: context).filter { !hasSequence || $0.confidence >= 0.8 }
        results += fallbacks(text, context: context, hasStrong: results.contains { $0.confidence >= 0.8 })
        var seen = Set<String>()
        let ranked = results.sorted { $0.confidence > $1.confidence }.filter { seen.insert($0.title.lowercased()).inserted }
        return Array(remembered(ranked, said: said, context: context).prefix(8))
    }

    /// Learns from you: what you chose for this exact text comes first, and the
    /// start of a command you've run before offers the whole thing.
    static func remembered(_ results: [CommandSuggestion], said: String, context: CommandContext) -> [CommandSuggestion] {
        var results = results
        let top = results.first?.confidence ?? 0
        if let title = context.learned[said], let index = results.firstIndex(where: { $0.title == title }), index > 0 {
            let chosen = results.remove(at: index)
            results.insert(.init(title: chosen.title, subtitle: chosen.subtitle, icon: chosen.icon, action: chosen.action,
                                 confidence: max(chosen.confidence, top)), at: 0)
        }
        guard said.count >= 2 else { return results }
        var plain = context; plain.recent = []; plain.learned = [:]
        for past in context.recent {
            let pastSaid = normalize(past)
            guard pastSaid.count > said.count, pastSaid.hasPrefix(said),
                  let again = suggestions(for: past, context: plain).first, again.confidence >= 0.6,
                  !results.contains(where: { $0.title == again.title }) else { continue }
            // First when nothing else fits well, second otherwise; always below the instant-voice bar.
            let strong = top >= 0.8
            results.insert(.init(title: again.title, subtitle: "Recent · \(again.subtitle)", icon: again.icon, action: again.action,
                                 confidence: strong ? min(top, 0.86) - 0.01 : 0.86), at: strong ? min(1, results.count) : 0)
            break
        }
        return results
    }

    /// The single best interpretation, for spoken commands.
    static func best(for input: String, context: CommandContext) -> CommandSuggestion? {
        suggestions(for: input, context: context).first
    }

    // MARK: Normalizing

    private static let politeness = ["hey murmur", "okay murmur", "ok murmur", "murmur", "can you please", "could you please", "can you",
                                     "could you", "would you", "will you", "please", "i want to", "i wanna", "i'd like to", "go ahead and",
                                     "let's", "lets", "quickly", "just", "for me", "real quick", "now", "hey", "hi", "yo", "okay", "ok", "um", "uh", "so",
                                     "alright", "thanks", "thank you"]

    static func normalize(_ input: String) -> String {
        var text = input.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".?!,")))
        // "hey, can you…": the comma after a greeting means nothing; other commas separate steps.
        text = text.replacingOccurrences(of: "^(?:hey|hi|yo|okay|ok|so|um|uh|alright)(?: murmur)?\\s*,\\s*", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\s*,\\s*", with: ", ", options: .regularExpression)
        text = text.replacingOccurrences(of: "[\\s]+", with: " ", options: .regularExpression)
        // "recallr dot com" → "recallr.com"
        text = text.replacingOccurrences(of: " dot (com|org|net|io|ai|app|dev|co|edu|so|xyz|me)\\b", with: ".$1", options: .regularExpression)
        var changed = true
        while changed {
            changed = false
            for phrase in politeness {
                if text.hasPrefix(phrase + " ") { text = String(text.dropFirst(phrase.count + 1)); changed = true }
                if text.hasPrefix(phrase + ", ") { text = String(text.dropFirst(phrase.count + 2)); changed = true }
                if text.hasSuffix(" " + phrase) { text = String(text.dropLast(phrase.count + 1)); changed = true }
            }
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// "open and play this" → "play this"; "open youtube and search for lofi" → "search youtube for lofi".
    static func rephrase(_ text: String) -> String {
        var text = text.replacingOccurrences(of: "^(?:open|find|go) and (play|search|watch|listen to|look up) ", with: "$1 ", options: .regularExpression)
        // "open youtube and play linger": one step, not two.
        if let match = capture(text, "^(?:open|go to|pull up|launch) (youtube music|youtube|spotify|apple music),? (?:and |then |and then )?(?:play|put on|watch|listen to) (.+)$") {
            text = "play \(match[2]) on \(match[1])"
        }
        if let match = capture(text, "^(?:open|go to|pull up) ([a-z0-9. ]+?) and (?:search|look up|find)(?: for)? (.+)$"), Sites.searchable(match[1]) != nil {
            text = "search \(match[1]) for \(match[2])"
        }
        return text
    }

    private static let verbs = ["open", "launch", "start", "play", "search", "google", "look up", "find", "quit", "close", "hide",
                                "set", "turn", "mute", "unmute", "pause", "resume", "skip", "go to", "show", "take", "run", "ask",
                                "timer", "lock", "put on", "listen to", "email", "new", "translate", "navigate", "directions", "volume", "switch to"]

    private static let mediaWords: Set<String> = ["pause", "next song", "skip", "mute", "unmute", "lock screen", "dark mode", "light mode"]

    static func splitSequence(_ text: String) -> [String] {
        var pieces = text.components(separatedBy: " and then ").flatMap { $0.components(separatedBy: " then ") }
            .flatMap { $0.components(separatedBy: " and ") }.flatMap { $0.components(separatedBy: ", ") }
        // "open safari open workloom", said without a pause: a second "open" starts a new step.
        pieces = pieces.flatMap { piece -> [String] in
            var parts: [String] = []
            var current = ""
            for word in piece.split(separator: " ").map(String.init) {
                if ["open", "launch"].contains(word), current.split(separator: " ").count >= 2, verbs.contains(where: { current.hasPrefix($0 + " ") }) {
                    parts.append(current); current = word
                } else { current += current.isEmpty ? word : " " + word }
            }
            if !current.isEmpty { parts.append(current) }
            return parts
        }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ","))) }
            .filter { !$0.isEmpty }
        guard pieces.count > 1 else { return [text] }
        // Only split when every part starts like a command: "rock and roll" stays one search.
        // Each part needs a verb and something to act on ("open" alone isn't a step).
        return pieces.allSatisfy { piece in verbs.contains { piece.hasPrefix($0 + " ") } || mediaWords.contains(piece) } ? pieces : [text]
    }

    // MARK: One command

    private static func single(_ text: String, context: CommandContext) -> [CommandSuggestion] {
        if let timer = timer(text) { return [timer] }
        if let media = media(text) { return [media] }
        if let volume = volume(text) { return [volume] }
        if let system = system(text) { return [system] }
        if let meeting = meeting(text) { return [meeting] }
        if let shortcut = shortcut(text, context: context) { return [shortcut] }
        if let play = play(text, context: context) { return [play] }
        // "play spotify", "put on music": open the player itself.
        if let player = strip(text, prefixes: ["play", "put on"]), ["spotify", "music", "apple music", "youtube", "youtube music", "some music"].contains(player) {
            return open(player == "some music" ? context.music == .spotify ? "spotify" : "music" : player, context: context, explicit: true)
        }
        if let ask = ask(text) { return [ask] }
        if let search = search(text) { return [search] }
        if let quit = quitOrHide(text, context: context) { return [quit] }
        if let make = create(text) { return [make] }
        if let directions = directions(text) { return [directions] }
        if let translate = translate(text) { return [translate] }
        if let murmur = murmur(text) { return [murmur] }
        if let rest = strip(text, prefixes: openVerbs) { return open(rest, context: context, explicit: true) }
        // A bare name: "spotify", "github", "downloads".
        return open(text, context: context, explicit: false)
    }

    private static let openVerbs = ["open up", "open", "launch", "start up", "start", "go to", "show me", "show", "bring up", "pull up",
                                    "switch to", "take me to", "visit", "navigate to", "load", "fire up", "boot up", "get"]

    static func strip(_ text: String, prefixes: [String]) -> String? {
        for prefix in prefixes where text.hasPrefix(prefix + " ") {
            let rest = String(text.dropFirst(prefix.count + 1)).trimmingCharacters(in: .whitespaces)
            if !rest.isEmpty { return rest }
        }
        return nil
    }

    private static func dropArticles(_ text: String) -> String {
        var result = text
        for article in ["the ", "my ", "a ", "an ", "up ", "some "] where result.hasPrefix(article) { result = String(result.dropFirst(article.count)) }
        for suffix in [" app", " application", " website", " site", " page", " for me"] where result.hasSuffix(suffix) && result.count > suffix.count + 1 {
            result = String(result.dropLast(suffix.count))
        }
        return result
    }

    private static func open(_ raw: String, context: CommandContext, explicit: Bool) -> [CommandSuggestion] {
        var target = dropArticles(raw)
        var results: [CommandSuggestion] = []
        // "open workloom website": the site, even when an app or folder has the same name.
        let said = raw.trimmingCharacters(in: .whitespaces)
        for suffix in [" website", " site", " homepage", " web page", " webpage", " dot com"] where said.hasSuffix(suffix) {
            let name = dropArticles(String(said.dropLast(suffix.count)))
            guard !name.isEmpty else { break }
            if let url = webURL(name) {
                return [.init(title: "Open \(url.host ?? name)", subtitle: "Website", icon: .symbol("globe", tint: .blue), action: .openURL(url), confidence: 0.95)]
            }
            let site = website(named: name, context: context)
            return [.init(title: site.title, subtitle: "Website", icon: .symbol("globe", tint: .blue), action: site.action, confidence: 0.95)]
        }
        // "open murmur in cursor", "open this in safari"
        var inApp: AppEntry?
        if let range = target.range(of: " in ", options: .backwards) {
            let appName = String(target[range.upperBound...])
            if let match = matchApp(appName, in: context), match.score >= 0.75 {
                inApp = match.app; target = String(target[..<range.lowerBound])
            }
        }
        if ["this", "that", "it", "this link", "that link", "the link"].contains(target), let selection = context.selection?.nilIfBlank {
            if let url = webURL(selection) {
                return [.init(title: "Open \(url.host ?? url.absoluteString)", subtitle: "Selected link", icon: .symbol("link", tint: .blue), action: .openURL(url), confidence: 0.97)]
            }
            return [.init(title: "Search “\(selection.prefix(40))”", subtitle: "Google", icon: .symbol("magnifyingglass", tint: .blue),
                          action: .openURL(searchURL("google", selection)), confidence: 0.8)]
        }
        if let url = webURL(target) {
            results.append(.init(title: "Open \(url.host ?? target)" + (inApp.map { " in \($0.name)" } ?? ""), subtitle: inApp.map { "Website in \($0.name)" } ?? "Website",
                                 icon: .symbol("globe", tint: .blue), action: inApp.map { .openPath(url.absoluteString, in: $0) } ?? .openURL(url), confidence: 0.96))
        }
        // A folder "in Safari" means the website: browsers show websites.
        let inBrowser = inApp.map { app in browserNames.contains { app.name.lowercased() == $0 || app.name.lowercased().hasSuffix(" " + $0) } } ?? false
        if inBrowser, let browser = inApp, webURL(target) == nil {
            let site = website(named: target, context: context)
            results.append(.init(title: site.title + " in \(browser.name)", subtitle: "Website in \(browser.name)", icon: .symbol("globe", tint: .blue),
                                 action: .inBrowser(site.action, browser), confidence: 0.9))
            return results
        }
        // "open the workloom app": the app, not a folder with the same name.
        let saidApp = said.hasSuffix(" app") || said.hasSuffix(" application")
        if !saidApp, let folder = folder(target, context: context) {
            results.append(.init(title: "Open \(folder.name)" + (inApp.map { " in \($0.name)" } ?? ""), subtitle: (inApp.map { "Folder in \($0.name) · " } ?? "Folder · ") + abbreviate(folder.path),
                                 icon: inApp.map { .app($0.path) } ?? .symbol("folder.fill", tint: .blue), action: .openPath(folder.path, in: inApp), confidence: folder.score))
        }
        let appMatches = rankedApps(target, in: context).prefix(3)
        for match in appMatches where inApp == nil {
            results.append(.init(title: "Open \(match.app.name)", subtitle: "Application", icon: .app(match.app.path),
                                 action: .openApp(match.app), confidence: match.score * (explicit ? 1 : 0.97)))
        }
        if let site = Sites.find(target) {
            let confidence = site.exact ? 0.9 : 0.7
            results.append(.init(title: "Open \(site.site.name)", subtitle: site.site.home.host ?? "Website",
                                 icon: .symbol("globe", tint: .blue), action: .openURL(site.site.home), confidence: confidence))
        }
        if explicit, inApp != nil || results.allSatisfy({ $0.confidence < 0.8 }) {
            results.append(.init(title: "Find “\(target)”", subtitle: inApp.map { "Search your files, open in \($0.name)" } ?? "Search your files",
                                 icon: .symbol("doc.text.magnifyingglass", tint: .neutral), action: .findFile(target, in: inApp), confidence: 0.55))
        }
        return results
    }

    /// A website by its name: one you've told Murmur about, a well-known one, or
    /// one to look up among your sites when the command runs.
    static func website(named name: String, context: CommandContext) -> (title: String, action: CommandAction) {
        if let url = context.sites[SiteBook.key(name)] { return ("Open \(url.host ?? name)", .openURL(url)) }
        if let site = Sites.find(name) { return ("Open \(site.site.name)", .openURL(site.site.home)) }
        return ("Open \(name.capitalizedFirst) website", .openSite(name))
    }

    private static func abbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    // MARK: Apps

    static func rankedApps(_ name: String, in context: CommandContext) -> [(app: AppEntry, score: Double)] {
        let query = name.lowercased()
        guard query.count >= 2 else { return [] }
        let aliased = appAliases[query].map { [$0] } ?? []
        return context.apps.compactMap { app -> (AppEntry, Double)? in
            var score = appScore(query, app.name)
            if aliased.contains(where: { $0.lowercased() == app.name.lowercased() }) { score = max(score, 0.98) }
            guard score >= 0.5 else { return nil }
            // Apps you open a lot win close calls.
            let boost = min(0.04, Double(context.usage[app.name] ?? 0) * 0.005)
            return (app, min(1, score + boost))
        }.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.name.count < $1.0.name.count }
    }

    static func matchApp(_ name: String, in context: CommandContext) -> (app: AppEntry, score: Double)? {
        rankedApps(dropArticles(name), in: context).first
    }

    static let appAliases: [String: String] = [
        "vs code": "Visual Studio Code", "vscode": "Visual Studio Code", "code": "Visual Studio Code", "chrome": "Google Chrome",
        "settings": "System Settings", "system preferences": "System Settings", "preferences": "System Settings",
        "app store": "App Store", "iterm": "iTerm", "word": "Microsoft Word", "excel": "Microsoft Excel",
        "powerpoint": "Microsoft PowerPoint", "teams": "Microsoft Teams", "outlook": "Microsoft Outlook", "facetime": "FaceTime",
        "imessage": "Messages", "texts": "Messages", "text messages": "Messages", "itunes": "Music", "apple music": "Music",
        "calculator": "Calculator", "the terminal": "Terminal", "photoshop": "Adobe Photoshop", "final cut": "Final Cut Pro",
        "activity monitor": "Activity Monitor", "task manager": "Activity Monitor", "t3": "T3 Code", "t3 code": "T3 Code",
        "claude code": "Claude", "chat gpt": "ChatGPT", "gpt": "ChatGPT", "codex": "Codex", "xcode": "Xcode",
    ]

    /// How well a spoken or typed name matches an app name, 0…1.
    static func appScore(_ query: String, _ appName: String) -> Double {
        let name = appName.lowercased()
        let compactQuery = query.filter { $0.isLetter || $0.isNumber }
        let compactName = name.filter { $0.isLetter || $0.isNumber }
        guard !compactQuery.isEmpty, !compactName.isEmpty else { return 0 }
        if compactQuery == compactName { return 1 }
        if name.hasPrefix(query) { return 0.86 + 0.1 * Double(query.count) / Double(name.count) }
        let words = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        // "studio code", "teams": matches a word inside the name.
        if words.contains(where: { $0 == compactQuery }) { return 0.85 }
        if words.contains(where: { $0.hasPrefix(compactQuery) }) && compactQuery.count >= 3 { return 0.78 }
        // Initials: "vsc" → Visual Studio Code.
        if words.count > 1, compactQuery == String(words.compactMap(\.first)) { return 0.8 }
        if compactName.contains(compactQuery) && compactQuery.count >= 4 { return 0.72 }
        // Misheard names: "cursor" ≈ "curser", "figma" ≈ "fig ma".
        let similarity = CorrectionLearner.similarity(compactQuery, compactName)
        if compactQuery.count >= 4, similarity >= 0.75, compactQuery.first == compactName.first { return 0.6 + 0.3 * similarity }
        if compactQuery.count >= 4, compactQuery.first == compactName.first,
           BoostGuard.soundCode(compactQuery) == BoostGuard.soundCode(compactName), similarity >= 0.5 { return 0.7 }
        if isSubsequence(compactQuery, of: compactName), compactQuery.count >= 3 { return 0.55 }
        return 0
    }

    private static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        var index = haystack.startIndex
        for character in needle {
            guard let found = haystack[index...].firstIndex(of: character) else { return false }
            index = haystack.index(after: found)
        }
        return true
    }

    private static func folder(_ name: String, context: CommandContext) -> (name: String, path: String, score: Double)? {
        let home = NSHomeDirectory()
        let standard: [String: String] = ["downloads": "Downloads", "documents": "Documents", "desktop": "Desktop", "pictures": "Pictures",
                                          "photos folder": "Pictures", "music folder": "Music", "movies": "Movies", "home": "", "home folder": "",
                                          "applications": "/Applications", "apps folder": "/Applications", "icloud": "Library/Mobile Documents/com~apple~CloudDocs",
                                          "icloud drive": "Library/Mobile Documents/com~apple~CloudDocs", "projects": "Projects", "trash": ".Trash"]
        var query = name
        for suffix in [" folder", " project", " repo", " directory", " codebase"] where query.hasSuffix(suffix) { query = String(query.dropLast(suffix.count)) }
        if let relative = standard[query] ?? standard[name] {
            let path = relative.hasPrefix("/") ? relative : (relative.isEmpty ? home : home + "/" + relative)
            return ((query == "home" || query == "home folder") ? "Home" : (relative as NSString).lastPathComponent.capitalizedFirst, path, 0.95)
        }
        let saidFolder = query != name
        var best: (String, String, Double)?
        var bestRaw = 0.0
        for (folderName, path) in context.folders.sorted(by: { $0.key.count < $1.key.count }) {
            let score = appScore(query, folderName)
            if score >= 0.72, score > bestRaw { bestRaw = score; best = (folderName, path, saidFolder ? min(1, score + 0.1) : score * 0.92) }
        }
        return best
    }

    // MARK: Specific commands

    private static let numberWords: [String: Int] = ["a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7,
        "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "fifteen": 15, "twenty": 20, "twenty five": 25, "thirty": 30,
        "forty": 40, "forty five": 45, "fifty": 50, "sixty": 60, "ninety": 90, "half an": 30, "a half": 30]

    /// A number said as digits or words; anything beyond a day's worth of seconds isn't a real amount.
    static func number(_ word: String) -> Int? {
        guard let value = Int(word) ?? numberWords[word], (0...100_000).contains(value) else { return nil }
        return value
    }

    private static func timer(_ text: String) -> CommandSuggestion? {
        let pattern = "^(?:set (?:a |an )?|start (?:a |an )?)?(?:(.+?) )?timer(?: for)? ([a-z0-9 ]+?) ?(seconds?|secs?|minutes?|mins?|hours?|hrs?|h|m|s)(?: (?:to|for|called) (.+))?$"
        let remind = "^remind me in ([a-z0-9 ]+?) ?(seconds?|minutes?|mins?|hours?) (?:to )?(.+)$"
        if let match = capture(text, pattern), let amount = number(match[2]) {
            let seconds = amount * unit(match[3])
            let label = match[4].isEmpty ? (match[1].isEmpty ? "Timer" : match[1].capitalizedFirst) : match[4].capitalizedFirst
            return .init(title: "Timer for \(duration(seconds))", subtitle: label == "Timer" ? "Murmur will chime when it’s done" : label,
                         icon: .symbol("timer", tint: .orange), action: .timer(seconds: seconds, label: label), confidence: 0.97)
        }
        if let match = capture(text, remind), let amount = number(match[1]) {
            let seconds = amount * unit(match[2])
            return .init(title: "Remind me in \(duration(seconds))", subtitle: match[3].capitalizedFirst, icon: .symbol("bell", tint: .orange),
                         action: .timer(seconds: seconds, label: match[3].capitalizedFirst), confidence: 0.96)
        }
        return nil
    }

    private static func unit(_ word: String) -> Int {
        if word.hasPrefix("h") { return 3600 }
        if word.hasPrefix("s") { return 1 }
        return 60
    }

    static func duration(_ seconds: Int) -> String {
        if seconds % 3600 == 0 { return "\(seconds / 3600) hour\(seconds == 3600 ? "" : "s")" }
        if seconds >= 60, seconds % 60 == 0 { return "\(seconds / 60) minute\(seconds == 60 ? "" : "s")" }
        if seconds > 60 { return "\(seconds / 60) min \(seconds % 60) s" }
        return "\(seconds) second\(seconds == 1 ? "" : "s")"
    }

    private static func media(_ text: String) -> CommandSuggestion? {
        let pause = ["pause", "pause music", "pause the music", "pause it", "stop the music", "stop music", "pause song", "pause the song",
                     "resume", "resume music", "resume the music", "play", "unpause", "play music", "continue playing", "keep playing"]
        let next = ["next", "next song", "next track", "skip", "skip song", "skip this song", "skip this", "skip track", "next one"]
        let previous = ["previous", "previous song", "previous track", "last song", "go back", "back a song", "play the last song", "replay"]
        if pause.contains(text) { return .init(title: "Play / Pause", subtitle: "Whatever is playing", icon: .symbol("playpause.fill", tint: .pink), action: .media(.playPause), confidence: 0.95) }
        if next.contains(text) { return .init(title: "Next track", subtitle: "Whatever is playing", icon: .symbol("forward.fill", tint: .pink), action: .media(.next), confidence: 0.95) }
        if previous.contains(text) { return .init(title: "Previous track", subtitle: "Whatever is playing", icon: .symbol("backward.fill", tint: .pink), action: .media(.previous), confidence: 0.93) }
        return nil
    }

    private static func volume(_ text: String) -> CommandSuggestion? {
        func result(_ title: String, _ symbol: String, _ change: CommandAction.Volume) -> CommandSuggestion {
            .init(title: title, subtitle: "Volume", icon: .symbol(symbol, tint: .neutral), action: .volume(change), confidence: 0.96)
        }
        if ["mute", "mute it", "mute the sound", "mute audio", "mute volume", "mute my mac", "silence"].contains(text) { return result("Mute", "speaker.slash.fill", .mute) }
        if ["unmute", "unmute it", "unmute the sound", "unmute audio", "sound on"].contains(text) { return result("Unmute", "speaker.wave.2.fill", .unmute) }
        if let match = capture(text, "^(?:set |turn )?(?:the )?volume (?:to |at )?([a-z0-9 ]+?)(?: percent|%)?$"), let level = number(match[1]) ?? percentWords(match[1]) {
            return result("Volume \(min(level, 100))%", "speaker.wave.2.fill", .set(min(level, 100)))
        }
        let up = ["volume up", "turn it up", "turn up the volume", "turn the volume up", "louder", "make it louder", "increase volume", "increase the volume", "raise the volume"]
        let down = ["volume down", "turn it down", "turn down the volume", "turn the volume down", "quieter", "make it quieter", "softer", "lower the volume", "decrease volume", "decrease the volume"]
        if up.contains(text) { return result("Volume up", "speaker.plus.fill", .up) }
        if down.contains(text) { return result("Volume down", "speaker.minus.fill", .down) }
        if ["max volume", "full volume", "volume max", "volume all the way up"].contains(text) { return result("Volume 100%", "speaker.wave.3.fill", .set(100)) }
        return nil
    }

    private static func percentWords(_ text: String) -> Int? {
        ["half": 50, "max": 100, "maximum": 100, "full": 100, "zero": 0, "low": 20, "high": 80]
            .first { text.contains($0.key) }?.value
    }

    private static func system(_ text: String) -> CommandSuggestion? {
        let table: [(phrases: [String], title: String, symbol: String, action: CommandAction.System)] = [
            (["lock", "lock screen", "lock the screen", "lock my screen", "lock my mac", "lock the computer", "lock my computer", "lock the mac"], "Lock screen", "lock.fill", .lock),
            (["sleep", "go to sleep", "sleep the computer", "put the computer to sleep", "put my mac to sleep", "sleep my mac"], "Sleep", "moon.zzz.fill", .sleep),
            (["dark mode", "turn on dark mode", "switch to dark mode", "enable dark mode", "dark mode on"], "Dark mode", "moon.fill", .darkMode),
            (["light mode", "turn on light mode", "switch to light mode", "turn off dark mode", "dark mode off", "disable dark mode"], "Light mode", "sun.max.fill", .lightMode),
            (["toggle dark mode", "toggle appearance", "switch appearance"], "Toggle dark mode", "circle.lefthalf.filled", .toggleAppearance),
            (["empty trash", "empty the trash", "empty my trash", "clear the trash"], "Empty Trash", "trash.fill", .emptyTrash),
            (["screenshot", "take a screenshot", "take screenshot", "screen shot", "capture the screen", "screen recording", "record my screen"], "Screenshot", "camera.viewfinder", .screenshot),
            (["show desktop", "show the desktop", "hide everything", "clear the screen"], "Show desktop", "menubar.dock.rectangle", .showDesktop),
        ]
        guard let row = table.first(where: { $0.phrases.contains(text) }) else { return nil }
        return .init(title: row.title, subtitle: row.action == .emptyTrash ? "Can’t be undone" : "System",
                     icon: .symbol(row.symbol, tint: row.action == .emptyTrash ? .red : .neutral), action: .system(row.action), confidence: 0.97)
    }

    private static func meeting(_ text: String) -> CommandSuggestion? {
        let start = ["take notes", "take meeting notes", "start meeting notes", "start notes", "record this meeting", "record the meeting",
                     "record meeting", "start a meeting", "start meeting", "meeting notes", "start taking notes", "transcribe this meeting", "transcribe this call", "record this call"]
        let stop = ["stop notes", "stop meeting notes", "stop the meeting", "end meeting", "end the meeting", "stop recording the meeting",
                    "stop taking notes", "meeting over", "end notes", "stop meeting"]
        if start.contains(text) { return .init(title: "Take meeting notes", subtitle: "Murmur records both sides and writes notes after", icon: .symbol("person.2.wave.2.fill", tint: .red), action: .meeting(.start), confidence: 0.97) }
        if stop.contains(text) { return .init(title: "End meeting and write notes", subtitle: "Meetings", icon: .symbol("stop.circle.fill", tint: .red), action: .meeting(.stop), confidence: 0.97) }
        return nil
    }

    private static func murmur(_ text: String) -> CommandSuggestion? {
        let table: [(phrases: [String], title: String, symbol: String, target: String)] = [
            (["murmur settings", "open murmur settings", "settings for murmur"], "Murmur Settings", "gearshape.fill", "settings"),
            (["my library", "library", "my transcripts", "transcripts", "dictations", "my dictations"], "Murmur Library", "tray.full.fill", "library"),
            (["my meetings", "meetings", "meeting notes list", "past meetings"], "Murmur Meetings", "person.2.fill", "meetings"),
        ]
        let target = strip(text, prefixes: openVerbs) ?? text
        guard let row = table.first(where: { $0.phrases.contains(target) || $0.phrases.contains(text) }) else { return nil }
        return .init(title: row.title, subtitle: "Murmur", icon: .symbol(row.symbol, tint: .neutral), action: .murmur(row.target), confidence: 0.9)
    }

    private static func shortcut(_ text: String, context: CommandContext) -> CommandSuggestion? {
        guard let match = capture(text, "^(?:run|do|start|trigger) (?:the |my )?(?:shortcut )?(.+?)(?: shortcut)?$") ?? capture(text, "^shortcut (.+)$") else { return nil }
        let name = match[1]
        let saidShortcut = text.contains("shortcut")
        let found = context.shortcuts.map { ($0, appScore(name, $0)) }.max { $0.1 < $1.1 }
        if let found, found.1 >= 0.72 {
            return .init(title: "Run “\(found.0)”", subtitle: "Shortcut", icon: .symbol("square.2.layers.3d.fill", tint: .purple), action: .shortcut(found.0), confidence: 0.94)
        }
        guard saidShortcut else { return nil }
        return .init(title: "Run “\(name.capitalizedFirst)”", subtitle: "Shortcut", icon: .symbol("square.2.layers.3d.fill", tint: .purple), action: .shortcut(name), confidence: 0.8)
    }

    private static func play(_ text: String, context: CommandContext) -> CommandSuggestion? {
        guard var query = strip(text, prefixes: ["play me", "play", "put on", "throw on", "bump", "spin", "listen to", "i want to listen to", "queue up", "blast", "watch", "stream"]) else { return nil }
        let isWatch = text.hasPrefix("watch") || text.hasPrefix("stream")
        var service = isWatch ? MusicService.youtube : context.music
        let services: [(String, MusicService)] = [("on youtube music", .youtubeMusic), ("on apple music", .appleMusic), ("in apple music", .appleMusic),
                                                  ("on music", .appleMusic), ("on spotify", .spotify), ("in spotify", .spotify), ("from spotify", .spotify),
                                                  ("on youtube", .youtube), ("from youtube", .youtube), ("on yt", .youtube)]
        var saidService = false
        for (suffix, value) in services where query.hasSuffix(" " + suffix) || query == suffix {
            query = String(query.dropLast(min(query.count, suffix.count + 1))).trimmingCharacters(in: .whitespaces); service = value; saidService = true; break
        }
        // "play spotify" is opening the app, not a song called Spotify.
        if !saidService, ["spotify", "music", "apple music", "youtube", "youtube music", "some music", "music please"].contains(query) { return nil }
        if ["this", "that", "it", "this song", "this video", "that song"].contains(query) {
            guard let selection = context.selection?.nilIfBlank else { return nil }
            if let url = webURL(selection) {
                return .init(title: "Play \(url.host ?? "link")", subtitle: "Selected link", icon: .symbol("play.fill", tint: .red), action: .openURL(url), confidence: 0.96)
            }
            query = String(selection.prefix(120))
        }
        query = query.replacingOccurrences(of: "^(some|a little|the song|the video|the album|the playlist|songs by|music by) ", with: "", options: .regularExpression)
        guard !query.isEmpty else { return nil }
        let tint: CommandSuggestion.Icon.Tint = service == .spotify ? .green : service == .appleMusic ? .pink : .red
        return .init(title: "Play “\(query)”", subtitle: service.rawValue, icon: .symbol("play.fill", tint: tint), action: .play(query, on: service), confidence: 0.93)
    }

    private static func ask(_ text: String) -> CommandSuggestion? {
        let services: [(names: [String], name: String, url: String)] = [
            (["chatgpt", "chat gpt", "gpt", "chat"], "ChatGPT", "https://chatgpt.com/?q="),
            (["claude"], "Claude", "https://claude.ai/new?q="),
            (["perplexity"], "Perplexity", "https://www.perplexity.ai/search?q="),
            (["gemini", "google gemini"], "Gemini", "https://gemini.google.com/app?q="),
        ]
        for service in services {
            for name in service.names {
                if let match = capture(text, "^(?:ask|tell|hey) \(NSRegularExpression.escapedPattern(for: name))(?: to| about| for)? (.+)$")
                    ?? capture(text, "^\(NSRegularExpression.escapedPattern(for: name)),? (.+)$") {
                    let question = match[1]
                    return .init(title: "Ask \(service.name): “\(question.prefix(60))”", subtitle: service.name, icon: .symbol("bubble.left.and.text.bubble.right.fill", tint: .purple),
                                 action: .openURL(URL(string: service.url + encode(question))!), confidence: 0.95)
                }
            }
        }
        return nil
    }

    private static func search(_ text: String) -> CommandSuggestion? {
        // "search youtube for lofi", "search for flights on google", "google best ramen", "look up X on wikipedia", "youtube cat videos"
        var engine: String?, query: String?
        if let match = capture(text, "^(?:search|look up|find|look for) (?:on )?([a-z0-9. ]+?) for (.+)$"), Sites.searchable(match[1]) != nil {
            engine = match[1]; query = match[2]
        } else if let match = capture(text, "^(?:search|look up|find|look for|search for) (.+?) (?:on|in|at) ([a-z0-9. ]+)$"), Sites.searchable(match[2]) != nil {
            engine = match[2]; query = match[1]
        } else if let match = capture(text, "^(google|youtube|bing|amazon|wikipedia|reddit|github|twitter|x|linkedin|tiktok|duckduckgo|maps|google maps) (?:for )?(.+)$") {
            engine = match[1]; query = match[2]
        } else if capture(text, "^(?:what|whats|what's|who|whos|who's|when|where|wheres|why|how|is|are|does|do|can|which|define|weather)\\b") != nil, !text.hasPrefix("do ") {
            engine = "google"; query = text
        } else if let match = capture(text, "^(?:search for|search|look up|google) ?(.*)$") {
            engine = "google"
            query = match[1]
        }
        guard let engine, var query, !query.isEmpty, let site = Sites.searchable(engine) else { return nil }
        query = query.replacingOccurrences(of: "^for ", with: "", options: .regularExpression)
        return .init(title: "Search \(site.name) for “\(query.prefix(60))”", subtitle: site.name, icon: .symbol("magnifyingglass", tint: .blue),
                     action: .openURL(searchURL(engine, query)), confidence: 0.9)
    }

    private static func quitOrHide(_ text: String, context: CommandContext) -> CommandSuggestion? {
        if let name = strip(text, prefixes: ["quit", "close", "kill", "exit", "force quit", "shut down", "close out of", "get rid of"]) {
            let target = dropArticles(name)
            let app = matchApp(target, in: context)
            let display = app.map { $0.score >= 0.7 ? $0.app.name : target.capitalizedFirst } ?? target.capitalizedFirst
            return .init(title: "Quit \(display)", subtitle: "Application", icon: app.map { .app($0.app.path) } ?? .symbol("xmark.circle.fill", tint: .neutral),
                         action: .quitApp(display), confidence: app.map { $0.score >= 0.7 ? 0.94 : 0.7 } ?? 0.65)
        }
        if let name = strip(text, prefixes: ["hide", "minimize"]) {
            let target = dropArticles(name)
            let app = matchApp(target, in: context)
            let display = app.map { $0.score >= 0.7 ? $0.app.name : target.capitalizedFirst } ?? target.capitalizedFirst
            return .init(title: "Hide \(display)", subtitle: "Application", icon: app.map { .app($0.app.path) } ?? .symbol("eye.slash", tint: .neutral),
                         action: .hideApp(display), confidence: 0.9)
        }
        return nil
    }

    private static func create(_ text: String) -> CommandSuggestion? {
        let table: [(phrases: [String], title: String, url: String, symbol: String)] = [
            (["new doc", "new google doc", "new document", "create a doc", "create a google doc", "start a doc"], "New Google Doc", "https://docs.new", "doc.text.fill"),
            (["new sheet", "new spreadsheet", "new google sheet", "create a spreadsheet"], "New Google Sheet", "https://sheets.new", "tablecells.fill"),
            (["new slides", "new presentation", "new deck", "new slide deck", "create a presentation"], "New Google Slides", "https://slides.new", "rectangle.on.rectangle"),
            (["new meeting", "new google meet", "start a google meet", "new meet", "create a meeting link"], "New Google Meet", "https://meet.new", "video.fill"),
            (["new event", "new calendar event", "create an event", "add an event"], "New calendar event", "https://calendar.google.com/calendar/r/eventedit", "calendar.badge.plus"),
            (["new email", "new mail", "compose email", "write an email", "compose an email"], "New email", "mailto:", "envelope.fill"),
            (["new repo", "new repository", "create a repo"], "New GitHub repository", "https://github.com/new", "plus.square.on.square"),
            (["new figma file", "new figma"], "New Figma file", "https://figma.new", "paintbrush.pointed.fill"),
            (["new notion page", "new note in notion", "new notion"], "New Notion page", "https://notion.new", "square.and.pencil"),
        ]
        if let row = table.first(where: { $0.phrases.contains(text) }) {
            return .init(title: row.title, subtitle: URL(string: row.url)?.host ?? "Mail", icon: .symbol(row.symbol, tint: .blue), action: .openURL(URL(string: row.url)!), confidence: 0.95)
        }
        if let match = capture(text, "^(?:email|send an email to|write an email to|mail) ([^ ]+@[^ ]+)(?: (?:about|saying|that) (.+))?$") {
            var url = "mailto:\(match[1])"
            if !match[2].isEmpty { url += "?subject=" + encode(match[2].capitalizedFirst) }
            return .init(title: "Email \(match[1])", subtitle: match[2].isEmpty ? "Mail" : match[2].capitalizedFirst, icon: .symbol("envelope.fill", tint: .blue),
                         action: .openURL(URL(string: url)!), confidence: 0.93)
        }
        return nil
    }

    private static func directions(_ text: String) -> CommandSuggestion? {
        guard let match = capture(text, "^(?:directions to|navigate to|take me to|how do i get to|route to|get directions to) (.+)$") else { return nil }
        // "take me to youtube" is a website, not a drive.
        if Sites.find(match[1])?.exact == true || webURL(match[1]) != nil { return nil }
        return .init(title: "Directions to \(match[1].capitalizedFirst)", subtitle: "Maps", icon: .symbol("map.fill", tint: .green),
                     action: .openURL(URL(string: "maps://?daddr=" + encode(match[1]))!), confidence: 0.85)
    }

    private static func translate(_ text: String) -> CommandSuggestion? {
        guard let match = capture(text, "^translate (.+?)(?: (?:to|into) ([a-z]+))?$") else { return nil }
        let languages = ["spanish": "es", "french": "fr", "german": "de", "chinese": "zh-CN", "japanese": "ja", "korean": "ko", "italian": "it",
                         "portuguese": "pt", "arabic": "ar", "hindi": "hi", "burmese": "my", "russian": "ru", "english": "en", "thai": "th", "vietnamese": "vi"]
        let target = languages[match[2]] ?? "en"
        return .init(title: "Translate “\(match[1].prefix(50))”", subtitle: "Google Translate" + (match[2].isEmpty ? "" : " → \(match[2].capitalizedFirst)"),
                     icon: .symbol("character.bubble.fill", tint: .blue),
                     action: .openURL(URL(string: "https://translate.google.com/?sl=auto&tl=\(target)&text=" + encode(match[1]))!), confidence: 0.92)
    }

    // MARK: Typing into apps

    /// "open claude and write fix the login bug", "tell T3 Code to run the tests",
    /// "in slack type on my way", "type see you at 5". Case and punctuation of the
    /// words to type are preserved; politeness before the command is dropped.
    static func typing(_ input: String, context: CommandContext) -> CommandSuggestion? {
        var raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        raw = raw.replacingOccurrences(of: "^(?i:(?:hey |ok |okay )?murmur,? |(?:can|could|would) you (?:please )?|please )+", with: "", options: .regularExpression)
        let verb = "(?:type|write|paste|dictate|send)(?: (?:that|this|the following|out))?[:,]?"
        func app(_ name: String) -> AppEntry? {
            guard let found = matchApp(name.lowercased(), in: context), found.score >= 0.8 else { return nil }
            return found.app
        }
        var target: (words: String, app: AppEntry?)?
        if let match = capture(raw, "^(?i:(?:open|go to|switch to|pull up) (.+?) and " + verb + ") (.+)$"), let found = app(match[1]) {
            target = (match[2], found)
        } else if let match = capture(raw, "^(?i:(?:tell|message|reply to)) (.+)$") {
            // "tell T3 Code to run the tests": the longest app name wins.
            let words = match[1].split(separator: " ").map(String.init)
            for count in stride(from: min(4, words.count - 1), through: 1, by: -1) {
                guard let found = app(words.prefix(count).joined(separator: " ")) else { continue }
                var rest = words.dropFirst(count).joined(separator: " ")
                rest = rest.replacingOccurrences(of: "^(?i:to|that)\\b[:,]? ?|^[:,] ?", with: "", options: .regularExpression)
                if !rest.isEmpty { target = (rest, found) }
                break
            }
        } else if let match = capture(raw, "^(?i:(?:in|on|into) (.+?),? " + verb + ") (.+)$"), let found = app(match[1]) {
            target = (match[2], found)
        } else if let match = capture(raw, "^(?i:" + verb + ") (.+) (?i:in|into|on) (.+?)$"), let found = app(match[2]) {
            target = (match[1], found)
        } else if let match = capture(raw, "^(?i:" + verb + ") (.+)$") {
            target = (match[1], nil)
        }
        guard let (initialWords, app) = target else { return nil }; var words = initialWords
        words = words.trimmingCharacters(in: .whitespaces)
        if (words.hasPrefix("\"") && words.hasSuffix("\"")) || (words.hasPrefix("“") && words.hasSuffix("”")) { words = String(words.dropFirst().dropLast()) }
        guard !words.isEmpty else { return nil }
        let preview = words.count > 48 ? words.prefix(48) + "…" : Substring(words)
        return .init(title: app.map { "Type in \($0.name): “\(preview)”" } ?? "Type “\(preview)”",
                     subtitle: app == nil ? "Into the text box you were in · won’t send" : "Into its message box · won’t send",
                     icon: app.map { .app($0.path) } ?? .symbol("character.cursor.ibeam", tint: .neutral),
                     action: .type(words, in: app), confidence: app == nil ? 0.9 : 0.96)
    }

    /// Commands that are safe to run straight from the live transcript, before
    /// the final speech pass: their meaning doesn't depend on exact spelling.
    /// Sure enough to run without asking the local model. A one-target
    /// command ("Open Safari") can't account for a long or several-part
    /// request; that's a partial match, not an answer.
    static func isSure(_ suggestion: CommandSuggestion, for input: String) -> Bool {
        guard suggestion.confidence >= 0.9 else { return false }
        var said = normalize(input)
        var inner = suggestion.action
        if case .inBrowser(let wrapped, _) = inner {
            inner = wrapped
            // The browser part ("open safari, …", "… in chrome") is already accounted for.
            for name in browserNames where said.contains(name) {
                let escaped = NSRegularExpression.escapedPattern(for: name)
                said = said.replacingOccurrences(of: "^(?:open|launch|go to|use|pull up) (?:the )?\(escaped)(?: browser)?(?:,? (?:and|then|and then)|,|(?= (?:open|go to|search|look up|find|play|pull up) )) ", with: "", options: .regularExpression)
                    .replacingOccurrences(of: ",? (?:on|in|using|with|via|through) (?:the )?\(escaped)(?: browser)?", with: "", options: .regularExpression)
            }
        }
        // Several parts ("play kendrick and turn it up") need every part accounted for,
        // counted after merging ("open amazon and search X" is one search on Amazon).
        let merged = rephrase(said)
        let parts = splitSequence(merged).count
        if parts > 1 {
            if case .sequence(let steps) = inner { return steps.count == parts }
            return false
        }
        if case .openURL(let url) = inner, url.query?.contains("=") == true {
            // A search uses up the rest of what you said.
            return !merged.contains(" then ")
        }
        switch inner {
        case .openApp, .quitApp, .hideApp, .openPath, .openURL, .openSite, .findFile, .media, .volume, .system, .timer, .meeting, .murmur, .shortcut:
            let several = merged.contains(", ") || merged.contains(" and ") || merged.contains(" then ")
            return !several && merged.split(separator: " ").count <= 6
        default:
            return true
        }
    }

    /// Spoken requests the rules answer on their own: short, exact commands
    /// ("open slack", "next song", "volume 30", "timer 10 minutes"). Anything
    /// longer is read by the local model, which understands plain language.
    static func isTrivial(_ suggestion: CommandSuggestion, for input: String) -> Bool {
        guard isSure(suggestion, for: input) else { return false }
        switch suggestion.action {
        case .media, .volume, .system, .timer, .meeting: return true
        default:
            // Several parts the rules fully understood ("open amazon and search soccer balls",
            // "open murmur in cursor and open slack") are exact; so are short commands.
            let said = normalize(input)
            return said.split(separator: " ").count <= 4 || splitSequence(said).count > 1 || said.contains(", ") || said.contains(" and ")
        }
    }

    static func isInstant(_ action: CommandAction) -> Bool {
        switch action {
        case .openApp, .quitApp, .hideApp, .openPath, .media, .volume, .timer, .system, .meeting, .murmur, .openSite: return true
        case .openURL(let url): return !(url.query ?? "").contains("=")  // a site, not a search
        case .sequence(let steps): return steps.allSatisfy(isInstant)
        case .inBrowser(let inner, _): return isInstant(inner)
        default: return false
        }
    }

    // MARK: Fallbacks

    private static func fallbacks(_ text: String, context: CommandContext, hasStrong: Bool) -> [CommandSuggestion] {
        let query = strip(text, prefixes: openVerbs) ?? text
        var results: [CommandSuggestion] = [
            .init(title: "Search Google for “\(query.prefix(60))”", subtitle: "Google", icon: .symbol("magnifyingglass", tint: .blue),
                  action: .openURL(searchURL("google", query)), confidence: hasStrong ? 0.2 : 0.4),
            .init(title: "Ask ChatGPT: “\(query.prefix(60))”", subtitle: "ChatGPT", icon: .symbol("bubble.left.and.text.bubble.right.fill", tint: .purple),
                  action: .openURL(URL(string: "https://chatgpt.com/?q=" + encode(text))!), confidence: hasStrong ? 0.18 : 0.38),
        ]
        if !hasStrong, query.split(separator: " ").count <= 8 {
            results.append(.init(title: "Play “\(query.prefix(60))”", subtitle: context.music.rawValue, icon: .symbol("play.fill", tint: .red),
                                 action: .play(query, on: context.music), confidence: 0.3))
        }
        return results
    }

    // MARK: Helpers

    static func capture(_ text: String, _ pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (0..<match.numberOfRanges).map { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
        }
    }

    static func encode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=?#"))) ?? text
    }

    /// "github.com/lhz56", "https://…", "recallr.app" → a web address.
    static func webURL(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(" "), trimmed.count >= 4 else { return nil }
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") { return URL(string: trimmed) }
        let tlds = ["com", "org", "net", "io", "ai", "app", "dev", "co", "edu", "gov", "so", "xyz", "me", "us", "tv", "gg", "fm", "ly", "sh", "to", "new"]
        let host = trimmed.split(separator: "/").first.map(String.init) ?? trimmed
        guard let tld = host.split(separator: ".").last.map(String.init), host.contains("."), tlds.contains(tld.lowercased()) else { return nil }
        return URL(string: "https://" + trimmed)
    }

    static func searchURL(_ engine: String, _ query: String) -> URL {
        let site = Sites.searchable(engine) ?? Sites.searchable("google")!
        return URL(string: site.search! + encode(query))!
    }
}

/// Websites people open by name, and how to search them.
enum Sites {
    struct Site { let name: String; let home: URL; let search: String?; let names: [String] }

    static let all: [Site] = [
        site("YouTube", "https://www.youtube.com", "https://www.youtube.com/results?search_query=", ["youtube", "yt", "you tube"]),
        site("Google", "https://www.google.com", "https://www.google.com/search?q=", ["google", "google search"]),
        site("Gmail", "https://mail.google.com", "https://mail.google.com/mail/u/0/#search/", ["gmail", "my email", "email", "my inbox", "inbox", "google mail"]),
        site("Google Calendar", "https://calendar.google.com", nil, ["google calendar", "my calendar"]),
        site("Google Drive", "https://drive.google.com", "https://drive.google.com/drive/search?q=", ["google drive", "drive", "my drive"]),
        site("Google Docs", "https://docs.google.com", nil, ["google docs", "docs"]),
        site("Google Sheets", "https://sheets.google.com", nil, ["google sheets", "sheets"]),
        site("Google Maps", "https://maps.google.com", "https://www.google.com/maps/search/", ["google maps", "maps"]),
        site("GitHub", "https://github.com", "https://github.com/search?q=", ["github", "git hub", "my github"]),
        site("X", "https://x.com", "https://x.com/search?q=", ["twitter", "x", "x.com"]),
        site("Reddit", "https://www.reddit.com", "https://www.reddit.com/search/?q=", ["reddit"]),
        site("LinkedIn", "https://www.linkedin.com", "https://www.linkedin.com/search/results/all/?keywords=", ["linkedin", "linked in"]),
        site("Instagram", "https://www.instagram.com", nil, ["instagram", "insta", "ig"]),
        site("TikTok", "https://www.tiktok.com", "https://www.tiktok.com/search?q=", ["tiktok", "tik tok"]),
        site("Netflix", "https://www.netflix.com", "https://www.netflix.com/search?q=", ["netflix"]),
        site("Amazon", "https://www.amazon.com", "https://www.amazon.com/s?k=", ["amazon"]),
        site("ChatGPT", "https://chatgpt.com", "https://chatgpt.com/?q=", ["chatgpt", "chat gpt"]),
        site("Claude", "https://claude.ai", "https://claude.ai/new?q=", ["claude", "claude.ai"]),
        site("Perplexity", "https://www.perplexity.ai", "https://www.perplexity.ai/search?q=", ["perplexity"]),
        site("Wikipedia", "https://en.wikipedia.org", "https://en.wikipedia.org/wiki/Special:Search?search=", ["wikipedia", "wiki"]),
        site("Notion", "https://www.notion.so", nil, ["notion"]),
        site("Figma", "https://www.figma.com/files", nil, ["figma"]),
        site("Linear", "https://linear.app", nil, ["linear"]),
        site("Vercel", "https://vercel.com/dashboard", nil, ["vercel"]),
        site("Supabase", "https://supabase.com/dashboard", nil, ["supabase"]),
        site("Hacker News", "https://news.ycombinator.com", "https://hn.algolia.com/?q=", ["hacker news", "hn", "hackernews"]),
        site("Product Hunt", "https://www.producthunt.com", nil, ["product hunt"]),
        site("Y Combinator", "https://www.ycombinator.com", nil, ["y combinator", "yc", "ycombinator"]),
        site("App Store Connect", "https://appstoreconnect.apple.com", nil, ["app store connect", "testflight", "test flight"]),
        site("Stack Overflow", "https://stackoverflow.com", "https://stackoverflow.com/search?q=", ["stack overflow", "stackoverflow"]),
        site("Spotify", "https://open.spotify.com", "https://open.spotify.com/search/", ["spotify web", "spotify"]),
        site("YouTube Music", "https://music.youtube.com", "https://music.youtube.com/search?q=", ["youtube music"]),
        site("Slack", "https://app.slack.com", nil, ["slack"]),
        site("Discord", "https://discord.com/app", nil, ["discord"]),
        site("Zoom", "https://zoom.us/join", nil, ["zoom"]),
        site("Microsoft Teams", "https://teams.microsoft.com", nil, ["teams", "microsoft teams"]),
        site("WhatsApp", "https://web.whatsapp.com", nil, ["whatsapp", "whats app"]),
        site("Outlook", "https://outlook.office.com/mail", nil, ["outlook", "hotmail"]),
        site("Google Meet", "https://meet.google.com", nil, ["google meet", "meet"]),
        site("Twitch", "https://www.twitch.tv", "https://www.twitch.tv/search?term=", ["twitch"]),
        site("Pinterest", "https://www.pinterest.com", "https://www.pinterest.com/search/pins/?q=", ["pinterest"]),
        site("Bing", "https://www.bing.com", "https://www.bing.com/search?q=", ["bing"]),
        site("DuckDuckGo", "https://duckduckgo.com", "https://duckduckgo.com/?q=", ["duckduckgo", "duck duck go"]),
        site("Weather", "https://www.google.com/search?q=weather", nil, ["weather", "the weather"]),
        site("npm", "https://www.npmjs.com", "https://www.npmjs.com/search?q=", ["npm"]),
        site("Canvas", "https://canvas.instructure.com", nil, ["canvas"]),
        site("Hugging Face", "https://huggingface.co", "https://huggingface.co/search/full-text?q=", ["hugging face", "huggingface"]),
    ]

    private static func site(_ name: String, _ home: String, _ search: String?, _ names: [String]) -> Site {
        Site(name: name, home: URL(string: home)!, search: search, names: names)
    }

    static func find(_ text: String) -> (site: Site, exact: Bool)? {
        let query = text.lowercased()
        if let site = all.first(where: { $0.names.contains(query) }) { return (site, true) }
        guard query.count >= 4 else { return nil }
        return all.first { site in site.names.contains { CorrectionLearner.similarity($0.filter(\.isLetter), query.filter(\.isLetter)) >= 0.8 } }.map { ($0, false) }
    }

    static func searchable(_ name: String) -> Site? {
        let query = name.trimmingCharacters(in: .whitespaces).lowercased()
        return all.first { $0.search != nil && $0.names.contains(query) }
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
