import Foundation

/// Understands a spoken request in plain language with the local model,
/// using tool calling: the model picks tools ("play", "type_message",
/// "open_folder"…) and fills in named fields, and Murmur carries them out
/// directly. Tested on qwen3:1.7b: about half a second to a second.
enum CommandPlanner {
    /// One tool call from the model.
    struct Call: Equatable {
        var name: String
        var arguments: [String: String]
        init(_ name: String, _ arguments: [String: String] = [:]) { self.name = name; self.arguments = arguments }
        subscript(_ key: String) -> String? {
            guard let value = arguments[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty,
                  !["default", "none", "null", "n/a", "current"].contains(value.lowercased()) else { return nil }
            return value
        }
    }

    // MARK: Tools

    private static func tool(_ name: String, _ description: String, _ properties: [(String, String, String)], required: [String]) -> [String: Any] {
        var fields: [String: Any] = [:]
        for (key, type, about) in properties { fields[key] = ["type": type, "description": about] }
        return ["type": "function", "function": ["name": name, "description": description,
                                                 "parameters": ["type": "object", "properties": fields, "required": required]]]
    }

    private static let browserField = ("browser", "string", "browser the user named, e.g. safari or chrome; empty if none")

    static let tools: [[String: Any]] = [
        tool("play", "Play a song, artist, album, podcast or video.", [
            ("query", "string", "what to play, cleaned up: e.g. 'linger slowed' for 'the slow version of linger'"),
            ("service", "string", "youtube, spotify or apple music; empty = the user's default. Use youtube for videos, slowed/reverb/remix versions, or when the user says youtube"),
            browserField], required: ["query"]),
        tool("open_app", "Open or switch to an app on the Mac (Calendar, Mail, Notes, Reminders…).", [("app", "string", "app name")], required: ["app"]),
        tool("open_website", "Open a website.", [("site", "string", "site name or address, e.g. youtube, github.com"), browserField], required: ["site"]),
        tool("open_folder", "Open a folder or project, optionally in an app.", [
            ("folder", "string", "folder or project name"), ("app", "string", "app to open it in, e.g. cursor")], required: ["folder"]),
        tool("search", "Search the web or a site.", [
            ("query", "string", "what to search for"),
            ("site", "string", "google, youtube, amazon, reddit, github, maps, wikipedia; default google"), browserField], required: ["query"]),
        tool("ask_ai", "Ask an AI assistant website a question.", [
            ("question", "string", "the question"), ("assistant", "string", "chatgpt, claude, perplexity or gemini")], required: ["question"]),
        tool("type_message", "Write a message or instruction into an app's message box (never sends). For tell/message/text/write/reply.", [
            ("message", "string", "the exact message, in the user's words"), ("app", "string", "app to write in; empty = the current app")], required: ["message"]),
        tool("quit_app", "Quit an app.", [("app", "string", "app name")], required: ["app"]),
        tool("set_timer", "Set a timer or reminder.", [("minutes", "number", "minutes"), ("label", "string", "what it's for")], required: ["minutes"]),
        tool("set_volume", "Change the volume.", [("level", "number", "0-100 when a level is said; all the way up = 100, all the way down = 0"),
                                                  ("change", "string", "up, down, mute or unmute")], required: []),
        tool("browser_tab", "Close, open or reopen a browser tab.", [("command", "string", "close, new or reopen")], required: ["command"]),
        tool("translate", "Translate words into another language.", [("text", "string", "the words to translate"), ("language", "string", "language to translate into")], required: ["text", "language"]),
        tool("email", "Start a new email (never sends).", [("to", "string", "email address if said"), ("subject", "string", "subject"), ("body", "string", "what the email says")], required: ["body"]),
        tool("open_settings", "Open a page of System Settings.", [("page", "string", "bluetooth, wifi, sound, displays, battery, notifications, privacy, keyboard, wallpaper…")], required: ["page"]),
        tool("add_reminder", "Add a reminder to the Reminders app.", [
            ("title", "string", "the reminder, short, e.g. 'Apply to a16z Speedrun'"), ("notes", "string", "extra details, if any"),
            ("when", "string", "when to be reminded, in the user's words, e.g. 'tomorrow at 9am'; empty if not said")], required: ["title"]),
        tool("add_event", "Add an event to the calendar.", [
            ("title", "string", "what the event is"), ("when", "string", "when it starts, in the user's words"), ("minutes", "number", "how long, if said")], required: ["title", "when"]),
        tool("add_note", "Write a new note in the Notes app.", [("text", "string", "what the note says")], required: ["text"]),
        tool("facetime", "Phone or FaceTime someone.", [("person", "string", "who to call")], required: ["person"]),
        tool("media", "Control what's playing.", [("command", "string", "pause, resume, next or previous")], required: ["command"]),
        tool("system", "Mac controls.", [("command", "string", "lock, sleep, dark mode, light mode, screenshot, empty trash, show desktop")], required: ["command"]),
        tool("meeting_notes", "Start or stop taking meeting notes.", [("command", "string", "start or stop")], required: ["command"]),
    ]

    static func system(apps: [String], music: MusicService) -> String {
        """
        You are Murmur, a Mac assistant. The user speaks a request; speech recognition may mishear words (e.g. "and Safari" \
        for "on Safari"). Work out what they want and call the tools to do it, in order, one call per step. Don't open an app \
        or site separately when another call already does it: playing on YouTube opens YouTube, and naming a browser opens it. \
        The user's default music service is \(music.rawValue.lowercased()).
        Installed apps: \(apps.prefix(150).joined(separator: ", "))
        """
    }

