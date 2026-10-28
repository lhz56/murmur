import Foundation

@main struct UpdateTests {
    static func main() {
        assert(UpdateChecker.isNewer("v1.1", than: "1.0"))
        assert(UpdateChecker.isNewer("1.10", than: "1.9"))
        assert(!UpdateChecker.isNewer("v1.0.0", than: "1.0"))
        assert(!UpdateChecker.isNewer("v0.9", than: "1.0"))
        assert(UpdateChecker.isNewer("v2.0-beta", than: "1.9.9"))
        assert(UpdateChecker.clean("v1.2") == "1.2")
        print("PASS: update check compares release versions numerically")
    }
}
