import AppKit
import ApplicationServices
import NaturalLanguage
import Carbon
import Contacts
import os

/// Words worth listening for in this recording: names, products and jargon
/// visible in the app you're dictating into, plus words you've corrected in
/// past transcripts. Nothing is stored or sent anywhere; the terms only bias
/// the on-device recognizer for one recording.
enum ContextVocabulary {
    static let maxTerms = 80

    /// Reads on-screen text, the project you're working in, and (if allowed)
    /// contact names, then filters out ordinary dictionary words. Bounded to
    /// a few hundred milliseconds; project and contact lists are cached.
    static func gather(pid: pid_t?, edits: [(original: String, corrected: String)], contacts: Bool = false) async -> [String] {
        let found = await Task.detached(priority: .userInitiated) { () -> (names: [String], words: [String: Int], learned: [String], extra: [String]) in
            let text = pid.map { screenText(pid: $0) } ?? ""
            let (names, words) = candidates(in: text)
            let project = pid.flatMap(projectRoot).map(projectWords) ?? []
            return (names, words, learnedWords(from: edits), project + (contacts ? contactNames() : []))
        }.value
        return await MainActor.run {
            rank(names: found.names, words: found.words, learned: found.learned, extra: found.extra, isUnknown: isUnknownWord)
        }
    }

    // MARK: Project words

    private static let cache = OSAllocatedUnfairLock(initialState: [String: (date: Date, terms: [String])]())

    private static func cached(_ key: String, maxAge: TimeInterval, make: () -> [String]) -> [String] {
        if let hit = cache.withLock({ $0[key] }), Date().timeIntervalSince(hit.date) < maxAge { return hit.terms }
        let terms = make()
        cache.withLock { $0[key] = (Date(), terms) }
        return terms
    }

