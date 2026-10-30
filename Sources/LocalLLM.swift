import Foundation

/// A free language model that runs on this Mac. Murmur prefers Ollama when it's
/// installed (bigger context, better notes), then Apple Intelligence. Nothing
/// is sent to the internet.
enum LocalLLM {
    enum Failure: LocalizedError {
        case unavailable, failed(String)
        var errorDescription: String? {
            switch self {
            case .unavailable: return "No local AI model is available. Install Ollama (free) or turn on Apple Intelligence."
            case .failed(let message): return message
            }
        }
    }

    static let ollamaURL = URL(string: "http://127.0.0.1:11434")!
    /// Chat models Murmur knows work well, best first. Any other installed chat model is used if none of these are.
    /// Big models only on Macs with room for them; on 16 GB an 8B model is fast and leaves the Mac cool.
    private static var preferred: [String] {
        let large = ProcessInfo.processInfo.physicalMemory > 24 * 1_073_741_824
        let small = ["qwen3:8b", "qwen2.5:7b", "llama3.1:8b", "gemma3:4b", "qwen3:4b", "mistral", "llama3.2"]
        return large ? ["qwen3:14b", "qwen2.5:14b", "gemma3:12b"] + small : small + ["qwen3:14b", "qwen2.5:14b", "gemma3:12b"]
    }

    /// Installed Ollama chat models, or [] when Ollama isn't running.
    static func ollamaModels() async -> [String] {
        var request = URLRequest(url: ollamaURL.appendingPathComponent("api/tags"))
        request.timeoutInterval = 1.5
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else { return [] }
        return models.compactMap { model -> String? in
            guard let name = model["name"] as? String else { return nil }
            let family = ((model["details"] as? [String: Any])?["family"] as? String ?? "").lowercased()
            let capabilities = model["capabilities"] as? [String] ?? []
            if capabilities.contains("embedding") || family.contains("bert") || name.contains("embed") { return nil }
            // Ollama can also run "cloud" models that send everything to its servers. Murmur stays on this Mac.
            if model["remote_host"] != nil || model["remote_model"] != nil || name.hasSuffix("-cloud") || name.contains(":cloud") { return nil }
            return name
        }
    }

    private static let ollamaPaths = ["/opt/homebrew/bin/ollama", "/usr/local/bin/ollama", "/Applications/Ollama.app/Contents/Resources/ollama",
                                      NSHomeDirectory() + "/Applications/Ollama.app/Contents/Resources/ollama"]
    static var isOllamaInstalled: Bool { ollamaPaths.contains { FileManager.default.isExecutableFile(atPath: $0) } }

    /// Whether Ollama is answering, even with no models downloaded yet.
    static func isOllamaRunning() async -> Bool {
        var request = URLRequest(url: ollamaURL.appendingPathComponent("api/version"))
        request.timeoutInterval = 1.5
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    /// Downloads a model; `progress` gets 0…1 as it comes in.
    static func pull(_ model: String, progress: @escaping @MainActor (Double) -> Void) async throws {
        var request = URLRequest(url: ollamaURL.appendingPathComponent("api/pull"))
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": model, "stream": true])
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.failed("Ollama didn’t start the download.") }
        var finished = false
        for try await line in bytes.lines {
            guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            if let error = json["error"] as? String { throw Failure.failed(error) }
            if let total = (json["total"] as? NSNumber)?.doubleValue, total > 0, let done = (json["completed"] as? NSNumber)?.doubleValue {
                await progress(min(1, done / total))
            }
            if json["status"] as? String == "success" { finished = true }
        }
        guard finished else { throw Failure.failed("The download stopped early.") }
    }

