import Foundation

enum TranscriptStatus: String, Codable { case recording, complete, interrupted, failed }

struct Transcript: Identifiable, Codable, Equatable {
    var id = UUID()
    var createdAt = Date()
    var text = ""
    var originalText = ""
    var duration: TimeInterval = 0
    var locale = "en-US"
    var sourceApp = "Murmur"
    var audioFile: String?
    var isFavorite = false
    var status: TranscriptStatus = .recording
    var deletedAt: Date?
    var engineName: String?
    var microphoneName: String?
    var confidence: Float?
    var reviewReason: String?
    /// The text before your first edit in the library; your edits teach Murmur words.
    var editedFrom: String?
    /// What happened to this dictation, shown under "What Murmur did".
    var details: DictationDetails?

    var wordCount: Int { text.split(whereSeparator: { $0.isWhitespace }).count }
    var title: String {
        let split = titleSplit
        if split.head.isEmpty { return status == .recording ? "A thought in progress" : "Untitled recording" }
        return split.rest.isEmpty || split.endsLine ? split.head : split.head + "…"
    }
    /// The words after the title, for a second line that continues instead of repeating.
    var preview: String {
        TextScan.collapsing(titleSplit.rest, \.isWhitespace)
    }
    /// The first line, cut at a word boundary near 64 characters, and everything after it.
    private var titleSplit: (head: String, rest: String, endsLine: Bool) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lineEnd = trimmed.firstIndex(where: \.isNewline) ?? trimmed.endIndex
        let line = trimmed[..<lineEnd]
        if line.count <= 64 {
            return (String(line), trimmed[lineEnd...].trimmingCharacters(in: .whitespacesAndNewlines), true)
        }
        let limit = line.index(line.startIndex, offsetBy: 61)
        let cut = line[..<limit].lastIndex(where: \.isWhitespace).flatMap { $0 > line.startIndex ? $0 : nil } ?? limit
        return (String(line[..<cut]).trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ",;:-–—"))),
                trimmed[cut...].trimmingCharacters(in: .whitespacesAndNewlines), false)
    }
    var durationLabel: String { String(format: "%d:%02d", Int(duration) / 60, Int(duration) % 60) }
}

struct DictationDetails: Codable, Equatable {
    /// Names and unusual words gathered from the screen, project, contacts and past fixes.
    var contextWords: [String] = []
    /// Words the recognizer swapped in because they were listened for.
    var boostedWords: [String] = []
    /// Cleanup steps that changed the text, in order.
    var steps: [String] = []
    var transcribeSeconds: Double?
    var polishSeconds: Double?
    var insertion: String?
}

struct HistoryDocument: Codable {
    var version = 1
    var transcripts: [Transcript]
}

/// Atomic history writes, a last-good backup, and recovery of unfinished sessions.
final class HistoryStorage {
    let root: URL
    let audioDirectory: URL
    let historyURL: URL
    let backupURL: URL
    /// Compact encoding for checkpoints written every few seconds while recording.
    private let encoder = JSONEncoder()
    /// Readable encoding for files the user exports.
    private let exportEncoder = JSONEncoder()
    private let decoder = JSONDecoder()
    /// Bytes known to decode as a valid history: the last file loaded or written.
    /// Saves reuse them for the backup instead of re-reading and re-decoding disk.
    private var lastGood: Data?
    /// Whether `historyURL` currently holds exactly `lastGood`.
    private var primaryIsCurrent = false