    /// Worked examples, as earlier turns of the conversation: small models copy the pattern.
    static func examples(music: MusicService) -> [[String: Any]] {
        let service = music.rawValue.lowercased()
        func turn(_ request: String, _ calls: [(String, [String: String])]) -> [[String: Any]] {
            [["role": "user", "content": request],
             ["role": "assistant", "content": "", "tool_calls": calls.map { ["function": ["name": $0.0, "arguments": $0.1]] }]]
            + calls.map { _ in ["role": "tool", "content": "done"] }
        }
        return turn("open youtube on safari and play the slowed version of glimpse of us",
                    [("play", ["query": "glimpse of us slowed", "service": "youtube", "browser": "safari"])])
            + turn("get the atlas project up in vs code and throw on some jazz",
                   [("open_folder", ["folder": "atlas", "app": "VS Code"]), ("play", ["query": "jazz", "service": service])])
            + turn("open notion on chrome", [("open_website", ["site": "notion", "browser": "chrome"])])
            + turn("turn it all the way up", [("set_volume", ["level": "100"])])
            + turn("email my landlord that the sink is leaking", [("email", ["subject": "Sink leaking", "body": "Hi, the sink is leaking. Could you take a look?"])])
            + turn("tell cursor to add a dark mode toggle", [("type_message", ["message": "add a dark mode toggle", "app": "Cursor"])])
            + turn("it's way too quiet", [("set_volume", ["change": "up"])])
            + turn("skip this one", [("media", ["command": "next"])])
            + turn("how tall is mount everest", [("search", ["query": "how tall is mount everest", "site": "google"])])
            + turn("I wanna watch the new veritasium video", [("play", ["query": "veritasium new video", "service": "youtube"])])
            + turn("open spotify and turn it down a bit", [("open_app", ["app": "Spotify"]), ("set_volume", ["change": "down"])])
            + turn("close this tab", [("browser_tab", ["command": "close"])])
            + turn("open reminders and add one called dentist, remind me to book a cleaning friday",
                   [("open_app", ["app": "Reminders"]), ("add_reminder", ["title": "Dentist", "notes": "Book a cleaning", "when": "friday"])])
            + turn("put lunch with maya on my calendar tomorrow at 1", [("add_event", ["title": "Lunch with Maya", "when": "tomorrow at 1pm"])])
            + turn("make a note that the wifi password is sunflower", [("add_note", ["text": "The wifi password is sunflower"])])
            + turn("what's on my calendar today", [("open_app", ["app": "Calendar"])])
    }

    /// The model's tool calls for a request. Nil when there's no Ollama model or it took too long.
    static func calls(for request: String, apps: [String], music: MusicService, model: String, timeout: TimeInterval = 6) async -> [Call]? {
        let messages: [[String: Any]] = [["role": "system", "content": system(apps: apps, music: music)]]
            + examples(music: music) + [["role": "user", "content": request]]
        guard let raw = try? await LocalLLM.toolCalls(model: model, messages: messages, tools: tools, timeout: timeout) else { return nil }
        return raw.map { Call($0.name, $0.arguments.mapValues { value in
            if let number = value as? NSNumber { return number.stringValue }
            return "\(value)"
        }) }
    }

    // MARK: Carrying out

    static let services = ["youtube", "youtube music", "spotify", "apple music", "music", "yt"]

