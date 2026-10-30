import Foundation

/// A meeting Murmur took notes for: what was said (you on the microphone, the
/// others through your Mac's audio), your own notes, and the finished notes.
struct Meeting: Codable, Identifiable, Equatable {
    enum Status: String, Codable { case live, writing, done, failed }

    var id = UUID()
    var title = ""
    var createdAt = Date()
    var endedAt: Date?
    /// The app the call happened in ("Zoom", "Google Meet").
    var app = ""
    var template: MeetingTemplate = .auto
    var attendees: [String] = []
    /// What you typed during the meeting.
    var myNotes = ""
    var segments: [MeetingSegment] = []
    var notes: MeetingNotes?
    var status: Status = .live
    var chat: [ChatTurn] = []
    var deletedAt: Date?
    /// Calendar event this meeting belongs to.
    var eventID: String?
    /// The invite's description, without the dial-in boilerplate.
    var agenda: String?

    var duration: TimeInterval { (endedAt ?? Date()).timeIntervalSince(createdAt) }
    var displayTitle: String { !title.isEmpty ? title : notes?.title.isEmpty == false ? notes!.title : app.isEmpty ? "Meeting" : "\(app) call" }
    var wordCount: Int { segments.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count } }
    var durationLabel: String {
        let minutes = Int(duration / 60)
        return minutes < 1 ? "<1 min" : minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h \(minutes % 60) min"
    }

    struct ChatTurn: Codable, Equatable, Identifiable {
        var id = UUID()
        var question: String
        var answer: String
    }
}

struct MeetingSegment: Codable, Equatable, Identifiable {
    enum Speaker: String, Codable { case me, them }
    var id = UUID()
    var speaker: Speaker
    /// Seconds from the start of the meeting.
    var start: TimeInterval
    var end: TimeInterval
    var text: String
}

/// The written-up meeting: summary, topics, decisions and action items.
struct MeetingNotes: Codable, Equatable {
    struct Section: Codable, Equatable, Identifiable {
        var id = UUID()
        var heading: String
        var bullets: [String]
        enum CodingKeys: String, CodingKey { case heading, bullets }
        init(heading: String, bullets: [String]) { self.heading = heading; self.bullets = bullets }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            heading = (try? container.decode(String.self, forKey: .heading)) ?? ""
            bullets = (try? container.decode([String].self, forKey: .bullets)) ?? []
        }
    }
    struct ActionItem: Codable, Equatable, Identifiable {
        var id = UUID()
        var task: String
        var owner: String?
        var due: String?
        var done = false
        enum CodingKeys: String, CodingKey { case task, owner, due, done }
        init(task: String, owner: String? = nil, due: String? = nil) { self.task = task; self.owner = owner; self.due = due }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            task = (try? container.decode(String.self, forKey: .task)) ?? ""
            owner = (try? container.decodeIfPresent(String.self, forKey: .owner)).flatMap { $0?.nilIfBlank }
            due = (try? container.decodeIfPresent(String.self, forKey: .due)).flatMap { $0?.nilIfBlank }
            done = (try? container.decode(Bool.self, forKey: .done)) ?? false
        }
    }

    var title = ""
    var summary = ""
    var sections: [Section] = []
    var decisions: [String] = []
    var actionItems: [ActionItem] = []
    /// Which model wrote these ("qwen3:8b", "Apple Intelligence", "Murmur").
    var writer = ""

    enum CodingKeys: String, CodingKey { case title, summary, sections, decisions, actionItems, writer }
    init(title: String = "", summary: String = "", sections: [Section] = [], decisions: [String] = [], actionItems: [ActionItem] = [], writer: String = "") {
        self.title = title; self.summary = summary; self.sections = sections
        self.decisions = decisions; self.actionItems = actionItems; self.writer = writer
    }
    /// Lenient: models sometimes leave out a field.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = (try? container.decode(String.self, forKey: .title)) ?? ""
        summary = (try? container.decode(String.self, forKey: .summary)) ?? ""
        sections = (try? container.decode([Section].self, forKey: .sections)) ?? []
        decisions = (try? container.decode([String].self, forKey: .decisions)) ?? []
        actionItems = (try? container.decode([ActionItem].self, forKey: .actionItems)) ?? []
        writer = (try? container.decode(String.self, forKey: .writer)) ?? ""
    }

    var isEmpty: Bool { summary.isEmpty && sections.isEmpty && actionItems.isEmpty && decisions.isEmpty }

    /// Markdown for copying into Notion, Docs, Slack or an email.
    func markdown(title fallback: String, date: Date, myNotes: String = "") -> String {
        var lines = ["# \(title.isEmpty ? fallback : title)", "_\(date.formatted(date: .abbreviated, time: .shortened))_", ""]
        if !summary.isEmpty { lines += [summary, ""] }
        for section in sections where !section.bullets.isEmpty {
            lines.append("## \(section.heading)")
            lines += section.bullets.map { "- \($0)" }
            lines.append("")
        }
        if !decisions.isEmpty { lines += ["## Decisions"] + decisions.map { "- \($0)" } + [""] }
        if !actionItems.isEmpty {
            lines.append("## Action items")
            lines += actionItems.map { item in
                var line = "- [\(item.done ? "x" : " ")] \(item.task)"
                if let owner = item.owner { line += " — \(owner)" }
                if let due = item.due { line += " (\(due))" }
                return line
            }
            lines.append("")
        }
        let mine = myNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !mine.isEmpty { lines += ["## My notes", mine, ""] }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }
}

extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || ["none", "null", "n/a", "unknown", "-"].contains(trimmed.lowercased()) ? nil : trimmed
    }
}

/// How the notes are shaped. "Auto" fits most calls.
enum MeetingTemplate: String, Codable, CaseIterable, Identifiable {
    case auto = "Auto", oneOnOne = "1:1", standup = "Standup", userInterview = "User interview",
         sales = "Sales call", investor = "Investor meeting", lecture = "Class or lecture", brainstorm = "Brainstorm"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .auto: return "sparkles"
        case .oneOnOne: return "person.2"
        case .standup: return "figure.stand"
        case .userInterview: return "person.crop.circle.badge.questionmark"
        case .sales: return "briefcase"
        case .investor: return "chart.line.uptrend.xyaxis"
        case .lecture: return "graduationcap"
        case .brainstorm: return "lightbulb"
        }
    }
    /// The section headings the writer should use, in order.
    var guidance: String {
        switch self {
        case .auto: return "Choose 2–5 section headings that fit what was actually discussed, named after the topics (not generic labels)."
        case .oneOnOne: return "Use sections: \"Updates\", \"Blockers\", \"Feedback\", \"Career and growth\" (skip any that weren't discussed)."
        case .standup: return "Use sections: \"Yesterday\", \"Today\", \"Blockers\", grouped by person where possible."
        case .userInterview: return "Use sections: \"About them\", \"Pain points\", \"How they work today\", \"Reactions to the product\", \"Notable quotes\" (quotes verbatim)."
        case .sales: return "Use sections: \"Their situation\", \"Needs and pain points\", \"Objections\", \"Pricing and budget\", \"Next steps\"."
        case .investor: return "Use sections: \"Their questions\", \"Concerns\", \"Signals of interest\", \"Advice\", \"Next steps\"."
        case .lecture: return "Use sections named after the concepts taught, with definitions, examples, and anything said to be on an exam or due."
        case .brainstorm: return "Use sections: \"Ideas\", \"Most promising\", \"Open questions\"."
        }
    }
}

// MARK: Speech chunking

/// Splits a continuous 16 kHz stream into utterances at natural pauses, so
/// each piece can be transcribed while the meeting continues. Silence is
/// measured against an adaptive noise floor, so a noisy room still splits.
struct SpeechChunker {
    struct Chunk { let samples: [Float]; let start: TimeInterval }

    static let rate = 16_000.0
    private static let frame = 320  // 20 ms
    var minimumPause: TimeInterval = 0.65
    var minimumLength: TimeInterval = 1.6
    var maximumLength: TimeInterval = 22

    private var pending: [Float] = []
    private var current: [Float] = []
    private var currentStart: TimeInterval = 0
    private var voicedFrames = 0
    private var silentFrames = 0
    private var position = 0  // samples consumed
    private var noiseFloor: Float = 0.002
    private var preroll: [Float] = []

