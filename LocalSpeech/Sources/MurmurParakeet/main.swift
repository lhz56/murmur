import Foundation
import FluidAudio

struct Request: Decodable { let id: String; let path: String }
final class Output: @unchecked Sendable { static let shared = Output(); let lock = NSLock() }
func emit(_ value: [String: Any]) {
    guard var data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return }
    data.append(10)
    Output.shared.lock.lock(); defer { Output.shared.lock.unlock() }
    FileHandle.standardOutput.write(data)
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
            while let line = readLine() {
                guard let data = line.data(using: .utf8), let request = try? JSONDecoder().decode(Request.self, from: data) else { continue }
                do {
                    let result = try await manager.transcribe(URL(fileURLWithPath: request.path))
                    emit(["type": "result", "id": request.id, "text": result.text, "confidence": result.confidence, "processingTime": result.processingTime])
                } catch { emit(["type": "error", "id": request.id, "message": error.localizedDescription]) }
            }
        } catch { emit(["type": "error", "message": error.localizedDescription]) }
    }
}
