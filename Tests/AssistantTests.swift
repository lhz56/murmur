import Foundation

@main
struct AssistantTests {
    @MainActor static func main() {
        // Tags are pulled out; the spoken words read cleanly.
        var reply = AssistantReply("<point x=640 y=212 label=\"Save\">Click Save, up here. <do>open Spotify and play Drake</do>Playing it now.")
        assert(reply.spoken == "Click Save, up here. Playing it now.", reply.spoken)
        assert(reply.points == [.init(x: 640, y: 212, label: "Save")])
        assert(reply.steps == [.command("open Spotify and play Drake")])

        // Malformed tag names and non-finite coordinates must never become actions.
        for tag in ["<clickbait x=10 y=20>", "<click x=inf y=20>", "<click x=nan y=20>", "<click ax=10 y=20>"] {
            assert(AssistantReply(tag).steps.isEmpty, tag)
        }
        let shot = ScreenShot(url: URL(fileURLWithPath: "/tmp/unused.jpg"), pixelSize: CGSize(width: 100, height: 100), screenFrame: .zero)
        assert(!shot.contains(.init(x: 100, y: 20, label: "")))
        assert(!shot.contains(.init(x: 999999, y: 20, label: "")))
        assert(shot.contains(.init(x: 99, y: 20, label: "")))
        for request in ["explain this", "where do I click", "don't click Wi-Fi", "show me how to enable Wi-Fi", "what does open Safari mean?"] {
            let intent = AssistantIntent(request)
            assert(!intent.clicks && !intent.types && !intent.commands, request)
        }
        assert(AssistantIntent("Can you turn on Wi-Fi for me?").clicks)
        assert(AssistantIntent("turn on Wi-Fi").allowsClick(label: "Wi-Fi"))
        assert(!AssistantIntent("turn on Wi-Fi").allowsClick(label: "Firewall"))
        assert(!AssistantIntent("turn it on").allowsClick(label: "Wi-Fi"))
        assert(AssistantIntent("please draft a reply").types)
        assert(AssistantIntent("open Spotify").commands)
        assert(ScreenClick.permits(role: "AXCheckBox", name: "Wi-Fi", label: "Wi-Fi"))
        for name in ["", "Continue", "Allow", "OK", "Delete", "Unrelated control"] {
            assert(!ScreenClick.permits(role: "AXCheckBox", name: name, label: "Wi-Fi"))
        }
        assert(!ScreenClick.permits(role: "AXButton", name: "Buy now", label: "Buy now"))
        assert(!ScreenClick.permits(role: "AXButton", name: "Send", label: "Send"))
        assert(ScreenClick.permits(role: "AXButton", name: "Save", label: "Save"))
        assert(ScreenClick.permits(role: "AXCheckBox", name: "Wi‑Fi", label: "wi-fi"), "hyphen styles match")
        assert(!ScreenClick.permits(role: "AXStaticText", name: "Wi-Fi", label: "Wi-Fi"), "only real controls")
        // Natural phrasing, the way Parakeet writes it, still counts as asking.
        for request in ["Hey, can you open Spotify?", "Okay, open Safari.", "Murmur, open Safari", "I want to listen to Drake",
                        "Could you please play some lofi?", "So, set a timer for 10 minutes."] {
            assert(AssistantIntent(request).commands, request)
        }
        for request in ["Make this friendlier.", "Hey, reply saying I'll be late", "Can you write back that I'm in?"] {
            assert(AssistantIntent(request).types, request)
        }
        for request in ["Okay, turn on Bluetooth for me.", "Hey, click Save", "Switch it to Claude"] {
            assert(AssistantIntent(request).clicks, request)
        }
        assert(AssistantIntent("Hey, click Save").allowsClick(label: "Save"))
        assert(AssistantIntent("Turn on wi‑fi please").allowsClick(label: "Wi-Fi"))
        for request in ["Hey, how do I open Spotify?", "What does this error mean?", "Okay, where is Save?", "Don't click anything, just open it"] {
            let intent = AssistantIntent(request)
            assert(!intent.clicks && !intent.types && !intent.commands, request)
        }

        // Quotes are optional, any order, single quotes too.
        assert(AssistantReply.point(" label='Search field' y=40.5 x=12") == .init(x: 12, y: 40.5, label: "Search field"))
        assert(AssistantReply.point(" x=12 label=Go") == nil, "a point needs both coordinates")
        assert(AssistantReply("<point x=-4 y=10>Here.").points.isEmpty, "no negative coordinates")

        // While streaming: a half-written tag is neither spoken nor run.
        reply = AssistantReply("Sure. <do>open Sla")
        assert(reply.spoken == "Sure." && reply.steps.isEmpty)
        reply = AssistantReply("Sure. <poi")
        assert(reply.spoken == "Sure." && reply.points.isEmpty)
        reply = AssistantReply("Here it is <point x=10 y=")
        assert(reply.spoken == "Here it is" && reply.points.isEmpty)
        reply = AssistantReply("Drafted it. <type>On my way, see you at 6</type>")
        assert(reply.steps == [.type("On my way, see you at 6")] && reply.spoken == "Drafted it.")

        // Tags the model made up are dropped.
        assert(AssistantReply("It’s a note.</final>").spoken == "It’s a note.")
        // A plain "<" that isn't a tag stays in the words.
        assert(AssistantReply("If x < 5 then stop.").spoken == "If x < 5 then stop.")

        // Markdown the model slipped in is dropped.
        assert(AssistantReply("Press **Command** and `S`.").spoken == "Press Command and S.")

        // Clicks point too, and run in order with the other steps.
        reply = AssistantReply("<click x=300 y=40 label=\"Wi-Fi\">Turning on Wi-Fi. <do>volume 30</do>")
        assert(reply.spoken == "Turning on Wi-Fi.", reply.spoken)
        assert(reply.points == [.init(x: 300, y: 40, label: "Wi-Fi")])
        assert(reply.steps == [.click(.init(x: 300, y: 40, label: "Wi-Fi")), .command("volume 30")])
        assert(!reply.waits)
        // <wait> ends one step of a walkthrough, in any spelling, and is never read aloud.
        for tag in ["<wait>", "<wait/>", "<wait />", "</wait>"] {
            reply = AssistantReply("<point x=10 y=20 label=\"General\">Click General on the left. \(tag)")
            assert(reply.waits && reply.spoken == "Click General on the left.", "\(tag): \(reply.spoken)")
        }
        reply = AssistantReply("Click General. <wai")
        assert(!reply.waits && reply.spoken == "Click General.", reply.spoken)
        reply = AssistantReply("Click General. <wait/")
        assert(!reply.waits && reply.spoken == "Click General.", reply.spoken)
        reply = AssistantReply("Half a click <click x=3")
        assert(reply.steps.isEmpty && reply.spoken == "Half a click")

        // Ask leaves the risky buttons to you.
        for label in ["Send", "Delete Account", "Buy now", "Place Order", "Empty Trash", "Sign Out", "Post", "Confirm"] {
            assert(ScreenClick.isRisky(label), label)
        }
        for label in ["Wi-Fi", "General", "Sender settings", "Posters", "Open", "Turn On", "Allow", "Next", ""] {
            assert(!ScreenClick.isRisky(label), label)
        }

        // A walkthrough note replaces "They said".
        var note = AssistantQuestion(text: "", note: "They clicked. This is the screen now.")
        assert(note.prompt.contains("Murmur: They clicked.") && !note.prompt.contains("They said"))
        note.note = nil; note.text = "hi"
        assert(note.prompt.contains("They said: hi"))
        assert(AssistantInstructions.system.contains("<click") && AssistantInstructions.system.contains("<wait>"))

        // Sentences: speak the finished ones, hold the one still arriving.
        var (said, offset) = AssistantReply.sentences(in: "It’s the Notes app. You can add a no", after: 0, final: false)
        assert(said == "It’s the Notes app." && offset == 19, "\(said) \(offset)")
        (said, offset) = AssistantReply.sentences(in: "It’s the Notes app. You can add a note.", after: offset, final: true)
        assert(said == "You can add a note.")
        (said, offset) = AssistantReply.sentences(in: "Use e.g. the menu", after: 0, final: false)
        assert(said.isEmpty && offset == 0, "e.g. isn't a sentence end")
        (said, _) = AssistantReply.sentences(in: "Done! Next", after: 0, final: false)
        assert(said == "Done!")

        // The question the model reads.
        var question = AssistantQuestion(text: "what's this?", image: URL(fileURLWithPath: "/tmp/x.jpg"), imageSize: CGSize(width: 1512, height: 982), app: "Safari", window: "GitHub")
        assert(question.prompt.contains("Front app: Safari — window “GitHub”") && question.prompt.contains("1512×982") && question.prompt.hasSuffix("They said: what's this?"))
        question.image = nil
        assert(question.prompt.contains("No screenshot"))

        // Only the everyday models are offered, never the most expensive ones.
        for provider in AssistantProvider.allCases {
            assert(provider.models.count >= 2)
            assert(!provider.models.contains { $0.id.contains("astra") || $0.id.contains("opus") })
        }
        assert(AssistantProvider.chatgpt.defaultModel == "gpt-6.1-sol" && AssistantProvider.claude.defaultModel == "sonnet")

        // Screenshot pixels map onto the screen it came from (AppKit coordinates, y up).
        let frame = CGRect(x: 1512, y: 0, width: 1512, height: 982)
        let spot = ScreenPoint.map(x: 100, y: 82, imageSize: CGSize(width: 1512, height: 982), screenFrame: frame)
        assert(spot == CGPoint(x: 1612, y: 900), "\(spot)")
        let scaled = ScreenPoint.map(x: 756, y: 491, imageSize: CGSize(width: 756, height: 491), screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982))
        assert(scaled == CGPoint(x: 1512, y: 0))
        // The natural voice says tech words right, without touching other words.
        assert(NaturalVoice.spoken("Open Xcode, then ask ChatGPT about the API.") == "Open X code, then ask chat G P T about the A P I.")
        assert(NaturalVoice.spoken("Guide the SwiftUI build") == "Guide the Swift U I build", "no match inside words")
        assert(NaturalVoice.choices.contains { $0.id == NaturalVoice.defaultVoice })
        print("Assistant tests passed")
    }
}
