import Foundation
if CommandLine.arguments.contains("--check") { exit(0) }
print("{\"type\":\"ready\"}")
fflush(stdout)
while let line = readLine() {
    if let data = line.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let id = json["id"] as? String {
        Thread.sleep(forTimeInterval: 0.03)
        let data = try! JSONSerialization.data(withJSONObject: ["type": "error", "id": id, "message": "fixture error"])
        print(String(data: data, encoding: .utf8)!)
        fflush(stdout)
    }
}
