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

    private static let scratch = try! NSRegularExpression(
        pattern: "(?i)[,.;]?\\s*\\b(scratch that|delete that|strike that)\\b[.,!]?")

    /// "We ship Friday. Scratch that." drops the sentence before the command.
    static func applyingScratchThat(_ text: String) -> String {
        var result = text
        while let match = scratch.firstMatch(in: result, range: NSRange(result.startIndex..., in: result)),
              let range = Range(match.range, in: result) {
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

    private static let correctionCue = try! NSRegularExpression(
        pattern: "(?i)\\b(no wait|wait no|no,? sorry|sorry,? i meant?|i meant?|make that|or rather|correction|actually,? no|let me rephrase|no no)\\b")

    /// True when the speaker seems to correct themselves mid-sentence, which is
    /// the only time the on-device model is asked to resolve it.
    static func hasCorrectionCue(_ text: String) -> Bool {
        correctionCue.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
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

    private static let tlds = "com|org|net|io|ai|co|dev|app|edu|gov|me|us|uk|ca|xyz|so|gg|fm|tv|info|biz"
    private static let email = try! NSRegularExpression(
        pattern: "(?i)\\b([a-z0-9][a-z0-9._-]*) at ([a-z0-9-]+(?: dot [a-z0-9-]+)*) dot (\(tlds))\\b")
    private static let domain = try! NSRegularExpression(
        pattern: "(?i)\\b([a-z0-9][a-z0-9-]*(?: dot [a-z0-9-]+)*) dot (\(tlds))\\b")

    private static let notMailboxes: Set<String> = [
        "look", "looking", "looked", "meet", "me", "us", "him", "her", "them", "it", "that", "this", "out", "here", "there",
        "arrive", "arrived", "stare", "point", "aim", "work", "works", "worked", "working", "be", "is", "are", "was", "were",
        "go", "went", "check", "find", "found", "available", "live", "lives", "hosted", "up", "online", "site", "page", "or", "and",
    ]

    /// "lin at gmail dot com" → lin@gmail.com, "recallr dot ai" → recallr.ai.
    static func formattingAddresses(_ text: String) -> String {
        var result = replace(email, in: text) { groups in
            // "look at recallr dot ai" is a sentence, not an address.
            guard !notMailboxes.contains(groups[1].lowercased()) else {
                return groups[0].replacingOccurrences(of: " at ", with: " at ", options: .caseInsensitive)
            }
            return "\(groups[1].lowercased())@\(groups[2].replacingOccurrences(of: " dot ", with: ".").lowercased()).\(groups[3].lowercased())"
        }
        result = replace(domain, in: result) { groups in
            guard !notMailboxes.contains(groups[1].lowercased()), !["the", "a", "an", "my", "your", "our"].contains(groups[1].lowercased()) else {
                return groups[0]
            }
            return "\(groups[1].replacingOccurrences(of: " dot ", with: ".").lowercased()).\(groups[2].lowercased())"
        }
        return result
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
            let words = normalized(snippet.trigger).split(separator: " ").map { NSRegularExpression.escapedPattern(for: String($0)) }
            let pattern = "(?i)\\b(?:insert|paste) " + words.joined(separator: "[\\s,.-]+") + "\\b"
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result),
                                                    withTemplate: NSRegularExpression.escapedTemplate(for: snippet.text))
        }
        return result
    }

    // MARK: Helpers

    private static func replace(_ regex: NSRegularExpression, in text: String, with make: ([String]) -> String) -> String {
        var result = text
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            let groups = (0..<match.numberOfRanges).map { index -> String in
                Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
            }
            if let range = Range(match.range, in: result) { result.replaceSubrange(range, with: make(groups)) }
        }
        return result
    }

    static func capitalizedFirst(_ text: String) -> String {
        guard let first = text.first, first.isLowercase else { return text }
        return first.uppercased() + text.dropFirst()
    }
}
