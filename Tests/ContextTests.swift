import Foundation

@main struct ContextTests {
    @MainActor static func main() {
        let text = """
        Recallr launch notes. Lin Zaw met Dario Amodei in San Francisco to talk about FluidAudio and GPT4.
        Settings File Edit Window Help. The Recallr beta ships Friday; ask Nkechi Okafor about macOS builds.
        """
        let (names, words) = ContextVocabulary.candidates(in: text)
        assert(names.contains("Dario Amodei"), "\(names)")
        assert(words["Recallr"] == 2 && words["FluidAudio"] == 1 && words["GPT4"] == 1, "\(words)")
        assert(words["notes"] == nil && words["about"] == nil) // Ordinary lowercase words aren't candidates.
        assert(ContextVocabulary.isProperShape("macOS") && ContextVocabulary.isProperShape("Figma"))
        assert(!ContextVocabulary.isProperShape("figma") && !ContextVocabulary.isProperShape("SETTINGSPANEL"))

        let dictionary: Set<String> = ["Settings", "File", "Edit", "Window", "Help", "Friday", "Launch"]
        let ranked = ContextVocabulary.rank(names: names, words: words, learned: ["Recallr"],
                                            isUnknown: { !dictionary.contains($0) })
        assert(ranked.first == "Recallr", "\(ranked)")
        assert(ranked.contains("FluidAudio") && ranked.contains("Dario Amodei"))
        assert(!ranked.contains("Settings") && !ranked.contains("Friday"), "\(ranked)")
        assert(Set(ranked.map { $0.lowercased() }).count == ranked.count) // No duplicates.
        assert(ContextVocabulary.rank(names: names, words: words, learned: [], isUnknown: { _ in true }, limit: 3).count == 3)

        let learned = ContextVocabulary.learnedWords(from: [("I'm working on recaller today", "I'm working on Recallr today"),
                                                            ("same text", "same text")])
        assert(learned == ["Recallr"], "\(learned)")
        print("PASS: context terms pick names, product words and past corrections, and drop dictionary words")
    }
}