    /// Feeds samples; returns any finished utterances.
    mutating func append(_ samples: [Float]) -> [Chunk] {
        pending += samples
        var chunks: [Chunk] = []
        while pending.count >= Self.frame {
            let frame = Array(pending.prefix(Self.frame)); pending.removeFirst(Self.frame)
            let energy = (frame.reduce(0) { $0 + $1 * $1 } / Float(Self.frame)).squareRoot()
            let voiced = energy > max(noiseFloor * 3.2, 0.006)
            // The floor follows quiet frames quickly and loud ones very slowly.
            noiseFloor = voiced ? noiseFloor * 0.99995 + energy * 0.00005 : noiseFloor * 0.95 + energy * 0.05
            let time = Double(position) / Self.rate
            position += Self.frame
            if current.isEmpty {
                if voiced {
                    current = preroll + frame
                    currentStart = max(0, time - Double(preroll.count) / Self.rate)
                    voicedFrames = 1; silentFrames = 0
                } else {
                    preroll = Array((preroll + frame).suffix(Self.frame * 12))
                }
                continue
            }
            current += frame
            if voiced { voicedFrames += 1; silentFrames = 0 } else { silentFrames += 1 }
            let length = Double(current.count) / Self.rate
            let paused = Double(silentFrames * Self.frame) / Self.rate >= minimumPause
            if (paused && length >= minimumLength) || length >= maximumLength || (paused && voicedFrames < 8) {
                if let chunk = finishCurrent() { chunks.append(chunk) }
            }
        }
        return chunks
    }

    /// Whatever is left when the meeting ends.
    mutating func flush() -> Chunk? {
        current += pending; pending = []
        return finishCurrent()
    }

    private mutating func finishCurrent() -> Chunk? {
        defer { current = []; voicedFrames = 0; silentFrames = 0; preroll = [] }
        // Under ~0.25 s of voice is a click or a cough, not words.
        guard voicedFrames >= 12 else { return nil }
        // Trim most of the trailing silence; keep a little for the last word.
        let keep = max(0, silentFrames - 10) * Self.frame
        return Chunk(samples: Array(current.dropLast(min(keep, current.count))), start: currentStart)
    }
}

// MARK: Transcript helpers

enum MeetingTranscript {
    /// Drops your microphone's copy of what the others said, when you're on
    /// speakers rather than headphones: a "me" line that repeats an
    /// overlapping "them" line is an echo.
    static func isEcho(_ mine: MeetingSegment, among others: [MeetingSegment]) -> Bool {
        let words = Set(normalizedWords(mine.text))
        guard words.count >= 2 else {
            // A short "yes" is an echo only of the other side saying it, never of your own earlier "yes".
            return others.contains { $0.speaker == .them && $0.end > mine.start - 1.5 && $0.start < mine.end + 1.5 && normalizedWords($0.text) == normalizedWords(mine.text) }
        }
        for other in others where other.speaker == .them && other.end > mine.start - 2.5 && other.start < mine.end + 2.5 {
            let theirs = Set(normalizedWords(other.text))
            let overlap = Double(words.intersection(theirs).count) / Double(words.count)
            if overlap >= 0.6 { return true }
        }
        return false
    }

    static func normalizedWords(_ text: String) -> [String] {
        text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }

    /// "[12:03] Lin: …" lines, merging consecutive lines from the same speaker.
    static func formatted(_ segments: [MeetingSegment], me: String = "Me", them: String = "Them") -> String {
        var lines: [String] = []
        var last: MeetingSegment.Speaker?
        for segment in segments.sorted(by: { $0.start < $1.start }) {
            let name = segment.speaker == .me ? me : them
            if last == segment.speaker, !lines.isEmpty { lines[lines.count - 1] += " " + segment.text }
            else { lines.append("[\(clock(segment.start))] \(name): \(segment.text)") }
            last = segment.speaker
        }
        return lines.joined(separator: "\n")
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
                             : String(format: "%d:%02d", total / 60, total % 60)
    }