    init(unpreparedRoot root: URL) {
        self.root = root
        audioDirectory = root.appendingPathComponent("Recordings", isDirectory: true)
        historyURL = root.appendingPathComponent("history.json")
        backupURL = root.appendingPathComponent("history.backup.json")
        encoder.dateEncodingStrategy = .iso8601
        exportEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        exportEncoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    convenience init(root: URL) throws {
        self.init(unpreparedRoot: root)
        try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
    }

    func load() throws -> [Transcript] {
        lastGood = nil; primaryIsCurrent = false
        guard FileManager.default.fileExists(atPath: historyURL.path) else {
            guard FileManager.default.fileExists(atPath: backupURL.path) else { return [] }
            return try recover(contentsOf: backupURL)
        }
        do {
            return try recover(contentsOf: historyURL)
        } catch StorageError.newerFormat {
            throw StorageError.newerFormat
        } catch {
            // Preserve the damaged file for recovery instead of silently replacing it.
            let recovery = root.appendingPathComponent("history-damaged-\(UUID().uuidString).json")
            try? FileManager.default.copyItem(at: historyURL, to: recovery)
            return try recover(contentsOf: backupURL)
        }
    }

    private func recover(contentsOf url: URL) throws -> [Transcript] {
        let data = try Data(contentsOf: url)
        let transcripts = try recover(decoder.decode(HistoryDocument.self, from: data))
        lastGood = data; primaryIsCurrent = url == historyURL
        return transcripts
    }

    private func recover(_ document: HistoryDocument) throws -> [Transcript] {
        guard document.version == 1 else { throw StorageError.newerFormat }
        return document.transcripts.map { entry in
            var recovered = entry
            if recovered.status == .recording { recovered.status = .interrupted }
            return recovered
        }.sorted { $0.createdAt > $1.createdAt }
    }

    func save(_ transcripts: [Transcript]) throws {
        let data = try encoder.encode(HistoryDocument(transcripts: transcripts))
        if primaryIsCurrent, data == lastGood { return }
        if let previous = lastGood {
            try previous.write(to: backupURL, options: .atomic)
        } else if let previous = try? Data(contentsOf: historyURL),
                  (try? decoder.decode(HistoryDocument.self, from: previous)) != nil {
            try previous.write(to: backupURL, options: .atomic)
        }
        try data.write(to: historyURL, options: .atomic)
        lastGood = data; primaryIsCurrent = true
    }

    func audioURL(for entry: Transcript) -> URL? {
        guard let name = entry.audioFile, !name.contains("/"), !name.contains("..") else { return nil }
        return audioDirectory.appendingPathComponent(name)
    }

    func exportData(_ transcripts: [Transcript]) throws -> Data {
        try exportEncoder.encode(HistoryDocument(transcripts: transcripts))
    }

    func replaceBackup(_ transcripts: [Transcript]) throws {
        try encoder.encode(HistoryDocument(transcripts: transcripts)).write(to: backupURL, options: .atomic)
    }

    enum StorageError: LocalizedError {
        case newerFormat
        var errorDescription: String? { "This history was saved by a newer version of Murmur. Your files have been preserved." }
    }
}

enum TextTools {
    /// Conservative formatting; never changes the meaning or removes arbitrary words.
    static func clean(_ text: String, replacements: String = "", removeFillers: Bool = false, voiceCommands: Bool = false) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if removeFillers { result = withoutFillers(result) }
        result = TextScan.collapsing(result, TextScan.isSpaceOrTab)
        for line in replacements.components(separatedBy: .newlines) {
            let pair = line.components(separatedBy: "=>")
            guard pair.count == 2 else { continue }
            let heard = pair[0].trimmingCharacters(in: .whitespaces)
            let desired = pair[1].trimmingCharacters(in: .whitespaces)
            guard !heard.isEmpty, !desired.isEmpty else { continue }
            result = TextScan.replacing(heard, with: desired, in: result)
        }
        if voiceCommands { result = applyingVoiceCommands(result) }
        return result
    }

    /// The "heard => desired" pairs that matched somewhere in `text`.
    static func appliedReplacements(in text: String, replacements: String) -> [(heard: String, desired: String)] {
        replacements.components(separatedBy: .newlines).compactMap { line in
            let pair = line.components(separatedBy: "=>").map { $0.trimmingCharacters(in: .whitespaces) }
            guard pair.count == 2, !pair[0].isEmpty, !pair[1].isEmpty else { return nil }
            return TextScan.contains(pair[0], in: text) ? (pair[0], pair[1]) : nil
        }
    }

    /// English hesitation sounds the recognizer writes out: um, uh, erm, hmm.
    /// Real words ("uh-huh", "umbrella") are left alone, along with the commas
    /// that set a filler off, and a sentence that began with one is recapitalized.
    /// um, umm, uh, uhm, erm, hmm: each letter repeated any number of times.
    static func isFiller(_ word: String) -> Bool {
        let letters = Array(word.lowercased())
        func shape(_ parts: [(Character, Bool)]) -> Bool {
            // Each part is a letter that must appear (true) or may be left out (false), repeated any number of times.
            var index = 0
            for (letter, required) in parts {
                var count = 0
                while index < letters.count, letters[index] == letter { index += 1; count += 1 }
                if required, count == 0 { return false }
            }
            return index == letters.count
        }
        return shape([("u", true), ("h", true), ("m", false)]) || shape([("u", true), ("m", true)])
            || shape([("e", true), ("r", true), ("m", true)]) || shape([("h", true), ("m", true)])
    }

