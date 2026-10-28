import Foundation
import FoundationModels

/// Apple's on-device language model (macOS 26, Apple Intelligence). Free,
/// private, and only called for explicit edits or heard self-corrections.
enum LocalModel {
    enum Failure: LocalizedError {
        case unavailable(String), timeout, rejected
        var errorDescription: String? {
            switch self {
            case .unavailable(let reason): return reason
            case .timeout: return "The on-device model took too long."
            case .rejected: return "The on-device model couldn’t do that."
            }
        }
    }

    static var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    /// A plain-language reason the model can't be used, or nil when it can.
    static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available: return nil
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Turn on Apple Intelligence in System Settings to use this."
        case .unavailable(.deviceNotEligible): return "This Mac doesn’t support Apple Intelligence."
        case .unavailable(.modelNotReady): return "Apple Intelligence is still downloading. Try again soon."
        case .unavailable: return "Apple Intelligence isn’t available right now."
        }
    }

    static func respond(instructions: String, prompt: String, timeout: Duration = .seconds(6)) async throws -> String {
        if let reason = unavailableReason { throw Failure.unavailable(reason) }
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                let session = LanguageModelSession(instructions: instructions)
                let response = try await session.respond(to: prompt, options: GenerationOptions(temperature: 0.2))
                return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            group.addTask { try await Task.sleep(for: timeout); throw Failure.timeout }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw Failure.timeout }
            return first
        }
    }

    // MARK: Tasks

    /// Applies "no wait", "I mean" style corrections. Returns nil to keep the
    /// rule-based text when the model is unavailable or its output looks wrong.
    static func resolveSelfCorrections(_ text: String) async -> String? {
        guard isAvailable else { return nil }
        let instructions = """
        You clean up dictated text. The speaker corrected themselves mid-sentence (for example "no wait", "I mean", "make that"). \
        Remove the parts they took back and keep their final intent. Keep every other word, the wording, names, and punctuation \
        exactly as given. Output only the final text, with no quotes or commentary.
        """
        guard let output = try? await respond(instructions: instructions, prompt: text, timeout: .seconds(4)),
              TextPolish.acceptsCorrection(output, for: text) else { return nil }
        return output
    }

    /// Rewrites `selection` following a spoken instruction ("make this shorter").
    static func edit(_ selection: String, instruction: String) async throws -> String {
        let instructions = """
        You edit text for the user. Apply their instruction to the text and output only the edited text. \
        Do not add quotes, explanations, or a preamble. If the instruction asks a question about the text, \
        answer it briefly instead.
        """
        let output = try await respond(instructions: instructions,
                                       prompt: "Instruction: \(instruction)\n\nText:\n\(selection)", timeout: .seconds(20))
        guard !output.isEmpty else { throw Failure.rejected }
        return output
    }

    /// Answers a question from the user's own transcripts, citing dates.
    static func answer(_ question: String, from notes: [(date: Date, text: String)]) async throws -> String {
        let formatter = DateFormatter(); formatter.dateStyle = .medium; formatter.timeStyle = .short
        let context = notes.map { "[\(formatter.string(from: $0.date))] \($0.text.prefix(1200))" }.joined(separator: "\n\n")
        let instructions = """
        You answer questions using only the user's own dictated notes below. Be brief. Mention the date of the note you used. \
        If the notes don't contain the answer, say so plainly.
        """
        return try await respond(instructions: instructions, prompt: "Notes:\n\(context)\n\nQuestion: \(question)", timeout: .seconds(20))
    }
}
