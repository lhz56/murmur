import Foundation

/// Opt-in check for a newer Murmur on GitHub Releases. It sends no data about
/// you; it reads the public "latest release" and compares version numbers.
@MainActor
final class UpdateChecker: ObservableObject {
    struct Release: Equatable { let version: String; let url: URL }
    @Published private(set) var available: Release?
    @Published private(set) var checking = false
    @Published private(set) var lastError: String?
    static let repository = "lhz56/murmur"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

    /// Checks at most once a day unless `force` is set.
    func check(force: Bool = false) async {
        let last = defaults.object(forKey: "lastUpdateCheck") as? Date ?? .distantPast
        guard force || Date().timeIntervalSince(last) > 86_400, !checking else { return }
        checking = true; lastError = nil
        defer { checking = false }
        do {
            var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest")!)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 15
            let (data, response) = try await URLSession.shared.data(for: request)
            defaults.set(Date(), forKey: "lastUpdateCheck")
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String, let page = (json["html_url"] as? String).flatMap(URL.init(string:)) else {
                available = nil; return
            }
            available = Self.isNewer(tag, than: currentVersion) ? Release(version: Self.clean(tag), url: page) : nil
        } catch { lastError = error.localizedDescription }
    }

    static func clean(_ tag: String) -> String { tag.hasPrefix("v") ? String(tag.dropFirst()) : tag }

    /// Numeric comparison: 1.10 is newer than 1.9, and 1.0 equals 1.0.0.
    static func isNewer(_ tag: String, than current: String) -> Bool {
        func parts(_ value: String) -> [Int] { clean(value).split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 } }
        let a = parts(tag), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