    /// Splits a long transcript into parts of about `limit` characters at line breaks.
    static func parts(_ transcript: String, limit: Int) -> [String] {
        var parts: [String] = [], current = ""
        // A long lecture from one speaker is one huge line: split it at sentence ends so every part fits.
        let lines = transcript.components(separatedBy: "\n").flatMap { line -> [String] in
            guard line.count > limit, limit > 200 else { return [line] }
            var pieces: [String] = [], rest = Substring(line)
            while rest.count > limit {
                let window = rest.prefix(limit)
                let cut = window.range(of: ". ", options: .backwards)?.upperBound ?? window.range(of: " ", options: .backwards)?.upperBound ?? window.endIndex
                pieces.append(String(rest[..<cut]).trimmingCharacters(in: .whitespaces))
                rest = rest[cut...]
            }
            if !rest.isEmpty { pieces.append(String(rest)) }
            return pieces
        }
        for line in lines {
            if current.count + line.count > limit, !current.isEmpty { parts.append(current); current = "" }
            current += (current.isEmpty ? "" : "\n") + line
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }
}

/// The useful part of a calendar invite's description: what the meeting is
/// for, without the dial-in numbers, passcodes and join links.
enum MeetingAgenda {
    static func clean(_ notes: String?) -> String? {
        guard let notes else { return nil }
        let boilerplate = ["join zoom meeting", "meeting id", "passcode", "password", "one tap mobile", "dial by", "find your local number",
                           "join by", "microsoft teams meeting", "join on your computer", "click here to join", "learn more", "meeting options",
                           "join with google meet", "join by phone", "more phone numbers", "pin:", "dial-in", "join the meeting",
                           "need help?", "-::~:", "invitation from google calendar", "you are receiving this", "forwarding this invitation",
                           "to stop receiving", "reply for", "view all guest info"]
        let text = notes.replacingOccurrences(of: "<[^>]+>", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&amp;", with: "&")
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { line in
            let lower = line.lowercased()
            guard line.count > 2, line.contains(where: \.isLetter) else { return false }
            if lower.range(of: "https?://\\S+", options: .regularExpression).map({ lower[$0].count > line.count / 2 }) == true { return false }
            if lower.range(of: "\\+?\\d[\\d ,#*-]{7,}", options: .regularExpression) != nil { return false }
            if line.allSatisfy({ "─━-=_~:*.".contains($0) || $0 == " " }) { return false }
            if !line.contains(" "), line.contains("/"), line.contains(".") { return false }
            return !boilerplate.contains { lower.contains($0) }
        }
        let agenda = lines.joined(separator: "\n")
        return agenda.isEmpty ? nil : String(agenda.prefix(1_500))
    }
}

// MARK: Notes without a language model

/// Plain notes from the transcript alone, for when no language model is
/// available: the most informative sentences, plus lines that sound like a
/// decision or a commitment.
enum BasicNotes {
    private static let actionCue = try! NSRegularExpression(pattern:
        "(?i)\\b(i'll|i will|we'll|we will|we need to|we should|i need to|you need to|can you|could you|please|let me|i'm going to|follow up|send (you|over|me)|todo|to-do|action item|by (monday|tuesday|wednesday|thursday|friday|tomorrow|next week|end of (the )?(day|week)))\\b")
    private static let decisionCue = try! NSRegularExpression(pattern:
        "(?i)\\b(we decided|decided to|let's go with|we'll go with|we agreed|agreed to|the plan is|we're going with|final decision|let's do)\\b")
    private static let stopwords: Set<String> = ["the", "a", "an", "and", "or", "but", "so", "to", "of", "in", "on", "at", "for", "is", "it", "i",
        "we", "you", "they", "he", "she", "that", "this", "with", "be", "was", "are", "like", "just", "yeah", "um", "uh", "know",
        "think", "really", "kind", "sort", "gonna", "going", "do", "have", "can", "what", "if", "there", "my", "your", "me", "okay", "ok",
        "right", "um", "mean", "get", "got", "not", "all", "about", "would", "will", "our", "as", "from", "up", "out", "then", "them"]

    static func notes(for meeting: Meeting, me: String) -> MeetingNotes {
        let sentences = meeting.segments.sorted { $0.start < $1.start }.flatMap { segment in
            split(segment.text).map { (speaker: segment.speaker, text: $0) }
        }
        var frequency: [String: Int] = [:]
        for sentence in sentences { for word in Set(MeetingTranscript.normalizedWords(sentence.text)) where word.count > 3 && !stopwords.contains(word) { frequency[word, default: 0] += 1 } }
        func score(_ text: String) -> Double {
            let words = MeetingTranscript.normalizedWords(text).filter { !stopwords.contains($0) }
            guard words.count >= 5 else { return 0 }
            return Double(words.reduce(0) { $0 + (frequency[$1] ?? 0) }) / Double(words.count).squareRoot()
        }
        let actions = sentences.filter { matches(actionCue, $0.text) }.prefix(8).map { sentence in
            MeetingNotes.ActionItem(task: sentence.text, owner: sentence.speaker == .me ? me : nil)
        }
        let decisions = sentences.filter { matches(decisionCue, $0.text) }.prefix(6).map(\.text)
        let ranked = sentences.enumerated().sorted { score($0.element.text) > score($1.element.text) }.prefix(8)
            .sorted { $0.offset < $1.offset }.map(\.element.text)
        let topics = frequency.sorted { $0.value > $1.value }.prefix(4).map { $0.key.capitalized }
        var summary = topics.isEmpty ? "" : "Talked about " + list(topics) + "."
        if meeting.segments.isEmpty { summary = "Nothing was transcribed in this meeting." }
        return MeetingNotes(title: "", summary: summary,
                            sections: ranked.isEmpty ? [] : [.init(heading: "Key moments", bullets: Array(ranked))],
                            decisions: Array(decisions), actionItems: Array(actions), writer: "Murmur")
    }

