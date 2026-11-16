import Foundation

/// Rule-based finishing for English dictation: "scratch that", spoken emails
/// and domains, numbered lists, per-app style, and voice snippets. Every rule
/// is deterministic and cheap; anything needing judgment goes to the on-device
/// model only when a correction phrase is heard.
enum TextPolish {
    // MARK: Per-app style

    enum AppStyle: Equatable {
        /// Mail, documents, notes: unchanged.
        case standard
        /// Chat apps: no period after the last sentence.
        case casual
        /// Terminals and code editors: no closing period either; prose prompts still read naturally.
        case code

        init(bundleID: String?) {
            guard let id = bundleID?.lowercased() else { self = .standard; return }
            let casual = ["com.apple.mobilesms", "com.apple.ichat", "com.tinyspeck.slackmacgap", "com.hnc.discord",
                          "net.whatsapp.whatsapp", "desktop.whatsapp", "ru.keepcoder.telegram", "com.facebook.archon",
                          "com.microsoft.teams2", "com.microsoft.teams", "org.whispersystems.signal-desktop"]
            let code = ["com.apple.terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.warp-stable",
                        "com.microsoft.vscode", "com.todesktop.230313mzl4w4u92", "com.apple.dt.xcode", "dev.zed.zed",
                        "com.exafunction.windsurf", "net.kovidgoyal.kitty", "io.alacritty"]
            if casual.contains(id) { self = .casual } else if code.contains(id) { self = .code } else { self = .standard }
        }
    }

    static func styled(_ text: String, for style: AppStyle) -> String {
        guard style != .standard, !text.contains("\n"), text.hasSuffix("."), !text.hasSuffix("..") else { return text }
        // Keep the period when it ends an abbreviation or a domain ("U.S.", "recallr.ai.").
        let lastWord = text.split(separator: " ").last.map(String.init) ?? ""
        if lastWord.dropLast().contains(".") { return text }
        return String(text.dropLast())
    }

    // MARK: Changing your mind


    /// "We ship Friday. Scratch that." drops the sentence before the command.
    static func applyingScratchThat(_ text: String) -> String {
        var result = text
        while let range = scratchCommand(in: result) {
            let before = result[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
            let after = result[range.upperBound...].trimmingCharacters(in: .whitespaces)
            // Remove the last sentence (or clause run-on) before the command.
            var kept = before
            if let end = kept.dropLast().lastIndex(where: { ".!?\n".contains($0) }) {
                kept = String(kept[...end])
            } else { kept = "" }
            result = [kept, after].filter { !$0.isEmpty }.joined(separator: kept.hasSuffix("\n") ? "" : " ")
        }
        return capitalizedFirst(result.trimmingCharacters(in: .whitespaces))
    }

    /// The first "scratch that", with the mark and spaces before it and the mark after it.
    private static func scratchCommand(in text: String) -> Range<String.Index>? {
        let found = ["scratch that", "delete that", "strike that"].compactMap { TextScan.ranges(of: $0, in: text).first }.min { $0.lowerBound < $1.lowerBound }
        guard let found else { return nil }
        var lower = found.lowerBound, upper = found.upperBound
        while lower > text.startIndex, text[text.index(before: lower)].isWhitespace { lower = text.index(before: lower) }
        if lower > text.startIndex, ",.;".contains(text[text.index(before: lower)]) { lower = text.index(before: lower) } else { lower = found.lowerBound }
        if upper < text.endIndex, ".,!".contains(text[upper]) { upper = text.index(after: upper) }
        return lower..<upper
    }

    private static let correctionCues = ["no wait", "wait no", "no, sorry", "no sorry", "sorry, i meant", "sorry i meant", "sorry, i mean",
                                         "sorry i mean", "i meant", "i mean", "make that", "or rather", "correction", "actually, no",
                                         "actually no", "let me rephrase", "no no"]

    /// True when the speaker seems to correct themselves mid-sentence, which is
    /// the only time the on-device model is asked to resolve it.
    static func hasCorrectionCue(_ text: String) -> Bool {
        TextScan.containsAny(correctionCues, in: text)
    }

    /// Rejects model output that isn't a plausible cleanup of the input.
    static func acceptsCorrection(_ output: String, for input: String) -> Bool {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= input.count + 8, trimmed.count * 10 >= input.count * 3 else { return false }
        let lower = trimmed.lowercased()
        return !["sure", "here", "certainly", "i can", "i'm sorry", "as an"].contains(where: lower.hasPrefix)
    }

    /// A restyle may change wording and length a little, never wholesale.
    static func acceptsRestyle(_ output: String, for input: String) -> Bool {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count * 2 >= input.count, trimmed.count <= input.count * 2 + 20 else { return false }
        let lower = trimmed.lowercased()
        return !["sure", "here", "certainly", "i can", "i'm sorry", "as an", "restyled"].contains(where: lower.hasPrefix)
    }

    /// A user's writing style for one app, applied by the on-device model.
    struct StyleRule: Codable, Equatable, Identifiable {
        var id = UUID()
        var bundleID: String
        var appName: String
        var instruction: String
    }

    // MARK: Formatting

    private static let tlds: Set<String> = ["com", "org", "net", "io", "ai", "co", "dev", "app", "edu", "gov", "me", "us", "uk", "ca",
                                            "xyz", "so", "gg", "fm", "tv", "info", "biz"]

    private static func isLabelCharacter(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber || character == "-")
    }

