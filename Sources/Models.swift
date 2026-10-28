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

    var wordCount: Int { text.split(whereSeparator: { $0.isWhitespace }).count }
    var title: String {
        let split = titleSplit
        if split.head.isEmpty { return status == .recording ? "A thought in progress" : "Untitled recording" }
        return split.rest.isEmpty || split.endsLine ? split.head : split.head + "…"
    }
    /// The words after the title, for a second line that continues instead of repeating.
    var preview: String {
        titleSplit.rest.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
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
        result = result.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        for line in replacements.components(separatedBy: .newlines) {
            let pair = line.components(separatedBy: "=>")
            guard pair.count == 2 else { continue }
            let heard = pair[0].trimmingCharacters(in: .whitespaces)
            let desired = pair[1].trimmingCharacters(in: .whitespaces)
            guard !heard.isEmpty, !desired.isEmpty else { continue }
            let pattern = "(?i)(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: heard) + "(?![\\p{L}\\p{N}])"
            if let regex = try? NSRegularExpression(pattern: pattern) {
                result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: NSRegularExpression.escapedTemplate(for: desired))
            }
        }
        if voiceCommands { result = applyingVoiceCommands(result) }
        return result
    }

    /// English hesitation sounds the recognizer writes out: um, uh, erm, hmm.
    /// Real words ("uh-huh", "umbrella") are left alone, along with the commas
    /// that set a filler off, and a sentence that began with one is recapitalized.
    private static let filler = try! NSRegularExpression(
        pattern: "(?i)(,\\s*)?(?<![\\p{L}\\p{N}'’-])(?:u+h+m*|u+m+|e+r+m+|h+m+)(?![\\p{L}\\p{N}'’-])(\\s*,)?")

    static func withoutFillers(_ text: String) -> String {
        var result = text
        for match in filler.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let before = result[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
            let startsSentence = before.isEmpty || ".!?\n".contains(before.last!)
            let offset = result.distance(from: result.startIndex, to: range.lowerBound)
            result.replaceSubrange(range, with: "")
            let start = result.index(result.startIndex, offsetBy: offset)
            if startsSentence, let letter = result[start...].firstIndex(where: { !$0.isWhitespace }),
               result[letter].isLetter {
                result.replaceSubrange(letter...letter, with: result[letter].uppercased())
            }
        }
        result = result.replacingOccurrences(of: "[ \\t]+([,.!?;:])", with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: "[ \\t]{2,}", with: " ", options: .regularExpression)
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        // A recording that was only "Um." leaves nothing worth inserting.
        return result.contains(where: { $0.isLetter || $0.isNumber }) ? result : ""
    }

    /// Spoken "new line" and "new paragraph" become line breaks. The comma or
    /// period the recognizer puts around a command is dropped with it.
    private static let command = try! NSRegularExpression(
        pattern: "(?i)[,;]?[ \\t]*(?<![\\p{L}\\p{N}])new (line|paragraph)(?![\\p{L}\\p{N}])[.,;:!?]?[ \\t]*")

    static func applyingVoiceCommands(_ text: String) -> String {
        var result = text
        for match in command.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range, in: result), let kind = Range(match.range(at: 1), in: result) else { continue }
            let breaks = result[kind].lowercased() == "line" ? "\n" : "\n\n"
            let offset = result.distance(from: result.startIndex, to: range.lowerBound) + breaks.count
            result.replaceSubrange(range, with: breaks)
            let start = result.index(result.startIndex, offsetBy: offset)
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
