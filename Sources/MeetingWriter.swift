import Foundation

/// Turns a meeting's transcript and your own notes into finished notes, the
/// way Granola does: your notes steer what matters, the transcript fills in
/// the detail. Long meetings are summarized in parts first, then combined.
enum MeetingWriter {
    static let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "title": ["type": "string"],
            "summary": ["type": "string"],
            "sections": ["type": "array", "items": ["type": "object", "properties": [
                "heading": ["type": "string"], "bullets": ["type": "array", "items": ["type": "string"]]], "required": ["heading", "bullets"]]],
            "decisions": ["type": "array", "items": ["type": "string"]],
            "actionItems": ["type": "array", "items": ["type": "object", "properties": [
                "task": ["type": "string"], "owner": ["type": "string"], "due": ["type": "string"]], "required": ["task"]]],
        ],
        "required": ["title", "summary", "sections", "decisions", "actionItems"],
    ]

    /// The other side's label: their name for a one-on-one from the calendar, otherwise "Other person".
    static func othersLabel(_ meeting: Meeting) -> String {
        meeting.attendees.count == 1 ? meeting.attendees[0].split(separator: " ").first.map(String.init) ?? "Other person" : "Other person"
    }

    /// Models sometimes treat the speaker label as a name.
    static func tidy(_ notes: inout MeetingNotes) {
        let placeholders: Set<String> = ["them", "they", "other", "others", "other person", "guest", "speaker", "the other person"]
        for index in notes.actionItems.indices where placeholders.contains(notes.actionItems[index].owner?.lowercased() ?? "") {
            notes.actionItems[index].owner = nil
        }
        func fix(_ text: String) -> String {
            text.replacingOccurrences(of: "\\b(Them|Other person) (will|requested|asked|said|wants|offered|suggested|plans|is|was|thinks|agreed)\\b",
                                      with: "They $2", options: .regularExpression)
        }
        notes.summary = fix(notes.summary)
        notes.decisions = notes.decisions.map(fix)
        for index in notes.sections.indices { notes.sections[index].bullets = notes.sections[index].bullets.map(fix) }
        for index in notes.actionItems.indices {
            // "Send the flow by Friday (Friday)": the deadline is already its own chip.
            if let due = notes.actionItems[index].due, notes.actionItems[index].task.hasSuffix(" by " + due) {
                notes.actionItems[index].task = String(notes.actionItems[index].task.dropLast(due.count + 4))
            }
        }
    }

    static func system(me: String, others: String = "Other person", template: MeetingTemplate) -> String {
        """
        You write meeting notes for \(me). The transcript labels \(me)'s microphone as "\(me)" and everyone else on the call as "\(others)" \
        (possibly several people; use their real names when the transcript makes them clear).
        Write notes the way a sharp chief of staff would: specific, skimmable, no filler. Keep every concrete detail: names, numbers, \
        dates, prices, product names, links, commitments. Never invent anything that wasn't said. Speech recognition makes mistakes: \
        quietly fix obvious mishearings using context, and keep the user's own spellings from their notes and vocabulary.
        - title: 3–7 words naming what the meeting was about (not "Meeting notes").
        - summary: 1–3 sentences: the point of the meeting and how it ended.
        - sections: \(template.guidance) Each bullet is one short, complete thought. 2–6 bullets per section.
        - decisions: things that were agreed, decided or scheduled (a launch date, a choice between options, a price). Empty only if truly none.
        - actionItems: concrete next steps someone committed to or was asked to do, phrased as a short task starting with a verb. \
        owner is the person's name ("\(me)" for the user); never write "Them" or "Other" — leave owner empty if you don't know their name. \
        due is the deadline said for that task ("Friday", "next Tuesday", "end of month"), else empty.
        Refer to the others by name when known; otherwise say "they", never "Them".
        If the user wrote their own notes, treat them as the outline of what mattered: every point they wrote must appear, expanded with detail from the transcript.
        Answer in the language of the transcript.
        """
    }

    /// Everything that goes into the final request except the transcript.
    static func header(_ meeting: Meeting, vocabulary: [String]) -> String {
        var prompt = ""
        if !meeting.title.isEmpty { prompt += "Meeting: \(meeting.title)\n" }
        if !meeting.app.isEmpty { prompt += "Held in: \(meeting.app)\n" }
        if !meeting.attendees.isEmpty { prompt += "Attendees: \(meeting.attendees.joined(separator: ", "))\n" }
        prompt += "Date: \(meeting.createdAt.formatted(date: .complete, time: .shortened))\n"
        if let agenda = meeting.agenda?.nilIfBlank { prompt += "Agenda from the calendar invite:\n\(agenda)\n" }
        if !vocabulary.isEmpty { prompt += "Words and names the user uses (correct spellings): \(vocabulary.prefix(60).joined(separator: ", "))\n" }
        let mine = meeting.myNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !mine.isEmpty { prompt += "\nThe user's own notes:\n\(mine)\n" }
        return prompt
    }

    /// The context size the final request will use, so the model can be loaded
    /// ahead of time with exactly that size (a different size means a reload).
    /// `extra` leaves room for words still being transcribed.
    static func contextSize(for meeting: Meeting, me: String, vocabulary: [String], extra: Int = 0) -> Int {
        let transcript = MeetingTranscript.formatted(meeting.segments, me: me, them: othersLabel(meeting))
        let characters = system(me: me, template: meeting.template).count + header(meeting, vocabulary: vocabulary).count + transcript.count + extra
        return LocalLLM.contextSize(for: characters)
    }

    /// Condenses one part of a long meeting. Parts finished during the meeting
    /// are condensed while it's still going, so the notes are quick at the end.
    static func digest(_ part: String, me: String, writer: Writer) async throws -> String {
        try await writer.respond(system: """
            You condense one part of a meeting transcript into detailed bullet notes for \(me). Keep every name, number, \
            decision, commitment and open question. Plain bullets only.
            """, prompt: part, timeout: 240)
    }

    /// Writes notes with the best local model, falling back to plain notes.
    /// `draft` receives the notes as they're written; `digests` holds parts
    /// already condensed during the meeting.
    static func write(_ meeting: Meeting, me: String, vocabulary: [String], savedModel: String = "", warmContext: Int? = nil,
                      digests cached: [String: String] = [:],
                      progress: @escaping @MainActor (String) -> Void = { _ in },
                      draft: @escaping @MainActor (MeetingNotes) -> Void = { _ in }) async -> MeetingNotes {
        let others = othersLabel(meeting)
        let transcript = MeetingTranscript.formatted(meeting.segments, me: me, them: others)
        guard !transcript.isEmpty || !meeting.myNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return BasicNotes.notes(for: meeting, me: me)
        }
        await progress("Waking up the local model…")
        let writer = await Writer.best(saved: savedModel)
        guard writer.kind != .none else { return BasicNotes.notes(for: meeting, me: me) }
        do {
            var material = transcript
            let parts = MeetingTranscript.parts(transcript, limit: writer.budget)
            if parts.count > 1 {
                var digests: [String] = []
                for (index, part) in parts.enumerated() {
                    let digest: String
                    if let done = cached[part] { digest = done } else {
                        await progress("Reading part \(index + 1) of \(parts.count)…")
                        digest = try await self.digest(part, me: me, writer: writer)
                    }
                    digests.append("Part \(index + 1) (\(firstClock(part)) onward):\n\(digest)")
                }
                material = "Condensed notes from each part of the meeting:\n\n" + digests.joined(separator: "\n\n")
            }
            await progress("Writing your notes…")
            let system = system(me: me, others: others, template: meeting.template)
            let prompt = header(meeting, vocabulary: vocabulary) + "\nTranscript:\n\(material)"
            // The model loaded at the end of the meeting is reused when the request fits.
            let needed = LocalLLM.contextSize(for: system.count + prompt.count)
            let context = warmContext.map { $0 >= needed ? $0 : needed } ?? needed
            let name = writer.name
            let answer = try await writer.respond(system: system, prompt: prompt, schema: schema, timeout: 300, context: context) { text in
                guard let json = LocalLLM.closePartialJSON(text), let data = json.data(using: .utf8),
                      var notes = try? JSONDecoder().decode(MeetingNotes.self, from: data) else { return }
                notes.writer = name
                notes.sections = notes.sections.filter { !$0.heading.isEmpty }
                // Steady ids, so lines already on screen stay put as more arrive.
                for index in notes.sections.indices { notes.sections[index].id = steadyID(index) }
                for index in notes.actionItems.indices { notes.actionItems[index].id = steadyID(1_000 + index) }
                await draft(notes)
            }
            guard let data = LocalLLM.jsonObject(in: answer), var notes = try? JSONDecoder().decode(MeetingNotes.self, from: data), !notes.isEmpty else {
                return BasicNotes.notes(for: meeting, me: me)
            }
            notes.writer = writer.name
            notes.sections = notes.sections.filter { !$0.bullets.isEmpty && !$0.heading.isEmpty }
            notes.actionItems = notes.actionItems.filter { !$0.task.trimmingCharacters(in: .whitespaces).isEmpty }
            tidy(&notes)
            return notes
        } catch {
            return BasicNotes.notes(for: meeting, me: me)
        }
    }

    private static func steadyID(_ index: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", index))!
    }

    private static func firstClock(_ part: String) -> String {
        guard part.hasPrefix("["), let close = part.firstIndex(of: "]") else { return "start" }
        return String(part[part.index(after: part.startIndex)..<close])
    }

    /// Answers a question about one meeting ("what did they say about pricing?").
    static func answer(_ question: String, about meeting: Meeting, me: String, savedModel: String = "",
                       partial: (@Sendable (String) async -> Void)? = nil) async -> String {
        let writer = await Writer.best(saved: savedModel)
        var transcript = MeetingTranscript.formatted(meeting.segments, me: me, them: othersLabel(meeting))
        if writer.kind == .none { return localAnswer(question, in: meeting) }
        if transcript.count > writer.budget {
            // Keep the lines that share words with the question, in order.
            let terms = Set(LibrarySearch.terms(question))
            let lines = transcript.components(separatedBy: "\n")
            let relevant = lines.filter { line in terms.contains { line.lowercased().contains($0) } }
            transcript = String((relevant.isEmpty ? lines : relevant).joined(separator: "\n").prefix(writer.budget))
        }
        var context = ""
        if let notes = meeting.notes { context += notes.markdown(title: meeting.displayTitle, date: meeting.createdAt) + "\n" }
        if !meeting.myNotes.isEmpty { context += "The user's own notes:\n\(meeting.myNotes)\n\n" }
        let live = meeting.status == .live
        do {
            return try await writer.respond(system: """
                You answer questions about one meeting for \(me), using only its notes and transcript. Be brief and specific; quote \
                when it helps. If the meeting doesn't cover it, say so. When asked to draft something (an email, a follow-up, a \
                summary for someone), write it ready to send.\(live ? " The meeting is still going on: the end of the transcript is what's being said right now. Keep answers short enough to read at a glance." : "")
                Write plain text: no Markdown headings, no bold.
                """, prompt: "\(context)Transcript:\n\(transcript)\n\nQuestion: \(question)", timeout: 180, partial: partial)
        } catch { return localAnswer(question, in: meeting) }
    }

    /// Without a model: the transcript lines that mention the question's words.
    static func localAnswer(_ question: String, in meeting: Meeting) -> String {
        let terms = LibrarySearch.terms(question)
        let hits = meeting.segments.filter { LibrarySearch.matches($0.text, terms: terms) }.prefix(5)
        guard !hits.isEmpty else { return "Nothing in this meeting mentions that. (Install Ollama for full answers.)" }
        return hits.map { "[\(MeetingTranscript.clock($0.start))] \($0.text)" }.joined(separator: "\n")
    }
}