    /// A spoken domain starting at `words[start]` (a plain label): "gmail dot com",
    /// "mail dot recallr dot ai". The longest run that ends in an ending like "com";
    /// the last word may carry punctuation after it ("com."). Gives the labels, the
    /// index of the last word, and that punctuation.
    private static func spokenDomain(_ words: [String], from start: Int) -> (labels: [String], end: Int, tail: String)? {
        var labels = [words[start]]
        var tails = [""]
        var index = start
        while index + 2 < words.count, words[index + 1].lowercased() == "dot" {
            let next = words[index + 2]
            let core = String(next.prefix(while: isLabelCharacter))
            let tail = String(next.dropFirst(core.count))
            guard !core.isEmpty, !(tail.first.map { $0.isLetter || $0.isNumber || $0 == "_" } ?? false) else { break }
            labels.append(core); tails.append(tail)
            index += 2
            if !tail.isEmpty { break }
        }
        for last in stride(from: labels.count - 1, through: 1, by: -1) where tlds.contains(labels[last].lowercased()) {
            return (Array(labels[...last]), start + 2 * last, tails[last])
        }
        return nil
    }

    /// Opening punctuation, then a word made only of `allowed` characters that starts
    /// with a letter or digit: "(lin" → ("(", "lin").
    private static func leading(_ word: String, allowed: (Character) -> Bool) -> (lead: String, core: String)? {
        guard let first = word.firstIndex(where: { $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        let lead = String(word[..<first]), core = String(word[first...])
        guard !(lead.last.map { $0.isLetter || $0.isNumber || $0 == "_" } ?? false), core.allSatisfy(allowed) else { return nil }
        return (lead, core)
    }

    private static let notMailboxes: Set<String> = [
        "look", "looking", "looked", "meet", "me", "us", "him", "her", "them", "it", "that", "this", "out", "here", "there",
        "arrive", "arrived", "stare", "point", "aim", "work", "works", "worked", "working", "be", "is", "are", "was", "were",
        "go", "went", "check", "find", "found", "available", "live", "lives", "hosted", "up", "online", "site", "page", "or", "and",
    ]

    /// "lin at gmail dot com" → lin@gmail.com, "recallr dot ai" → recallr.ai.
    static func formattingAddresses(_ text: String) -> String {
        var words = text.components(separatedBy: " ")
        // Email addresses first: "lin at gmail dot com".
        var index = 0
        while index < words.count {
            guard index + 2 < words.count, words[index + 1].lowercased() == "at",
                  let (lead, mailbox) = leading(words[index], allowed: { isLabelCharacter($0) || $0 == "." || $0 == "_" }),
                  words[index + 2].allSatisfy(isLabelCharacter), !words[index + 2].isEmpty,
                  let domain = spokenDomain(words, from: index + 2) else { index += 1; continue }
            if notMailboxes.contains(mailbox.lowercased()) {
                // "look at recallr dot ai" is a sentence, not an address.
                index = domain.end + 1
                continue
            }
            words.replaceSubrange(index...domain.end, with: [lead + mailbox.lowercased() + "@" + domain.labels.joined(separator: ".").lowercased() + domain.tail])
            index += 1
        }
        // Then plain addresses: "recallr dot ai".
        index = 0
        while index < words.count {
            guard let (lead, first) = leading(words[index], allowed: isLabelCharacter) else { index += 1; continue }
            var chain = words
            chain[index] = first
            guard let domain = spokenDomain(chain, from: index) else { index += 1; continue }
            let name = domain.labels.dropLast().joined(separator: " dot ").lowercased()
            if notMailboxes.contains(name) || ["the", "a", "an", "my", "your", "our"].contains(name) {
                index = domain.end + 1
                continue
            }
            words.replaceSubrange(index...domain.end, with: [lead + domain.labels.joined(separator: ".").lowercased() + domain.tail])
            index += 1
        }
        return words.joined(separator: " ")
    }

    private static let ordinals: [[String]] = [
        ["one", "first", "firstly", "1"], ["two", "second", "secondly", "2"], ["three", "third", "thirdly", "3"],
        ["four", "fourth", "4"], ["five", "fifth", "5"], ["six", "sixth", "6"], ["seven", "seventh", "7"],
        ["eight", "eighth", "8"], ["nine", "ninth", "9"], ["ten", "tenth", "10"],
    ]

    /// "Groceries. One, milk. Two, eggs." → "Groceries:\n1. Milk\n2. Eggs".
    /// Needs at least two items numbered in order, each starting a sentence.
    static func formattingLists(_ text: String) -> String {
        var sentences: [String] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .bySentences) { sentence, _, _, _ in
            if let sentence { sentences.append(sentence.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        guard sentences.count >= 2 else { return text }
        var items: [String] = []
        var firstItem: Int?
        for (index, sentence) in sentences.enumerated() {
            let words = sentence.split(separator: " ", maxSplits: 1)
            guard let head = words.first else { continue }
            let marker = head.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ",.:;)"))
            let expected = items.count
            if expected < ordinals.count, ordinals[expected].contains(marker), words.count == 2 {
                if firstItem == nil { firstItem = index }
                guard firstItem! + expected == index else { return text }
                var item = String(words[1]).trimmingCharacters(in: .whitespaces)
                if item.hasSuffix(".") { item.removeLast() }
                items.append(capitalizedFirst(item))
            } else if firstItem != nil { return text } // Trailing prose after a list: leave it alone.
        }
        guard items.count >= 2, let start = firstItem else { return text }
        var lead = sentences[..<start].joined(separator: " ")
        if lead.hasSuffix(".") { lead = String(lead.dropLast()) + ":" }
        let list = items.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        return lead.isEmpty ? list : lead + "\n" + list
    }

    // MARK: Snippets

    struct Snippet: Codable, Equatable, Identifiable {
        var id = UUID()
        var trigger: String
        var text: String
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// "Insert my email" or just "my email" → the saved text. A trigger said
    /// inside a sentence after "insert" is replaced in place.
    static func expandingSnippets(_ text: String, snippets: [Snippet]) -> String {
        let spoken = normalized(text)
        for snippet in snippets {
            let trigger = normalized(snippet.trigger)
            guard !trigger.isEmpty else { continue }
            if spoken == trigger || spoken == "insert " + trigger || spoken == "paste " + trigger { return snippet.text }
        }
        var result = text
        for snippet in snippets where !normalized(snippet.trigger).isEmpty {
            let trigger = normalized(snippet.trigger).split(separator: " ").map(String.init)
            result = replacingSaid(trigger, with: snippet.text, in: result)
        }
        return result
    }

    /// "insert my email" / "paste my, email" (any case, words apart by spaces or
    /// punctuation) replaced by `replacement`.
    private static func replacingSaid(_ trigger: [String], with replacement: String, in text: String) -> String {
        let characters = Array(text)
        func isWord(_ index: Int) -> Bool { index >= 0 && index < characters.count && (characters[index].isLetter || characters[index].isNumber || characters[index] == "_") }
        func word(_ word: String, at index: Int) -> Int? {
            let length = word.count
            guard index + length <= characters.count, String(characters[index..<(index + length)]).lowercased() == word else { return nil }
            return index + length
        }
        var output = ""
        var index = 0
        while index < characters.count {
            var end: Int?
            if !isWord(index - 1) {
                for command in ["insert", "paste"] {
                    guard let afterCommand = word(command, at: index), afterCommand < characters.count, characters[afterCommand] == " " else { continue }
                    var at = afterCommand + 1
                    var matched = true
                    for (position, piece) in trigger.enumerated() {
                        if position > 0 {
                            let gapStart = at
                            while at < characters.count, characters[at].isWhitespace || ",.-".contains(characters[at]) { at += 1 }
                            if at == gapStart { matched = false; break }
                        }
                        guard let next = word(piece, at: at) else { matched = false; break }
                        at = next
                    }
                    if matched, !isWord(at) { end = at; break }
                }
            }
            if let end {
                output += replacement
                index = end
            } else {
                output.append(characters[index])
                index += 1
            }
        }
        return output
    }

    // MARK: Helpers

    static func capitalizedFirst(_ text: String) -> String {
        guard let first = text.first, first.isLowercase else { return text }
        return first.uppercased() + text.dropFirst()
    }
}
