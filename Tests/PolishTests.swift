import Foundation

@main struct PolishTests {
    static func main() {
        typealias P = TextPolish
        // Changing your mind
        assert(P.applyingScratchThat("We ship Friday. Scratch that. We ship Monday.") == "We ship Monday.")
        assert(P.applyingScratchThat("Hello Sam. We ship Friday. Scratch that. Monday works.") == "Hello Sam. Monday works.")
        assert(P.applyingScratchThat("Scratch that.") == "")
        assert(P.applyingScratchThat("Keep this sentence.") == "Keep this sentence.")
        assert(P.hasCorrectionCue("Meet Tuesday, no wait, Wednesday.") && P.hasCorrectionCue("Send it to Sam, I mean Lin."))
        assert(!P.hasCorrectionCue("Meet Tuesday at noon."))
        assert(P.acceptsCorrection("Meet Wednesday.", for: "Meet Tuesday, no wait, Wednesday."))
        assert(!P.acceptsCorrection("Sure! Here is the text: Meet Wednesday.", for: "Meet Tuesday, no wait, Wednesday."))
        assert(!P.acceptsCorrection("", for: "Meet Tuesday."))

        // Addresses and lists
        assert(P.formattingAddresses("Email lin at gmail dot com today") == "Email lin@gmail.com today", P.formattingAddresses("Email lin at gmail dot com today"))
        assert(P.formattingAddresses("Check out recallr dot ai.") == "Check out recallr.ai.")
        assert(P.formattingAddresses("Look at recallr dot ai.") == "Look at recallr.ai.", P.formattingAddresses("Look at recallr dot ai."))
        assert(P.formattingAddresses("We talked about the dot com era.") == "We talked about the dot com era.")
        let list = P.formattingLists("Groceries for today. One, milk. Two, eggs. Three, bread.")
        assert(list == "Groceries for today:\n1. Milk\n2. Eggs\n3. Bread", list)
        assert(P.formattingLists("First, open the app. Second, hold Control.") == "1. Open the app\n2. Hold Control")
        assert(P.formattingLists("One thing I love is coffee. It helps.") == "One thing I love is coffee. It helps.")
        assert(P.formattingLists("Two, eggs. One, milk.") == "Two, eggs. One, milk.")

        // Style
        assert(P.AppStyle(bundleID: "com.tinyspeck.slackmacgap") == .casual && P.AppStyle(bundleID: "com.apple.Terminal") == .code)
        assert(P.AppStyle(bundleID: "com.apple.mail") == .standard && P.AppStyle(bundleID: nil) == .standard)
        assert(P.styled("Sounds good.", for: .casual) == "Sounds good")
        assert(P.styled("Sounds good.", for: .standard) == "Sounds good.")
        assert(P.styled("Moving to the U.S.", for: .casual) == "Moving to the U.S.")
        assert(P.styled("One.\nTwo.", for: .casual) == "One.\nTwo.")
        assert(P.styled("Really?", for: .code) == "Really?")

        // Snippets
        let snippets = [P.Snippet(trigger: "my email", text: "lin@recallr.ai"), P.Snippet(trigger: "calendar link", text: "cal.com/lin")]
        assert(P.expandingSnippets("Insert my email.", snippets: snippets) == "lin@recallr.ai")
        assert(P.expandingSnippets("My email", snippets: snippets) == "lin@recallr.ai")
        assert(P.expandingSnippets("Book a time here: insert calendar link.", snippets: snippets) == "Book a time here: cal.com/lin.")
        assert(P.expandingSnippets("I lost my email password.", snippets: snippets) == "I lost my email password.")
        print("PASS: scratch that, correction cues, addresses, numbered lists, per-app style, and voice snippets")
    }
}
