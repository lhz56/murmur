import Foundation
import FluidAudio

struct Term: Decodable, Equatable { let text: String; let aliases: [String]? }
/// A line is a transcription (`id` + `path`), a vocabulary update (`vocabulary`), or both.
struct Request: Decodable { let id: String?; let path: String?; let vocabulary: [Term]?; let warm: Bool? }
final class Output: @unchecked Sendable { static let shared = Output(); let lock = NSLock() }
func emit(_ value: [String: Any]) {
    guard var data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return }
    data.append(10)
    Output.shared.lock.lock(); defer { Output.shared.lock.unlock() }
    FileHandle.standardOutput.write(data)
}

/// Custom words (names, products, jargon) are found by a small CTC model that
/// runs beside Parakeet and only replaces a word when the audio supports it.
/// The CTC model (~110M parameters) is downloaded and loaded on first use.
actor Vocabulary {
    private var current: [Term] = []
    private var ctc: CtcModels?
    private var tokenizer: CtcTokenizer?

    /// Loads the CTC model and tokenizer ahead of the first dictation that needs them.
    func warm() async {
        do {
            if ctc == nil { ctc = try await CtcModels.downloadAndLoad() }
            if tokenizer == nil { tokenizer = try await CtcTokenizer.load(from: CtcModels.defaultCacheDirectory()) }
            emit(["type": "vocabularyReady"])
        } catch { emit(["type": "vocabularyError", "message": error.localizedDescription]) }
    }

    func apply(_ terms: [Term], to manager: AsrManager) async {
        guard terms != current else { return }
        current = terms
        guard !terms.isEmpty else { await manager.disableVocabularyBoosting(); return }
        do {
            if ctc == nil { ctc = try await CtcModels.downloadAndLoad() }
            if tokenizer == nil { tokenizer = try await CtcTokenizer.load(from: CtcModels.defaultCacheDirectory()) }
            // The rescorer silently skips terms without CTC token IDs.
            let tokenized = terms.compactMap { term -> CustomVocabularyTerm? in
                let ids = tokenizer!.encode(term.text)
                return ids.isEmpty ? nil : CustomVocabularyTerm(text: term.text, aliases: term.aliases, ctcTokenIds: ids)
            }
            let context = CustomVocabularyContext(terms: tokenized)
            try await manager.configureVocabularyBoosting(vocabulary: context, ctcModels: ctc!)
            emit(["type": "vocabulary", "terms": terms.count])
        } catch {
            // Transcription continues without boosting; a later change retries.
            current = []
            await manager.disableVocabularyBoosting()
            emit(["type": "vocabularyError", "message": error.localizedDescription])
        }
    }
}

@main struct Worker {
    static func main() async {
        do {
            let arguments = CommandLine.arguments
            let root = URL(fileURLWithPath: arguments[1], isDirectory: true)
            let install = arguments.contains("--install")
            let models: AsrModels
            if install {
                models = try await AsrModels.downloadAndLoad(to: root, version: .v3, progressHandler: { progress in
                    emit(["type": "progress", "fraction": progress.fractionCompleted])
                })
            } else {
                guard AsrModels.modelsExist(at: root, version: .v3) else {
                    emit(["type": "error", "message": "Parakeet’s local model is missing. Install it in Murmur’s settings."]); return
                }
                models = try await AsrModels.load(from: root, version: .v3)
            }
            let manager = AsrManager(config: .default)
            try await manager.initialize(models: models)
            // Compile and touch the inference path before the first real stop.
            // No microphone is opened, and the silent result is never emitted.
            _ = try await manager.transcribe([Float](repeating: 0, count: 16000), source: .system)
            emit(["type": "ready"])
            let vocabulary = Vocabulary()
            while let line = readLine() {
                guard let data = line.data(using: .utf8), let request = try? JSONDecoder().decode(Request.self, from: data) else { continue }
                if request.warm == true { await vocabulary.warm() }
                if let terms = request.vocabulary { await vocabulary.apply(terms, to: manager) }
                guard let id = request.id, let path = request.path else { continue }
                do {
                    let result = try await manager.transcribe(URL(fileURLWithPath: path))
                    emit(["type": "result", "id": id, "text": result.text, "confidence": result.confidence,
                          "processingTime": result.processingTime, "vocabularyApplied": result.ctcAppliedTerms ?? []])
                } catch { emit(["type": "error", "id": id, "message": error.localizedDescription]) }
            }
        } catch { emit(["type": "error", "message": error.localizedDescription]) }
    }
}
