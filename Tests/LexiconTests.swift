import Foundation

@main struct LexiconTests {
    static func main() {
        let dictionary: Set<String> = ["really", "recall", "recolor", "work", "loom", "whisper", "flow", "keep", "home", "done", "our", "talk", "let", "me", "sheriff", "deck", "send", "the", "so"]
        let known: (String) -> Bool = { dictionary.contains($0.lowercased()) }
        func fix(_ text: String, _ terms: [String] = ["Recallr", "Workloom", "Wispr Flow", "KEEP", "Lin"]) -> String {
            Lexicon.fixingSoundAlikes(text, terms: terms, isKnownWord: known).text
        }
        // Mishearings from real dictations.
        assert(fix("Yeah, recaller so far we've submitted app review.") == "Yeah, Recallr so far we've submitted app review.")
        assert(fix("we started recolor in March, and recolor's beta") == "we started Recallr in March, and Recallr's beta", fix("we started recolor in March, and recolor's beta"))
        assert(fix("open work loom and check") == "open Workloom and check", fix("open work loom and check"))
        assert(fix("I don't need whisper flow anymore.") == "I don't need Wispr Flow anymore.")
        assert(fix("check recallr.") == "check Recallr.")
        // Plain words that only start alike stay.
        assert(fix("I'm really in awe. Let me recall that.") == "I'm really in awe. Let me recall that.")
        // Labels and short words aren't fixed by sound; nor are words across a sentence break.
        assert(fix("keep it at home, Lynn") == "keep it at home, Lynn")
        assert(fix("we need work. Loom later") == "we need work. Loom later")
        assert(fix("let me recall our talk") == "let me recall our talk", fix("let me recall our talk"))
        let fixes = Lexicon.fixingSoundAlikes("send the recaller deck", terms: ["Recallr"], isKnownWord: known).fixes
        assert(fixes.count == 1 && fixes[0].heard == "recaller" && fixes[0].term == "Recallr")

        // Memory: seeing and saying words builds confidence; labels and hashes are skipped.
        var lexicon = Lexicon()
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        lexicon.saw(["Recallr", "aad8", "README.md", "KEEP", "Done", "Nkechi", "Recallr"], at: day)
        assert(lexicon.entries["recallr"]?.seen == 1 && lexicon.entries["aad8"] == nil)
        assert(!lexicon.top(10, isKnownWord: known, now: day).contains("KEEP") && !lexicon.top(10, isKnownWord: known, now: day).contains("README.md")
               && !lexicon.top(10, isKnownWord: known, now: day).contains("Done"))
        assert(lexicon.confident(isKnownWord: known, now: day).isEmpty) // Seen once isn't enough.
        lexicon.spoke("send the Recallr deck", at: day)
        lexicon.saw(["Recallr"], at: day)
        assert(lexicon.confident(isKnownWord: known, now: day) == ["Recallr"], "\(lexicon.confident(isKnownWord: known, now: day))")
        assert(lexicon.top(1, isKnownWord: known, now: day) == ["Recallr"])
        // Words you stop running into fade.
        assert(lexicon.confident(isKnownWord: known, now: day.addingTimeInterval(86_400 * 60)).isEmpty)
        // A name that's also a dictionary word counts once you've said it mid-sentence.
        lexicon.saw(["Sharif", "Done"], at: day)
        lexicon.spoke("Done. Send it to Sharif today.", at: day)
        let top = lexicon.top(10, isKnownWord: { known($0) || $0 == "sharif" }, now: day)
        assert(top.contains("Sharif") && !top.contains("Done"), "\(top)")
        assert(Lexicon.saysMidSentence("Recallr", in: "we use Recallr.") && !Lexicon.saysMidSentence("Done", in: "Ok. Done now"))
        lexicon.forget("recallr")
        assert(lexicon.entries["recallr"] == nil)
        let data = try! JSONEncoder().encode(lexicon)
        assert(try! JSONDecoder().decode(Lexicon.self, from: data) == lexicon)
        print("PASS: Murmur remembers your words and fixes sound-alike spellings without touching plain words")
    }
}