    static func split(_ text: String) -> [String] {
        var result: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { sentence, _, _, _ in
            if let sentence = sentence?.trimmingCharacters(in: .whitespacesAndNewlines), !sentence.isEmpty { result.append(sentence) }
        }
        return result
    }

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return "\(items[0]) and \(items[1])"
        default: return items.dropLast().joined(separator: ", ") + ", and " + items.last!
        }
    }
}

// MARK: Meeting apps

enum MeetingApps {
    /// Friendly names for apps people take calls in.
    private static let known: [(prefix: String, name: String)] = [
        ("us.zoom", "Zoom"), ("com.microsoft.teams", "Microsoft Teams"), ("com.tinyspeck.slackmacgap", "Slack"),
        ("com.hnc.Discord", "Discord"), ("com.apple.FaceTime", "FaceTime"), ("com.apple.avconferenced", "FaceTime"),
        ("com.apple.TelephonyUtilities", "Phone"), ("com.cisco.webex", "Webex"), ("com.webex", "Webex"),
        ("net.whatsapp", "WhatsApp"), ("desktop.WhatsApp", "WhatsApp"), ("com.skype", "Skype"), ("ru.keepcoder.Telegram", "Telegram"),
        ("com.loom", "Loom"), ("com.around", "Around"), ("co.tuple", "Tuple"), ("com.gather", "Gather"), ("com.signal", "Signal"),
        ("org.whispersystems.signal-desktop", "Signal"), ("com.google.Chrome", "Chrome"), ("com.apple.Safari", "Safari"),
        ("company.thebrowser", "Arc"), ("com.brave.Browser", "Brave"), ("com.microsoft.edgemac", "Edge"), ("org.mozilla.firefox", "Firefox"),
        ("company.thebrowser.dia", "Dia"), ("ai.perplexity.comet", "Comet"), ("com.vivaldi", "Vivaldi"), ("com.operasoftware", "Opera"),
    ]
    private static let browsers: Set<String> = ["Chrome", "Safari", "Arc", "Brave", "Edge", "Firefox", "Dia", "Comet", "Vivaldi", "Opera"]
    /// Microphone users that are never a meeting: dictation, Siri, voice memos, recorders.
    private static let ignored = ["com.apple.SpeechRecognitionCore", "com.apple.corespeechd", "com.apple.assistant", "com.apple.siri",
                                  "com.apple.VoiceMemos", "com.apple.dictation", "com.apple.accessibility", "com.apple.CoreSpeech",
                                  "com.apple.audio", "com.apple.controlcenter", "app.murmur", "com.apple.QuickTimePlayerX",
                                  "com.obsproject", "com.apple.PhotoBooth", "com.apple.Translate", "com.wispr", "com.superwhisper"]

    static func name(for bundleID: String) -> String? {
        guard !ignored.contains(where: { bundleID.hasPrefix($0) }) else { return nil }
        return known.first { bundleID.hasPrefix($0.prefix) }?.name
    }

    static func isBrowser(_ name: String) -> Bool { browsers.contains(name) }

    /// "Meet - abc-defg-hij" → "Google Meet". Browser calls are named after the site in the window title.
    static func site(fromTitle title: String) -> String? {
        let lower = title.lowercased()
        let sites: [(String, String)] = [("meet.google", "Google Meet"), ("meet -", "Google Meet"), ("google meet", "Google Meet"),
                                         ("zoom", "Zoom"), ("teams", "Microsoft Teams"), ("whereby", "Whereby"), ("discord", "Discord"),
                                         ("slack", "Slack"), ("webex", "Webex"), ("jitsi", "Jitsi"), ("riverside", "Riverside"),
                                         ("gather", "Gather"), ("around", "Around"), ("huddle", "Slack")]
        return sites.first { lower.contains($0.0) }?.1
    }
}