    /// The git project behind the focused window: from the window's document
    /// (editors, Terminal's working directory) or a folder named in its title.
    nonisolated static func projectRoot(pid: pid_t) -> URL? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.1)
        guard let window = element(app, kAXFocusedWindowAttribute) else { return nil }
        AXUIElementSetMessagingTimeout(window, 0.1)
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser.standardizedFileURL.path
        // Folders macOS guards with a permission prompt are never probed, and a
        // dotfiles repo in your home folder isn't a project.
        let protected = ["Documents", "Desktop", "Downloads", "Library", "Pictures", "Movies", "Music"].map { home + "/" + $0 }
        func allowed(_ url: URL) -> Bool {
            let path = url.standardizedFileURL.path
            return path.hasPrefix(home + "/") && !protected.contains { path == $0 || path.hasPrefix($0 + "/") }
        }
        func gitRoot(from start: URL) -> URL? {
            var url = start
            for _ in 0..<8 {
                guard allowed(url) else { return nil }
                if fileManager.fileExists(atPath: url.appendingPathComponent(".git").path) { return url }
                let parent = url.deletingLastPathComponent()
                if parent.path == url.path || parent.path == "/" { return nil }
                url = parent
            }
            return nil
        }
        if let document = string(window, kAXDocumentAttribute), let url = URL(string: document), url.isFileURL,
           let root = gitRoot(from: url) { return root }
        guard let title = string(window, kAXTitleAttribute) else { return nil }
        let homeURL = fileManager.homeDirectoryForCurrentUser
        let parents = ["", "Developer", "Projects", "projects", "code", "Code", "src", "dev", "GitHub"]
            .map { $0.isEmpty ? homeURL : homeURL.appendingPathComponent($0) }
        for part in title.components(separatedBy: CharacterSet(charactersIn: "—–|")).map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if part.hasPrefix("~/") || part.hasPrefix("/") {
                let url = URL(fileURLWithPath: (part as NSString).expandingTildeInPath)
                if let root = gitRoot(from: url) { return root }
            }
            guard !part.isEmpty, part.count <= 60, !part.contains("/"), !part.hasPrefix(".") else { continue }
            for parent in parents where fileManager.fileExists(atPath: parent.appendingPathComponent(part).appendingPathComponent(".git").path) {
                return parent.appendingPathComponent(part)
            }
        }
        return nil
    }

    /// Names from the project's files and folders and its README: product
    /// names, types, and modules ("FluidAudio", "ContextVocabulary").
    nonisolated static func projectWords(_ root: URL) -> [String] {
        cached("project:" + root.path, maxAge: 600) {
            var counts: [String: Int] = [:]
            func add(_ word: String) { if word.count >= 4, word.count <= 40, isProperShape(word) { counts[word, default: 0] += 1 } }
            add(root.lastPathComponent.prefix(1).uppercased() + root.lastPathComponent.dropFirst())
            let skip: Set<String> = ["node_modules", ".build", "build", "dist", "Pods", "vendor", "DerivedData", ".git", "target", "venv", ".venv"]
            if let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                var seen = 0
                for case let url as URL in walker {
                    if skip.contains(url.lastPathComponent) { walker.skipDescendants(); continue }
                    if walker.level > 3 { walker.skipDescendants() }
                    seen += 1; if seen > 3000 { break }
                    let name = url.deletingPathExtension().lastPathComponent
                    for part in name.components(separatedBy: CharacterSet(charactersIn: "-_. ")) { add(part) }
                }
            }
            for name in ["README.md", "README", "readme.md", "Readme.md"] {
                if let text = try? String(contentsOf: root.appendingPathComponent(name), encoding: .utf8) {
                    let (names, words) = candidates(in: String(text.prefix(8000)))
                    names.forEach { counts[$0, default: 0] += 2 }
                    words.forEach { counts[$0.key, default: 0] += $0.value }
                    break
                }
            }
            return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(150).map(\.key)
        }
    }

    // MARK: Contacts

    /// Full names and companies from Contacts, only once access is granted.
    nonisolated static func contactNames() -> [String] {
        guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else { return [] }
        return cached("contacts", maxAge: 3600) {
            var names: [String] = []
            let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactNicknameKey, CNContactOrganizationNameKey] as [CNKeyDescriptor]
            try? CNContactStore().enumerateContacts(with: CNContactFetchRequest(keysToFetch: keys)) { contact, stop in
                let full = [contact.givenName, contact.familyName].filter { !$0.isEmpty }.joined(separator: " ")
                for name in [full, contact.nickname, contact.organizationName] where name.count >= 3 && name.count <= 40 {
                    names.append(name)
                }
                if names.count > 2000 { stop.pointee = true }
            }
            return names
        }
    }

    // MARK: Screen text

    /// Visible text of the focused window: titles, labels, and text views,
    /// walked breadth-first with element, character, and time budgets.
    nonisolated static func screenText(pid: pid_t, maxElements: Int = 1500, maxCharacters: Int = 40_000,
                                       budget: TimeInterval = 0.25) -> String {
        guard AXIsProcessTrusted(), !IsSecureEventInputEnabled() else { return "" }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.1)
        guard let window = element(app, kAXFocusedWindowAttribute) else { return "" }
        let deadline = ProcessInfo.processInfo.systemUptime + budget
        var pieces: [String] = []
        var characters = 0
        var queue = [window]
        var visited = 0
        while !queue.isEmpty, visited < maxElements, characters < maxCharacters,
              ProcessInfo.processInfo.systemUptime < deadline {
            let current = queue.removeFirst()
            AXUIElementSetMessagingTimeout(current, 0.05)
            visited += 1
            // Password fields report their kind in the subrole, not the role.
            if string(current, kAXSubroleAttribute) == kAXSecureTextFieldSubrole as String { continue }
            for attribute in [kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute] {
                guard let value = string(current, attribute), !value.isEmpty else { continue }
                let piece = String(value.prefix(maxCharacters - characters))
                pieces.append(piece); characters += piece.count
            }
            var children: CFTypeRef?
            if AXUIElementCopyAttributeValue(current, kAXChildrenAttribute as CFString, &children) == .success,
               let list = children as? [AXUIElement] { queue.append(contentsOf: list) }
        }
        return pieces.joined(separator: "\n")
    }

    private nonisolated static func element(_ parent: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parent, attribute as CFString, &value) == .success, let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private nonisolated static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    // MARK: Picking terms

    /// Named entities (people, places, organizations) and word shapes that
    /// suggest a proper noun: capitalized, camelCase, or letters with digits.
    nonisolated static func candidates(in text: String) -> (names: [String], words: [String: Int]) {
        guard !text.isEmpty else { return ([], [:]) }
        var names: [String: Int] = [:]
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        let options: NLTagger.Options = [.omitWhitespace, .omitPunctuation, .joinNames]
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType, options: options) { tag, range in
            if let tag, [.personalName, .organizationName, .placeName].contains(tag) {
                let name = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                if name.count >= 3, name.count <= 40 { names[name, default: 0] += 1 }
            }
            return true
        }
        var words: [String: Int] = [:]
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .byWords) { word, _, _, _ in
            guard let word, word.count >= 4, word.count <= 30, isProperShape(word) else { return }
            words[word, default: 0] += 1
        }
        return (names.sorted { $0.value > $1.value }.map(\.key), words)
    }

    nonisolated static func isProperShape(_ word: String) -> Bool {
        guard let first = word.first, first.isLetter else { return false }
        let letters = word.filter(\.isLetter)
        guard letters.count >= 3, !word.allSatisfy({ $0.isUppercase || !$0.isLetter }) || word.count <= 6 else { return false }
        let innerCapital = word.dropFirst().contains(where: \.isUppercase)
        let hasDigit = word.contains(where: \.isNumber)
        return first.isUppercase || innerCapital || hasDigit
    }

    /// Words you fixed when editing a transcript, e.g. "recaller" → "Recallr".
    /// Only small word swaps count; added or rewritten sentences don't.
    nonisolated static func learnedWords(from edits: [(original: String, corrected: String)]) -> [String] {
        var seen = Set<String>(), result: [String] = []
        for edit in edits {
            for pair in CorrectionLearner.pairs(original: edit.original, edited: edit.corrected)
            where seen.insert(pair.desired.lowercased()).inserted { result.append(pair.desired) }
        }
        return result
    }

    /// Learned words always qualify. Names and other shaped words qualify only when
    /// the system dictionary doesn't know them, which drops UI labels like "Settings".
    static func rank(names: [String], words: [String: Int], learned: [String], extra: [String] = [],
                     isUnknown: (String) -> Bool, limit: Int = maxTerms) -> [String] {
        var seen = Set<String>(), result: [String] = []
        func add(_ term: String) {
            guard result.count < limit, seen.insert(term.lowercased()).inserted else { return }
            result.append(term)
        }
        learned.forEach(add)
        // A one-word "name" that's also a dictionary word is usually a button or
        // label ("Done", "Hub"), and boosting it would replace what you said.
        for name in names where name.contains(" ") || isUnknown(name) { add(name) }
        let ordered = words.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        for (word, _) in ordered where !seen.contains(word.lowercased()) && isUnknown(word) { add(word) }
        // Project and contact names count when any part is unusual ("Nkechi Okafor", not "John Smith").
        for term in extra where !seen.contains(term.lowercased()) && term.split(separator: " ").contains(where: { isUnknown(String($0)) }) {
            add(term)
        }
        return result
    }

    @MainActor static func isUnknownWord(_ word: String) -> Bool {
        let checker = NSSpellChecker.shared
        if checker.checkSpelling(of: word, startingAt: 0).location != NSNotFound { return true }
        // "macOS" or "GPT4" can pass a spell check yet still need help.
        return word.dropFirst().contains(where: \.isUppercase) || word.contains(where: \.isNumber)
    }
}