    /// One action for all the calls, with the steps that don't add anything
    /// removed (opening Safari when the next step plays in Safari). Nil when a
    /// step names something that isn't there.
    /// Each step happens where the one before it left you: "open amazon and
    /// search soccer balls" is a search on Amazon, "open slack and write hi"
    /// writes in Slack, "open spotify and play drake" plays on Spotify.
    static func carryOver(_ calls: [Call], request: String, context: CommandContext) -> [Call] {
        var result: [Call] = []
        let lowered = request.lowercased()
        let saidGoogle = lowered.contains("google")
        let words = Set(lowered.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        // Only a browser you actually named; small models like to add one.
        let saidBrowser = CommandParser.browserNames.contains { name in name.split(separator: " ").allSatisfy { words.contains(String($0)) } }
        let searching = ["search", "look", "find", "lookup", "searching"].contains { words.contains($0) }
        for var call in calls {
            if !saidBrowser { call.arguments["browser"] = nil }
            // "search for flights to tokyo" given as a website called "flights to tokyo": it's a search.
            if call.name == "open_website", searching, let site = call["site"], site.contains(" "),
               Sites.find(site.lowercased())?.exact != true, context.sites[SiteBook.key(site)] == nil, !site.contains(".") {
                call = Call("search", ["query": site, "browser": call.arguments["browser"] ?? ""])
            }
            // The same site twice in a row ("open github", then "github.com") is one step.
            if let previous = result.last, previous.name == call.name, ["open_website", "open_app"].contains(call.name),
               canonical(previous["site"] ?? previous["app"]) == canonical(call["site"] ?? call["app"]) { continue }
            if let previous = result.last, previous.name == "open_website" || previous.name == "open_app" {
                let place = canonical(previous["site"] ?? previous["app"]) ?? ""
                switch call.name {
                case "search":
                    // The site you just opened, unless you named another one.
                    let named = call["site"]?.lowercased()
                    if let site = Sites.searchable(place), site.search != nil,
                       named == nil || named == place || (named == "google" && !saidGoogle) || site.names.contains(named ?? "") {
                        call.arguments["site"] = place
                        if call["browser"] == nil, let browser = previous["browser"] { call.arguments["browser"] = browser }
                        result.removeLast()
                    }
                case "type_message":
                    // "open slack and write on my way": in Slack.
                    if call["app"] == nil, previous.name == "open_app", app(named: place, in: context) != nil {
                        call.arguments["app"] = previous["app"]
                        result.removeLast()
                    }
                case "ask_ai":
                    // "open chatgpt and ask it…": in the app you opened, or that assistant's site.
                    if previous.name == "open_app", app(named: place, in: context) != nil, let question = call["question"] {
                        call = Call("type_message", ["message": question, "app": previous["app"] ?? place])
                        result.removeLast()
                    } else if call["assistant"] == nil || ["chatgpt", "claude", "perplexity", "gemini"].contains(place) {
                        call.arguments["assistant"] = place
                        if previous.name == "open_website" { result.removeLast() }
                    }
                case "play":
                    if call["service"] == nil, let service = MusicService.named(place) { call.arguments["service"] = service.rawValue.lowercased() }
                default: break
                }
            }
            result.append(call)
        }
        return result
    }

    /// A site or app name in one form: "github.com", "GitHub" and "github" are all "github".
    static func canonical(_ name: String?) -> String? {
        guard let name = name?.lowercased().trimmingCharacters(in: .whitespaces), !name.isEmpty else { return nil }
        let host = name.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")
            .replacingOccurrences(of: "www.", with: "").split(separator: "/").first.map(String.init) ?? name
        if let site = Sites.find(host)?.site ?? Sites.all.first(where: { $0.home.host?.replacingOccurrences(of: "www.", with: "") == host }) {
            return site.names.first ?? site.name.lowercased()
        }
        return host.contains(".") ? SiteBook.label(of: host) : host
    }

    static func action(for calls: [Call], request: String, context: CommandContext) -> CommandSuggestion? {
        let calls = carryOver(calls, request: request, context: context)
        let browsers = browsers(in: context)
        func browser(_ value: String?) -> AppEntry? {
            guard let value = value?.lowercased() else { return nil }
            return browsers.first { name(of: $0) == value || $0.name.lowercased().contains(value) || value.contains(name(of: $0)) }
        }
        let webCalls: Set<String> = ["play", "open_website", "search", "ask_ai"]
        // A browser named anywhere in the request applies to every web step.
        let namedBrowser = calls.lazy.compactMap { browser($0["browser"]) ?? (($0.name == "open_app") ? browser($0["app"]) : nil) }.first
        let hasWeb = calls.contains { webCalls.contains($0.name) && !($0.name == "open_website" && services.contains($0["site"]?.lowercased() ?? "")) }
            || calls.contains { $0.name == "play" }
        let plays = calls.filter { $0.name == "play" }.map { service($0["service"], browser: namedBrowser, default: context.music) }

        var steps: [CommandSuggestion] = []
        for call in calls {
            let target = (call["app"] ?? call["site"])?.lowercased() ?? ""
            // Opening the browser or the player is already part of a later step.
            if call.name == "open_app" || call.name == "open_website" {
                if hasWeb, browser(target) != nil { continue }
                if let service = MusicService.named(target), plays.contains(service) { continue }
                if services.contains(target), !plays.isEmpty { continue }
            }
            guard let step = suggestion(for: call, browser: namedBrowser, request: request, context: context) else { return nil }
            if steps.contains(where: { $0.action == step.action }) { continue }
            steps.append(step)
        }
        // Opening a browser is part of any step that opens a page in it.
        let usedBrowsers = steps.compactMap { step -> AppEntry? in if case .inBrowser(_, let app) = step.action { return app }; return nil }
        steps.removeAll { step in if case .openApp(let app) = step.action { return usedBrowsers.contains(app) }; return false }
        guard !steps.isEmpty else { return nil }
        if steps.count == 1 { return steps[0] }
        return CommandSuggestion(title: steps.map(\.title).joined(separator: ", then "), subtitle: "\(steps.count) steps",
                                 icon: steps[0].icon, action: .sequence(steps.map(\.action)), confidence: 0.92)
    }

    static func browsers(in context: CommandContext) -> [AppEntry] {
        context.apps.filter { CommandParser.browserNames.contains(name(of: $0)) || $0.name.lowercased().contains("chrome") }
    }

    static func isBrowser(_ name: String, context: CommandContext) -> Bool {
        let wanted = name.lowercased()
        return CommandParser.browserNames.contains(wanted) || browsers(in: context).contains { Self.name(of: $0) == wanted || $0.name.lowercased() == wanted }
    }

    private static func name(of app: AppEntry) -> String {
        app.name.lowercased().replacingOccurrences(of: " browser", with: "")
    }

    private static func service(_ value: String?, browser: AppEntry?, default fallback: MusicService) -> MusicService {
        if let named = MusicService.named(value?.lowercased() ?? "") { return named }
        // A browser means a video page, not the Spotify app.
        return browser != nil ? .youtube : fallback
    }

    static func suggestion(for call: Call, browser: AppEntry?, request: String, context: CommandContext) -> CommandSuggestion? {
        func web(_ suggestion: CommandSuggestion) -> CommandSuggestion {
            guard let browser else { return suggestion }
            return CommandSuggestion(title: suggestion.title + " in \(browser.name)", subtitle: suggestion.subtitle, icon: suggestion.icon,
                                     action: .inBrowser(suggestion.action, browser), confidence: suggestion.confidence)
        }
        switch call.name {
        case "play":
            guard let query = call["query"], grounded(query, in: request) else { return nil }
            var service = service(call["service"], browser: browser, default: context.music)
            if browser != nil, service == .spotify || service == .appleMusic { service = .youtube }
            let tint: CommandSuggestion.Icon.Tint = service == .spotify ? .green : service == .appleMusic ? .pink : .red
            let play = CommandSuggestion(title: "Play “\(query)” on \(service.rawValue)", subtitle: service.rawValue,
                                         icon: .symbol("play.fill", tint: tint), action: .play(query, on: service), confidence: 0.92)
            return service == .youtube || service == .youtubeMusic ? web(play) : play
        case "open_app":
            guard let name = call["app"] else { return nil }
            // "open workloom on safari": with a browser named, it's the website, not the app.
            if browser != nil, !isBrowser(name, context: context) { return website(name, context: context).map(web) }
            if let app = app(named: name, in: context) {
                return CommandSuggestion(title: "Open \(app.name)", subtitle: "Application", icon: .app(app.path), action: .openApp(app), confidence: 0.92)
            }
            return website(name, context: context).map(web)
        case "open_website":
            guard let site = call["site"] else { return nil }
            return website(site, context: context).map(web)
        case "open_folder":
            guard let folder = call["folder"] else { return nil }
            // A folder "in Safari" is a website.
            if let name = call["app"], isBrowser(name, context: context) {
                let named = browsers(in: context).first { name.lowercased().contains(Self.name(of: $0)) || $0.name.lowercased().contains(name.lowercased()) }
                return website(folder, context: context).map { site in
                    guard let named else { return site }
                    return CommandSuggestion(title: site.title + " in \(named.name)", subtitle: site.subtitle, icon: site.icon,
                                             action: .inBrowser(site.action, named), confidence: site.confidence)
                }
            }
            var app: AppEntry?
            if let name = call["app"] { app = Self.app(named: name, in: context); if app == nil { return nil } }
            let wanted = folder.lowercased().replacingOccurrences(of: " project", with: "").replacingOccurrences(of: " folder", with: "")
            let home = NSHomeDirectory()
            let known = ["downloads": home + "/Downloads", "desktop": home + "/Desktop", "documents": home + "/Documents", "home": home]
            let path = context.folders.first { $0.key.lowercased() == wanted }?.value
                ?? known[wanted]
                ?? context.folders.first { $0.key.lowercased().hasPrefix(wanted) || wanted.hasPrefix($0.key.lowercased()) }?.value
            let place = app.map { " in \($0.name)" } ?? ""
            if let path {
                return CommandSuggestion(title: "Open \((path as NSString).lastPathComponent)\(place)", subtitle: (path as NSString).abbreviatingWithTildeInPath,
                                         icon: CommandSuggestion.Icon.app(app?.path ?? path), action: .openPath(path, in: app), confidence: 0.92)
            }
            return CommandSuggestion(title: "Find “\(folder)”\(place)", subtitle: "Spotlight", icon: .symbol("magnifyingglass", tint: .neutral),
                                     action: .findFile(folder, in: app), confidence: 0.8)
        case "search":
            guard var query = call["query"], grounded(query, in: request) else { return nil }
            let site = call["site"].flatMap { Sites.searchable($0.lowercased()) } ?? Sites.searchable("google")!
            // "recallr on github" searched on GitHub is "recallr".
            for name in [site.name.lowercased()] + site.names {
                for joiner in [" on ", " in "] where query.lowercased().hasSuffix(joiner + name) { query = String(query.dropLast(joiner.count + name.count)) }
            }
            guard let prefix = site.search, let url = URL(string: prefix + CommandParser.encode(query)) else { return nil }
            return web(CommandSuggestion(title: "Search \(site.name) for “\(query.prefix(60))”", subtitle: site.name,
                                         icon: .symbol("magnifyingglass", tint: .blue), action: .openURL(url), confidence: 0.92))
        case "ask_ai":
            guard let question = call["question"], grounded(question, in: request) else { return nil }
            let assistants = ["chatgpt": ("ChatGPT", "https://chatgpt.com/?q="), "claude": ("Claude", "https://claude.ai/new?q="),
                              "perplexity": ("Perplexity", "https://www.perplexity.ai/search?q="), "gemini": ("Gemini", "https://gemini.google.com/app?q=")]
            let wanted = call["assistant"]?.lowercased().replacingOccurrences(of: " ", with: "") ?? "chatgpt"
            // "tell claude to…" talks to the app you have, the way you'd type it there.
            if CommandParser.normalize(request).hasPrefix("tell "), let name = call["assistant"], app(named: name, in: context) != nil {
                return suggestion(for: Call("type_message", ["message": question, "app": name]), browser: browser, request: request, context: context)
            }
            guard let (label, prefix) = assistants[wanted] ?? (assistants.first { wanted.contains($0.key) }?.value) else {
                // "Ask T3 Code…" is an app you talk to: write it there.
                return suggestion(for: Call("type_message", ["message": question, "app": call["assistant"] ?? ""]), browser: browser, request: request, context: context)
            }
            return web(CommandSuggestion(title: "Ask \(label): “\(question.prefix(60))”", subtitle: label, icon: .symbol("bubble.left.and.text.bubble.right.fill", tint: .purple),
                                         action: .openURL(URL(string: prefix + CommandParser.encode(question))!), confidence: 0.92))
        case "type_message":
            guard let message = call["message"], grounded(message, in: request) else { return nil }
            // Typing into Reminders or Notes means adding one: do it directly, without clicking through the app.
            switch call["app"]?.lowercased() ?? "" {
            case "reminders": return suggestion(for: Call("add_reminder", ["title": message]), browser: browser, request: request, context: context)
            case "notes": return suggestion(for: Call("add_note", ["text": message]), browser: browser, request: request, context: context)
            default: break
            }
            var app: AppEntry?
            if let name = call["app"] { app = Self.app(named: name, in: context); if app == nil { return nil } }
            return CommandSuggestion(title: app.map { "Write in \($0.name): “\(message.prefix(50))”" } ?? "Type “\(message.prefix(50))”",
                                     subtitle: "Doesn’t press Send", icon: app.map { CommandSuggestion.Icon.app($0.path) } ?? .symbol("keyboard", tint: .neutral),
                                     action: .type(message, in: app), confidence: 0.92)
        case "quit_app":
            guard let name = call["app"], let app = app(named: name, in: context) else { return nil }
            // "close this tab" is never "quit the browser".
            if request.lowercased().contains("tab") { return suggestion(for: Call("browser_tab", ["command": "close"]), browser: browser, request: request, context: context) }
            return CommandSuggestion(title: "Quit \(app.name)", subtitle: "Application", icon: .app(app.path), action: .quitApp(app.name), confidence: 0.92)
        case "set_timer":
            // The length is read from your own words when they say it; models are bad at "an hour and a half".
            var fromModel: Int?
            if let minutes = call["minutes"].flatMap(Double.init), minutes.isFinite, minutes > 0, minutes <= 1_440 { fromModel = Int(minutes * 60) }
            guard let seconds = Self.seconds(in: request) ?? fromModel, seconds > 0, seconds <= 24 * 3600 else { return nil }
            let label = call["label"] ?? "Timer"
            let length = seconds % 60 == 0 ? "\(seconds / 60) minute\(seconds == 60 ? "" : "s")" : "\(seconds) seconds"
            return CommandSuggestion(title: "Timer for \(length)", subtitle: label, icon: .symbol("timer", tint: .orange),
                                     action: .timer(seconds: seconds, label: label), confidence: 0.92)
        case "set_volume":
            var level = call["level"].flatMap(Double.init).flatMap { (0...100).contains($0) ? Int($0) : nil }
            // An exact level only when you gave one ("volume 30", "all the way up"); "turn it up" is a step.
            let lowered = request.lowercased()
            let exact = lowered.contains(where: \.isNumber) || ["all the way", "max", "full", "zero", "percent", "halfway", "half"].contains { lowered.contains($0) }
            if !exact, let given = level {
                level = nil
                if call["change"] == nil { return suggestion(for: Call("set_volume", ["change": given >= 50 ? "up" : "down"]), browser: browser, request: request, context: context) }
            }
            let change: CommandAction.Volume
            switch call["change"]?.lowercased() ?? "" {
            case "up", "louder", "increase": change = .up
            case "down", "quieter", "lower", "decrease": change = .down
            case "mute": change = .mute
            case "unmute": change = .unmute
            default:
                guard let level else { return nil }
                change = .set(level)
            }
            let title: String
            switch change {
            case .up: title = "Volume up"
            case .down: title = "Volume down"
            case .mute: title = "Mute"
            case .unmute: title = "Unmute"
            case .set(let level): title = "Volume \(level)%"
            }
            return CommandSuggestion(title: title, subtitle: "Sound", icon: .symbol("speaker.wave.2.fill", tint: .neutral), action: .volume(change), confidence: 0.92)
        case "media":
            let command = call["command"]?.lowercased() ?? ""
            let media: CommandAction.Media = command.contains("next") || command.contains("skip") ? .next
                : command.contains("prev") || command.contains("back") ? .previous : .playPause
            let title = media == .next ? "Next track" : media == .previous ? "Previous track" : "Play / Pause"
            return CommandSuggestion(title: title, subtitle: "Whatever is playing", icon: .symbol("playpause.fill", tint: .pink), action: .media(media), confidence: 0.92)
        case "system":
            let command = call["command"]?.lowercased() ?? ""
            let options: [(String, CommandAction.System, String)] = [("lock", .lock, "Lock screen"), ("sleep", .sleep, "Sleep"), ("dark", .darkMode, "Dark mode"),
                                                                    ("light", .lightMode, "Light mode"), ("screenshot", .screenshot, "Screenshot"),
                                                                    ("trash", .emptyTrash, "Empty Trash"), ("desktop", .showDesktop, "Show desktop")]
            guard let (_, system, title) = options.first(where: { command.contains($0.0) }) else { return nil }
            return CommandSuggestion(title: title, subtitle: "System", icon: .symbol("gearshape.fill", tint: .neutral), action: .system(system), confidence: 0.92)
        case "meeting_notes":
            let command = call["command"]?.lowercased() ?? ""
            let stop = command.contains("stop") || command.contains("end")
            return CommandSuggestion(title: stop ? "Stop meeting notes" : "Take meeting notes", subtitle: "Meetings", icon: .symbol("person.2.wave.2.fill", tint: .blue),
                                     action: .meeting(stop ? .stop : .start), confidence: 0.92)
        case "browser_tab":
            let command = call["command"]?.lowercased() ?? ""
            let (system, title): (CommandAction.System, String) = command.contains("reopen") || command.contains("restore") ? (.reopenTab, "Reopen closed tab")
                : command.contains("new") || command.contains("open") ? (.newTab, "New tab")
                : (.closeTab, "Close tab")
            return CommandSuggestion(title: title, subtitle: "In the app in front", icon: .symbol("macwindow", tint: .neutral), action: .system(system), confidence: 0.92)
        case "translate":
            guard let text = call["text"], grounded(text, in: request) else { return nil }
            var language = call["language"] ?? "english"
            // The model sometimes gives a code ("es") instead of a name.
            if let name = languages.first(where: { $0.value.lowercased() == language.lowercased() })?.key { language = name }
            let code = languages[language.lowercased()] ?? "en"
            guard let url = URL(string: "https://translate.google.com/?sl=auto&tl=\(code)&op=translate&text=" + CommandParser.encode(text)) else { return nil }
            return web(CommandSuggestion(title: "Translate “\(text.prefix(40))” to \(language.capitalizedFirst)", subtitle: "Google Translate",
                                         icon: .symbol("character.bubble.fill", tint: .blue), action: .openURL(url), confidence: 0.92))
        case "email":
            let body = call["body"] ?? "", subject = call["subject"] ?? ""
            guard grounded(body + " " + subject, in: request) else { return nil }
            let to = call["to"].flatMap { $0.contains("@") ? $0.replacingOccurrences(of: " ", with: "") : nil } ?? ""
            guard let url = URL(string: "mailto:\(to)?subject=\(CommandParser.encode(subject))&body=\(CommandParser.encode(body))") else { return nil }
            return CommandSuggestion(title: "New email" + (subject.isEmpty ? "" : ": “\(subject.prefix(40))”"), subtitle: "Doesn’t send",
                                     icon: .symbol("envelope.fill", tint: .blue), action: .openURL(url), confidence: 0.92)
        case "open_settings":
            let page = call["page"]?.lowercased() ?? ""
            let match = settingsPages.first { page.contains($0.key) }
            let url = URL(string: "x-apple.systempreferences:" + (match?.value ?? ""))!
            return CommandSuggestion(title: match.map { "Open \($0.key.capitalizedFirst) settings" } ?? "Open System Settings", subtitle: "System Settings",
                                     icon: .symbol("gearshape.fill", tint: .neutral), action: .openURL(url), confidence: 0.92)
        case "add_reminder":
            var notes = call["notes"].flatMap { grounded($0, in: request) ? $0 : nil }
            // A made-up title with real details: the details are what you said.
            guard let title = call["title"].flatMap({ grounded($0, in: request) ? $0 : nil }) ?? notes.map({ found in defer { notes = nil }; return found }) else { return nil }
            if notes?.lowercased() == title.lowercased() { notes = nil }
            // "…named a16z Speedrun, remind me to apply to them": keep the part the title doesn't say.
            if notes == nil, let range = request.range(of: "remind me to ", options: .caseInsensitive) {
                var rest = String(request[range.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: " .!?"))
                if !rest.isEmpty, !title.lowercased().contains(rest.lowercased()), !rest.lowercased().contains(title.lowercased()) {
                    rest = rest.prefix(1).uppercased() + rest.dropFirst()
                    notes = rest
                }
            }
            // A due date only when you said one; a day without a time is all day.
            let said = when(in: request)
            let due = said.flatMap { said in when(in: call["when"])?.date ?? said.date }
            let timed = said?.timed ?? false
            let label = due.map { " · " + $0.formatted(timed ? .dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()
                                                         : .dateTime.weekday(.abbreviated).month(.abbreviated).day()) } ?? ""
            return CommandSuggestion(title: "Add reminder “\(title.prefix(50))”", subtitle: "Reminders" + label, icon: .symbol("checklist", tint: .orange),
                                     action: .addReminder(title, notes: notes, due: due.map { timed ? $0 : Calendar.current.startOfDay(for: $0) }), confidence: 0.92)
        case "add_event":
            guard let title = call["title"], grounded(title, in: request), let start = date(in: call["when"]) ?? date(in: request) else { return nil }
            let minutes = call["minutes"].flatMap(Double.init).flatMap { $0.isFinite && (5...1_440).contains($0) ? Int($0) : nil } ?? 60
            return CommandSuggestion(title: "Add “\(title.prefix(50))” to your calendar",
                                     subtitle: start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()),
                                     icon: .symbol("calendar.badge.plus", tint: .red), action: .addEvent(title, start: start, minutes: minutes), confidence: 0.92)
        case "add_note":
            guard let text = call["text"], grounded(text, in: request) else { return nil }
            return CommandSuggestion(title: "New note: “\(text.prefix(50))”", subtitle: "Notes", icon: .symbol("note.text", tint: .orange),
                                     action: .addNote(text), confidence: 0.92)
        case "facetime":
            // Murmur can't dial yet; FaceTime opens so you can pick the person.
            guard let facetime = app(named: "FaceTime", in: context) else { return nil }
            return CommandSuggestion(title: "Open FaceTime to call \(call["person"] ?? "them")", subtitle: "Murmur can’t place the call itself yet",
                                     icon: .app(facetime.path), action: .openApp(facetime), confidence: 0.9)
        default:
            return nil
        }
    }