    /// Starts Ollama in the background if it's installed but not running.
    static func wakeOllama() async -> Bool {
        if await isOllamaRunning() { return true }
        guard let binary = ollamaPaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["serve"]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        process.qualityOfService = .utility
        guard (try? process.run()) != nil else { return false }
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(300))
            if await isOllamaRunning() { return true }
        }
        return false
    }

    /// The best installed Ollama model, honoring a saved choice.
    static func pickModel(from models: [String], preferring saved: String = "") -> String? {
        if !saved.isEmpty, models.contains(saved) { return saved }
        for name in preferred { if let match = models.first(where: { $0 == name || $0.hasPrefix(name + ":") || $0 == name + ":latest" }) { return match } }
        // Vision models also chat, but plain chat models are better writers.
        return models.first { !$0.contains("vl") && !$0.contains("vision") } ?? models.first
    }

    /// One chat completion from Ollama. `schema` asks for JSON matching it.
    static func ollama(model: String, system: String, prompt: String, schema: [String: Any]? = nil,
                       context: Int? = nil, predict: Int? = nil, keepAlive: String = "20s",
                       timeout: TimeInterval = 240) async throws -> String {
        // Short answers (commands) are picked greedily: the same words always give the same plan.
        var options: [String: Any] = ["temperature": (predict ?? .max) <= 400 ? 0 : 0.2, "num_ctx": context ?? contextSize(for: system.count + prompt.count)]
        if let predict { options["num_predict"] = predict }
        var body: [String: Any] = [
            "model": model, "stream": false, "think": false, "keep_alive": keepAlive,
            "messages": [["role": "system", "content": system], ["role": "user", "content": prompt]],
            "options": options,
        ]
        if let schema { body["format"] = schema }
        var request = URLRequest(url: ollamaURL.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = json["message"] as? [String: Any], let content = message["content"] as? String else {
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw Failure.failed(detail ?? "The local model didn’t answer.")
        }
        return stripThinking(content)
    }

    /// Like `ollama`, but streams: `partial` gets the answer so far as it's written.
    static func ollamaStream(model: String, system: String, prompt: String, schema: [String: Any]? = nil,
                             context: Int? = nil, keepAlive: String = "20s", timeout: TimeInterval = 240,
                             partial: @escaping @Sendable (String) async -> Void) async throws -> String {
        var body: [String: Any] = [
            "model": model, "stream": true, "think": false, "keep_alive": keepAlive,
            "messages": [["role": "system", "content": system], ["role": "user", "content": prompt]],
            "options": ["temperature": 0.2, "num_ctx": context ?? contextSize(for: system.count + prompt.count)],
        ]
        if let schema { body["format"] = schema }
        var request = URLRequest(url: ollamaURL.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.failed("The local model didn’t answer.") }
        var text = ""
        var lastSent = Date.distantPast
        for try await line in bytes.lines {
            guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            if let error = json["error"] as? String { throw Failure.failed(error) }
            if let piece = (json["message"] as? [String: Any])?["content"] as? String { text += piece }
            // A few updates a second is smooth to watch and cheap to draw.
            if Date().timeIntervalSince(lastSent) > 0.12 { lastSent = Date(); await partial(text) }
            if json["done"] as? Bool == true { break }
        }
        guard !text.isEmpty else { throw Failure.failed("The local model didn’t answer.") }
        return stripThinking(text)
    }

    /// One tool-calling request: the model answers with the tools to run.
    /// Greedy and short, with the command context size the model was preloaded with.
    static func toolCalls(model: String, messages: [[String: Any]], tools: [[String: Any]],
                          timeout: TimeInterval = 6) async throws -> [(name: String, arguments: [String: Any])] {
        let body: [String: Any] = [
            "model": model, "stream": false, "think": false, "keep_alive": "60s", "tools": tools, "messages": messages,
            "options": ["temperature": 0, "num_ctx": commandContext, "num_predict": 300],
        ]
        var request = URLRequest(url: ollamaURL.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = json["message"] as? [String: Any] else { throw Failure.failed("The local model didn’t answer.") }
        let calls = message["tool_calls"] as? [[String: Any]] ?? []
        return calls.compactMap { call in
            guard let function = call["function"] as? [String: Any], let name = function["name"] as? String else { return nil }
            return (name, function["arguments"] as? [String: Any] ?? [:])
        }
    }

    /// Loads a model into memory ahead of a request, with the same context size,
    /// so the request that follows starts writing at once.
    static func warm(_ model: String, context: Int, keepAlive: String = "60s") async {
        guard !(await loadedModels()).contains(model) else { return }
        var request = URLRequest(url: ollamaURL.appendingPathComponent("api/generate"))
        request.httpMethod = "POST"; request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["model": model, "keep_alive": keepAlive, "options": ["num_ctx": context]])
        _ = try? await URLSession.shared.data(for: request)
    }

    /// Turns half-written JSON into the longest valid JSON it starts with, so
    /// notes can be shown while they're being written. Unfinished text values
    /// are kept; an unfinished key is dropped.
    static func closePartialJSON(_ text: String) -> String? {
        enum Container { case object, array }
        var stack: [Container] = []
        var expectingKey = false, inString = false, stringIsKey = false, escaped = false
        var safe: (end: String.Index, stack: [Container])?
        guard let start = text.firstIndex(of: "{") else { return nil }
        var index = start
        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            if inString {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" {
                    inString = false
                    if !stringIsKey { safe = (next, stack) }
                }
            } else {
                switch character {
                case "\"":
                    inString = true; stringIsKey = stack.last == .object && expectingKey
                case ":": expectingKey = false
                case ",": expectingKey = stack.last == .object
                case "{": stack.append(.object); expectingKey = true; safe = (next, stack)
                case "[": stack.append(.array); expectingKey = false; safe = (next, stack)
                case "}", "]":
                    guard !stack.isEmpty else { return nil }
                    stack.removeLast()
                    expectingKey = false
                    safe = (next, stack)
                    if stack.isEmpty { return String(text[start..<next]) }
                default: break
                }
            }
            index = next
        }
        func closers(_ stack: [Container]) -> String { stack.reversed().map { $0 == .object ? "}" : "]" }.joined() }
        if inString, !stringIsKey {
            var body = String(text[start...])
            // A half-written escape like \u00 can't be closed.
            if let slash = body.lastIndex(of: "\\"), body.distance(from: slash, to: body.endIndex) <= 6 { body = String(body[..<slash]) }
            return body + "\"" + closers(stack)
        }
        guard let safe else { return nil }
        return String(text[start..<safe.end]) + closers(safe.stack)
    }

    /// Just enough context for the prompt plus the answer. Memory grows with
    /// context, so a 10-minute call doesn't reserve what a 2-hour one needs.
    static func contextSize(for characters: Int, answer: Int = 2_048) -> Int {
        let tokens = characters / 3 + answer
        return min(16_384, max(4_096, (tokens + 1_023) / 1_024 * 1_024))
    }

    /// Context for command requests; the model is preloaded with the same size, so it isn't reloaded.
    static let commandContext = 4_096

    /// Small, quick chat models for commands, best first.
    static let small = ["qwen3:1.7b", "qwen2.5:1.5b", "gemma3:1b", "llama3.2:3b", "llama3.2:1b", "qwen3:4b", "gemma3:4b", "qwen2.5:3b", "phi4-mini"]

    /// Chat models already in memory, so using one costs no load time or extra memory.
    static func loadedModels() async -> [String] {
        var request = URLRequest(url: ollamaURL.appendingPathComponent("api/ps"))
        request.timeoutInterval = 1
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else { return [] }
        return models.filter { $0["remote_host"] == nil && $0["remote_model"] == nil }
            .compactMap { $0["name"] as? String }.filter { !$0.contains("embed") && !$0.hasSuffix("-cloud") && !$0.contains(":cloud") }
    }

    /// Loads the small command model into memory without generating anything.
    static func preload() async {
        let models = await ollamaModels()
        guard let model = small.lazy.compactMap({ name in models.first { $0 == name || $0.hasPrefix(name + "-") } }).first,
              !(await loadedModels()).contains(model) else { return }
        var request = URLRequest(url: ollamaURL.appendingPathComponent("api/generate"))
        request.httpMethod = "POST"; request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["model": model, "keep_alive": "60s", "options": ["num_ctx": commandContext]])
        _ = try? await URLSession.shared.data(for: request)
    }

    /// Qwen and DeepSeek can prefix answers with <think>…</think>.
    static func stripThinking(_ text: String) -> String {
        var result = text
        while let open = result.range(of: "<think>"), let close = result.range(of: "</think>", range: open.upperBound..<result.endIndex) {
            result.removeSubrange(open.lowerBound..<close.upperBound)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The first JSON object in a model's answer, tolerating code fences and chatter.
    static func jsonObject(in text: String) -> Data? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else { return nil }
        return String(text[start...end]).data(using: .utf8)
    }
}

