import Foundation
import SQLite3

/// Your own websites, so "open workloom" goes to workloom.live and not
/// someone else's WorkLoom. Murmur finds candidates in two local places, and
/// asks once when they disagree:
/// - the sites you visit, from your browsers' history (only site names and
///   visit counts are read, on this Mac; Safari's needs Full Disk Access);
/// - your project folders, where code and docs name the project's domain.
enum SiteBook {
    struct Candidate: Equatable {
        let host: String
        /// Visits in your browser history, or mentions in the project.
        let weight: Int
        let fromHistory: Bool
        var url: URL { URL(string: "https://" + host)! }
    }

    /// The part of a host that's the site's name: "workloom" for workloom.live,
    /// "recallrai" for recallr-ai.org. Lowercased, without dashes or spaces.
    static func label(of host: String) -> String {
        var parts = host.lowercased().split(separator: ".").map(String.init)
        if parts.first == "www" || parts.first == "app" { parts.removeFirst() }
        guard parts.count >= 2 else { return key(parts.first ?? host) }
        // "co.uk"-style endings keep one more part.
        let doubled = parts.count >= 3 && ["co", "com", "org", "net", "ac", "gov"].contains(parts[parts.count - 2]) && parts.last!.count == 2
        return key(parts[parts.count - (doubled ? 3 : 2)])
    }

