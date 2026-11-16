import Foundation

/// The model's steps → one action → checked against the words. The steps here are
/// what qwen3:1.7b really answered for these requests, wrong ones included: the
/// checks have to turn its mistakes away, so nothing it misread ever runs.
@main struct QuickPlanTests {
    static func main() {
        let names = ["Google Chrome", "Safari", "Spotify", "Slack", "Finder", "Notes", "TextEdit", "Cursor", "Claude", "Mail",
                     "System Settings", "T3 Code (Beta)", "Microsoft Word", "Calendar", "Messages", "Reminders"]
        let apps = names.map { AppEntry(name: $0, path: "/Applications/\($0).app") }
        var context = CommandContext(apps: apps)
        context.music = .spotify
        func app(_ name: String) -> AppEntry { apps.first { $0.name == name }! }
        typealias Call = CommandPlanner.Call
        /// The plan, if it would run.
        func run(_ said: String, _ calls: [Call]) -> CommandAction? {
            guard let action = QuickPlan.build(calls, request: said, context: context) else { return nil }
            return QuickPlan.trusted(action, for: said) ? action : nil
        }
        func url(_ text: String) -> URL { URL(string: text)! }

        // The Messi request, said cleanly and said with fillers: straight to his profile, in Chrome.
        let messi = run("open chrome, open instagram and search for messi's profile", [
            Call("open_website", ["site": "instagram", "browser": "chrome"]), Call("open_profile", ["query": "messi','site':'instagram"])])
        assert(messi == .inBrowser(.openURL(url("https://duckduckgo.com/?q=%5Csite:instagram.com%20messi")), app("Google Chrome")), "\(String(describing: messi))")
        assert(QuickPlan.describe(messi!) == ["Open messi’s profile on Instagram in Google Chrome"])
        assert(run("Um, open Chrome and uh, go to Instagram and search for Messi's profile please", [
            Call("open_app", ["app": "Chrome"]), Call("open_website", ["browser": "chrome", "site": "instagram"]),
            Call("open_profile", ["place": "Instagram", "query": "messi"])]) == messi)

        // A search for a profile on a site goes straight to it; covering every part is still required.
        assert(run("open chrome, open instagram and search for messi's profile", [
            Call("open_app", ["app": "Chrome"]), Call("open_website", ["site": "instagram", "browser": "chrome"]), Call("search", ["query": "messi's profile", "site": "google"])]) == messi)
        assert(run("open chrome, open instagram and search for messi's profile", [
            Call("open_website", ["site": "instagram", "browser": "chrome"]), Call("search", ["query": "messi's profile"])]) == messi)
        assert(run("open chrome open instagram search messi profile", [Call("open_website", ["site": "instagram", "browser": "chrome"])]) == nil)
        // The browser you named, even when the model forgot it.
        assert(run("open youtube in safari and search for mkbhd", [Call("open_website", ["site": "youtube"]), Call("search", ["query": "mkbhd"])])
               == .inBrowser(.openURL(url("https://www.youtube.com/results?search_query=mkbhd")), app("Safari")))
        // A site given as a button to click is opened.
        assert(run("hey murmur, open chrome and go to youtube", [Call("open_app", ["app": "Chrome"]), Call("click", ["target": "youtube"])])
               == .inBrowser(.openURL(url("https://www.youtube.com")), app("Google Chrome")))
        // A search folded into "open the site".
        assert(run("open amazon and search for soccer balls", [Call("open_website", ["site": "amazon", "target": "search for soccer balls"])])
               == .openURL(url("https://www.amazon.com/s?k=soccer%20balls")))
        // An empty email isn't what you asked for.
        assert(run("email john saying I'm running late", [Call("email", ["to": "john"])]) == nil)
        assert(run("email john saying I'm running late", [Call("email", ["command": "say", "query": "I'm running late", "to": "john"])]) != nil)

        // A browser in the wrong field is still the browser.
        assert(run("throw open the github website in safari", [Call("open_website", ["site": "github", "target": "safari"])])
               == .inBrowser(.openURL(url("https://github.com")), app("Safari")))
        // A site or player in the wrong field is still where it goes.
        assert(run("search reddit for mechanical keyboards", [Call("search", ["query": "mechanical keyboards", "to": "reddit", "when": "now"])])
               == .openURL(url("https://www.reddit.com/search/?q=mechanical%20keyboards")))
        assert(run("play drake on spotify", [Call("play", ["query": "drake", "to": "spotify", "when": "now"])]) == .play("drake", on: .spotify))
        // …and when it can't be placed, the place you named is missing, so it doesn't run.
        assert(run("search reddit for mechanical keyboards", [Call("search", ["query": "mechanical keyboards"])]) == nil)
        assert(run("play drake on spotify", [Call("play", ["query": "drake", "service": "youtube"])]) == nil)

        // "fire up spotify": the player itself.
        assert(run("fire up spotify", [Call("play", ["service": "spotify"])]) == .openApp(app("Spotify")))
        // Searching right after opening a site searches that site.
        assert(run("open youtube and search lofi beats", [Call("open_website", ["site": "youtube"]), Call("search", ["query": "lofi beats','site':'youtube'}]"])])
               == .openURL(url("https://www.youtube.com/results?search_query=lofi%20beats")))

        // Opening an app, clicking a thread, typing: the words typed are yours, exactly.
        let t3 = run("open t3 code, open the thread called murmur and type fix the build", [
            Call("open_app", ["app": "T3 Code"]), Call("click", ["target": "murmur"]), Call("type_message", ["app": "T3 Code", "text": "fix the build"])])
        assert(t3 == .sequence([.openApp(app("T3 Code (Beta)")), .press("murmur"), .type("fix the build", in: app("T3 Code (Beta)"))]), "\(String(describing: t3))")
        assert(QuickPlan.needsPreview(t3!))
        assert(!QuickPlan.needsPreview(.sequence([.openApp(app("Safari")), .openURL(url("https://github.com"))])))
        assert(run("open claude and ask it what the weather is", [Call("open_app", ["app": "Claude"]), Call("type_message", ["app": "Claude", "text": "what is the weather"])])
               == .sequence([.openApp(app("Claude")), .type("what the weather is", in: app("Claude"))]))
        assert(QuickPlan.snap("what is the weather", to: "open claude and ask it what the weather is") == "what the weather is")
        assert(QuickPlan.snap("Ship it", to: "type ship it tonight") == "ship it")
        assert(QuickPlan.snap("something else entirely", to: "type ship it") == "something else entirely")
        // An in-app "settings" is a click in that app, not System Settings.
        assert(run("open slack and go to settings", [Call("open_app", ["app": "Slack"]), Call("click", ["target": "settings"])])
               == .sequence([.openApp(app("Slack")), .press("settings")]))
        // "go to github" after opening Safari is the site, not a button.
        assert(run("open safari and go to github", [Call("open_website", ["site": "github", "browser": "safari"]), Call("click", ["target": "github"])])
               == .inBrowser(.openURL(url("https://github.com")), app("Safari")))

        // The model repeating itself ("buy milk", "milk", "buy") writes it once.
        assert(run("open notes and write buy milk", [Call("open_app", ["app": "Notes"]), Call("type_message", ["text": "buy milk"]),
                                                     Call("type_message", ["text": "milk"]), Call("type_message", ["text": "buy"])]) == .addNote("buy milk"))

        // Its mistakes never run.
        // "what's on my calendar" is not "lock the screen".
        assert(run("what's on my calendar today", [Call("system", ["command": "show desktop"]), Call("system", ["command": "lock"])]) == nil)
        assert(run("what's on my calendar today", [Call("open_app", ["app": "Calendar"])]) == .openApp(app("Calendar")))
        // "turn the volume up" is up a step, not all the way.
        assert(run("turn the volume up", [Call("set_volume", ["level": "100"])]) == .volume(.up))
        assert(run("turn the volume up", [Call("set_volume", ["change": "down"])]) == nil)
        // "skip this song" is next, never previous; "close this tab" is about what's in front, which is fine.
        assert(run("skip this song", [Call("media", ["command": "previous"])]) == nil)
        assert(run("skip this song", [Call("media", ["command": "next"])]) == .media(.next))
        assert(run("close this tab", [Call("browser_tab", ["command": "close"])]) == .system(.closeTab))
        // Deleting isn't quitting; anything that changes things for good goes to Ask.
        assert(run("delete all my emails", [Call("quit_app", ["app": "Mail"])]) == nil)
        assert(run("book the cheapest flight to tokyo", [Call("search", ["query": "cheapest flight to tokyo"])]) == nil)
        assert(run("book the cheapest flight to tokyo", [Call("cant_do")]) == nil)
        // A file search for "notes" isn't opening Notes; an app it made up isn't opened.
        assert(run("pop open notes", [Call("open_folder", ["folder": "notes", "app": "Notes"])]) == nil)
        assert(run("pop open notes", [Call("open_app", ["app": "Notes"])]) == .openApp(app("Notes")))
        assert(run("open slick", [Call("open_app", ["app": "Slack"])]) == nil)
        // A dropped part means it doesn't run half.
        assert(run("open slack and play drake", [Call("open_app", ["app": "Slack"])]) == nil)
        // About the screen: Ask, which can see it.
        assert(run("open this in safari", [Call("open_app", ["app": "Safari"])]) == nil)
        // Giving up into a web search of the whole sentence isn't a plan.
        assert(run("fix my wifi", [Call("search", ["query": "fix my wifi"])]) == nil)
        // Clicks have to name something you said, and never Send or Delete.
        assert(run("open finder and click downloads", [Call("open_app", ["app": "Finder"]), Call("click", ["target": "documents"])]) == nil)
        assert(run("open mail and click send", [Call("open_app", ["app": "Mail"]), Call("click", ["target": "send"])]) == nil)

        // Everyday ones.
        assert(run("set a timer for 10 minutes", [Call("set_timer", ["minutes": "10"])]) == .timer(seconds: 600, label: "Timer"))
        assert(run("open system settings and go to bluetooth", [Call("open_settings", ["page": "bluetooth"])])
               == .openURL(url("x-apple.systempreferences:com.apple.BluetoothSettings")))
        assert(run("get directions to the airport", [Call("directions", ["place": "airport"])]) == .openURL(url("maps://?daddr=airport")))
        assert(run("make a note that the wifi password is sunflower", [Call("add_note", ["text": "the wifi password is sunflower"])])
               == .addNote("the wifi password is sunflower"))
        assert(run("open microsoft word", [Call("open_app", ["app": "Word"])]) == .openApp(app("Microsoft Word")))
        assert(run("open tee three code", [Call("open_app", ["app": "T3 Code"])]) == .openApp(app("T3 Code (Beta)")))
        assert(QuickPlan.asksFirst(.quitApp("Spotify")))
        assert(QuickPlan.presses(t3!))

        // Names.
        assert(QuickPlan.bare("T3 Code (Beta)") == "T3 Code")
        assert(QuickPlan.bare("Firefox Nightly") == "Firefox")
        assert(QuickPlan.named(app: "Google Chrome", in: "open chrome"))
        assert(!QuickPlan.named(app: "Slack", in: "open slick"))

        // What counts as a question, or a request to click or type.
        assert(AssistantIntent.isQuestion("hey, what does this error mean"))
        assert(AssistantIntent.isQuestion("don't click anything"))
        assert(!AssistantIntent.isQuestion("open slack"))
        assert(AssistantIntent("can you click save").clicks)
        assert(AssistantIntent("okay so please type hello").types)
        assert(AssistantIntent("open spotify").commands)
        assert(!AssistantIntent("why is this slow").clicks)
        assert(AssistantIntent.request("hey murmur can you just open slack") == "open slack")
        print("PASS quick plan tests")
    }
}