    static func withoutFillers(_ text: String) -> String {
        var result = text
        // Words, with apostrophes and hyphens as part of them: "uh-huh" isn't "uh".
        var words: [Range<String.Index>] = []
        var index = text.startIndex
        while index < text.endIndex {
            guard TextScan.isWord(text[index], extra: "'’-") else { index = text.index(after: index); continue }
            let start = index
            while index < text.endIndex, TextScan.isWord(text[index], extra: "'’-") { index = text.index(after: index) }
            words.append(start..<index)
        }
        // Worked out front to back, so a comma between two fillers goes with the first one only.
        var cuts: [Range<String.Index>] = []
        for word in words where isFiller(String(text[word])) {
            // The comma that sets it off goes with it: ", um," or "um, ".
            let floor = cuts.last?.upperBound ?? text.startIndex
            guard word.lowerBound >= floor else { continue }
            var lower = word.lowerBound, upper = word.upperBound
            var back = lower
            while back > floor, text[text.index(before: back)].isWhitespace { back = text.index(before: back) }
            if back > floor, text[text.index(before: back)] == "," { lower = text.index(before: back) }
            var ahead = upper
            while ahead < text.endIndex, text[ahead].isWhitespace { ahead = text.index(after: ahead) }
            if ahead < text.endIndex, text[ahead] == "," { upper = text.index(after: ahead) }
            cuts.append(lower..<upper)
        }
        for cut in cuts.reversed() {
            let lower = cut.lowerBound, upper = cut.upperBound
            // Same offsets in `result`: everything after this point was already edited, nothing before it.
            let offset = text.distance(from: text.startIndex, to: lower)
            let length = text.distance(from: lower, to: upper)
            let from = result.index(result.startIndex, offsetBy: offset)
            let range = from..<result.index(from, offsetBy: length)
            let before = result[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
            let startsSentence = before.isEmpty || ".!?\n".contains(before.last!)
            result.replaceSubrange(range, with: "")
            let start = result.index(result.startIndex, offsetBy: offset)
            if startsSentence, let letter = result[start...].firstIndex(where: { !$0.isWhitespace }),
               result[letter].isLetter {
                result.replaceSubrange(letter...letter, with: result[letter].uppercased())
            }
        }
        result = TextScan.tightening(result, before: ",.!?;:")
        result = TextScan.collapsing(result, TextScan.isSpaceOrTab, minimum: 2)
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        // A recording that was only "Um." leaves nothing worth inserting.
        return result.contains(where: { $0.isLetter || $0.isNumber }) ? result : ""
    }

    /// Spoken "new line" and "new paragraph" become line breaks. The comma or
    /// period the recognizer puts around a command is dropped with it.
    static func applyingVoiceCommands(_ text: String) -> String {
        var result = text
        let found = (TextScan.ranges(of: "new line", in: text).map { ($0, "\n") } + TextScan.ranges(of: "new paragraph", in: text).map { ($0, "\n\n") })
            .sorted { $0.0.lowerBound < $1.0.lowerBound }
        for (phrase, breaks) in found.reversed() {
            // Spaces and one comma or semicolon before; one mark and spaces after.
            var lower = phrase.lowerBound, upper = phrase.upperBound
            while lower > text.startIndex, TextScan.isSpaceOrTab(text[text.index(before: lower)]) { lower = text.index(before: lower) }
            if lower > text.startIndex, ",;".contains(text[text.index(before: lower)]) { lower = text.index(before: lower) }
            if upper < text.endIndex, ".,;:!?".contains(text[upper]) { upper = text.index(after: upper) }
            while upper < text.endIndex, TextScan.isSpaceOrTab(text[upper]) { upper = text.index(after: upper) }
            let offset = text.distance(from: text.startIndex, to: lower)
            let from = result.index(result.startIndex, offsetBy: offset)
            result.replaceSubrange(from..<result.index(from, offsetBy: text.distance(from: lower, to: upper)), with: breaks)
            let start = result.index(result.startIndex, offsetBy: offset + breaks.count)
            if start < result.endIndex, result[start].isLowercase {
                result.replaceSubrange(start...start, with: result[start].uppercased())
            }
        }
        return result
    }

    /// Adds a space when dictation lands right after a word, so two dictations
    /// in a row read "Hello there. How are you" instead of "there.How".
    static func spaced(_ text: String, after previous: Character?) -> String {
        guard let previous, !previous.isWhitespace, !"([{“‘\"'/-".contains(previous),
              let first = text.first, first.isLetter || first.isNumber else { return text }
        return " " + text
    }
}

/// Library search that understands questions: "what did I say about pricing"
/// looks for notes mentioning price/pricing. Words are matched by stem, so
/// "launches" finds "launch", and all content words must appear.
enum LibrarySearch {
    private static let stopwords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "of", "to", "in", "on", "at", "for", "with", "about", "from", "by", "as",
        "is", "are", "was", "were", "be", "been", "do", "did", "does", "i", "me", "my", "we", "our", "you", "your", "it",
        "what", "when", "where", "who", "why", "how", "which", "that", "this", "these", "those", "say", "said", "tell",
        "talk", "talked", "mention", "mentioned", "any", "anything", "something", "there", "have", "has", "had", "can",
        "could", "would", "should", "will", "find", "show", "notes", "note", "last", "ago",
    ]