    /// A length of time in plain words: "90 seconds", "twenty five minutes",
    /// "an hour and a half", "half an hour", "1.5 hours".
    static func seconds(in text: String) -> Int? {
        let words = text.lowercased().replacingOccurrences(of: "-", with: " ").split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "." }).map(String.init)
        let units: [String: Double] = ["second": 1, "seconds": 1, "sec": 1, "secs": 1, "minute": 60, "minutes": 60, "min": 60, "mins": 60,
                                       "hour": 3600, "hours": 3600, "hr": 3600, "hrs": 3600]
        let numbers: [String: Double] = ["one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
                                         "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16, "seventeen": 17,
                                         "eighteen": 18, "nineteen": 19, "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "ninety": 90]
        var total = 0.0, pending: Double?, lastUnit: Double?
        var index = 0
        while index < words.count {
            let word = words[index]
            let next = index + 1 < words.count ? words[index + 1] : ""
            if let unit = units[word] {
                if let amount = pending { total += amount * unit; lastUnit = unit }
                pending = nil
            } else if let value = Double(word) ?? numbers[word] {
                // "twenty five"
                if let current = pending, current >= 20, current.truncatingRemainder(dividingBy: 10) == 0, value < 10 { pending = current + value }
                else { pending = value }
            } else if word == "a" || word == "an" {
                if pending == nil { pending = 1 }
            } else if word == "half" {
                if units[next] != nil || ((next == "a" || next == "an") && index + 2 < words.count && units[words[index + 2]] != nil) {
                    pending = 0.5
                    if next == "a" || next == "an" { index += 1 }
                } else if let unit = lastUnit {
                    total += unit / 2; pending = nil   // "an hour and a half"
                }
            } else if word == "quarter" {
                pending = 0.25
                if next == "of" { index += 1 }
                if index + 1 < words.count, ["a", "an"].contains(words[index + 1]) { index += 1 }
            } else if word != "and" {
                pending = nil
            }
            index += 1
        }
        // Days at most; a huge number someone said isn't a timer.
        return total > 0 && total <= 7 * 86_400 ? Int(total.rounded()) : nil
    }

