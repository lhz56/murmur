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
