import Foundation

/// Space + Down Arrow in one breath: "open T3 Code, open the thread called launch
/// notes, and type ship it tonight". The on-Mac model reads the request and lists
/// the steps (`StepPlanner`); this turns them into one action and checks it against
/// your own words before anything runs. There are no word patterns here: the model
/// does the understanding, and the checks only make sure it didn't invent anything.
enum QuickPlan {
    typealias Call = CommandPlanner.Call

    // MARK: From the model's steps to one action

    /// The model's steps as one action, or nil when it said it can't, or a step
    /// doesn't make sense. The model sometimes puts a value in the wrong field
    /// ("browser" as "app"), so fields are read generously here and checked strictly
    /// in `trusted`.
    static func build(_ calls: [Call], request: String, context: CommandContext) -> CommandAction? {
        suggestion(calls, request: request, context: context)?.action
    }

    static func suggestion(_ calls: [Call], request: String, context: CommandContext) -> CommandSuggestion? {
        var steps: [Call] = []
        for raw in calls {
            var call = Call(raw.name, raw.arguments.compactMapValues(clean))
            func move(_ from: String, to: String) { if call[to] == nil, let value = call[from] { call.arguments[to] = value } }
            // A browser given as the app or the service.
            for field in call.arguments.keys.sorted() where field != "browser" && call["browser"] == nil && call.name != "open_app" {
                if let value = call[field], CommandPlanner.isBrowser(value, context: context) {
                    call.arguments["browser"] = value; call.arguments[field] = nil
                }
            }
            let values = Array(call.arguments.values)
            // Only the tools the model was given.
            guard StepPlanner.tools.contains(where: { $0.0 == call.name }) else { return nil }
            switch call.name {
            case "cant_do": return nil
            case "open_app":
                move("site", to: "app")
                // "open chrome" with a site after it: the site opens in Chrome.
                if let app = call["app"], CommandPlanner.isBrowser(app, context: context) { call.arguments["browser"] = app }
            case "open_website":
                move("app", to: "site")
                // "open youtube and search lofi" given as one step with the search in another field.
                let leftover = [call["query"], call["target"], call["text"]].compactMap { $0 }
                    .first { $0.lowercased() != call["site"]?.lowercased() && !CommandPlanner.isBrowser($0, context: context) && Sites.find($0.lowercased())?.exact != true }
                if let leftover, let site = call["site"], Sites.searchable(site.lowercased()) != nil,
                   !calls.contains(where: { $0.name == "search" || $0.name == "open_profile" || $0.name == "play" }) {
                    steps.append(Call("open_website", ["site": site, "browser": call["browser"] ?? ""].filter { !$0.value.isEmpty }))
                    call = Call("search", ["query": strip(leftover, verbs: ["search for", "search", "look up", "find"]), "site": site, "browser": call["browser"] ?? ""].filter { !$0.value.isEmpty })
                }
            case "search", "open_profile":
                move("person", to: "query"); move("text", to: "query")
                // "search for messi's profile" on a site: straight to the profile.
                if call.name == "search", let query = call["query"], call["site"].map({ Sites.find($0.lowercased())?.site.name != "Google" }) ?? true || !word("google", in: request),
                   !Set(AssistantIntent.plain(query).split(separator: " ").map(String.init)).isDisjoint(with: ["profile", "account", "channel", "handle"]) {
                    call = Call("open_profile", call.arguments)
                    // "google" is the model's default, not a site you named: the profile is on the site you opened.
                    if Sites.find(call["site"]?.lowercased() ?? "")?.site.name == "Google", !word("google", in: request) { call.arguments["site"] = nil }
                }
                // The site, whatever field it landed in ("to": "reddit").
                if call["site"] == nil, let site = values.first(where: { $0 != call["query"] && Sites.find($0.lowercased())?.exact == true && ($0.lowercased() != "google" || word("google", in: request)) }) { call.arguments["site"] = site }
            case "play":
                move("subject", to: "query"); move("text", to: "query"); move("target", to: "query")
                if call["service"] == nil, let service = values.first(where: { $0 != call["query"] && MusicService.named($0) != nil }) { call.arguments["service"] = service }
                // "fire up spotify": the player, nothing to play.
                if call["query"] == nil {
                    guard let service = call["service"] ?? call["app"] else { return nil }
                    call = Call("open_app", ["app": service])
                }
            case "click":
                move("text", to: "target"); move("query", to: "target")
                guard let target = call["target"] else { return nil }
                // "open safari and go to github": GitHub is the site it opened, not a button.
                if let last = steps.last, CommandPlanner.canonical(last["site"] ?? last["app"]) == CommandPlanner.canonical(target) { continue }
                // "open chrome and go to youtube": a site you named is opened, not looked for as a button.
                if Sites.find(target.lowercased())?.exact == true {
                    let browser = steps.last.flatMap { $0.name == "open_app" ? $0["app"] : nil }.flatMap { CommandPlanner.isBrowser($0, context: context) ? $0 : nil }
                    if browser != nil { steps.removeLast() }
                    call = Call("open_website", ["site": target, "browser": browser ?? ""].filter { !$0.value.isEmpty })
                }
            case "type_message":
                move("query", to: "text")
                // Typed exactly as you said it, even when the model reworded it.
                call.arguments["message"] = call["text"].map { snap($0, to: request) }
            case "set_volume": move("command", to: "change")
            case "email":
                move("query", to: "text"); move("subject", to: "text")
                // An email with nothing in it isn't what you asked for.
                guard let text = call["text"] else { return nil }
                call.arguments["body"] = snap(text, to: request)
            case "add_note": move("query", to: "text")
            case "add_reminder", "add_event": move("query", to: "text"); call.arguments["title"] = call["text"]
            case "set_timer": call.arguments["label"] = call["subject"]
            case "directions": move("query", to: "place"); move("text", to: "place")
            default: break
            }
            // The same words typed again, or a piece of them: the model repeating itself.
            if ["type_message", "add_note"].contains(call.name), let text = call["text"].map(AssistantIntent.plain),
               steps.contains(where: { step in ["type_message", "add_note"].contains(step.name) && (step["text"].map(AssistantIntent.plain) ?? "").contains(text) }) { continue }
            // "click the first video" right before playing it is the same step.
            if call.name == "play", let last = steps.last, last.name == "click", last["target"] == call["query"] { steps.removeLast() }
            steps.append(call)
        }
        guard !steps.isEmpty else { return nil }
        // The browser you named is where the web steps go, even when the model forgot it.
        let saidBrowsers = CommandPlanner.browsers(in: context).filter { named(app: $0.name, in: request) }
        if saidBrowsers.count == 1, let browser = saidBrowsers.first {
            let web: Set<String> = ["open_website", "search", "open_profile", "play"]
            for index in steps.indices where web.contains(steps[index].name) && steps[index]["browser"] == nil {
                if steps[index].name == "play", let service = steps[index]["service"].flatMap(MusicService.named), service == .spotify || service == .appleMusic { continue }
                steps[index].arguments["browser"] = browser.name
            }
        }
        return CommandPlanner.action(for: steps, request: request, context: context)
    }

