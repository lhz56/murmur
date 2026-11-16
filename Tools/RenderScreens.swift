import SwiftUI
import AppKit

// Renders Murmur's main screens with sample data to PNGs, for checking the
// design and for the README. Run: Tools/RenderScreens.sh OUTPUT_DIR

@main struct RenderScreens {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        NaturalVoice.helperOverride = URL(fileURLWithPath: "Resources/Helpers/MurmurVoice")
        let model = AppModel(preview: true)
        model.meetings.seed(sampleMeetings())

        func shoot<V: View>(_ name: String, _ view: V, size: CGSize, dark: Bool = false) {
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
            host.frame = NSRect(origin: .zero, size: size)
            window.contentView = host
            window.orderFrontRegardless()
            for _ in 0..<8 { RunLoop.main.run(until: Date().addingTimeInterval(0.08)) }
            let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: rep)
            try! rep.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name + ".png"))
            window.orderOut(nil)
        }
        let size = CGSize(width: 1240, height: 800)
        model.section = .meetings
        shoot("meetings-notes", MainView(model: model), size: size)
        shoot("meetings-notes-dark", MainView(model: model), size: size, dark: true)
        var live = sampleMeetings()[0]
        live.id = UUID(); live.status = .live; live.notes = nil; live.endedAt = nil; live.createdAt = Date().addingTimeInterval(-754)
        live.myNotes = "- retention numbers?\n- ask about launch timing"
        model.meetings.seed([live] + sampleMeetings())
        shoot("meetings-live", MainView(model: model), size: size)
        live.chat = [.init(question: "Catch me up", answer: "• Dana walked through Q3 retention: 41% at day 30, up from 33%.\n• You agreed the import step is the biggest drop-off.\n• Open question: launch before or after the pricing change.")]
        model.meetings.seed([live] + sampleMeetings())
        shoot("meetings-live-ask", MainView(model: model), size: size)
        var partial = sampleMeetings()[0].notes!
        partial.actionItems = []; partial.decisions = []
        partial.sections = Array(partial.sections.prefix(1))
        shoot("notes-streaming", VStack(alignment: .leading, spacing: 14) { WritingStatus(step: "Writing…"); NotesView(notes: partial, onToggle: { _ in }, writing: true); Spacer() }.padding(40), size: CGSize(width: 760, height: 520))
        model.meetings.seed(sampleMeetings())
        model.meetings.selectedID = nil
        shoot("meetings-home", MainView(model: model), size: size)
        model.section = .commands
        shoot("commands", MainView(model: model), size: size)
        model.section = .transcripts
        shoot("dictations", MainView(model: model), size: size)
        let asks = model.assistant
        asks.seed(phase: .idle, recent: [
            .init(question: "Where do I turn on automatic signing?", answer: "Click Signing & Capabilities, then tick Automatically manage signing.",
                  date: Date().addingTimeInterval(-900), provider: "ChatGPT · GPT-6.1 Sol"),
            .init(question: "What's this error about?", answer: "Swift can’t find AssistantCenter because the file isn’t in the build list. Add it to build.sh and it’ll compile.",
                  date: Date().addingTimeInterval(-5400), provider: "ChatGPT · GPT-6.1 Sol")])
        model.section = .home
        shoot("home", MainView(model: model), size: size)
        shoot("home-dark", MainView(model: model), size: size, dark: true)
        model.settingsPane = .assistant
        shoot("settings-ask", SettingsView(model: model, preferences: model.preferences, speech: model.speech, microphoneCheck: model.microphoneCheck, initialPane: .assistant), size: CGSize(width: 780, height: 600))
        shoot("settings-ask-voice", ScrollView { Form { VoiceSettings(center: model.assistant, natural: model.assistant.natural) }.formStyle(.grouped) }, size: CGSize(width: 580, height: 330))
        shoot("settings-dictation", SettingsView(model: model, preferences: model.preferences, speech: model.speech, microphoneCheck: model.microphoneCheck, initialPane: .dictation), size: CGSize(width: 780, height: 600))
        let desk = LinearGradient(colors: [Color(red: 0.16, green: 0.2, blue: 0.3), Color(red: 0.36, green: 0.28, blue: 0.38)], startPoint: .topLeading, endPoint: .bottomTrailing)
        func bubble(_ name: String) {
            shoot(name, ZStack(alignment: .topLeading) {
                desk
                Image(systemName: "cursorarrow").font(.system(size: 22)).foregroundStyle(.white).shadow(radius: 2).offset(x: 40, y: 30)
                AssistantBubble(center: asks, speech: model.speech).offset(x: 58, y: 54)
            }, size: CGSize(width: 520, height: 420))
        }
        let plan = ["Open T3 Code", "Click “launch notes”", "Type “ship it tonight” in T3 Code"]
        asks.seed(phase: .thinking, heard: "open t3 code", plan: plan, planAt: 1)
        bubble("ask-steps-running")
        asks.seed(phase: .done, heard: "open t3 code", outcomes: [.init(title: "Done", problem: nil)], plan: plan, planAt: 2)
        bubble("ask-steps-done")
        asks.seed(phase: .done, heard: "open t3 code", outcomes: [.init(title: "", problem: "Couldn’t find “launch notes” on screen.")], plan: plan, planAt: 1)
        bubble("ask-steps-problem")
        model.speech.liveText = "where do I turn on automatic signing"
        asks.seed(phase: .listening)
        bubble("ask-listening")
        asks.seed(phase: .thinking, heard: "Where do I turn on automatic signing?")
        bubble("ask-thinking")
        asks.seed(phase: .done, heard: "Open Spotify and play something chill, then tell me what this error means",
                  answer: "Playing a chill mix on Spotify. The error says Swift can’t find AssistantCenter, because that file isn’t in the build. Add it to build.sh and it’ll compile.",
                  outcomes: [.init(title: "Played chill on Spotify", problem: nil)])
        bubble("ask-answer")
        asks.seed(phase: .failed("Codex isn’t signed in. Open Terminal, run “codex login”, and sign in with ChatGPT."), heard: "What's on my screen?")
        bubble("ask-failed")
        model.speech.liveText = ""
        asks.seed(phase: .idle)

        let backdrop = LinearGradient(colors: [Color(red: 0.2, green: 0.25, blue: 0.4), Color(red: 0.45, green: 0.3, blue: 0.4)], startPoint: .topLeading, endPoint: .bottomTrailing)
        let center = model.commands
        center.prepare()
        center.query = "open spotify and play drake"
        for _ in 0..<10 { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        shoot("palette-typed", ZStack(alignment: .top) { backdrop; CommandPaletteView(center: center, speech: model.speech) }, size: CGSize(width: 760, height: 560))
        center.query = ""
        shoot("palette-home", ZStack(alignment: .top) { backdrop; CommandPaletteView(center: center, speech: model.speech) }, size: CGSize(width: 760, height: 560))
        model.meetings.detected = .init(app: "Google Meet", bundleID: "com.google.Chrome", event: nil)
        shoot("meeting-prompt", ZStack(alignment: .topTrailing) { backdrop; MeetingPromptView(center: model.meetings) }, size: CGSize(width: 440, height: 120))
        for step in OnboardingView.Step.allCases {
            shoot("onboarding-\(step.rawValue)", OnboardingView(model: model, preferences: model.preferences, speech: model.speech, step: step), size: CGSize(width: 600, height: 520))
        }
        func healthSample(_ free: Double, swap: Double, swapTotal: Double, pressure: Int32 = 1, ago: TimeInterval = 0) -> HealthSample {
            let gb = Double(MacHealthRules.gigabyte)
            return HealthSample(date: Date().addingTimeInterval(-ago), freeDisk: UInt64(free * gb), swapUsed: UInt64(swap * gb),
                                swapTotal: UInt64(swapTotal * gb), pressure: pressure, totalDisk: UInt64(460 * gb))
        }
        let biggest = [("T3 Code (Beta)", 3.4), ("Web pages", 2.1), ("Google Chrome for Testing", 1.9), ("Claude", 1.5), ("node", 0.7)]
            .map { HealthProcess(name: $0.0, footprint: UInt64($0.1 * Double(MacHealthRules.gigabyte))) }
        func seedHealth(start: Double, end: Double, swap: Double, swapTotal: Double, pressure: Int32 = 1) {
            let trend = stride(from: 3600.0, through: 0, by: -30).map { ago -> HealthSample in
                let progress = 1 - ago / 3600
                let eased = progress * progress * (1 + 0.04 * sin(progress * 22))
                return healthSample(start + (end - start) * eased, swap: swap * (0.72 + 0.28 * progress), swapTotal: swapTotal, pressure: pressure, ago: ago)
            }
            let gb = Double(MacHealthRules.gigabyte)
            let pulse = (0..<45).map { index -> MacVitals in
                var vitals = MacVitals()
                vitals.cpu = 0.22 + 0.16 * sin(Double(index) / 4) + 0.08 * sin(Double(index) * 1.7)
                return vitals
            }
            var vitals = pulse.last!
            vitals.memoryTotal = UInt64(16 * gb); vitals.appMemory = UInt64(7.8 * gb); vitals.wired = UInt64(2.4 * gb)
            vitals.compressed = UInt64((pressure > 1 ? 4.1 : 1.6) * gb)
            vitals.thermal = pressure > 1 ? 1 : 0; vitals.uptime = 3 * 86400 + 5 * 3600
            vitals.battery = .init(percent: 76, charging: false, pluggedIn: false, health: 91, cycles: 214, minutesLeft: 312)
            let busiest = [("T3 Code (Beta)", 64.0), ("Google Chrome", 38.0), ("WindowServer", 21.0), ("ollama", 12.0), ("Murmur", 4.0)]
                .map { HealthProcess(name: $0.0, footprint: UInt64($0.1 * 100)) }
            model.health.seed(trend.last!, trend: trend, biggest: biggest, vitals: vitals, pulse: pulse, busiest: busiest,
                              models: [LoadedModel(name: "qwen3:1.7b", bytes: UInt64(1.9 * gb), until: Date().addingTimeInterval(1500))],
                              murmur: UInt64(0.31 * gb))
        }
        func healthPane(_ name: String, dark: Bool = false, checkup: String = "") {
            shoot(name, MacHealthView(health: model.health, preferences: model.preferences, assistant: model.assistant, live: false, checkup: checkup),
                  size: CGSize(width: 900, height: 1900), dark: dark)
        }
        seedHealth(start: 19, end: 11, swap: 5.2, swapTotal: 6)
        healthPane("health-danger")
        healthPane("health-danger-dark", dark: true)
        shoot("health-swap", MacHealthView(health: model.health, preferences: model.preferences, live: false, metric: .swap), size: CGSize(width: 900, height: 1900))
        seedHealth(start: 96, end: 88, swap: 2.4, swapTotal: 6)
        healthPane("health-ok")
        healthPane("health-ok-dark", dark: true, checkup: "Your Mac is in great shape: plenty of disk, memory is calm and it’s running cool. The one thing worth knowing is T3 Code is the busiest app right now, using about two thirds of a core. Nothing to do.")
        seedHealth(start: 22, end: 13, swap: 3.1, swapTotal: 6)
        healthPane("health-warning")
        model.section = .health
        shoot("health-window", MainView(model: model), size: CGSize(width: 1180, height: 820))
        model.section = .home
        print("Wrote screens to \(output.path)")
        exit(0)
    }

    static func sampleMeetings() -> [Meeting] {
        var meeting = Meeting()
        meeting.title = "Retention and Product Hunt launch"
        meeting.app = "Google Meet"
        meeting.createdAt = Date().addingTimeInterval(-3600)
        meeting.endedAt = Date().addingTimeInterval(-3600 + 1860)
        meeting.attendees = ["Priya Shah"]
        meeting.status = .done
        meeting.myNotes = "retention?\nlaunch date"
        meeting.segments = [
            .init(speaker: .them, start: 0, end: 8, text: "Hey Lin, thanks for jumping on. We looked at the Recallr numbers. You're at about 120 users, which is great for a beta."),
            .init(speaker: .me, start: 9, end: 13, text: "Yeah, about 60% come back every week, mostly students using it for lectures."),
            .init(speaker: .them, start: 14, end: 22, text: "I'd like to see the onboarding fixed before you launch. Can you send me the new import flow by Friday?"),
            .init(speaker: .me, start: 23, end: 27, text: "Yes, I'll send it by Friday. Sharif is working on the Workloom integration too."),
        ]
        meeting.notes = MeetingNotes(title: "Retention and Product Hunt launch",
            summary: "Priya reviewed Recallr’s beta traction and retention, and asked for the onboarding to be fixed before launch. The Product Hunt launch is set for next Tuesday.",
            sections: [.init(heading: "Retention", bullets: ["Recallr has about 120 beta users.", "About 60% come back every week, mostly students using it for lectures."]),
                       .init(heading: "Onboarding and integrations", bullets: ["Priya wants onboarding fixed before launch, starting with the import flow.", "Sharif is building the Workloom integration."]),
                       .init(heading: "Launch", bullets: ["Priya will introduce Lin to two founders who launched on Product Hunt."])],
            decisions: ["Launch on Product Hunt next Tuesday."],
            actionItems: [.init(task: "Send Priya the new import flow", owner: "Lin", due: "Friday"),
                          .init(task: "Introduce Lin to two Product Hunt founders", owner: "Priya"),
                          .init(task: "Finish the Workloom integration", owner: "Sharif", due: "before launch")],
            writer: "qwen3:8b")
        var standup = Meeting()
        standup.title = "Recallr standup"; standup.app = "Slack"; standup.status = .done
        standup.createdAt = Date().addingTimeInterval(-86_400); standup.endedAt = standup.createdAt.addingTimeInterval(900)
        standup.notes = MeetingNotes(summary: "Shipped the iPad build; App Store review is pending.", writer: "qwen3:8b")
        var lecture = Meeting()
        lecture.title = "CS 3410: Caches"; lecture.app = "Zoom"; lecture.status = .done; lecture.template = .lecture
        lecture.createdAt = Date().addingTimeInterval(-2 * 86_400); lecture.endedAt = lecture.createdAt.addingTimeInterval(4500)
        lecture.notes = MeetingNotes(summary: "Direct-mapped vs. set-associative caches; the midterm covers chapters 4–6.", writer: "qwen3:8b")
        return [meeting, standup, lecture]
    }
}