/// Learns corrections from edits you make right after Murmur types: if
/// "recaller" was inserted and you fix it to "Recallr", that pair is kept.
/// Heavy rewrites are ignored; only small, similar-looking word swaps count.
enum CorrectionLearner {
    static func pairs(original: String, edited: String) -> [(heard: String, desired: String)] {
        let a = words(original), b = words(edited)
        guard !a.isEmpty, !b.isEmpty, a != b else { return [] }
        let (common, gaps) = differences(a, b, same: ==)
        // Mostly rewritten text is an edit of meaning, not a recognition fix.
        guard common * 10 >= a.count * 6 else { return [] }
        var result: [(String, String)] = []
        for gap in gaps where (1...3).contains(gap.old.count) && (1...3).contains(gap.new.count) {
            let heard = a[gap.old].joined(separator: " "), desired = b[gap.new].joined(separator: " ")
            if accept(heard: heard, desired: desired, atStart: gap.new.lowerBound == 0) { result.append((heard, desired)) }
        }
        return result.count <= 3 ? result : []
    }

    /// Longest common subsequence over words: the number of shared words, and
    /// each run that differs, as ranges into `a` and `b`.
    static func differences<T>(_ a: [T], _ b: [T], same: (T, T) -> Bool) -> (common: Int, gaps: [(old: Range<Int>, new: Range<Int>)]) {
        var table = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                table[i][j] = same(a[i], b[j]) ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var gaps: [(Range<Int>, Range<Int>)] = []
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, same(a[i], b[j]) { i += 1; j += 1; continue }
            let startI = i, startJ = j
            while i < a.count || j < b.count {
                if i < a.count, j < b.count, same(a[i], b[j]) { break }
                if j < b.count, i == a.count || table[i][j + 1] >= table[i + 1][j] { j += 1 } else { i += 1 }
            }
            gaps.append((startI..<i, startJ..<j))
        }
        return (table[0][0], gaps)
    }

    private static func accept(heard: String, desired: String, atStart: Bool) -> Bool {
        let h = heard.lowercased().filter(\.isLetter), d = desired.lowercased().filter(\.isLetter)
        guard h.count >= 3, d.count >= 3 else { return false }
        if h == d {
            // Capitalization alone counts only for names mid-sentence ("recallr" → "Recallr").
            return !atStart && heard != desired && desired.contains(where: \.isUppercase)
        }
        let score = similarity(h, d)
        // Short mishearings keep their first sound: "Zha" → "Zaw", but not "Tuesday" → "Friday".
        return score >= 0.5 || (h.first == d.first && score >= 0.3)
    }

    private static func words(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map { $0.trimmingCharacters(in: .punctuationCharacters) }.filter { !$0.isEmpty }
    }

    /// 1 − normalized edit distance.
    static func similarity(_ a: String, _ b: String) -> Double {
        let x = Array(a), y = Array(b)
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        var previous = Array(0...y.count)
        for i in 1...x.count {
            var current = [i] + Array(repeating: 0, count: y.count)
            for j in 1...y.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return 1 - Double(previous[y.count]) / Double(max(x.count, y.count))
    }
}