    /// The stretch of your own words the model's text came from: "what is the weather"
    /// from "ask it what the weather is" is "what the weather is". Unchanged when
    /// your words don't hold all of it.
    static func snap(_ text: String, to said: String) -> String {
        let original = said.split(separator: " ").map(String.init)
        let plain = original.map(AssistantIntent.plain)
        let wanted = AssistantIntent.plain(text).split(separator: " ").map(String.init)
        guard !wanted.isEmpty else { return text }
        var best: Range<Int>?
        for start in plain.indices where wanted.contains(plain[start]) {
            var missing = wanted
            for end in start..<plain.count {
                for piece in plain[end].split(separator: " ") { if let at = missing.firstIndex(of: String(piece)) { missing.remove(at: at) } }
                if missing.isEmpty {
                    if best.map({ end + 1 - start < $0.count }) ?? true { best = start..<(end + 1) }
                    break
                }
            }
        }
        guard let best, best.count <= wanted.count + 2 else { return text }
        return original[best].joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " .,!;"))
    }

    /// "search for soccer balls" → "soccer balls".
    private static func strip(_ text: String, verbs: [String]) -> String {
        for verb in verbs where text.lowercased().hasPrefix(verb + " ") { return String(text.dropFirst(verb.count + 1)) }
        return text
    }

    /// Strips what leaks out of a value when the model fumbles its JSON (`messi','site':'x`).
    private static func clean(_ value: String) -> String? {
        var value = value
        for leak in ["\",", "',", "\":", "':"] { if let range = value.range(of: leak) { value = String(value[..<range.lowerBound]) } }
        value = value.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'“”")))
        return value.isEmpty ? nil : value
    }

    // MARK: Names

    private static let numbers = ["zero": "0", "one": "1", "two": "2", "three": "3", "four": "4", "five": "5",
                                  "six": "6", "seven": "7", "eight": "8", "nine": "9", "ten": "10"]

    /// Plain words with number words as digits and no spaces: "T three code" and "T3 Code" are both "t3code".
    static func compact(_ text: String) -> String {
        AssistantIntent.plain(text).split(separator: " ").map { numbers[String($0)] ?? String($0) }.joined()
    }

    /// "T3 Code (Beta)" → "T3 Code": what people call it.
    static func bare(_ name: String) -> String {
        var name = name
        while let open = name.firstIndex(of: "("), let close = name[open...].firstIndex(of: ")") { name.removeSubrange(open...close) }
        var words = name.split(separator: " ").map(String.init)
        if words.count > 1, let last = words.last, ["beta", "preview", "nightly", "canary"].contains(last.lowercased()) { words.removeLast() }
        return words.joined(separator: " ")
    }

    static func named(_ name: String, in said: String) -> Bool {
        let wanted = compact(bare(name))
        return wanted.count >= 2 && (compact(said).contains(wanted) || spelled(said).contains(wanted))
    }

    /// Letters said as words ("tee three code" for T3 Code). Only for exact name matches.
    private static let letters = ["tee": "t", "dee": "d", "bee": "b", "gee": "g", "pee": "p", "vee": "v", "zee": "z", "jay": "j", "kay": "k", "ess": "s", "ex": "x"]
    static func spelled(_ text: String) -> String {
        AssistantIntent.plain(text).split(separator: " ").map { letters[String($0)] ?? numbers[String($0)] ?? String($0) }.joined()
    }

    /// Other names people use for an app.
    private static let appAliases = ["system preferences": "system settings", "settings": "system settings", "preferences": "system settings",
                                     "itunes": "music", "apple music": "music", "the app store": "app store", "terminal app": "terminal",
                                     "vs code": "visual studio code", "vscode": "visual studio code", "word": "microsoft word", "excel": "microsoft excel",
                                     "email": "mail", "my email": "mail", "texts": "messages", "imessage": "messages"]

    /// Words that don't pick out one app on their own ("Google", "Code", "Studio").
    private static let generic: Set<String> = ["google", "microsoft", "apple", "adobe", "the", "app", "apps", "code", "studio",
                                               "desktop", "browser", "system", "settings", "editor", "player", "music", "mail", "pro", "for"]

    /// An app is named when you said its whole name, or a word of it that's its
    /// own ("Chrome" for Google Chrome, "Word" for Microsoft Word). "Slick" isn't Slack.
    static func named(app name: String, in said: String) -> Bool {
        if named(name, in: said) { return true }
        let plain = AssistantIntent.plain(said)
        if appAliases.contains(where: { $0.value == bare(name).lowercased() && " \(plain) ".contains(" \($0.key) ") }) { return true }
        let heard = Set(plain.split(separator: " ").map(String.init))
        return AssistantIntent.plain(bare(name)).split(separator: " ").map(String.init)
            .contains { $0.count >= 4 && !generic.contains($0) && heard.contains($0) }
    }

    /// A site is named by its name or one of its nicknames ("insta", "yt").
    private static func named(site host: String, in said: String) -> Bool {
        let key = host.lowercased().replacingOccurrences(of: "www.", with: "")
        let label = key.split(separator: ".").first.map(String.init) ?? key
        if named(label, in: said) { return true }
        let words = " " + AssistantIntent.plain(said) + " "
        if label.count == 1, words.contains(" \(label) ") { return true }
        return Sites.all.contains { $0.home.host?.replacingOccurrences(of: "www.", with: "") == key && $0.names.contains { words.contains(" \($0) ") } }
    }

    // MARK: Checks

    /// Did you name it? Apps, sites and browsers have to be in your words; what you
    /// type, press or play comes from your words already.
    static func grounded(_ action: CommandAction, in said: String) -> Bool {
        switch action {
        case .openApp(let app): return named(app: app.name, in: said)
        case .openSite(let name): return named(name, in: said)
        case .openURL(let url):
            if url.host == "duckduckgo.com" { return true }
            // A search carries your words; a site has to be one you said.
            if url.query?.contains("=") == true { return url.host.map { named(site: $0, in: said) || $0.contains("google.") } ?? true }
            // Directions, a new email, a settings page: made from your words, not a name.
            if let scheme = url.scheme, !scheme.hasPrefix("http") { return true }
            return named(site: url.host ?? "", in: said)
        case .type(_, let app): return app.map { named(app: $0.name, in: said) } ?? true
        case .inBrowser(let inner, let browser): return grounded(inner, in: said) && named(app: browser.name, in: said)
        case .sequence(let steps): return steps.allSatisfy { grounded($0, in: said) }
        case .quitApp(let name), .hideApp(let name): return named(app: name, in: said)
        case .press(let name): return AssistantIntent.plain(name).split(separator: " ").allSatisfy { word(String($0), in: said) }
        default: return true
        }
    }

    private static func words(_ text: String) -> Set<String> { Set(AssistantIntent.plain(text).split(separator: " ").map(String.init)) }
    private static func word(_ word: String, in said: String) -> Bool { words(said).contains(word) }
    private static func any(_ list: [String], in said: String) -> Bool {
        let heard = " " + AssistantIntent.plain(said) + " "
        return list.contains { heard.contains(" \($0) ") }
    }

    /// Each kind of step needs a word of yours that asks for it: the model can't
    /// lock the screen because you asked what's on your calendar.
    private static func asked(for step: CommandAction, in said: String) -> Bool {
        switch step {
        case .system(let system):
            switch system {
            case .lock: return any(["lock"], in: said)
            case .sleep: return any(["sleep"], in: said)
            case .darkMode: return any(["dark"], in: said)
            case .lightMode: return any(["light"], in: said)
            case .toggleAppearance: return any(["dark", "light", "appearance"], in: said)
            case .emptyTrash: return any(["trash"], in: said)
            case .screenshot: return any(["screenshot", "screen shot", "screengrab", "capture"], in: said)
            case .showDesktop: return any(["desktop"], in: said)
            case .closeTab, .newTab, .reopenTab: return any(["tab", "tabs"], in: said)
            case .goBack: return any(["back"], in: said)
            }
        case .media(let media):
            switch media {
            case .next: return any(["next", "skip"], in: said)
            case .previous: return any(["previous", "back", "last", "rewind", "restart"], in: said)
            case .playPause: return any(["pause", "resume", "stop", "unpause", "play", "continue"], in: said)
            }
        case .volume(let change):
            switch change {
            case .up: return any(["up", "louder", "raise", "increase", "higher", "boost", "quiet"], in: said)
            case .down: return any(["down", "quieter", "lower", "decrease", "softer", "loud", "reduce"], in: said)
            case .mute: return any(["mute", "silence"], in: said)
            case .unmute: return any(["unmute"], in: said)
            case .set: return said.contains(where: \.isNumber) || any(["all the way", "max", "maximum", "full", "half", "halfway", "zero", "percent"], in: said)
            }
        case .timer: return any(["timer", "alarm", "countdown"], in: said) && CommandPlanner.seconds(in: said) != nil
        case .quitApp: return any(["quit", "close", "exit", "kill"], in: said)
        case .addReminder: return any(["remind", "reminder", "reminders"], in: said)
        case .addNote: return any(["note", "notes", "jot"], in: said)
        case .addEvent: return any(["calendar", "event", "schedule", "meeting", "appointment"], in: said)
        case .type: return any(["type", "write", "tell", "message", "text", "say", "saying", "ask", "dictate", "put", "enter", "draft"], in: said)
        case .openURL(let url) where url.scheme == "mailto": return any(["email", "e mail", "mail"], in: said)
        case .openURL(let url) where url.scheme == "maps": return any(["directions", "navigate", "route", "drive", "way", "take me", "get to"], in: said)
        case .openURL(let url) where url.scheme == "x-apple.systempreferences":
            guard let page = CommandPlanner.settingsPages.first(where: { url.absoluteString.hasSuffix($0.value) && !$0.value.isEmpty })?.key else {
                return any(["settings", "preferences"], in: said)
            }
            return any([page], in: said) || compact(said).contains(compact(page))
        case .openURL(let url) where url.host == "duckduckgo.com":
            // A profile: the person's name is yours.
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }?.value ?? ""
            let who = query.split(separator: " ").dropFirst().map(String.init)
            return !who.isEmpty && who.allSatisfy { word(AssistantIntent.plain($0), in: said) }
        case .press(let name): return !ScreenClick.isRisky(name)
        case .inBrowser(let inner, _): return asked(for: inner, in: said)
        default: return true
        }
    }

    /// Things the screen has to show to make sense ("open this", "what's here"): Ask can see it.
    private static let screenWords: Set<String> = ["this", "these", "those", "here", "screen"]
    /// A request that changes something for good starts with one of these: never planned here.
    private static let changes: Set<String> = ["book", "buy", "order", "pay", "purchase", "post", "reply", "share", "follow", "subscribe",
                                              "delete", "remove", "erase", "submit", "accept", "approve", "install", "uninstall", "download",
                                              "upload", "send", "forward", "cancel", "sign", "log", "unfollow", "unsubscribe", "transfer"]

    /// The model's plan, checked before it runs: every app and site is one you named,
    /// each step is a kind you asked for, every part of the request is in it, and it
    /// doesn't guess a web search for something it didn't get. Anything about the
    /// screen ("fix this", "what's that") is left for Ask, which can see it.
    static func trusted(_ action: CommandAction, for said: String) -> Bool {
        let steps: [CommandAction]
        if case .sequence(let list) = action { steps = list } else { steps = [action] }
        // Your own words being written down ("write buy milk") aren't a request to buy.
        let dictated = steps.map { step -> String in
            switch step {
            case .type(let text, _), .addNote(let text): return text
            case .addReminder(let text, let notes, _): return text + " " + (notes ?? "")
            case .addEvent(let text, _, _): return text
            case .openURL(let url) where url.scheme == "mailto": return url.absoluteString.removingPercentEncoding ?? ""
            default: return ""
            }
        }.joined(separator: " ")
        let heard = words(said).subtracting(words(dictated))
        // One thing written per request; more is the model repeating itself.
        let writes = steps.filter { if case .type = $0 { return true }; if case .addNote = $0 { return true }; return false }.count
        if writes > 1 { return false }
        if !heard.isDisjoint(with: changes) { return false }
        guard !steps.isEmpty else { return false }
        // "close this tab", "skip this song": one step that's about what's in front, which is fine.
        let aboutFront = steps.count == 1 && { switch steps[0] { case .system, .media, .volume: return true; default: return false } }()
        if !heard.isDisjoint(with: screenWords), !aboutFront { return false }
        func fine(_ step: CommandAction) -> Bool {
            switch step {
            case .inBrowser(let inner, _): return fine(inner)
            case .none, .shortcut, .hideApp, .learnSite, .murmur, .sequence: return false
            case .openURL(let url):
                // "search the web for <your whole sentence>" is the model giving up.
                if url.host?.contains("google.") == true, let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "q" })?.value,
                   AssistantIntent.plain(query) == AssistantIntent.plain(said) { return false }
                return asked(for: step, in: said)
            default: return asked(for: step, in: said)
            }
        }
        return steps.allSatisfy(fine) && grounded(action, in: said) && covers(action, said) && keepsPlaces(action, said)
    }

    /// Sites, players and browsers that pick where something happens.
    private static let places = ["youtube", "spotify", "apple music", "reddit", "github", "linkedin", "instagram", "tiktok", "netflix", "amazon",
                                 "wikipedia", "twitter", "pinterest", "twitch", "bing", "stack overflow", "hacker news", "chatgpt", "perplexity",
                                 "gmail", "safari", "chrome", "firefox", "brave", "arc", "edge"]

    /// Every place you named is where the plan goes: "search reddit for…" can't turn
    /// into a Google search, "play drake on spotify" can't play on YouTube.
    static func keepsPlaces(_ action: CommandAction, _ said: String) -> Bool {
        let known = " " + planWords(action) + " "
        return places.allSatisfy { place in !any([place], in: said) || known.contains(" " + place + " ") || known.contains(" " + place.replacingOccurrences(of: " ", with: "") + " ") }
    }

    private static let filler: Set<String> = ["open", "launch", "start", "bring", "pull", "show", "get", "put", "throw", "turn", "go", "the", "and",
        "for", "some", "my", "me", "please", "look", "search", "find", "play", "set", "make", "take", "can", "you", "could", "would", "will",
        "just", "now", "then", "also", "new", "with", "from", "into", "onto", "about", "like", "want", "need", "hey", "murmur", "real", "quick",
        "fire", "pop", "crack", "app", "website", "site", "page", "called", "named", "thread", "click", "press", "tap", "type", "write", "that",
        "okay", "yeah", "wanna", "gonna", "thanks", "thank", "first", "after", "next", "finally", "there", "what", "was", "are", "its",
        "this", "that", "saying", "say", "tell", "ask", "them", "him", "her", "said", "says", "who", "which", "one", "out", "all", "way"]

    /// When, not what: carried by the step's date rather than its words.
    private static let timeWords: Set<String> = ["today", "tonight", "tomorrow", "morning", "afternoon", "evening", "noon", "midnight", "monday",
        "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday", "week", "month", "minute", "minutes", "hour", "hours", "second",
        "seconds", "min", "mins", "later", "o'clock", "oclock", "little", "bit", "lot", "way", "all"]

    /// Every part of what you said shows up in the plan: a model that dropped
    /// "and call mom" doesn't get to run the half it kept.
    static func covers(_ action: CommandAction, _ said: String) -> Bool {
        // Each part of the request needs a word of it in the plan: "open chrome open
        // instagram search messi profile" can't run as just "open Instagram".
        let known = Set(planWords(action).split(separator: " ").map(String.init))
        func covered(_ word: String) -> Bool { known.contains(word) || known.contains { $0.count >= 4 && (word.hasPrefix($0) || $0.hasPrefix(word)) } }
        for part in parts(said) {
            let content = part.filter { $0.count >= 3 && !filler.contains($0) && !timeWords.contains($0) && CommandPlanner.seconds(in: $0) == nil }
            if !content.isEmpty, !content.contains(where: covered) { return false }
        }
        return true
    }

    /// Words that start a new part of a request.
    private static let partVerbs: Set<String> = ["open", "search", "play", "go", "type", "click", "find", "look", "set", "turn", "make", "email",
                                                 "tell", "ask", "write", "launch", "pull", "add", "remind", "get", "take", "close", "quit",
                                                 "show", "press", "tap", "select", "put", "send", "message", "text", "call", "pause", "skip"]

    /// The parts of a request, as plain words: "open chrome, open instagram and search
    /// messi" is three. Split at "and", "then", commas and each action word.
    private static func parts(_ said: String) -> [[String]] {
        var parts: [[String]] = [[]]
        for raw in said.lowercased().split(separator: " ") {
            let breaks = raw.hasSuffix(",") || raw.hasSuffix(".") || raw.hasSuffix(";")
            let word = AssistantIntent.plain(String(raw))
            if ["and", "then"].contains(word) { parts.append([]); continue }
            if partVerbs.contains(word), !(parts.last?.isEmpty ?? true) { parts.append([]) }
            parts[parts.count - 1] += word.split(separator: " ").map(String.init)
            if breaks { parts.append([]) }
        }
        // A word right after "email", "tell", "message"… is who it's for, not a step.
        return parts.filter { !$0.isEmpty }.map { part in
            guard part.count > 1, ["email", "message", "text", "tell", "call", "ask"].contains(part[0]) else { return part }
            return [part[0]] + part.dropFirst(2)
        }
    }

    /// The plan as plain words, with the other names of what it opens.
    private static func planWords(_ action: CommandAction) -> String {
        var plan = describe(action).joined(separator: " ") + " " + (String(describing: action).removingPercentEncoding ?? String(describing: action))
        func aliases(_ step: CommandAction) {
            switch step {
            case .sequence(let steps): steps.forEach(aliases)
            case .inBrowser(let inner, let browser): aliases(inner); plan += " " + browser.name
            case .openURL(let url):
                let host = url.host?.replacingOccurrences(of: "www.", with: "") ?? ""
                if let site = Sites.all.first(where: { $0.home.host?.replacingOccurrences(of: "www.", with: "") == host || (url.absoluteString.hasPrefix($0.search ?? "\u{0}")) }) {
                    plan += " " + site.names.joined(separator: " ")
                }
                if url.host == "duckduckgo.com" { plan += " profile account page" }
                if url.scheme == "maps" { plan += " directions navigate route" }
                if url.scheme == "mailto" { plan += " email mail" }
                if url.scheme == "x-apple.systempreferences" { plan += " settings preferences system" }
            case .openApp(let app): plan += " " + appAliases.filter { $0.value == bare(app.name).lowercased() }.keys.joined(separator: " ")
            case .play(_, let service): plan += " " + service.rawValue + " music song songs video"
            case .addReminder: plan += " reminder reminders remind"
            case .addEvent: plan += " calendar event meeting"
            case .addNote: plan += " note notes"
            case .volume: plan += " volume sound louder quieter loud quiet"
            case .media: plan += " song music track skip"
            case .timer: plan += " timer minutes seconds hour"
            case .system: plan += " tab mode screen"
            default: break
            }
        }
        aliases(action)
        return AssistantIntent.plain(plan)
    }

    /// Clicks something on screen.
    static func presses(_ action: CommandAction) -> Bool {
        switch action {
        case .press: return true
        case .sequence(let steps): return steps.contains(where: presses)
        case .inBrowser(let inner, _): return presses(inner)
        default: return false
        }
    }

    /// Can't be taken back, or runs something unseen: the palette asks before it runs.
    static func asksFirst(_ action: CommandAction) -> Bool {
        switch action {
        case .quitApp, .shortcut: return true
        case .system(let system): return [.lock, .sleep, .emptyTrash].contains(system)
        case .sequence(let steps): return steps.contains(where: asksFirst)
        case .inBrowser(let inner, _): return asksFirst(inner)
        default: return action.needsConfirmation
        }
    }

    /// Opening and searching can't hurt anything, so it runs as soon as the words are
    /// final, without the preview. Clicking and typing are shown first.
    static func needsPreview(_ action: CommandAction) -> Bool {
        switch action {
        case .openApp, .openSite, .openURL, .media, .volume, .timer, .play: return false
        case .inBrowser(let inner, _): return needsPreview(inner)
        case .sequence(let steps): return steps.contains(where: needsPreview)
        default: return true
        }
    }

    /// The plan, step by step, as it'll be shown before it runs.
    static func describe(_ action: CommandAction) -> [String] {
        switch action {
        case .sequence(let steps): return steps.flatMap(describe)
        case .openApp(let app): return ["Open \(app.name)"]
        case .press(let name): return ["Click “\(name)”"]
        case .type(let words, let app): return ["Type “\(words)”" + (app.map { " in \($0.name)" } ?? "")]
        case .openSite(let name): return ["Open \(name)"]
        case .openURL(let url) where url.scheme == "maps":
            return ["Directions to \(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value ?? "there")"]
        case .openURL(let url) where url.scheme == "mailto":
            let body = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "body" }?.value ?? ""
            return ["New email: “\(body)” (not sent)"]
        case .openURL(let url) where url.scheme == "x-apple.systempreferences":
            return ["Open " + (CommandPlanner.settingsPages.first { url.absoluteString.hasSuffix($0.value) && !$0.value.isEmpty }.map { $0.key.capitalizedFirst + " settings" } ?? "System Settings")]
        case .openURL(let url) where Sites.all.contains { $0.search.map { url.absoluteString.hasPrefix($0) } ?? false } && url.host != "duckduckgo.com":
            let site = Sites.all.first { $0.search.map { url.absoluteString.hasPrefix($0) } ?? false }!
            let query = String(url.absoluteString.dropFirst(site.search!.count)).removingPercentEncoding ?? ""
            return ["Search \(site.name) for “\(query.replacingOccurrences(of: "+", with: " "))”"]
        case .openURL(let url):
            if let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "q" || $0.name == "search_query" || $0.name == "k" })?.value {
                if query.hasPrefix("\\site:") {
                    let parts = query.dropFirst(6).split(separator: " ", maxSplits: 1)
                    return ["Open \(parts.count > 1 ? parts[1] : "")’s profile on \(siteName(String(parts[0])))"]
                }
                return ["Search \(siteName(url.host ?? "")) for “\(query)”"]
            }
            return ["Open \(siteName(url.host ?? url.absoluteString))"]
        case .play(let query, let service): return ["Play \(query) on \(service.rawValue)"]
        case .timer(let seconds, _): return ["Set a timer for \(seconds >= 60 ? "\(seconds / 60) min" : "\(seconds) s")"]
        case .inBrowser(let inner, let browser): return describe(inner).map { $0 + " in \(browser.name)" }
        case .hideApp(let name): return ["Hide \(name)"]
        case .addNote(let text): return ["New note: “\(text)”"]
        case .addReminder(let title, _, _): return ["Remind you: “\(title)”"]
        case .addEvent(let title, _, _): return ["Add “\(title)” to your calendar"]
        case .media(let key): return [key == .next ? "Next track" : key == .previous ? "Previous track" : "Play / pause"]
        case .volume(let change):
            switch change {
            case .up: return ["Volume up"]
            case .down: return ["Volume down"]
            case .mute: return ["Mute"]
            case .unmute: return ["Unmute"]
            case .set(let level): return ["Volume to \(level)%"]
            }
        case .system(let system):
            let names: [CommandAction.System: String] = [.lock: "Lock the screen", .sleep: "Sleep", .darkMode: "Dark mode", .lightMode: "Light mode",
                                                         .toggleAppearance: "Switch light / dark", .emptyTrash: "Empty the Trash", .screenshot: "Take a screenshot",
                                                         .showDesktop: "Show the desktop", .closeTab: "Close the tab", .newTab: "New tab",
                                                         .reopenTab: "Reopen the tab", .goBack: "Go back"]
            return [names[system] ?? "Run that command"]
        case .openPath(let path, let app): return ["Open \((path as NSString).lastPathComponent)" + (app.map { " in \($0.name)" } ?? "")]
        case .findFile(let name, _): return ["Find “\(name)”"]
        case .quitApp(let name): return ["Quit \(name)"]
        case .shortcut(let name): return ["Run the “\(name)” shortcut"]
        case .meeting(let meeting): return [meeting == .start ? "Start meeting notes" : "Stop meeting notes"]
        default: return ["Run that command"]
        }
    }

    /// "www.instagram.com" → "Instagram".
    static func siteName(_ host: String) -> String {
        let key = host.lowercased().replacingOccurrences(of: "www.", with: "")
        if let site = Sites.all.first(where: { $0.home.host?.replacingOccurrences(of: "www.", with: "") == key }) { return site.name }
        return key
    }
}

/// Testing aid: with Murmur started with --debug-requests, each request's route,
/// plan, steps and timings go to /tmp/murmur-requests.log.
enum RequestTrace {
    nonisolated(unsafe) static var enabled = false
    private static let path = "/tmp/murmur-requests.log"
    private static var started = Date()

    static func begin(_ request: String) {
        started = Date()
        log("\n=== \(request)")
    }

    static func ms(since date: Date) -> String { "\(Int(Date().timeIntervalSince(date) * 1000)) ms" }

    static func log(_ line: String) {
        guard enabled else { return }
        let stamped = String(format: "[%5.0f] ", Date().timeIntervalSince(started) * 1000) + line + "\n"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile(); handle.write(Data(stamped.utf8)); try? handle.close()
        } else {
            try? stamped.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}