    /// How many of the things you named (apps, folders, sites, browsers,
    /// music services) a plan accounts for: "open murmur in cursor" names
    /// murmur and Cursor. Used to pick between the model's plan and the
    /// rules' when one of them dropped something.
    static func coverage(_ suggestion: CommandSuggestion, of request: String, context: CommandContext) -> Int {
        let said = " " + request.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "." }).joined(separator: " ") + " "
        var things = Set<String>()
        let names = context.apps.map { $0.name.lowercased().replacingOccurrences(of: "\\s*\\(.*\\)", with: "", options: .regularExpression) }
            + context.folders.keys.map { $0.lowercased() } + Sites.all.flatMap { [$0.name.lowercased()] + $0.names }
            + CommandParser.browserNames + services
        for name in names where name.count >= 3 && said.contains(" \(name) ") { things.insert(name) }
        // "google chrome" names Chrome once, not Google and Chrome.
        let distinct = things.filter { thing in !things.contains { $0 != thing && $0.contains(thing) } }
        var plan = (suggestion.title + " " + String(describing: suggestion.action)).lowercased()
        // Adding a reminder, event or note is using that app.
        if plan.contains("addreminder(") { plan += " reminders" }
        if plan.contains("addevent(") { plan += " calendar" }
        if plan.contains("addnote(") { plan += " notes" }
        return distinct.filter { plan.contains($0) }.count
    }

    /// A date and time in plain words ("tomorrow at 9", "next friday", "at 5pm"),
    /// read by Apple's date detector. A time that's already passed today means tomorrow.
    static func date(in text: String?) -> Date? { when(in: text)?.date }

    /// The date said, and whether a time of day was part of it ("friday" vs "friday at 9").
    static func when(in text: String?) -> (date: Date, timed: Bool)? {
        guard let text, !text.isEmpty, let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
              let match = detector.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let date = match.date,
              let range = Range(match.range, in: text) else { return nil }
        let phrase = text[range].lowercased()
        let timed = phrase.contains(where: \.isNumber) || ["am", "pm", "noon", "midnight", "morning", "evening", "night", "afternoon", "o'clock", "hour", "minute"]
            .contains { phrase.contains($0) }
        return (date, timed)
    }

    static let languages: [String: String] = [
        "english": "en", "spanish": "es", "french": "fr", "german": "de", "italian": "it", "portuguese": "pt", "japanese": "ja",
        "korean": "ko", "chinese": "zh-CN", "mandarin": "zh-CN", "cantonese": "zh-TW", "hindi": "hi", "arabic": "ar", "russian": "ru",
        "burmese": "my", "myanmar": "my", "thai": "th", "vietnamese": "vi", "indonesian": "id", "turkish": "tr", "dutch": "nl",
        "polish": "pl", "swedish": "sv", "greek": "el", "hebrew": "he", "tagalog": "tl", "filipino": "tl", "urdu": "ur", "bengali": "bn",
        "persian": "fa", "farsi": "fa", "ukrainian": "uk", "malay": "ms", "swahili": "sw", "punjabi": "pa", "tamil": "ta",
    ]

    static let settingsPages: [String: String] = [
        "bluetooth": "com.apple.BluetoothSettings", "wi-fi": "com.apple.wifi-settings-extension", "wifi": "com.apple.wifi-settings-extension",
        "network": "com.apple.Network-Settings.extension", "sound": "com.apple.Sound-Settings.extension", "display": "com.apple.Displays-Settings.extension",
        "battery": "com.apple.Battery-Settings.extension", "notification": "com.apple.Notifications-Settings.extension",
        "privacy": "com.apple.settings.PrivacySecurity.extension", "security": "com.apple.settings.PrivacySecurity.extension",
        "keyboard": "com.apple.Keyboard-Settings.extension", "trackpad": "com.apple.Trackpad-Settings.extension", "mouse": "com.apple.Mouse-Settings.extension",
        "wallpaper": "com.apple.Wallpaper-Settings.extension", "appearance": "com.apple.Appearance-Settings.extension",
        "accessibility": "com.apple.Accessibility-Settings.extension", "focus": "com.apple.Focus-Settings.extension",
        "dock": "com.apple.Desktop-Settings.extension", "desktop": "com.apple.Desktop-Settings.extension", "general": "com.apple.systempreferences.GeneralSettings",
        "software update": "com.apple.Software-Update-Settings.extension", "update": "com.apple.Software-Update-Settings.extension",
        "storage": "com.apple.settings.Storage", "users": "com.apple.Users-Groups-Settings.extension", "screen time": "com.apple.Screen-Time-Settings.extension",
        "login": "com.apple.LoginItems-Settings.extension", "printer": "com.apple.Print-Scan-Settings.extension",
    ]

    /// A website by name ("youtube", "workloom") or address ("recallr.app").
    static func website(_ text: String, context: CommandContext = CommandContext()) -> CommandSuggestion? {
        let lowered = text.lowercased().trimmingCharacters(in: .whitespaces)
        // An address you said ("github.com/lhz56") is opened exactly.
        let compact = lowered.replacingOccurrences(of: " ", with: "")
        if compact.contains("."), !compact.hasSuffix("."), compact.range(of: "^[a-z0-9-]+(\\.[a-z0-9-]+)+(/\\S*)?$", options: .regularExpression) != nil || compact.hasPrefix("http"),
           let url = URL(string: compact.hasPrefix("http") ? compact : "https://" + compact) {
            return CommandSuggestion(title: "Open \(compact.replacingOccurrences(of: "https://", with: ""))", subtitle: "Website", icon: .symbol("globe", tint: .blue), action: .openURL(url), confidence: 0.92)
        }
        guard compact.count > 1 else { return nil }
        let site = CommandParser.website(named: text, context: context)
        return CommandSuggestion(title: site.title, subtitle: "Website", icon: .symbol("globe", tint: .blue), action: site.action, confidence: 0.9)
    }

    /// An installed app by the name the model used ("T3 Code" finds "T3 Code (Beta)").
    static func app(named name: String, in context: CommandContext) -> AppEntry? {
        func plain(_ text: String) -> String {
            text.lowercased().replacingOccurrences(of: "\\(.*\\)", with: "", options: .regularExpression)
                .replacingOccurrences(of: ".app", with: "").trimmingCharacters(in: .whitespaces)
        }
        let wanted = plain(name)
        guard !wanted.isEmpty else { return nil }
        if let exact = context.apps.first(where: { plain($0.name) == wanted }) { return exact }
        if let close = context.apps.first(where: { plain($0.name).hasPrefix(wanted + " ") || wanted.hasPrefix(plain($0.name) + " ") }) { return close }
        if let suffix = context.apps.first(where: { plain($0.name).hasSuffix(" " + wanted) }) { return suffix }
        // Misheard names ("curser"): the same sound-alike matching typing uses.
        let scored = context.apps.map { ($0, CommandParser.appScore(wanted, $0.name)) }.max { $0.1 < $1.1 }
        return scored.flatMap { $0.1 >= 0.8 ? $0.0 : nil }
    }

    /// Words carried over from the request (a message, a search) must mostly be
    /// there: a small model can echo one of its examples instead of listening.
    static func grounded(_ words: String, in request: String) -> Bool {
        func tokens(_ text: String) -> [String] {
            text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count > 2 }
        }
        let heard = tokens(request)
        let carried = tokens(words)
        guard !carried.isEmpty else { return true }
        // Stems, so "slowed" matches "slow" and "recipe" matches "recipes".
        let found = carried.filter { word in heard.contains { $0.hasPrefix(word.prefix(4)) || word.hasPrefix($0.prefix(4)) } }.count
        return Double(found) / Double(carried.count) >= 0.5
    }
}

extension MusicService {
    /// "youtube", "spotify", "apple music"… as the model writes them.
    static func named(_ text: String) -> MusicService? {
        switch text.lowercased().trimmingCharacters(in: .whitespaces) {
        case "youtube music", "yt music": return .youtubeMusic
        case "youtube", "yt", "you tube": return .youtube
        case "spotify": return .spotify
        case "apple music", "music", "itunes": return .appleMusic
        default: return nil
        }
    }
}
