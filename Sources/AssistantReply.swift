import Foundation

/// Reads a streamed answer: the words to say, and the tags that point at the
/// screen, run a command or type text. Works on partial replies, so pointing
/// and speaking can start before the answer is finished.
struct AssistantReply: Equatable {
    struct Point: Equatable {
        var x: Double
        var y: Double
        var label: String
    }

    /// Something to do, in the order it appeared.
    enum Step: Equatable {
        case command(String)
        case type(String)
        case click(Point)
    }

    /// What's read aloud: the reply without its tags.
    var spoken = ""
    var points: [Point] = []
    /// Only finished `<do>` and `<type>` tags; one still streaming isn't here yet.
    var steps: [Step] = []
    /// Ended with `<wait>`: one step of a walkthrough. Murmur waits for the
    /// next click (yours, or its own), then looks again and carries on.
    var waits = false

    init(_ text: String) {
        var spoken = ""
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "<") {
            spoken += rest[..<open]
            let tail = rest[open...]
            let lower = tail.lowercased()
            if lower.hasPrefix("<do>") || lower.hasPrefix("<type>") {
                let name = lower.hasPrefix("<do>") ? "do" : "type"
                let body = tail.dropFirst(name.count + 2)
                // Not closed yet: it's still streaming, so nothing of it is said or done.
                guard let close = body.range(of: "</\(name)>", options: .caseInsensitive) else { rest = ""; break }
                let content = body[..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
                if !content.isEmpty { steps.append(name == "do" ? .command(content) : .type(content)) }
                rest = body[close.upperBound...]
                continue
            }
            if Self.tagName(lower, is: ["point", "click"]) {
                guard let end = tail.firstIndex(of: ">") else { rest = ""; break }
                if let point = Self.point(String(tail[tail.index(tail.startIndex, offsetBy: 6)..<end])) {
                    points.append(point)
                    if lower.hasPrefix("<click") { steps.append(.click(point)) }
                }
                rest = tail[tail.index(after: end)...]
                continue
            }
            if let end = lower.firstIndex(of: ">") {
                let inside = lower[lower.index(after: lower.startIndex)..<end]
                let name = inside.filter { $0 != "/" && !$0.isWhitespace }
                let length = lower.distance(from: lower.startIndex, to: end) + 1
                // <wait>, <wait/>, < /wait >.
                if name == "wait" {
                    waits = true
                    rest = tail[tail.index(tail.startIndex, offsetBy: length)...]
                    continue
                }
                // Some other tag the model made up, like "</final>": never read aloud.
                let bare = inside.hasPrefix("/") ? inside.dropFirst() : inside[...]
                if (1...20).contains(bare.count), bare.allSatisfy({ ("a"..."z").contains($0) || $0 == "_" }) {
                    rest = tail[tail.index(tail.startIndex, offsetBy: length)...]
                    continue
                }
            }
            // A "<" that may be the start of a tag still arriving: wait for more.
            if tail.count < 8, ["<point", "<click", "<type>", "<do>", "<wait>", "<wait/>", "<wait />"].contains(where: { $0.hasPrefix(lower) }) { rest = ""; break }
            spoken += "<"
            rest = tail.dropFirst()
        }
        spoken += rest
        self.spoken = Self.tidy(spoken)
    }

    /// `<point …` or `<click …`: the tag's name, followed by a space or `>`.
    static func tagName(_ lower: String, is names: [String]) -> Bool {
        names.contains { name in
            guard lower.hasPrefix("<" + name) else { return false }
            let after = lower.dropFirst(name.count + 1).first
            return after == ">" || after?.isWhitespace == true
        }
    }

    /// `x=640 y=212 label="Save"`, with or without quotes.
    static func point(_ attributes: String) -> Point? {
        // Reads `key = value` pairs left to right; a value is quoted or runs to the next space.
        var pairs: [String: String] = [:]
        var rest = Substring(attributes)
        while let equals = rest.firstIndex(of: "=") {
            let key = rest[..<equals].split(whereSeparator: \.isWhitespace).last.map { $0.lowercased() } ?? ""
            var value = rest[rest.index(after: equals)...].drop(while: \.isWhitespace)
            let read: Substring
            if let quote = value.first, quote == "\"" || quote == "'" {
                value = value.dropFirst()
                let close = value.firstIndex(of: quote) ?? value.endIndex
                read = value[..<close]
                rest = close < value.endIndex ? value[value.index(after: close)...] : ""
            } else {
                let end = value.firstIndex { $0.isWhitespace || $0 == ">" } ?? value.endIndex
                read = value[..<end]
                rest = value[end...]
            }
            if !key.isEmpty, pairs[key] == nil { pairs[key] = String(read).trimmingCharacters(in: .whitespaces) }
        }
        func value(_ key: String) -> String? { pairs[key] }
        guard let x = value("x").flatMap(Double.init), let y = value("y").flatMap(Double.init), x.isFinite, y.isFinite, x >= 0, y >= 0 else { return nil }
        return Point(x: x, y: y, label: value("label") ?? "")
    }