/// Context words are swapped in by a second model that compares how well each
/// fits the audio. With a word like "Recallr" on screen it can also win over a
/// plain word you said clearly ("I'm really in awe"). A swap that replaces
/// ordinary dictionary words is kept only when the two sound alike
/// ("whisper flow" → "Wispr Flow") or you listed it as a correction.
enum BoostGuard {
    static func filter(original: String, boosted: String, aliases: Set<String>, isKnownWord: (String) -> Bool) -> (text: String, kept: [String]) {
        let a = original.split(whereSeparator: \.isWhitespace).map(String.init)
        let b = boosted.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !a.isEmpty, a != b else { return (boosted, []) }
        let gaps = CorrectionLearner.differences(a, b) { normalized($0) == normalized($1) }.gaps
        var output: [String] = [], kept: [String] = [], position = 0
        for gap in gaps {
            output += b[position..<gap.new.lowerBound]
            position = gap.new.upperBound
            let heard = a[gap.old].map(normalized).filter { !$0.isEmpty }
            let term = b[gap.new].map { $0.trimmingCharacters(in: .punctuationCharacters) }.joined(separator: " ")
            let plainWords = !heard.isEmpty && heard.allSatisfy(isKnownWord)
            if gap.old.isEmpty || gap.new.isEmpty || !plainWords || aliases.contains(heard.joined(separator: " "))
                || soundCode(heard.joined()) == soundCode(term) {
                output += b[gap.new]
                if !gap.new.isEmpty { kept.append(term) }
            } else {
                output += a[gap.old]
            }
        }
        output += b[position...]
        return (output.joined(separator: " "), kept)
    }

    static func normalized(_ word: String) -> String { word.trimmingCharacters(in: .punctuationCharacters).lowercased() }

    /// A Soundex-style consonant code over the whole word: "whisper" and
    /// "Wispr" both give 216, "recaller" and "Recallr" 6246, "really" 64.
    static func soundCode(_ text: String) -> String {
        let groups: [String: Character] = ["bfpv": "1", "cgjkqsxz": "2", "dt": "3", "l": "4", "mn": "5", "r": "6"]
        var code = "", last: Character?
        for letter in text.lowercased() where letter.isLetter {
            let digit = groups.first { $0.key.contains(letter) }?.value
            if let digit, digit != last { code.append(digit) }
            if "aeiouy".contains(letter) { last = nil } else if digit != nil { last = digit }
        }
        return code
    }
}