/// Which model writes meeting notes and answers commands, chosen once per use.
struct Writer {
    enum Kind: Equatable { case ollama(String), apple, none }
    let kind: Kind

    var name: String {
        switch kind {
        case .ollama(let model): return model
        case .apple: return "Apple Intelligence"
        case .none: return "Murmur"
        }
    }
    /// Characters of transcript one request can hold.
    var budget: Int {
        switch kind {
        case .ollama: return 36_000
        case .apple: return 7_000
        case .none: return .max
        }
    }

    /// For understanding a command: fast and light. A small model if you have one,
    /// a bigger one only when it's already loaded, then Apple's on-device model.
    static func forCommands() async -> Writer {
        let models = await LocalLLM.ollamaModels()
        if let small = LocalLLM.small.lazy.compactMap({ name in models.first { $0 == name || $0.hasPrefix(name + "-") } }).first {
            return Writer(kind: .ollama(small))
        }
        if let loaded = await LocalLLM.loadedModels().first(where: { models.contains($0) }) { return Writer(kind: .ollama(loaded)) }
        if LocalModel.isAvailable { return Writer(kind: .apple) }
        return Writer(kind: .none)
    }

    static func best(saved: String = "", wake: Bool = true) async -> Writer {
        var models = await LocalLLM.ollamaModels()
        if models.isEmpty, wake, await LocalLLM.wakeOllama() { models = await LocalLLM.ollamaModels() }
        if let model = LocalLLM.pickModel(from: models, preferring: saved) { return Writer(kind: .ollama(model)) }
        if LocalModel.isAvailable { return Writer(kind: .apple) }
        return Writer(kind: .none)
    }

