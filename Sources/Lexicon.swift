import Foundation

/// Murmur's memory of your words. Every dictation counts the names and unusual
/// words around it (on screen, in your project) and the ones you actually say.
/// Words you keep running into become words Murmur knows: it listens for them
/// even when they aren't on screen, and fixes spellings that sound the same
/// ("recaller", "recolor" → Recallr; "work loom" → Workloom).
/// Stored only on this Mac, in `lexicon.json` next to your library.
struct Lexicon: Codable, Equatable {
    struct Entry: Codable, Equatable {
        var term: String
        /// Dictations where the word was around you: on screen or in your project.
        var seen: Int = 0
        /// Dictations whose final text contained the word.
        var spoken: Int = 0
        var lastSeen: Date
    }

    var version = 1
    private(set) var entries: [String: Entry] = [:]

    /// How well Murmur knows a word. Saying it counts more than seeing it,
    /// and words you haven't come across in a while fade (half every 30 days).
    func score(_ entry: Entry, now: Date = Date()) -> Double {
        let days = max(0, now.timeIntervalSince(entry.lastSeen) / 86_400)
        return (Double(entry.seen) + 4 * Double(entry.spoken)) * pow(0.5, days / 30)
    }

    /// Counts each word once for this dictation.
    mutating func saw(_ terms: [String], at date: Date = Date()) {
        var counted = Set<String>()
        for term in terms where Self.isWorthKeeping(term) && counted.insert(term.lowercased()).inserted {
            entries[term.lowercased(), default: Entry(term: term, lastSeen: date)].seen += 1
            entries[term.lowercased()]?.term = term
            entries[term.lowercased()]?.lastSeen = date
        }
        trim()
    }

    /// Credits known words that appear, spelled exactly, in what you said.
    /// A capitalized word only counts mid-sentence, where the capital means a name.
    mutating func spoke(_ text: String, at date: Date = Date()) {
        let words = Set(Self.words(text).map { $0.lowercased() })
        for (key, entry) in entries {
            let parts = Self.words(entry.term).map { $0.lowercased() }
            guard !parts.isEmpty, parts.allSatisfy(words.contains), Self.saysMidSentence(entry.term, in: text) else { continue }
            entries[key]?.spoken += 1
            entries[key]?.lastSeen = date
        }
    }

    static func saysMidSentence(_ term: String, in text: String) -> Bool {
        var start = text.startIndex
        while let range = text.range(of: term, range: start..<text.endIndex) {
            start = range.upperBound
            let before = text[..<range.lowerBound], after = text[range.upperBound...]
            guard before.last.map({ !$0.isLetter && !$0.isNumber }) ?? true,
                  after.first.map({ !$0.isLetter && !$0.isNumber }) ?? true else { continue }
            let previous = before.last { !$0.isWhitespace }
            if let previous, !".!?\n".contains(previous) { return true }
        }
        return false
    }

    mutating func forget(_ term: String) { entries.removeValue(forKey: term.lowercased()) }

