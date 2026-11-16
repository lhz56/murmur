import AppKit
import Foundation

/// The free local AI Murmur uses for Commands and meeting notes: finds Ollama,
/// and downloads a model with one click. Used by the welcome guide.
@MainActor
final class ModelSetup: ObservableObject {
    struct Model: Identifiable, Equatable {
        let name: String
        let title: String
        let detail: String
        let size: String
        var id: String { name }
    }

    static let commands = Model(name: "qwen3:1.7b", title: "Commands", detail: "Understands what you ask for in plain language.", size: "1.4 GB")
    static let notes = Model(name: "qwen3:8b", title: "Meeting notes", detail: "Optional. Writes full notes after a call.", size: "5.2 GB")

    @Published private(set) var isOllamaInstalled = false
    @Published private(set) var isOllamaRunning = false
    @Published private(set) var installed: Set<String> = []
    /// Models downloading now, 0…1.
    @Published private(set) var downloads: [String: Double] = [:]
    @Published private(set) var problem: String?
    private var waking = false

    /// Checks for Ollama, starting it if it's installed but not running.
    func refresh() async {
        isOllamaInstalled = LocalLLM.isOllamaInstalled
        isOllamaRunning = await LocalLLM.isOllamaRunning()
        if isOllamaInstalled, !isOllamaRunning, !waking {
            waking = true
            _ = await LocalLLM.wakeOllama()
            waking = false
            isOllamaRunning = await LocalLLM.isOllamaRunning()
        }
        if isOllamaRunning { isOllamaInstalled = true; installed = Set(await LocalLLM.ollamaModels()) }
    }

    func isReady(_ model: Model) -> Bool { installed.contains(model.name) }

    func download(_ model: Model) {
        guard downloads[model.name] == nil else { return }
        downloads[model.name] = 0; problem = nil
        Task {
            do {
                try await LocalLLM.pull(model.name) { [weak self] fraction in self?.downloads[model.name] = fraction }
                installed.insert(model.name)
            } catch { problem = "Couldn’t download \(model.title): \(error.localizedDescription)" }
            downloads[model.name] = nil
        }
    }
}