    /// Collapses the gaps tags leave behind, and drops markdown the model slipped in.
    static func tidy(_ text: String) -> String {
        let text = text.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
        // Runs of spaces become one, space before punctuation goes, blank lines close up.
        var result = ""
        for character in text {
            if ".,!?;:".contains(character) {
                while let last = result.last, last == " " || last == "\t" || last == "\n" { result.removeLast() }
            } else if character == " " || character == "\t" {
                if let last = result.last, last == " " || last == "\t" { continue }
            } else if character == "\n" {
                if result.last == "\n" { continue }
            }
            result.append(character)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Splits off the sentences that are complete, so speech can start early.
    /// Returns the finished sentences after `offset`, and the new offset.
    static func sentences(in spoken: String, after offset: Int, final: Bool) -> (String, Int) {
        let characters = Array(spoken)
        guard offset < characters.count else { return ("", offset) }
        if final { return (String(characters[offset...]).trimmingCharacters(in: .whitespacesAndNewlines), characters.count) }
        var end: Int?
        var index = characters.count - 2
        while index >= offset {
            if ".!?…".contains(characters[index]), characters[index + 1].isWhitespace {
                // "e.g. " isn't the end of a sentence.
                if !(characters[index] == "." && index > 1 && characters[index - 2] == ".") { end = index + 1; break }
            }
            index -= 1
        }
        guard let end else { return ("", offset) }
        return (String(characters[offset..<end]).trimmingCharacters(in: .whitespacesAndNewlines), end)
    }
}

/// Only the user's own words authorize actions. Screen content and model tags never grant permission.
struct AssistantIntent: Equatable {
    var clicks = false
    var types = false
    var commands = false
    private var request = ""

    /// The control's name has to be in what they said ("turn on Wi-Fi" names "Wi-Fi").
    func allowsClick(label: String) -> Bool {
        let label = Self.plain(label)
        guard clicks, !label.isEmpty else { return false }
        return " \(Self.plain(request)) ".contains(" \(label) ")
    }

    /// Lowercased words only: "Wi‑Fi," and "wi-fi" match.
    static func plain(_ text: String) -> String {
        text.lowercased().folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// "Hey, okay, so can you please…": the polite or filler words before the request.
    static let openers = ["hey", "hi", "ok", "okay", "so", "um", "uh", "alright", "all right", "right", "yo", "murmur", "please", "now",
                          "and", "then", "also", "actually", "just", "can you", "could you", "would you", "will you", "can u",
                          "i want you to", "i need you to", "i d like you to", "go ahead and", "i want to", "i wanna", "i d like to",
                          "i need to", "let s", "lets"]

    private static let questionWords = ["explain", "why", "how", "where", "what", "which", "who", "when", "is", "are", "does", "do i",
                                        "should", "walk me", "guide me", "show me", "tell me", "help me understand"]

    /// The request without the openers in front: "hey can you open slack" → "open slack". Plain words.
    static func request(_ words: String) -> String {
        var text = plain(words)
        var trimmed = true
        while trimmed {
            trimmed = false
            for opener in openers where text == opener || text.hasPrefix(opener + " ") {
                text = String(text.dropFirst(opener.count)).trimmingCharacters(in: .whitespaces)
                trimmed = true
            }
        }
        return text
    }

    /// Starts with one of these phrases, as whole words.
    static func starts(_ text: String, with phrases: [String]) -> Bool {
        phrases.contains { text == $0 || text.hasPrefix($0 + " ") }
    }

    /// A question, an explanation, or a "don't": answered, never acted on.
    static func isQuestion(_ words: String) -> Bool {
        let text = plain(words)
        let padded = " " + text + " "
        if [" don t ", " dont ", " do not ", " never "].contains(where: padded.contains) { return true }
        return starts(request(words), with: questionWords)
    }

    init(_ words: String) {
        request = words
        // Explanations and "don't" stay read-only.
        guard !Self.isQuestion(words) else { return }
        let text = Self.request(words)
        clicks = Self.starts(text, with: ["click", "press", "tap", "hit", "select", "choose", "pick", "switch", "toggle", "turn", "enable",
                                          "disable", "check", "uncheck", "do it", "go to"])
        types = Self.starts(text, with: ["type", "write", "draft", "reply", "respond", "answer", "replace", "rewrite", "insert", "make this",
                                         "make it", "fix this", "shorten", "translate", "fill"])
        commands = Self.starts(text, with: ["open", "launch", "start", "play", "put on", "listen to", "search", "look up", "google", "find",
                                            "go to", "set a timer", "timer", "remind", "volume", "turn the volume", "turn it up", "turn it down",
                                            "turn up", "turn down", "mute", "unmute", "pause", "resume", "skip", "next song", "stop the music"])
    }
}