    /// The best-known words, for the recognizer to listen for.
    func top(_ limit: Int, isKnownWord: (String) -> Bool, now: Date = Date()) -> [String] {
        // Best first, checking the dictionary only until enough words qualify.
        let ranked = entries.values.map { (entry: $0, score: score($0, now: now)) }
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.entry.term < $1.entry.term }
        var result: [String] = []
        for item in ranked where result.count < limit && !isLabel(item.entry, isKnownWord: isKnownWord) { result.append(item.entry.term) }
        return result
    }

    /// Words known well enough to fix sound-alike spellings in the text itself.
    func confident(isKnownWord: (String) -> Bool, now: Date = Date()) -> [String] {
        entries.values.filter { score($0, now: now) >= 6 && !isLabel($0, isKnownWord: isKnownWord) }.map(\.term)
    }

    /// Replaces words that sound and look like a known word: "recaller" →
    /// "Recallr", "work loom" → "Workloom". Ordinary words that merely start
    /// alike ("really", "recall") have a different sound and are left alone.
    static func fixingSoundAlikes(_ text: String, terms: [String], isKnownWord: (String) -> Bool) -> (text: String, fixes: [(heard: String, term: String)]) {
        let targets = terms.filter { isFixable($0, isKnownWord: isKnownWord) }
            .sorted { $0.count > $1.count }
            .map { (term: $0, letters: letters($0), code: BoostGuard.soundCode($0), parts: words($0).count) }
        guard !targets.isEmpty else { return (text, []) }
        var tokens = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        var fixes: [(String, String)] = []
        var i = 0
        while i < tokens.count {
            var matched = false
            for target in targets {
                // A term can be heard as one more or one fewer word ("work loom").
                for span in Set([target.parts, target.parts + 1, max(1, target.parts - 1)]).sorted(by: >) where i + span <= tokens.count {
                    let slice = Array(tokens[i..<(i + span)])
                    let (core, prefix, suffix) = split(slice)
                    let heard = core.joined(separator: " ")
                    let heardLetters = letters(heard)
                    guard !heardLetters.isEmpty, heard != target.term,
                          !core.contains(where: { stopwords.contains($0.lowercased()) }),
                          core.dropLast().allSatisfy({ !$0.contains(where: { ",.;:!?".contains($0) }) }) else { continue }
                    let sameLetters = heardLetters == target.letters
                    let sameStart: Bool = heardLetters.first == target.letters.first
                    let sameSound: Bool = BoostGuard.soundCode(heard) == target.code
                    let similar: Bool = CorrectionLearner.similarity(heardLetters, target.letters) >= 0.6
                    guard sameLetters || (sameStart && sameSound && similar) else { continue }
                    tokens.replaceSubrange(i..<(i + span), with: [prefix + target.term + suffix])
                    fixes.append((heard, target.term))
                    matched = true
                    break
                }
                if matched { break }
            }
            i += 1
        }
        return (tokens.joined(separator: " "), fixes)
    }

    // MARK: Helpers

    private static let stopwords: Set<String> = ["a", "an", "the", "and", "or", "but", "to", "of", "in", "on", "at", "for", "is",
                                                 "it", "i", "we", "you", "he", "she", "they", "be", "so", "as", "by", "my", "our",
                                                 "your", "their", "his", "her", "its", "me", "us", "them", "this", "that", "with",
                                                 "from", "are", "was", "were", "am", "not", "no", "do", "if", "up", "out", "all"]

    /// Leading punctuation of the first word, and trailing punctuation or "'s" of the last.
    private static func split(_ slice: [String]) -> (core: [String], prefix: String, suffix: String) {
        var core = slice
        let first = core[0]
        let prefix = String(first.prefix { !$0.isLetter && !$0.isNumber })
        core[0] = String(first.dropFirst(prefix.count))
        var last = core[core.count - 1]
        var suffix = String(last.reversed().prefix { !$0.isLetter && !$0.isNumber }.reversed())
        last = String(last.dropLast(suffix.count))
        for possessive in ["'s", "’s"] where last.lowercased().hasSuffix(possessive) {
            suffix = String(last.suffix(2)) + suffix; last = String(last.dropLast(2))
        }
        core[core.count - 1] = last
        return (core, prefix, suffix)
    }

    private static func letters(_ text: String) -> String { text.lowercased().filter(\.isLetter) }

    static func words(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map { $0.trimmingCharacters(in: .punctuationCharacters) }.filter { !$0.isEmpty }
    }

    /// Hashes, IDs and file names aren't words anyone says.
    static func isWorthKeeping(_ term: String) -> Bool {
        let letters = term.filter(\.isLetter)
        guard letters.count >= 3, term.count <= 40, !term.contains("/"), !term.contains("@") else { return false }
        let digits = term.filter(\.isNumber).count
        return digits == 0 || (term.contains(where: \.isUppercase) && digits <= 2 && term.count <= 8)
    }

    /// Buttons and labels ("Done", "KEEP") and file names ("README.md"): one
    /// ordinary dictionary word isn't worth listening for.
    func isLabel(_ entry: Entry, isKnownWord: (String) -> Bool) -> Bool {
        let term = entry.term
        if term.contains(".") && !term.contains(" ") { return true }
        // "YouTube" and names you've said ("Lin", "Sharif") are words, not labels.
        let innerCapital = term.dropFirst().contains(where: \.isUppercase) && !term.allSatisfy { !$0.isLetter || $0.isUppercase }
        return !term.contains(" ") && !innerCapital && entry.spoken == 0 && isKnownWord(term.lowercased())
    }

    /// Only distinctive words are fixed by sound: not dictionary words, not
    /// short ones, and not all-caps labels.
    static func isFixable(_ term: String, isKnownWord: (String) -> Bool) -> Bool {
        let parts = words(term)
        guard letters(term).count >= 4, !parts.isEmpty, parts.count <= 3,
              !term.allSatisfy({ !$0.isLetter || $0.isUppercase }) else { return false }
        return parts.contains { !isKnownWord($0.lowercased()) }
    }

    /// Keeps the file small: the 2,000 best-known words.
    private mutating func trim() {
        guard entries.count > 2_400 else { return }
        let now = Date()
        let keep = entries.sorted { score($0.value, now: now) > score($1.value, now: now) }.prefix(2_000)
        entries = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
    }
}

extension JSONEncoder {
    static var iso: JSONEncoder { let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; return encoder }
}

extension JSONDecoder {
    static var iso: JSONDecoder { let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; return decoder }
}
