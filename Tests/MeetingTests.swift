import Foundation

@main struct MeetingTests {
    static func main() {
        // Speech chunking: three bursts of "voice" separated by pauses become three pieces.
        var chunker = SpeechChunker()
        func tone(_ seconds: Double, amplitude: Float = 0.2) -> [Float] {
            (0..<Int(seconds * 16_000)).map { amplitude * sin(Float($0) * 0.18) }
        }
        func silence(_ seconds: Double) -> [Float] { (0..<Int(seconds * 16_000)).map { _ in Float.random(in: -0.0008...0.0008) } }
        var chunks: [SpeechChunker.Chunk] = []
        let stream = silence(0.5) + tone(2.4) + silence(1.0) + tone(3.0) + silence(1.2) + tone(1.8)
        var offset = 0
        while offset < stream.count {
            let end = min(offset + 1_600, stream.count)
            chunks += chunker.append(Array(stream[offset..<end]))
            offset = end
        }
        if let last = chunker.flush() { chunks.append(last) }
        assert(chunks.count == 3, "chunks: \(chunks.count)")
        assert(abs(chunks[0].start - 0.5) < 0.3, "start \(chunks[0].start)")
        assert(abs(chunks[1].start - 3.9) < 0.3, "start \(chunks[1].start)")
        // A long monologue is still cut, so text keeps arriving.
        var long = SpeechChunker()
        let pieces = long.append(tone(50))
        assert(pieces.count == 2 && pieces.allSatisfy { Double($0.samples.count) / 16_000 <= 22.1 }, "long: \(pieces.count)")
        // A click isn't speech.
        var clicks = SpeechChunker()
        assert(clicks.append(silence(1) + tone(0.1) + silence(1.5)).isEmpty && clicks.flush() == nil)

        // Echo: your mic picking up the other side through speakers is dropped.
        let theirs = MeetingSegment(speaker: .them, start: 10, end: 14, text: "We should ship the pricing page by Friday.")
        let echo = MeetingSegment(speaker: .me, start: 10.3, end: 14.2, text: "we should ship the pricing page by friday")
        let reply = MeetingSegment(speaker: .me, start: 14.5, end: 16, text: "Sounds good, I'll draft it tonight.")
        assert(MeetingTranscript.isEcho(echo, among: [theirs]))
        assert(!MeetingTranscript.isEcho(reply, among: [theirs]))

        // Transcript formatting merges consecutive lines from one speaker.
        let formatted = MeetingTranscript.formatted([theirs, MeetingSegment(speaker: .them, start: 14.1, end: 15, text: "Can you own it?"), reply], me: "Lin")
        assert(formatted == "[0:10] Them: We should ship the pricing page by Friday. Can you own it?\n[0:14] Lin: Sounds good, I'll draft it tonight.", formatted)
        assert(MeetingTranscript.parts(String(repeating: "line\n", count: 100), limit: 50).count > 5)
        // One speaker talking for an hour still splits into parts that fit.
        let lecture = "[0:00] Them: " + String(repeating: "This is one sentence of the lecture. ", count: 400)
        assert(MeetingTranscript.parts(lecture, limit: 2_000).allSatisfy { $0.count <= 2_000 } && MeetingTranscript.parts(lecture, limit: 2_000).count > 5)
        // Your own two "yes" answers aren't echoes of each other.
        let firstYes = MeetingSegment(speaker: .me, start: 5, end: 5.5, text: "Yes"), secondYes = MeetingSegment(speaker: .me, start: 6, end: 6.5, text: "Yes")
        assert(!MeetingTranscript.isEcho(secondYes, among: [firstYes]))
        assert(MeetingTranscript.isEcho(secondYes, among: [MeetingSegment(speaker: .them, start: 6, end: 6.4, text: "yes")]))

        // Notes without a model still find commitments and decisions.
        var meeting = Meeting()
        meeting.segments = [theirs, reply,
                            MeetingSegment(speaker: .them, start: 20, end: 24, text: "We decided to launch Recallr on Product Hunt next Tuesday."),
                            MeetingSegment(speaker: .me, start: 25, end: 30, text: "Great. The onboarding flow needs work before the launch, especially the import step.")]
        let notes = BasicNotes.notes(for: meeting, me: "Lin")
        assert(notes.actionItems.contains { $0.task.contains("draft it tonight") && $0.owner == "Lin" }, "\(notes.actionItems)")
        assert(notes.decisions.contains { $0.contains("Product Hunt") })
        assert(!notes.summary.isEmpty)

        // Model output is decoded leniently and rendered as Markdown.
        let json = #"{"title":"Launch plan","summary":"Agreed on a launch date.","sections":[{"heading":"Launch","bullets":["Product Hunt on Tuesday"]}],"decisions":["Launch Tuesday"],"actionItems":[{"task":"Draft pricing page","owner":"Lin","due":"Friday"},{"task":"Book a demo","owner":"","due":"none"}]}"#
        let decoded = try! JSONDecoder().decode(MeetingNotes.self, from: LocalLLM.jsonObject(in: "Sure!\n```json\n" + json + "\n```")!)
        assert(decoded.title == "Launch plan" && decoded.actionItems.count == 2 && decoded.actionItems[1].owner == nil && decoded.actionItems[1].due == nil)
        let markdown = decoded.markdown(title: "Meeting", date: Date(), myNotes: "ask about pricing")
        assert(markdown.contains("## Action items\n- [ ] Draft pricing page — Lin (Friday)") && markdown.contains("## My notes"), markdown)
        assert(LocalLLM.stripThinking("<think>hmm</think>\nAnswer") == "Answer")
        assert(LocalLLM.pickModel(from: ["nomic-embed-text:latest", "qwen2.5vl:7b", "qwen3:8b"]) == "qwen3:8b")

        // Half-written notes are shown while the model writes them.
        func partial(_ text: String) -> MeetingNotes? {
            LocalLLM.closePartialJSON(text).flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode(MeetingNotes.self, from: $0) }
        }
        assert(partial(#"{"title":"Launch pl"#)?.title == "Launch pl")
        assert(partial(#"{"title":"Launch plan","summ"#)?.title == "Launch plan")
        assert(partial(#"{"title":"A","summary":"Agreed on a date.","sections":[{"heading":"Launch","bullets":["Product Hunt on Tue"#)?.sections.first?.bullets == ["Product Hunt on Tue"])
        assert(partial(#"{"title":"A","sections":[{"heading":"Launch","bullets":["x"]},{"head"#)?.sections.count == 2)
        assert(partial(#"{"title":"Say \"hi\" \"#)?.title == #"Say "hi" "#)
        assert(partial("Sure! ") == nil)
        assert(LocalLLM.closePartialJSON(json) == json)
        // Streaming every prefix of real output never produces invalid JSON.
        for end in json.indices { if let closed = LocalLLM.closePartialJSON(String(json[..<end])) { assert((try? JSONSerialization.jsonObject(with: Data(closed.utf8))) != nil, closed) } }

        // Calendar invites: the agenda stays, the dial-in boilerplate goes.
        let invite = """
        Agenda: review Q3 pricing and decide on the launch date.
        Bring the churn numbers.
        ──────────
        Join Zoom Meeting
        https://us02web.zoom.us/j/8123456789?pwd=abc
        Meeting ID: 812 345 6789
        Passcode: 123456
        One tap mobile
        +16465588656,,8123456789# US
        """
        assert(MeetingAgenda.clean(invite) == "Agenda: review Q3 pricing and decide on the launch date.\nBring the churn numbers.", MeetingAgenda.clean(invite) ?? "nil")
        assert(MeetingAgenda.clean("Join with Google Meet\nmeet.google.com/abc-defg-hij") == nil)

        // Meeting apps and call sites.
        assert(MeetingApps.name(for: "us.zoom.xos") == "Zoom")
        assert(MeetingApps.name(for: "com.google.Chrome.helper") == "Chrome")
        assert(MeetingApps.name(for: "com.apple.SpeechRecognitionCore.speechrecognitiond") == nil)
        assert(MeetingApps.site(fromTitle: "Meet - abc-defg-hij - Google Chrome") == "Google Meet")
        print("PASS meeting tests")
    }
}