    static func key(_ name: String) -> String {
        name.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Candidates for a name, best first. Names must match the site's name
    /// closely: "recallr" matches recallr-ai.org, "loom" doesn't match workloom.live.
    static func candidates(for name: String, history: [String: Int], projects: [String: [String: Int]]) -> [Candidate] {
        let wanted = key(name)
        guard wanted.count >= 3 else { return [] }
        func matches(_ host: String) -> Bool {
            let site = label(of: host)
            return site == wanted || (site.hasPrefix(wanted) && site.count - wanted.count <= 3)
        }
        var found: [String: Candidate] = [:]
        for (host, visits) in history where matches(host) {
            let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            let previous = found[bare]?.weight ?? 0
            found[bare] = Candidate(host: bare, weight: previous + visits, fromHistory: true)
        }
        for (project, domains) in projects where key(project) == wanted || matches(project) {
            for (host, mentions) in domains where matches(host) && found[host] == nil {
                found[host] = Candidate(host: host, weight: mentions, fromHistory: false)
            }
        }
        return found.values.sorted { ($0.fromHistory ? 1 : 0, $0.weight) > ($1.fromHistory ? 1 : 0, $1.weight) }
    }

    enum Answer: Equatable { case open(URL), ask([Candidate]), unknown }

    /// Open it when one site clearly wins; ask when several are plausible.
    static func decide(_ candidates: [Candidate]) -> Answer {
        guard let first = candidates.first else { return .unknown }
        if candidates.count == 1 { return .open(first.url) }
        let second = candidates[1]
        // A site you visit often, and much more than any other match.
        if first.fromHistory, first.weight >= 3, !second.fromHistory || first.weight >= second.weight * 3 { return .open(first.url) }
        return .ask(Array(candidates.prefix(4)))
    }

    // MARK: Gathering

    /// Sites in your browsers' history and how often you visited them. Reads
    /// a copy of each History database, since the browser keeps it locked.
    nonisolated static func history() -> [String: Int] {
        let home = NSHomeDirectory()
        var databases: [String] = []
        let chromium = ["Google/Chrome", "BraveSoftware/Brave-Browser", "Microsoft Edge", "Arc/User Data", "Vivaldi", "Chromium"]
        for browser in chromium {
            let root = home + "/Library/Application Support/" + browser
            for profile in (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? [] where profile == "Default" || profile.hasPrefix("Profile") {
                databases.append(root + "/" + profile + "/History")
            }
        }
        var hosts: [String: Int] = [:]
        try? FileManager.default.removeItem(at: copies)
        for database in databases where FileManager.default.fileExists(atPath: database) {
            read(database, query: "SELECT url, visit_count FROM urls ORDER BY visit_count DESC LIMIT 20000", into: &hosts)
        }
        // Safari's history is only readable with Full Disk Access; without it this quietly finds nothing.
        read(home + "/Library/Safari/History.db",
             query: "SELECT url, visit_count FROM history_items ORDER BY visit_count DESC LIMIT 20000", into: &hosts)
        return hosts
    }

    /// Copies of history databases live here only while they're read; anything left from a crash is cleared first.
    private static var copies: URL { FileManager.default.temporaryDirectory.appendingPathComponent("Murmur-history", isDirectory: true) }

    private static func read(_ path: String, query: String, into hosts: inout [String: Int]) {
        try? FileManager.default.createDirectory(at: copies, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let copy = copies.appendingPathComponent("\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: copy) }
        guard (try? FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: copy)) != nil else { return }
        var db: OpaquePointer?
        guard sqlite3_open_v2(copy.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { sqlite3_close(db); return }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let text = sqlite3_column_text(statement, 0), let host = URL(string: String(cString: text))?.host?.lowercased(),
                  host.contains("."), !host.hasSuffix(".local"), host != "localhost" else { continue }
            hosts[host, default: 0] += Int(sqlite3_column_int(statement, 1))
        }
    }

    /// Domains each project's own files mention: docs, config and code, never
    /// secrets (.env files are skipped) and never dependencies.
    nonisolated static func projects(_ folders: [String: String], appNames: Set<String>) -> [String: [String: Int]] {
        let skipped: Set<String> = ["node_modules", "dist", "build", ".build", ".git", "Pods", "DerivedData", ".next", "vendor", "target", "venv", ".venv"]
        let kinds: Set<String> = ["md", "json", "ts", "tsx", "js", "mjs", "jsx", "html", "toml", "yml", "yaml", "txt", "swift", "py", "sql", "astro", "vue", "svelte"]
        let pattern = try! NSRegularExpression(pattern: "\\b((?:[a-z0-9-]+\\.)+(?:com|app|live|io|dev|ai|co|net|org|so|xyz|me|site|page|tech|sh|gg|studio|tv))\\b",
                                               options: [.caseInsensitive])
        var result: [String: [String: Int]] = [:]
        // Personal folders are never opened (macOS also guards several of them), and only
        // real code projects are read: a folder with a repository or a package file.
        let personal: Set<String> = ["desktop", "documents", "downloads", "movies", "music", "pictures", "public", "library", "applications",
                                     "icloud drive", "mobile documents", "dropbox", "google drive", "onedrive"]
        let markers = [".git", "package.json", "Package.swift", "Cargo.toml", "pyproject.toml", "go.mod", "Gemfile", "pubspec.yaml", "CNAME"]
        for (name, path) in folders where !personal.contains(name.lowercased()) {
            guard markers.contains(where: { FileManager.default.fileExists(atPath: path + "/" + $0) }) else { continue }
            var counts: [String: Int] = [:]
            var files = 0, visited = 0
            guard let walker = FileManager.default.enumerator(at: URL(fileURLWithPath: path), includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
                                                              options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in walker {
                visited += 1
                if visited > 5_000 { break }
                if skipped.contains(url.lastPathComponent) { walker.skipDescendants(); continue }
                // Never files that may hold secrets.
                let file = url.lastPathComponent.lowercased()
                if ["secret", "credential", "token", "password", "private", "service-account", "serviceaccount", ".env", "key", "auth"].contains(where: file.contains) { continue }
                guard kinds.contains(url.pathExtension.lowercased()) || url.lastPathComponent == "CNAME",
                      (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? .max < 200_000,
                      let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                files += 1
                if files > 800 { break }
                for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                    guard let range = Range(match.range(at: 1), in: text) else { continue }
                    var host = text[range].lowercased()
                    if host.hasPrefix("www.") { host.removeFirst(4) }
                    // "Murmur.app" is an app's file name, not a website.
                    if host.hasSuffix(".app"), appNames.contains(String(host.dropLast(4))) { continue }
                    if host.contains("example") || host.hasSuffix(".test") { continue }
                    // "com.recallr.app" is an app identifier, not a website.
                    if ["com", "org", "net", "io", "app", "dev"].contains(host.split(separator: ".").first.map(String.init) ?? "") { continue }
                    counts[host, default: 0] += 1
                }
            }
            if !counts.isEmpty { result[name] = counts }
        }
        return result
    }
}
