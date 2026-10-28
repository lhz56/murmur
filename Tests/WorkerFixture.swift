import Foundation

@main struct WorkerFixture {
    static func emit(_ value: [String: Any]) {
        var data = try! JSONSerialization.data(withJSONObject: value)
        data.append(10); FileHandle.standardOutput.write(data)
    }
    static func main() {
        if CommandLine.arguments[1].hasSuffix("delayed") { Thread.sleep(forTimeInterval: 0.5) }
        emit(["type": "ready"])
        while let line = readLine(), let data = line.data(using: .utf8) {
            guard let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = request["id"] as? String, let path = request["path"] as? String else { continue }
            if path.hasSuffix("cancelled.wav") {
                Thread.sleep(forTimeInterval: 0.15)
                emit(["type": "error", "id": id, "message": "Late cancelled error"])
            } else if path.hasSuffix("crash.wav") { exit(1) }
            else {
                if path.hasSuffix("timeout.wav") { Thread.sleep(forTimeInterval: 0.3) }
                emit(["type": "result", "id": id, "text": "Fixture result", "confidence": 0.99])
            }
        }
    }
}
