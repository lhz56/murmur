import Foundation

/// Plain text helpers Murmur uses instead of patterns: whole-word find and replace,
/// and tidying spaces. A "word" is letters and digits (plus any `extra` characters).
enum TextScan {
    static func isWord(_ character: Character, extra: String = "") -> Bool {
        character.isLetter || character.isNumber || extra.contains(character)
    }

    /// Every place `phrase` appears with no word character touching either end.
    static func ranges(of phrase: String, in text: String, extra: String = "", caseSensitive: Bool = false) -> [Range<String.Index>] {
        guard !phrase.isEmpty else { return [] }
        var found: [Range<String.Index>] = []
        var start = text.startIndex
        let options: String.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
        while start < text.endIndex, let range = text.range(of: phrase, options: options, range: start..<text.endIndex) {
            let before = range.lowerBound > text.startIndex ? text[text.index(before: range.lowerBound)] : nil
            let after = range.upperBound < text.endIndex ? text[range.upperBound] : nil
            if !(before.map { isWord($0, extra: extra) } ?? false), !(after.map { isWord($0, extra: extra) } ?? false) {
                found.append(range)
                start = range.upperBound
            } else {
                start = text.index(after: range.lowerBound)
            }
        }
        return found
    }

    static func contains(_ phrase: String, in text: String, extra: String = "", caseSensitive: Bool = false) -> Bool {
        !ranges(of: phrase, in: text, extra: extra, caseSensitive: caseSensitive).isEmpty
    }

    /// Any of `phrases`, as whole words.
    static func containsAny(_ phrases: [String], in text: String, caseSensitive: Bool = false) -> Bool {
        phrases.contains { contains($0, in: text, caseSensitive: caseSensitive) }
    }

    /// `phrase` as whole words replaced by `replacement`.
    static func replacing(_ phrase: String, with replacement: String, in text: String, extra: String = "", caseSensitive: Bool = false) -> String {
        var result = text
        for range in ranges(of: phrase, in: text, extra: extra, caseSensitive: caseSensitive).reversed() {
            result.replaceSubrange(range, with: replacement)
        }
        return result
    }

    /// Each run of at least `minimum` characters in `set` becomes one space; shorter runs stay as they are.
    static func collapsing(_ text: String, _ set: (Character) -> Bool, minimum: Int = 1) -> String {
        var result = ""
        var run = ""
        func flush() { result += run.count >= minimum ? " " : run; run = "" }
        for character in text {
            if set(character) { run.append(character) } else {
                if !run.isEmpty { flush() }
                result.append(character)
            }
        }
        if !run.isEmpty { flush() }
        return result
    }

    static func isSpaceOrTab(_ character: Character) -> Bool { character == " " || character == "\t" }

    /// Spaces and tabs right before any of `marks` go: "hi , there" → "hi, there".
    static func tightening(_ text: String, before marks: String) -> String {
        var result = ""
        for character in text {
            if marks.contains(character) { while let last = result.last, isSpaceOrTab(last) { result.removeLast() } }
            result.append(character)
        }
        return result
    }
}
