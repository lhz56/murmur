import Foundation

/// Space + Down Arrow understanding, done by the on-Mac model and nothing else:
/// no word patterns. The model reads the request and answers with steps in a
/// fixed JSON shape (Ollama holds it to the schema, so it can't ramble or invent
/// a tool), and `StepCheck` then makes sure every step is something you actually
/// said before anything runs.
enum StepPlanner {
    /// Each tool and the fields it takes. Every field is required (empty when not
    /// said), so the model can't put a value in a field another tool uses.
    static let tools: [(String, [String])] = [
        ("open_app", ["app"]), ("open_website", ["site", "browser"]), ("search", ["query", "site", "browser"]),
        ("open_profile", ["person", "site", "browser"]), ("play", ["query", "service", "browser"]), ("click", ["target"]),
        ("type_message", ["text", "app"]), ("open_settings", ["page"]), ("set_timer", ["minutes", "label"]),
        ("set_volume", ["change", "level"]), ("media", ["command"]), ("browser_tab", ["command"]),
        ("email", ["to", "subject", "text"]), ("add_note", ["text"]), ("add_reminder", ["text", "when"]),
        ("add_event", ["text", "when", "minutes"]), ("directions", ["place"]), ("system", ["command"]),
        ("quit_app", ["app"]), ("cant_do", []),
    ]

    static var fields: [String] { Array(Set(tools.flatMap(\.1))).sorted() }

    /// One flat shape for every step (small models lose their way in a shape per tool):
    /// the tool, from the fixed list, and the fields any tool uses.
    static var schema: [String: Any] {
        var properties: [String: Any] = ["tool": ["type": "string", "enum": tools.map(\.0)]]
        for field in fields { properties[field] = ["type": "string"] }
        return ["type": "object", "required": ["steps"],
                "properties": ["steps": ["type": "array", "minItems": 1, "maxItems": 6, "items": ["type": "object", "required": ["tool"], "properties": properties]]]]
    }

    static func system(apps: [String], music: MusicService) -> String {
        """
        You turn a spoken request to a Mac assistant into steps. Speech recognition adds filler ("um", "uh", "hey", \
        "please", "for me"): ignore it. Answer only with JSON: {"steps":[{"tool":…, fields…}]}, one step per thing \
        the user asked for, in order. Leave out any field you don't need.

        Tools and their fields:
        - open_app {app}: open an app on the Mac. Only an app from the installed list.
        - open_website {site, browser}: open a website. browser only if the user named one (chrome, safari, arc…).
        - search {query, site, browser}: search a site. site = the site just opened, or the one named, else google.
        - open_profile {person, site, browser}: open a person's or account's profile page on a site (instagram, x, linkedin, tiktok…).
        - play {query, service, browser}: play music or a video. service = youtube, spotify or apple music; empty = \(music.rawValue.lowercased()).
        - click {target}: click or open a named button, tab, thread, chat, folder or item inside the app that is open. \
        target = its name exactly as said, without words like "the thread called".
        - type_message {text, app}: type the user's words, exactly as said, into an app's message box (never sends).
        - open_settings {page}: a page of System Settings (bluetooth, wifi, sound, displays, battery, notifications…).
        - set_timer {minutes, label}
        - set_volume {change: up, down, mute or unmute; level: 0-100 only if a number or "all the way" was said}
        - media {command: pause, resume, next or previous}
        - browser_tab {command: new, close or reopen}
        - email {to, subject, text}: start an email (never sends).
        - add_note {text}
        - add_reminder {text, when}
        - add_event {text, when, minutes}
        - directions {place}
        - system {command: lock, sleep, dark mode, light mode, screenshot, show desktop}
        - quit_app {app}
        - cant_do {}: anything else. Use it for questions, for anything about "this" or "that" on the screen, \
        and for anything that buys, books, pays, posts, sends, replies, deletes, follows, signs in or installs.

        Rules: never add a step the user didn't ask for. Copy names, queries and typed words from the request; \
        don't correct or expand them. "go to settings" inside an app that was just opened is a click, not open_settings. \
        "open X" where X is a site (instagram, youtube, github…) and not an installed app is open_website.

        Installed apps: \(apps.prefix(150).joined(separator: ", "))
        """
    }

