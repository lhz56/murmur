import AppKit
import ApplicationServices
import NaturalLanguage
import Carbon

/// Words worth listening for in this recording: names, products and jargon
/// visible in the app you're dictating into, plus words you've corrected in
/// past transcripts. Nothing is stored or sent anywhere; the terms only bias
/// the on-device recognizer for one recording.
enum ContextVocabulary {
    static let maxTerms = 60

    /// Reads on-screen text, picks candidate terms, and filters out ordinary
    /// dictionary words. Bounded to a few hundred milliseconds.
    static func gather(pid: pid_t?, edits: [(original: String, corrected: String)]) async -> [String] {
        let found = await Task.detached(priority: .userInitiated) { () -> (names: [String], words: [String: Int], learned: [String]) in
            let text = pid.map { screenText(pid: $0) } ?? ""
            let (names, words) = candidates(in: text)
            return (names, words, learnedWords(from: edits))
        }.value
        return await MainActor.run {
            rank(names: found.names, words: found.words, learned: found.learned, isUnknown: isUnknownWord)
        }
    }

    // MARK: Screen text

    /// Visible text of the focused window: titles, labels, and text views,
    /// walked breadth-first with element, character, and time budgets.
    nonisolated static func screenText(pid: pid_t, maxElements: Int = 1500, maxCharacters: Int = 40_000,
                                       budget: TimeInterval = 0.25) -> String {
        guard AXIsProcessTrusted(), !IsSecureEventInputEnabled() else { return "" }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.1)
        guard let window = element(app, kAXFocusedWindowAttribute) else { return "" }
        let deadline = ProcessInfo.processInfo.systemUptime + budget
        var pieces: [String] = []
        var characters = 0
        var queue = [window]
        var visited = 0
        while !queue.isEmpty, visited < maxElements, characters < maxCharacters,
              ProcessInfo.processInfo.systemUptime < deadline {
            let current = queue.removeFirst()
            visited += 1
            let role = string(current, kAXRoleAttribute) ?? ""
            if role == "AXSecureTextField" { continue }
            for attribute in [kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute] {
                guard let value = string(current, attribute), !value.isEmpty else { continue }
                let piece = String(value.prefix(maxCharacters - characters))
                pieces.append(piece); characters += piece.count
            }
            var children: CFTypeRef?
            if AXUIElementCopyAttributeValue(current, kAXChildrenAttribute as CFString, &children) == .success,
               let list = children as? [AXUIElement] { queue.append(contentsOf: list) }
        }
        return pieces.joined(separator: "\n")
    }

    private nonisolated static func element(_ parent: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parent, attribute as CFString, &value) == .success, let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private nonisolated static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    // MARK: Picking terms

    /// Named entities (people, places, organizations) and word shapes that
    /// suggest a proper noun: capitalized, camelCase, or letters with digits.
    nonisolated static func candidates(in text: String) -> (names: [String], words: [String: Int]) {
        guard !text.isEmpty else { return ([], [:]) }
        var names: [String: Int] = [:]
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        let options: NLTagger.Options = [.omitWhitespace, .omitPunctuation, .joinNames]
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType, options: options) { tag, range in
            if let tag, [.personalName, .organizationName, .placeName].contains(tag) {
                let name = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                if name.count >= 3, name.count <= 40 { names[name, default: 0] += 1 }
            }
            return true
        }
        var words: [String: Int] = [:]
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .byWords) { word, _, _, _ in
            guard let word, word.count >= 4, word.count <= 30, isProperShape(word) else { return }
            words[word, default: 0] += 1
        }
        return (names.sorted { $0.value > $1.value }.map(\.key), words)
    }

    nonisolated static func isProperShape(_ word: String) -> Bool {
        guard let first = word.first, first.isLetter else { return false }
        let letters = word.filter(\.isLetter)
        guard letters.count >= 3, !word.allSatisfy({ $0.isUppercase || !$0.isLetter }) || word.count <= 6 else { return false }
        let innerCapital = word.dropFirst().contains(where: \.isUppercase)
        let hasDigit = word.contains(where: \.isNumber)
        return first.isUppercase || innerCapital || hasDigit
    }

    /// Words you added when correcting a transcript, e.g. "recaller" → "Recallr".
    nonisolated static func learnedWords(from edits: [(original: String, corrected: String)]) -> [String] {
        var seen = Set<String>(), result: [String] = []
        for edit in edits {
            let before = Set(words(edit.original).map { $0.lowercased() })
            for word in words(edit.corrected) where word.count >= 3 && !before.contains(word.lowercased()) {
                if seen.insert(word.lowercased()).inserted { result.append(word) }
            }
        }
        return result
    }

    private nonisolated static func words(_ text: String) -> [String] {
        var result: [String] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .byWords) { word, _, _, _ in
            if let word { result.append(word) }
        }
        return result
    }

    /// Names always qualify. Other shaped words qualify only when the system
    /// dictionary doesn't know them, which drops UI labels like "Settings".
    static func rank(names: [String], words: [String: Int], learned: [String],
                     isUnknown: (String) -> Bool, limit: Int = maxTerms) -> [String] {
        var seen = Set<String>(), result: [String] = []
        func add(_ term: String) {
            guard result.count < limit, seen.insert(term.lowercased()).inserted else { return }
            result.append(term)
        }
        learned.forEach(add)
        names.forEach(add)
        let ordered = words.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        for (word, _) in ordered where !seen.contains(word.lowercased()) && isUnknown(word) { add(word) }
        return result
    }

    @MainActor static func isUnknownWord(_ word: String) -> Bool {
        let checker = NSSpellChecker.shared
        if checker.checkSpelling(of: word, startingAt: 0).location != NSNotFound { return true }
        // "macOS" or "GPT4" can pass a spell check yet still need help.
        return word.dropFirst().contains(where: \.isUppercase) || word.contains(where: \.isNumber)
    }
}
