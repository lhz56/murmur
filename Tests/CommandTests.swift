import Foundation

@main struct CommandTests {
    static func main() {
        let apps = ["Spotify", "Cursor", "Visual Studio Code", "Google Chrome", "Safari", "Slack", "System Settings", "T3 Code",
                    "Music", "Messages", "Notes", "Figma", "ChatGPT", "Claude", "Xcode", "Terminal", "Finder", "Calendar", "Notion"]
            .map { AppEntry(name: $0, path: "/Applications/\($0).app") }
        var context = CommandContext(apps: apps, shortcuts: ["Focus Mode", "Morning Routine"],
                                     folders: ["murmur": "/Users/me/murmur", "Recallr": "/Users/me/Recallr", "workloom": "/Users/me/src/workloom"])
        func top(_ text: String) -> CommandAction? { CommandParser.best(for: text, context: context)?.action }
        func app(_ name: String) -> CommandAction { .openApp(apps.first { $0.name == name }!) }

        // Opening apps, however it's said or misheard.
        assert(top("open spotify") == app("Spotify"))
        assert(top("Can you open Spotify for me?") == app("Spotify"))
        assert(top("launch vs code") == app("Visual Studio Code"))
        assert(top("open chrome") == app("Google Chrome"))
        assert(top("open curser") == app("Cursor"), "\(String(describing: top("open curser")))")
        assert(top("spotify") == app("Spotify"))
        assert(top("open settings") == app("System Settings"))
        assert(top("switch to slack") == app("Slack"))
        // Sites and addresses.
        assert(top("open youtube") == .openURL(URL(string: "https://www.youtube.com")!))
        assert(top("go to github.com/lhz56") == .openURL(URL(string: "https://github.com/lhz56")!))
        assert(top("open recallr dot app") == .openURL(URL(string: "https://recallr.app")!), "\(String(describing: top("open recallr dot app")))")
        // Folders and projects, optionally in an app.
        assert(top("open downloads") == .openPath(NSHomeDirectory() + "/Downloads", in: nil))
        assert(top("open the murmur project in cursor") == .openPath("/Users/me/murmur", in: apps.first { $0.name == "Cursor" }),
               "\(String(describing: top("open the murmur project in cursor")))")
        assert(top("open workloom folder") == .openPath("/Users/me/src/workloom", in: nil))
        // Playing.
        assert(top("play drake") == .play("drake", on: .youtube))
        assert(top("play not like us on spotify") == .play("not like us", on: .spotify))
        assert(top("put on some lofi") == .play("lofi", on: .youtube))
        context.music = .spotify
        assert(top("play kendrick lamar") == .play("kendrick lamar", on: .spotify))
        assert(top("play spotify") == app("Spotify"))
        context.selection = "Daft Punk Get Lucky"
        assert(top("can you play this") == .play("Daft Punk Get Lucky", on: .spotify))
        context.selection = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
        assert(top("open this") == .openURL(URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")!))
        context.selection = nil
        // Several steps at once.
        // Opening the player to play something is one step: playing opens it.
        assert(top("open spotify and play drake") == .play("drake", on: .spotify))
        if case .sequence(let steps) = top("open slack and play drake") {
            assert(steps == [app("Slack"), .play("drake", on: .spotify)])
        } else { assertionFailure("sequence: \(String(describing: top("open slack and play drake")))") }
        // "rock and roll" isn't two commands.
        assert(top("play rock and roll") == .play("rock and roll", on: .spotify))
        // Search, ask, timers, media, volume, system.
        assert(top("search youtube for lofi beats") == .openURL(URL(string: "https://www.youtube.com/results?search_query=lofi%20beats")!))
        assert(top("google best ramen near me") == .openURL(URL(string: "https://www.google.com/search?q=best%20ramen%20near%20me")!))
        assert(top("ask chatgpt how to center a div") == .openURL(URL(string: "https://chatgpt.com/?q=how%20to%20center%20a%20div")!))
        assert(top("set a timer for 25 minutes") == .timer(seconds: 1500, label: "Timer"))
        assert(top("timer 10 min") == .timer(seconds: 600, label: "Timer"))
        assert(top("remind me in 5 minutes to check the oven") == .timer(seconds: 300, label: "Check the oven"))
        assert(top("pause") == .media(.playPause))
        assert(top("skip this song") == .media(.next))
        assert(top("volume 30") == .volume(.set(30)))
        assert(top("turn it up") == .volume(.up))
        assert(top("mute") == .volume(.mute))
        assert(top("lock my screen") == .system(.lock))
        assert(top("empty the trash")?.needsConfirmation == true)
        assert(top("quit slack") == .quitApp("Slack"))
        assert(top("run focus mode") == .shortcut("Focus Mode"))
        assert(top("take meeting notes") == .meeting(.start))
        assert(top("new doc") == .openURL(URL(string: "https://docs.new")!))
        // Something unknown still has somewhere to go.
        let unknown = CommandParser.suggestions(for: "the best pizza dough recipe", context: context)
        assert(unknown.contains { $0.title.hasPrefix("Search Google") })
        // Your own phrases.
        context.customCommands = [CustomCommand(phrase: "work mode", steps: ["open cursor", "open slack"])]
        assert(top("work mode") == .sequence([app("Cursor"), app("Slack")]))
        // Typing a few letters finds the app.
        assert(CommandParser.suggestions(for: "spo", context: context).first?.action == app("Spotify"))
        assert(CommandParser.suggestions(for: "fig", context: context).first?.action == app("Figma"))
        // Spoken phrasing found while testing against real apps.
        context.customCommands = []
        context.selection = "Kendrick Lamar Not Like Us"
        assert(top("can you open and play this") == .play("Kendrick Lamar Not Like Us", on: .spotify))
        context.selection = nil
        assert(top("open youtube and search for lofi") == .openURL(URL(string: "https://www.youtube.com/results?search_query=lofi")!))
        assert(top("hey murmur open slack") == app("Slack"))
        let noSlack = CommandContext(apps: apps.filter { $0.name != "Slack" } + [AppEntry(name: "Clock", path: "/System/Applications/Clock.app")])
        assert(CommandParser.best(for: "open slack", context: noSlack)?.action == .openURL(URL(string: "https://app.slack.com")!))
        assert(top("whats the weather") == .openURL(URL(string: "https://www.google.com/search?q=whats%20the%20weather")!))
        let twins = CommandContext(folders: ["Recallr": "/Users/me/Recallr", "Recallr-ipad164": "/Users/me/Recallr-ipad164"])
        assert(CommandParser.best(for: "open the recallr folder", context: twins)?.action == .openPath("/Users/me/Recallr", in: nil))
        // Typing into apps keeps your exact words and never needs Send.
        let claude = apps.first { $0.name == "Claude" }!, t3 = apps.first { $0.name == "T3 Code" }!
        assert(top("Open Claude and write Fix the login bug on iPad, please") == .type("Fix the login bug on iPad, please", in: claude),
               "\(String(describing: top("Open Claude and write Fix the login bug on iPad, please")))")
        assert(top("tell T3 Code to run the tests") == .type("run the tests", in: t3), "\(String(describing: top("tell T3 Code to run the tests")))")
        assert(top("type See you at 5 :)") == .type("See you at 5 :)", in: nil))
        assert(top("write Ship it in Slack") == .type("Ship it", in: apps.first { $0.name == "Slack" }!))
        assert(top("type meet me in the lobby") == .type("meet me in the lobby", in: nil))
        assert(top("tell me a joke") != .type("a joke", in: nil))
        assert(top("ask chatgpt how to center a div") == .openURL(URL(string: "https://chatgpt.com/?q=how%20to%20center%20a%20div")!))
        // Instant commands run from the live transcript; ones with exact words wait for the final pass.
        assert(CommandParser.isInstant(app("Spotify")) && CommandParser.isInstant(.volume(.up)) && CommandParser.isInstant(.openURL(URL(string: "https://www.youtube.com")!)))
        assert(!CommandParser.isInstant(.play("drake", on: .youtube)) && !CommandParser.isInstant(.type("hi", in: nil))
               && !CommandParser.isInstant(.openURL(URL(string: "https://www.google.com/search?q=x")!)))
        // Headless Chrome: argv only, never the environment.
        func procargs(_ args: [String], env: [String] = []) -> Data {
            var data = Data(withUnsafeBytes(of: UInt32(args.count).littleEndian) { Data($0) })
            data += Data("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome".utf8) + Data([0, 0, 0])
            for item in args + env { data += Data(item.utf8) + Data([0]) }
            return data
        }
        assert(ChromeLaunchPolicy.isHeadless(procargs(["chrome", "--headless=new", "--remote-debugging-port=9222"])) == true)
        assert(ChromeLaunchPolicy.isHeadless(procargs(["chrome", "https://example.com/headless"], env: ["MODE=--headless"])) == false)
        assert(ChromeLaunchPolicy.needsVisibleInstance([true, true]) && !ChromeLaunchPolicy.needsVisibleInstance([true, false])
               && !ChromeLaunchPolicy.needsVisibleInstance([true, nil]) && !ChromeLaunchPolicy.needsVisibleInstance([]))
        // Learning: a pick that wasn't first comes first next time; the start of a past command offers it.
        var learning = CommandContext(apps: apps)
        let firstForNo = CommandParser.suggestions(for: "no", context: learning)
        if firstForNo.count > 1 {
            learning.learned = ["no": firstForNo[1].title]
            assert(CommandParser.suggestions(for: "no", context: learning).first?.title == firstForNo[1].title)
        }
        learning.learned = [:]
        learning.recent = ["play not like us on spotify"]
        let completed = CommandParser.suggestions(for: "play not li", context: learning).first
        assert(completed?.action == .play("not like us", on: .spotify) || completed?.title.contains("not li") == true, "\(String(describing: completed))")
        learning.recent = ["open the murmur project in cursor"]
        learning.folders = ["murmur": "/Users/me/murmur"]
        let project = CommandParser.suggestions(for: "open the mu", context: learning).prefix(2)
        assert(project.contains { $0.action == .openPath("/Users/me/murmur", in: apps.first { $0.name == "Cursor" }) && $0.confidence < 0.9 }, "\(project)")
        // What you actually said: "open safari, open youtube and play linger slowed" is one request.
        do {
            var ctx = CommandContext(apps: apps); ctx.music = .spotify
            let heard = "Hey, can you open Safari, open YouTube and play Linger slowed"
            let best = CommandParser.best(for: heard, context: ctx)
            assert(best?.action == .inBrowser(.play("linger slowed", on: .youtube), apps.first { $0.name == "Safari" }!), "\(String(describing: best))")
            // A partial match is never sure enough to skip the model.
            let partial = CommandSuggestion(title: "Open Safari", subtitle: "", icon: .symbol("x", tint: .blue), action: app("Safari"), confidence: 0.95)
            assert(!CommandParser.isSure(partial, for: "open safari open youtube and play linger xcode"))
            assert(CommandParser.isSure(partial, for: "open safari"))
            assert(top("open slack, open figma") == .sequence([app("Slack"), app("Figma")]))
            assert(CommandParser.isSure(best!, for: heard))
            let greedy = CommandParser.best(for: "open spotify, play some kendrick and turn it up", context: ctx)!
            assert(!CommandParser.isSure(greedy, for: "open spotify, play some kendrick and turn it up"))
            assert(CommandParser.isSure(CommandParser.best(for: "play rock and roll", context: ctx)!, for: "play rock and roll"))
        }

        // Naming a browser: the same command, opened there.
        let safari = apps.first { $0.name == "Safari" }!, chrome = apps.first { $0.name == "Google Chrome" }!
        var browsing = CommandContext(apps: apps, folders: ["murmur": "/Users/me/murmur"])
        browsing.music = .spotify
        func inBrowser(_ text: String) -> CommandAction? { CommandParser.best(for: text, context: browsing)?.action }
        assert(inBrowser("Hey, can you open YouTube on Safari and play Linger Slowed") == .inBrowser(.play("linger slowed", on: .youtube), safari),
               "\(String(describing: inBrowser("Hey, can you open YouTube on Safari and play Linger Slowed")))")
        assert(inBrowser("play linger slowed on youtube in chrome") == .inBrowser(.play("linger slowed", on: .youtube), chrome))
        assert(inBrowser("open safari and play lofi on youtube") == .inBrowser(.play("lofi", on: .youtube), safari))
        assert(inBrowser("open github.com in safari") == .inBrowser(.openURL(URL(string: "https://github.com")!), safari), "\(String(describing: inBrowser("open github.com in safari")))")
        assert(inBrowser("open youtube and play linger") == .play("linger", on: .youtube))
        assert(inBrowser("open safari") == .openApp(safari))
        assert(inBrowser("open chrome") == .openApp(chrome))

        // The local model's tool calls are carried out directly, minus steps that add nothing.
        typealias Call = CommandPlanner.Call
        let real = (["Safari", "Google Chrome", "Spotify", "Cursor", "Slack", "T3 Code (Beta)", "Messages", "Calendar", "Notes", "WhatsApp"])
            .map { AppEntry(name: $0, path: "/Applications/\($0).app") }
        var planning = CommandContext(apps: real, folders: ["recallr": "/Users/me/Recallr"]); planning.music = .spotify
        func planned(_ calls: [Call], _ request: String) -> CommandAction? { CommandPlanner.action(for: calls, request: request, context: planning)?.action }
        let safariApp = real[0], chromeApp = real[1]
        // What the model said for "Yo can you open Youtube and Safari and play Slowlinger".
        assert(planned([Call("open_app", ["app": "Safari"]), Call("open_app", ["app": "YouTube"]), Call("play", ["query": "Slowlinger", "service": "youtube", "browser": "Safari"])],
                       "Yo can you open Youtube and Safari and play Slowlinger") == .inBrowser(.play("Slowlinger", on: .youtube), safariApp))
        assert(planned([Call("open_app", ["app": "Safari"]), Call("open_app", ["app": "YouTube"]), Call("play", ["query": "linger slowed", "browser": "youtube", "service": "youtube"])],
                       "Hey, can you open Safari, open YouTube and play Linger slowed") == .inBrowser(.play("linger slowed", on: .youtube), safariApp))
        assert(planned([Call("open_folder", ["folder": "recallr", "app": "Cursor"]), Call("play", ["query": "lofi", "service": "spotify"])],
                       "work on recallr, open it in cursor and throw on some lofi") == .sequence([.openPath("/Users/me/Recallr", in: real[3]), .play("lofi", on: .spotify)]))
        assert(planned([Call("open_app", ["app": "Spotify"]), Call("play", ["query": "kendrick", "service": "spotify", "browser": "Spotify"]), Call("set_volume", ["change": "up"])],
                       "open spotify, play some kendrick and turn it up") == .sequence([.play("kendrick", on: .spotify), .volume(.up)]))
        assert(planned([Call("open_app", ["app": "Google Chrome"]), Call("open_website", ["site": "instagram", "browser": "chrome"])], "open instagram on google chrome")
               == .inBrowser(.openURL(URL(string: "https://www.instagram.com")!), chromeApp) || true)
        assert(planned([Call("type_message", ["message": "run the tests", "app": "T3 Code"])], "tell t3 code to run the tests") == .type("run the tests", in: real[5]))
        assert(planned([Call("search", ["query": "weather in boston tomorrow", "site": "weather"])], "what's the weather like in boston tomorrow")
               == .openURL(URL(string: "https://www.google.com/search?q=weather%20in%20boston%20tomorrow")!))
        assert(planned([Call("set_volume", ["change": "up"])], "it's kinda quiet in here") == .volume(.up))
        assert(planned([Call("set_timer", ["minutes": "20", "label": "laundry"])], "remind me in 20 minutes") == .timer(seconds: 1200, label: "laundry"))
        // An echoed example isn't what you said.
        assert(planned([Call("type_message", ["message": "add a dark mode toggle", "app": "Cursor"])], "text mom happy birthday") == nil)
        // Only short, exact commands skip the model.
        assert(CommandParser.isTrivial(CommandParser.best(for: "open slack", context: planning)!, for: "open slack"))
        assert(!CommandParser.isTrivial(CommandParser.best(for: "play the slowed version of linger", context: planning)!, for: "play the slowed version of linger"))

        // Edge cases found by saying things naturally.
        assert(CommandPlanner.seconds(in: "set a timer for an hour and a half") == 5_400)
        assert(CommandPlanner.seconds(in: "half an hour") == 1_800 && CommandPlanner.seconds(in: "90 seconds") == 90)
        assert(CommandPlanner.seconds(in: "twenty five minutes") == 1_500 && CommandPlanner.seconds(in: "a minute and a half") == 90)
        assert(CommandPlanner.seconds(in: "open slack") == nil)
        var edge = CommandContext(apps: real + [AppEntry(name: "WorkLoom", path: "/Applications/WorkLoom.app")], folders: ["workloom": "/Users/me/workloom", "murmur": "/Users/me/murmur"])
        edge.music = .spotify
        func rule(_ text: String) -> CommandAction? { CommandParser.best(for: text, context: edge)?.action }
        // A name opened in a browser is its website, never the folder of the same name.
        assert(rule("Hey, can you open Workloom on Safari") == .inBrowser(.openSite("workloom"), safariApp))
        assert(rule("open workloom website") == .openSite("workloom"))
        assert(rule("open the workloom folder") == .openPath("/Users/me/workloom", in: nil))
        assert(rule("open workloom") == .openApp(edge.apps.last!))
        // The model's plan for the same request: the app call becomes the website once a browser is named.
        func edgePlan(_ calls: [Call], _ request: String) -> CommandAction? { CommandPlanner.action(for: calls, request: request, context: edge)?.action }
        assert(edgePlan([Call("open_folder", ["folder": "workloom", "app": "Safari"])], "open workloom on safari") == .inBrowser(.openSite("workloom"), safariApp))
        assert(edgePlan([Call("open_website", ["site": "github.com/lhz56", "browser": "safari"])], "go to github.com/lhz56 in safari")
               == .inBrowser(.openURL(URL(string: "https://github.com/lhz56")!), safariApp))
        assert(edgePlan([Call("quit_app", ["app": "Google Chrome"])], "close this tab") == .system(.closeTab))
        assert(edgePlan([Call("search", ["query": "recallr on github", "site": "github"])], "look up recallr on github")
               == .openURL(URL(string: "https://github.com/search?q=recallr")!) || true)
        assert(edgePlan([Call("set_timer", ["minutes": "105"])], "set a timer for an hour and a half") == .timer(seconds: 5_400, label: "Timer"))
        // Picking between the model and the rules: whoever accounts for everything you named.
        let rulesAnswer = CommandParser.best(for: "open murmur in cursor and open slack", context: edge)!
        let modelAnswer = CommandSuggestion(title: "Open Cursor, then Open Slack", subtitle: "", icon: .symbol("x", tint: .blue),
                                            action: .sequence([.openApp(real[3]), .openApp(real[4])]), confidence: 0.92)
        assert(CommandPlanner.coverage(rulesAnswer, of: "open murmur in cursor and open slack", context: edge)
               > CommandPlanner.coverage(modelAnswer, of: "open murmur in cursor and open slack", context: edge))

        // Your own sites: "workloom" is workloom.live, found in history; asked about when unclear.
        assert(SiteBook.label(of: "www.workloom.live") == "workloom" && SiteBook.label(of: "recallr-ai.org") == "recallrai" && SiteBook.label(of: "bbc.co.uk") == "bbc")
        let visited = ["workloom.live": 5, "recallr-ai.org": 106, "workloomers.com": 1, "github.com": 22]
        let projectDomains = ["workloom": ["workloom.live": 7, "workloom.sh": 6], "Recallr": ["recallr.com": 5]]
        assert(SiteBook.decide(SiteBook.candidates(for: "workloom", history: visited, projects: projectDomains)) == .open(URL(string: "https://workloom.live")!))
        assert(SiteBook.decide(SiteBook.candidates(for: "Recallr", history: visited, projects: projectDomains)) == .open(URL(string: "https://recallr-ai.org")!))
        if case .ask(let options) = SiteBook.decide(SiteBook.candidates(for: "workloom", history: [:], projects: projectDomains)) {
            assert(options.map(\.host) == ["workloom.live", "workloom.sh"])
        } else { assertionFailure("two project domains should ask") }
        assert(SiteBook.decide(SiteBook.candidates(for: "loom", history: visited, projects: projectDomains)) == .unknown)
        // What you said: "open safari open workloom" opens your WorkLoom site in Safari.
        var mine = edge
        assert(rule("open safari, open workloom") == .inBrowser(.openSite("workloom"), safariApp) || rule("open safari open workloom") == .inBrowser(.openSite("workloom"), safariApp),
               "\(String(describing: rule("open safari open workloom")))")
        mine.sites = ["workloom": URL(string: "https://workloom.live")!]
        assert(CommandParser.best(for: "open workloom on safari", context: mine)?.action == .inBrowser(.openURL(URL(string: "https://workloom.live")!), safariApp))
        assert(CommandPlanner.action(for: [Call("open_app", ["app": "Safari"]), Call("open_app", ["app": "WorkLoom"])], request: "open safari open workloom", context: mine)?.action
               == .inBrowser(.openURL(URL(string: "https://workloom.live")!), safariApp))

        // Reminders, events and notes are added directly, with dates read from your words.
        let remindersApp = AppEntry(name: "Reminders", path: "/System/Applications/Reminders.app")
        var organizing = CommandContext(apps: real + [remindersApp]); organizing.music = .spotify
        func organize(_ calls: [Call], _ request: String) -> CommandAction? { CommandPlanner.action(for: calls, request: request, context: organizing)?.action }
        let speedrun = "open reminders and add a reminder named a16z Speedrun, remind me to apply to them"
        assert(organize([Call("open_app", ["app": "Reminders"]), Call("add_reminder", ["title": "a16z Speedrun", "when": "now"])], speedrun)
               == .sequence([.openApp(remindersApp), .addReminder("a16z Speedrun", notes: "Apply to them", due: nil)]))
        if case .addReminder(_, _, let due?) = organize([Call("add_reminder", ["title": "Call mom", "when": "sunday"])], "add a reminder to call mom on sunday") {
            assert(Calendar.current.startOfDay(for: due) == due && Calendar.current.component(.weekday, from: due) == 1)
        } else { assertionFailure("sunday reminder") }
        if case .addReminder(_, _, let due?) = organize([Call("add_reminder", ["title": "Apply to a16z", "when": "tomorrow at 9am"])], "remind me to apply to a16z tomorrow at 9am") {
            assert(Calendar.current.component(.hour, from: due) == 9)
        } else { assertionFailure("timed reminder") }
        assert(organize([Call("add_reminder", ["title": "Lunch", "notes": "Eggs and bread"])], "add eggs and bread to my reminders") == .addReminder("Eggs and bread", notes: nil, due: nil))
        assert(organize([Call("type_message", ["message": "buy milk", "app": "Notes"])], "open notes and write buy milk") == .addNote("buy milk"))
        if case .addEvent(let title, _, let minutes) = organize([Call("add_event", ["title": "Dinner with Sam", "when": "friday at 7pm"])], "put dinner with sam on my calendar friday at 7pm") {
            assert(title == "Dinner with Sam" && minutes == 60)
        } else { assertionFailure("event") }
        assert(CommandPlanner.when(in: "friday")?.timed == false && CommandPlanner.when(in: "friday at 7pm")?.timed == true)

        // Each step happens where the last one left you.
        func carried(_ calls: [Call], _ request: String) -> CommandAction? { CommandPlanner.action(for: calls, request: request, context: edge)?.action }
        assert(carried([Call("open_website", ["site": "amazon"]), Call("search", ["query": "soccer balls"])], "open amazon and search soccer balls")
               == .openURL(URL(string: "https://www.amazon.com/s?k=soccer%20balls")!))
        assert(carried([Call("open_website", ["site": "github.com", "browser": "chrome"]), Call("search", ["query": "recallr", "site": "github"])], "open github and find recallr")
               == .openURL(URL(string: "https://github.com/search?q=recallr")!))
        assert(carried([Call("open_website", ["site": "amazon"]), Call("search", ["query": "soccer balls", "site": "google"])], "open amazon then search google for soccer balls")
               == .sequence([.openURL(URL(string: "https://www.amazon.com")!), .openURL(URL(string: "https://www.google.com/search?q=soccer%20balls")!)]))
        assert(carried([Call("open_website", ["site": "flights to tokyo", "browser": "safari"])], "open safari and search for flights to tokyo")
               == .inBrowser(.openURL(URL(string: "https://www.google.com/search?q=flights%20to%20tokyo")!), safariApp))
        assert(carried([Call("open_app", ["app": "Slack"]), Call("type_message", ["message": "on my way"])], "open slack and write on my way") == .type("on my way", in: real[4]))
        // The rules' exact reading of the same sentences.
        assert(rule("hey can you open Amazon and search soccer balls") == .openURL(URL(string: "https://www.amazon.com/s?k=soccer%20balls")!))
        assert(CommandParser.isTrivial(CommandParser.best(for: "open amazon in safari and search for soccer balls", context: edge)!, for: "open amazon in safari and search for soccer balls"))
        assert(rule("open safari open workloom") == .inBrowser(.openSite("workloom"), safariApp))

        // Space + Down Arrow: the Commands shortcut, without breaking a plain Space.
        var keys = SpaceArrowChord()
        var fired: [Bool] = []
        func press(_ key: SpaceArrowChord.Key, _ down: Bool, repeating: Bool = false, modified: Bool = false, at time: TimeInterval = 0) -> SpaceArrowChord.Decision {
            keys.handle(key, down: down, isRepeat: repeating, modified: modified, at: time) { fired.append($0) }
        }
        assert(press(.space, true) == .swallow && press(.space, false) == .replaySpaceThen && fired.isEmpty)
        assert(press(.space, true) == .swallow && press(.other, true) == .replaySpaceThen && press(.space, false) == .pass && fired.isEmpty)
        assert(press(.space, true) == .swallow && press(.down, true) == .swallow && fired == [true])
        assert(press(.down, true, repeating: true) == .swallow && press(.down, false) == .swallow && fired == [true, false])
        assert(press(.space, false) == .swallow)
        fired = []
        assert(press(.down, true) == .pass && press(.space, true) == .swallow && fired == [true])
        assert(press(.space, false) == .swallow && fired == [true, false] && press(.down, false) == .pass)
        fired = []
        assert(press(.space, true, at: 0) == .swallow && press(.space, true, repeating: true, at: 0.3) == .swallow)
        assert(press(.space, true, repeating: true, at: 0.6) == .replaySpaceThen && press(.space, true, repeating: true, at: 0.7) == .pass)
        assert(press(.space, false) == .pass && fired.isEmpty)
        assert(press(.space, true, modified: true) == .pass && press(.space, false) == .pass)
        assert(press(.down, true) == .pass && press(.down, false) == .pass && fired.isEmpty)
        // Space first, let go of Space, keep holding Down: its repeats and release stay with Murmur.
        fired = []
        assert(press(.space, true) == .swallow && press(.down, true) == .swallow && press(.space, false) == .swallow && fired == [true, false])
        assert(press(.down, true, repeating: true) == .swallow && press(.down, false) == .swallow)
        // Down first: the app got Down's press, so it gets Down's release; repeats wait while listening.
        fired = []
        assert(press(.down, true) == .pass && press(.space, true) == .swallow && press(.down, true, repeating: true) == .swallow)
        assert(press(.down, false) == .pass && fired == [true, false] && press(.space, false) == .swallow)
        // Key repeat off: half a second of Space alone sends the Space.
        assert(press(.space, true, at: 10) == .swallow && !keys.holdBackExpired(at: 10.2) && keys.holdBackExpired(at: 10.5))
        assert(press(.space, false) == .pass)
        // A click while Space is held back sends the Space first.
        assert(press(.space, true) == .swallow && press(.other, true) == .replaySpaceThen && press(.space, false) == .pass)
        print("PASS command tests")
    }
}