    static let examples: [(String, String)] = [
        ("open chrome, open instagram and search for messi's profile",
         #"{"steps":[{"tool":"open_website","site":"instagram","browser":"chrome"},{"tool":"open_profile","person":"messi","site":"instagram","browser":"chrome"}]}"#),
        ("throw open the github website in safari", #"{"steps":[{"tool":"open_website","site":"github","browser":"safari"}]}"#),
        ("open youtube and search lofi beats",
         #"{"steps":[{"tool":"open_website","site":"youtube","browser":""},{"tool":"search","query":"lofi beats","site":"youtube","browser":""}]}"#),
        ("open t3 code, open the thread called launch notes and type ship it tonight",
         #"{"steps":[{"tool":"open_app","app":"T3 Code"},{"tool":"click","target":"launch notes"},{"tool":"type_message","text":"ship it tonight","app":"T3 Code"}]}"#),
        ("open slack and go to settings", #"{"steps":[{"tool":"open_app","app":"Slack"},{"tool":"click","target":"settings"}]}"#),
        ("turn the volume up a bit", #"{"steps":[{"tool":"set_volume","change":"up","level":""}]}"#),
        ("skip this song", #"{"steps":[{"tool":"media","command":"next"}]}"#),
        ("fire up spotify", #"{"steps":[{"tool":"open_app","app":"Spotify"}]}"#),
        ("play the first video of veritasium on youtube", #"{"steps":[{"tool":"play","query":"veritasium","service":"youtube","browser":""}]}"#),
        ("open cursor and tell it to add a dark mode toggle",
         #"{"steps":[{"tool":"open_app","app":"Cursor"},{"tool":"type_message","text":"add a dark mode toggle","app":"Cursor"}]}"#),
        ("remind me to call the bank friday at 5", #"{"steps":[{"tool":"add_reminder","text":"call the bank","when":"friday at 5"}]}"#),
        ("what's on my calendar today", #"{"steps":[{"tool":"open_app","app":"Calendar"}]}"#),
        ("open chrome and go to youtube", #"{"steps":[{"tool":"open_website","site":"youtube","browser":"chrome"}]}"#),
        ("play taylor swift on youtube in safari", #"{"steps":[{"tool":"play","query":"taylor swift","service":"youtube","browser":"safari"}]}"#),
        ("open bluetooth settings", #"{"steps":[{"tool":"open_settings","page":"bluetooth"}]}"#),
        ("volume to 30", #"{"steps":[{"tool":"set_volume","level":"30"}]}"#),
        ("email sam saying I'll be there at 5", #"{"steps":[{"tool":"email","to":"sam","text":"I'll be there at 5"}]}"#),
        ("pull up linkedin and search for designer jobs", #"{"steps":[{"tool":"open_website","site":"linkedin"},{"tool":"search","query":"designer jobs","site":"linkedin"}]}"#),
        ("delete all my emails", #"{"steps":[{"tool":"cant_do"}]}"#),
        ("what does this error mean", #"{"steps":[{"tool":"cant_do"}]}"#),
    ]

    /// The model's steps, as calls. Nil when there's no model or it took too long.
    static func calls(for request: String, apps: [String], music: MusicService, model: String, timeout: TimeInterval) async -> [CommandPlanner.Call]? {
        let shots = examples.map { "Request: \($0.0)\nAnswer: \($0.1)" }.joined(separator: "\n\n")
        let prompt = "\(shots)\n\nRequest: \(request)\nAnswer:"
        guard let raw = try? await LocalLLM.ollama(model: model, system: system(apps: apps, music: music), prompt: prompt, schema: schema,
                                                   context: LocalLLM.commandContext, predict: 200, keepAlive: "30m", timeout: timeout),
              let data = LocalLLM.jsonObject(in: raw),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let steps = json["steps"] as? [[String: Any]] else { return nil }
        return steps.compactMap { step in
            guard let tool = step["tool"] as? String else { return nil }
            var arguments: [String: String] = [:]
            for (key, value) in step where key != "tool" {
                let text = (value as? String) ?? (value as? NSNumber)?.stringValue ?? ""
                if !text.trimmingCharacters(in: .whitespaces).isEmpty { arguments[key] = text }
            }
            return CommandPlanner.Call(tool, arguments)
        }
    }
}
