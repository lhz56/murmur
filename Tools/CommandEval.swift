import Foundation

// Scores Commands on 60 everyday requests, the way they're said out loud,
// through the same rules + local model path the app uses. Needs Ollama with
// the command model. Run: Tools/CommandEval.sh [model]

@main struct Suite {
    static func main() async {
        let names = ["/Applications", NSHomeDirectory() + "/Applications", "/System/Applications"].flatMap { (try? FileManager.default.contentsOfDirectory(atPath: $0)) ?? [] }
            .filter { $0.hasSuffix(".app") }.map { String($0.dropLast(4)) } + ["Slack", "WhatsApp", "Spotify"]
        let apps = names.map { AppEntry(name: $0, path: "/Applications/\($0).app") }
        var ctx = CommandContext(apps: apps, folders: ["murmur": "/Users/me/murmur", "Recallr": "/Users/me/Recallr", "workloom": "/Users/me/workloom"])
        ctx.music = .spotify
        let model = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "qwen3:1.7b"
        await LocalLLM.warm(model, context: LocalLLM.commandContext)
        _ = await CommandPlanner.calls(for: "open notes", apps: names, music: .spotify, model: model)
        // (request, every piece the right answer must contain)
        let cases: [(String, [String])] = [
            ("hey can you open Amazon and search soccer balls", ["amazon.com/s?k=soccer%20balls"]),
            ("open amazon in safari and search for soccer balls", ["amazon.com/s?k=soccer%20balls", "Safari"]),
            ("go to reddit and look up standing desks", ["reddit.com/search", "standing%20desks"]),
            ("open youtube and search lofi beats", ["youtube.com/results", "lofi%20beats"]),
            ("open github and find recallr", ["github.com/search?q=recallr"]),
            ("open youtube on chrome and look up how to tie a tie", ["youtube.com/results", "tie%20a%20tie", "Chrome"]),
            ("pull up amazon, search airpods", ["amazon.com/s?k=airpods"]),
            ("open safari and search for flights to tokyo", ["google.com/search", "flights%20to%20tokyo", "Safari"]),
            ("Yo can you open Youtube and Safari and play Slowlinger", ["play(\"", "youtube", "Safari"]),
            ("Hey, can you open Safari, open YouTube and play Linger slowed", ["linger slowed", "youtube", "Safari"]),
            ("can you open youtube on safari and play the slow version of linger", ["linger", "youtube", "Safari"]),
            ("yo put on some drake for me", ["play(\"drake\"", "spotify"]),
            ("open spotify and play drake", ["play(\"drake\"", "spotify"]),
            ("yo can you throw on that slowed version of glimpse of us in chrome", ["glimpse of us", "youtube", "Chrome"]),
            ("I wanna watch the new mkbhd video", ["mkbhd", "youtube"]),
            ("play taylor swift on apple music", ["taylor swift", "appleMusic"]),
            ("open spotify, play some kendrick and turn it up", ["kendrick", "volume(", "up"]),
            ("I need to get to work on recallr, open it in cursor and throw on some lofi", ["openPath(\"/Users/me/Recallr\"", "Cursor", "lofi"]),
            ("open murmur in cursor and open slack", ["openPath(\"/Users/me/murmur\"", "Cursor", "Slack"]),
            ("Hey, can you open Workloom on Safari", ["openSite(\"", "orkloom", "Safari"]),
            ("open safari open workloom", ["orkloom", "Safari"]),
            ("open workloom", ["openApp", "WorkLoom"]),
            ("open the workloom folder", ["openPath(\"/Users/me/workloom\""]),
            ("go to github.com/lhz56 in safari", ["github.com/lhz56", "Safari"]),
            ("Can you open Instagram on Google Chrome?", ["instagram.com", "Chrome"]),
            ("message sam on whatsapp that I'm running ten minutes late", ["type(\"", "running ten minutes late", "WhatsApp"]),
            ("tell T3 code to run the tests and fix whatever fails", ["type(\"", "run the tests", "T3 Code"]),
            ("open slack and write on my way", ["type(\"", "on my way", "Slack"]),
            ("tell claude to summarize this page", ["type(\"", "summarize this page", "Claude"]),
            ("ask chatgpt to write a cover letter for a swe internship", ["chatgpt.com/?q=", "cover%20letter"]),
            ("ask claude how to center a div", ["claude.ai/new?q=", "center"]),
            ("write an email to my professor saying I'll miss class", ["mailto:", "miss"]),
            ("what's the weather like in boston tomorrow", ["google.com/search", "boston"]),
            ("who won the lakers game last night", ["google.com/search", "lakers"]),
            ("show me cheap mechanical keyboards on amazon", ["amazon.com/s?k=", "mechanical%20keyboards"]),
            ("find a good recipe for chicken tikka on youtube", ["youtube.com/results", "chicken%20tikka"]),
            ("translate good morning to spanish", ["translate.google.com", "tl=es", "good%20morning"]),
            ("look up recallr on github", ["github.com/search?q=recallr"]),
            ("it's kinda quiet in here", ["volume(", "up"]),
            ("turn the volume all the way up", ["volume(", "set(100)"]),
            ("I'm done with slack for today", ["quitApp(\"Slack\")"]),
            ("close this tab", ["system(", "closeTab"]),
            ("skip this song", ["media(", "next"]),
            ("go back to the last song", ["media(", "previous"]),
            ("pause the music and open notes", ["media(", "openApp", "Notes"]),
            ("set a timer for an hour and a half", ["timer(seconds: 5400"]),
            ("remind me in 20 minutes to take the laundry out", ["timer(seconds: 1200"]),
            ("open reminders and add a reminder named a16z Speedrun, remind me to apply to them", ["addReminder(\"a16z Speedrun\"", "Apply to them"]),
            ("add a reminder to call mom on sunday", ["addReminder(", "all", "mom"]),
            ("put dinner with sam on my calendar friday at 7pm", ["addEvent(\"", "Sam"]),
            ("make a note that the parking spot is B12", ["addNote(\"", "B12"]),
            ("open notes and write buy milk", ["buy milk", "Notes"]),
            ("start taking notes for this meeting", ["meeting(", "start"]),
            ("turn on dark mode and lock my screen", ["darkMode", "lock"]),
            ("open bluetooth settings", ["x-apple.systempreferences:com.apple.BluetoothSettings"]),
            ("show me my calendar for today", ["openApp", "Calendar"]),
            ("pull up my calendar", ["openApp", "Calendar"]),
            ("can you open the ChatGPT app", ["openApp", "ChatGPT"]),
            ("uh can you like open spotify", ["openApp", "Spotify"]),
            ("open slack", ["openApp", "Slack"]),
        ]
        var passed = 0, times: [Double] = []
        for (phrase, expected) in cases {
            let start = Date()
            let rules = CommandParser.best(for: phrase, context: ctx)
            var chosen: CommandSuggestion?
            if let rules, CommandParser.isTrivial(rules, for: phrase) { chosen = rules }
            else {
                if let calls = await CommandPlanner.calls(for: phrase, apps: names, music: .spotify, model: model) {
                    chosen = CommandPlanner.action(for: calls, request: phrase, context: ctx)
                }
                if let model = chosen, let rules, CommandParser.isSure(rules, for: phrase),
                   CommandPlanner.coverage(rules, of: phrase, context: ctx) > CommandPlanner.coverage(model, of: phrase, context: ctx) { chosen = rules }
                if chosen == nil, let rules, rules.confidence >= 0.6 { chosen = rules }
            }
            times.append(Date().timeIntervalSince(start))
            let text = chosen.map { "\($0.action)".replacingOccurrences(of: "h.", with: "") } ?? "nil"
            // "all" stands for an all-day reminder: no time on the due date.
            let ok = expected.allSatisfy { piece in piece == "all" ? text.contains("00:00:00") || text.contains("04:00:00") || text.contains("05:00:00") : text.lowercased().contains(piece.lowercased()) }
            if ok { passed += 1 } else { print("FAIL", phrase, "\n     got:", text.prefix(260)) }
        }
        times.sort()
        print("\(model): \(passed)/\(cases.count) right · median \(String(format: "%.2f", times[times.count / 2]))s · slowest \(String(format: "%.2f", times.last!))s")
    }
}