    /// `light` is for short jobs like commands: a tiny context and a capped answer.
    func respond(system: String, prompt: String, schema: [String: Any]? = nil, timeout: TimeInterval = 240, light: Bool = false,
                 predict: Int = 80, context: Int? = nil, partial: (@Sendable (String) async -> Void)? = nil) async throws -> String {
        switch kind {
        case .ollama(let model):
            if let partial, !light {
                return try await LocalLLM.ollamaStream(model: model, system: system, prompt: prompt, schema: schema,
                                                       context: context, keepAlive: "20s", timeout: timeout, partial: partial)
            }
            if light {
                return try await LocalLLM.ollama(model: model, system: system, prompt: prompt, schema: schema,
                                                 context: context ?? LocalLLM.commandContext, predict: predict, keepAlive: "60s", timeout: timeout)
            }
            // Unload soon after: notes are written once, and the Mac gets its memory back.
            return try await LocalLLM.ollama(model: model, system: system, prompt: prompt, schema: schema, context: context, keepAlive: "20s", timeout: timeout)
        case .apple:
            let instructions = schema == nil ? system : system + "\nAnswer with one JSON object only, no other text."
            return try await LocalModel.respond(instructions: instructions, prompt: prompt, timeout: .seconds(timeout))
        case .none:
            throw LocalLLM.Failure.unavailable
        }
    }
}