    /// Stemmed content words; a plain one-word search is kept as typed.
    static func terms(_ query: String) -> [String] {
        let words = query.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        let content = words.filter { !stopwords.contains($0) }
        return (content.isEmpty ? words : content).map(stem)
    }

    static func stem(_ word: String) -> String {
        guard word.count > 4 else { return word }
        for suffix in ["ings", "ing", "ies", "ied", "es", "ed", "s"] where word.hasSuffix(suffix) && word.count - suffix.count >= 3 {
            var base = String(word.dropLast(suffix.count))
            if suffix == "ies" || suffix == "ied" { base += "y" }
            // "pricing" → "pric", which still finds "price" and "priced".
            return base.count > 4 && base.hasSuffix("e") ? String(base.dropLast()) : base
        }
        return word
    }

    static func matches(_ text: String, terms: [String]) -> Bool {
        guard !terms.isEmpty else { return true }
        return terms.allSatisfy { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    /// True when the search reads like a question for Ask.
    static func isQuestion(_ query: String) -> Bool {
        let lower = query.trimmingCharacters(in: .whitespaces).lowercased()
        return lower.hasSuffix("?") || ["what ", "when ", "where ", "who ", "why ", "how ", "did ", "do ", "which "].contains(where: lower.hasPrefix)
    }
}

/// Totals for the Insights sheet, computed from finished transcripts.
struct LibraryStats: Equatable {
    struct Day: Equatable, Identifiable { let date: Date; let words: Int; var id: Date { date } }
    var totalWords = 0
    var weekWords = 0
    var dictations = 0
    /// Words per minute while speaking, from recordings longer than a few seconds.
    var speakingPace: Int?
    /// Minutes saved versus typing the same words at `typingSpeed`.
    var minutesSaved = 0
    var days: [Day] = []

    init(_ transcripts: [Transcript], typingSpeed: Int, now: Date = Date(), calendar: Calendar = .current, dayCount: Int = 14) {
        let finished = transcripts.filter { $0.deletedAt == nil && $0.status == .complete && !$0.text.isEmpty }
        let today = calendar.startOfDay(for: now)
        let weekStart = calendar.date(byAdding: .day, value: -6, to: today)!
        var byDay: [Date: Int] = [:]
        var paceWords = 0, paceSeconds = 0.0, spokenSeconds = 0.0
        for entry in finished {
            let words = entry.wordCount
            totalWords += words
            dictations += 1
            spokenSeconds += entry.duration
            if entry.createdAt >= weekStart { weekWords += words }
            byDay[calendar.startOfDay(for: entry.createdAt), default: 0] += words
            if entry.duration >= 3 { paceWords += words; paceSeconds += entry.duration }
        }
        if paceSeconds >= 10 { speakingPace = Int((Double(paceWords) / (paceSeconds / 60)).rounded()) }
        let typingMinutes = Double(totalWords) / Double(max(typingSpeed, 1))
        minutesSaved = max(0, Int((typingMinutes - spokenSeconds / 60).rounded()))
        days = (0..<dayCount).reversed().map { offset in
            let date = calendar.date(byAdding: .day, value: -offset, to: today)!
            return Day(date: date, words: byDay[date] ?? 0)
        }
    }
}
