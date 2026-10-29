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
        // Adding a sentence teaches nothing; only word swaps count.
        assert(ContextVocabulary.learnedWords(from: [("We ship Friday.", "We ship Friday. The whole team will meet after.")]).isEmpty)
        let project = ContextVocabulary.projectWords(URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."))
        assert(project.contains("ContextVocabulary") && project.contains("FluidAudio"), "\(project.prefix(20))")
        let withExtra = ContextVocabulary.rank(names: [], words: [:], learned: [], extra: ["Nkechi Okafor", "John Smith"],
                                               isUnknown: { !["John", "Smith"].contains($0) })
        assert(withExtra == ["Nkechi Okafor"], "\(withExtra)")
        func pairs(_ a: String, _ b: String) -> [String] { CorrectionLearner.pairs(original: a, edited: b).map { "\($0.heard)=>\($0.desired)" } }
        assert(pairs("I'm working on recaller today.", "I'm working on Recallr today.") == ["recaller=>Recallr"])
        assert(pairs("Ask Lin Zha about it.", "Ask Lin Zaw about it.") == ["Zha=>Zaw"], "\(pairs("Ask Lin Zha about it.", "Ask Lin Zaw about it."))")
        assert(pairs("ship it with fluid audio", "ship it with FluidAudio") == ["fluid audio=>FluidAudio"])
        assert(pairs("we use recallr daily", "we use Recallr daily") == ["recallr=>Recallr"])
        assert(pairs("Hello there friend.", "hello there friend.").isEmpty) // Sentence-start case is style, not a name.
        assert(pairs("Meet on Tuesday at noon.", "Meet on Friday at noon.").isEmpty) // Different word, not a mishearing.
        assert(pairs("The quick brown fox jumps.", "A totally different sentence now.").isEmpty)
        assert(pairs("Same text.", "Same text.").isEmpty)
        // One-word "names" that are dictionary words are UI labels, not names.
        assert(ContextVocabulary.rank(names: ["Done", "Sharif"], words: [:], learned: [], isUnknown: { $0 != "Done" }) == ["Sharif"])
        print("PASS: context terms pick names, product words and past corrections, and drop dictionary words")

        // Real dictations where a context word replaced a plain word that was said clearly.
        let known: Set<String> = ["i'm", "really", "in", "awe", "of", "i", "don't", "need", "whisper", "flow", "send", "the", "deck",
                                  "to", "that", "would", "be", "cool", "sharing", "ask", "about", "it", "recaller", "anymore", "we"]
        func guarded(_ original: String, _ boosted: String, aliases: Set<String> = []) -> String {
            BoostGuard.filter(original: original, boosted: boosted, aliases: aliases) { known.contains($0) }.text
        }
        assert(guarded("I'm really in awe of this.", "I'm Recallr in awe of this.") == "I'm really in awe of this.")
        assert(guarded("That would be really cool.", "That would be Recallr cool.") == "That would be really cool.")
        assert(guarded("I don't need Whisper Flow anymore.", "I Done need Wispr Flow anymore.") == "I don't need Wispr Flow anymore.")
        // Real mishearings stay fixed: sound-alikes, and words the dictionary doesn't know.
        assert(guarded("send the recaller deck to nkechi", "send the Recallr deck to Nkechi") == "send the Recallr deck to Nkechi")
        assert(guarded("send the deck to Kechi.", "send the deck to Nkechi.") == "send the deck to Nkechi.")
        // A correction you listed ("sharing => Sharif") applies even when it doesn't sound alike.
        assert(guarded("Ask sharing about it.", "Ask Sharif about it.", aliases: ["sharing"]) == "Ask Sharif about it.")
        assert(guarded("Ask sharing about it.", "Ask Sharif about it.") == "Ask sharing about it.")
        let kept = BoostGuard.filter(original: "I'm really in awe of Whisper Flow", boosted: "I'm Recallr in awe of Wispr Flow", aliases: []) { known.contains($0) }.kept
        assert(kept == ["Wispr"], "\(kept)")
        assert(BoostGuard.soundCode("whisper") == BoostGuard.soundCode("Wispr") && BoostGuard.soundCode("really") != BoostGuard.soundCode("Recallr"))
        print("PASS: context words don't replace plain words you said clearly, but still fix mishearings")
    }
}
