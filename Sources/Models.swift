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
        let first = text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .newlines).first ?? ""
        if first.isEmpty { return status == .recording ? "A thought in progress" : "Untitled recording" }
        return first.count > 64 ? String(first.prefix(61)) + "…" : first
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
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(root: URL) throws {
        self.root = root
        audioDirectory = root.appendingPathComponent("Recordings", isDirectory: true)
        historyURL = root.appendingPathComponent("history.json")
        backupURL = root.appendingPathComponent("history.backup.json")
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
    }

    func load() throws -> [Transcript] {
        guard FileManager.default.fileExists(atPath: historyURL.path) else { return [] }
        let document: HistoryDocument
        do {
            document = try decoder.decode(HistoryDocument.self, from: Data(contentsOf: historyURL))
        } catch {
            // Preserve the damaged file for recovery instead of silently replacing it.
            let recovery = root.appendingPathComponent("history-damaged-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.copyItem(at: historyURL, to: recovery)
            document = try decoder.decode(HistoryDocument.self, from: Data(contentsOf: backupURL))
        }
        guard document.version == 1 else { throw StorageError.newerFormat }
        return document.transcripts.map { entry in
            var recovered = entry
            if recovered.status == .recording { recovered.status = .interrupted }
            return recovered
        }.sorted { $0.createdAt > $1.createdAt }
    }

    func save(_ transcripts: [Transcript]) throws {
        let data = try encoder.encode(HistoryDocument(transcripts: transcripts))
        if let previous = try? Data(contentsOf: historyURL),
           (try? decoder.decode(HistoryDocument.self, from: previous)) != nil {
            try previous.write(to: backupURL, options: .atomic)
        }
        try data.write(to: historyURL, options: .atomic)
    }

    func audioURL(for entry: Transcript) -> URL? {
        guard let name = entry.audioFile, !name.contains("/"), !name.contains("..") else { return nil }
        return audioDirectory.appendingPathComponent(name)
    }

    func exportData(_ transcripts: [Transcript]) throws -> Data {
        try encoder.encode(HistoryDocument(transcripts: transcripts))
    }

    func replaceBackup(_ transcripts: [Transcript]) throws {
        try exportData(transcripts).write(to: backupURL, options: .atomic)
    }

    enum StorageError: LocalizedError {
        case newerFormat
        var errorDescription: String? { "This history was saved by a newer version of Murmur. Your files have been preserved." }
    }
}

enum TextTools {
    /// Conservative formatting; never changes the meaning or removes arbitrary words.
    static func clean(_ text: String, replacements: String = "") -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
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
        return result
    }
}
