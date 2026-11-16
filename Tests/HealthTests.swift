import Foundation

@main struct HealthTests {
    static let gb = MacHealthRules.gigabyte
    static func sample(_ free: Double, swapUsed: Double = 0, swapTotal: Double = 0, pressure: Int32 = 1, at seconds: TimeInterval = 0) -> HealthSample {
        HealthSample(date: Date(timeIntervalSince1970: 1000 + seconds), freeDisk: UInt64(free * Double(gb)),
                     swapUsed: UInt64(swapUsed * Double(gb)), swapTotal: UInt64(swapTotal * Double(gb)), pressure: pressure)
    }

    static func main() {
        // The real freeze: 11 GB free, swap nearly full, memory pressure still normal.
        assert(MacHealthRules.read(sample(11, swapUsed: 5.2, swapTotal: 6), history: []).level == .danger)
        // Plenty of disk means swap can simply grow.
        assert(MacHealthRules.read(sample(120, swapUsed: 5.2, swapTotal: 6), history: []).level == .ok)
        // A little swap on a low disk isn't an emergency.
        assert(MacHealthRules.read(sample(18, swapUsed: 0.5, swapTotal: 1), history: []).level == .ok)
        assert(MacHealthRules.read(sample(18), history: []).level == .ok)

        assert(MacHealthRules.read(sample(4), history: []).level == .danger)
        assert(MacHealthRules.read(sample(14), history: []).level == .warning)
        assert(MacHealthRules.read(sample(200, pressure: 2), history: []).level == .warning)
        assert(MacHealthRules.read(sample(200, pressure: 4), history: []).level == .danger)

        // 8 GB gone in 60 seconds with 12 GB left: about a minute and a half.
        let falling = sample(12, at: 60), start = sample(20, at: 0)
        assert(abs(MacHealthRules.minutesUntilFull(falling, history: [start])! - 1.5) < 0.01)
        assert(MacHealthRules.read(sample(30, at: 60), history: [sample(36, at: 0)]).level == .warning)
        assert(MacHealthRules.read(sample(12, at: 60), history: [start]).title == "Your disk is filling fast")
        // Small dips and old samples don't count as a fall.
        assert(MacHealthRules.minutesUntilFull(sample(50, at: 60), history: [sample(51, at: 0)]) == nil)
        assert(MacHealthRules.minutesUntilFull(sample(50, at: 600), history: [sample(90, at: 0)]) == nil)
        // A disk that grew doesn't crash the math.
        assert(MacHealthRules.minutesUntilFull(sample(90, at: 60), history: [sample(50, at: 0)]) == nil)

        let now = Date(timeIntervalSince1970: 100_000)
        assert(MacHealthRules.shouldAlert(.warning, lastSent: [:], now: now))
        assert(!MacHealthRules.shouldAlert(.ok, lastSent: [:], now: now))
        assert(!MacHealthRules.shouldAlert(.warning, lastSent: [.warning: now.addingTimeInterval(-600)], now: now))
        assert(MacHealthRules.shouldAlert(.warning, lastSent: [.warning: now.addingTimeInterval(-21600)], now: now))
        // Getting worse alerts right away; easing off doesn't.
        assert(MacHealthRules.shouldAlert(.danger, lastSent: [.warning: now], now: now))
        assert(!MacHealthRules.shouldAlert(.warning, lastSent: [.danger: now.addingTimeInterval(-600)], now: now))

        assert(MacHealthRules.stage(sample(120), level: .ok) == 0)
        assert(MacHealthRules.stage(sample(120, swapUsed: 4, swapTotal: 6), level: .ok) == 1)
        assert(MacHealthRules.stage(sample(14), level: .warning) == 2)
        assert(MacHealthRules.stage(sample(11, swapUsed: 5.2, swapTotal: 6), level: .danger) == 2)
        assert(MacHealthRules.stage(sample(2), level: .danger) == 3)
        assert(MacHealthRules.stage(sample(100, pressure: 4), level: .danger) == 2)

        assert(MacHealthRules.appName("T3 Code (Beta) Helper (Renderer)") == "T3 Code (Beta)")
        assert(MacHealthRules.appName("com.apple.WebKit.WebContent") == "Web pages")
        assert(MacHealthRules.appName("node") == "node")

        // One score: a healthy Mac is near 100; anything Murmur warns about caps it.
        assert(MacHealthRules.score(sample(200), vitals: nil, level: .ok) == 100)
        assert(MacHealthRules.score(sample(4), vitals: nil, level: .danger) <= 40)
        assert(MacHealthRules.score(sample(14), vitals: nil, level: .warning) <= 74)
        var hot = MacVitals(); hot.thermal = 2
        assert(MacHealthRules.score(sample(200), vitals: hot, level: .ok) == 85)
        assert(MacVitals.cpuShare(from: (100, 1000), to: (400, 2000)) == 0.3)
        assert(MacVitals.cpuShare(from: (100, 1000), to: (100, 1000)) == 0)

        assert(MacHealth.measure() != nil)
        let vitals = MacVitals.measure(cpu: 0)
        assert(vitals.memoryTotal > 0 && vitals.memoryUsed > 0 && vitals.memoryUsed <= vitals.memoryTotal * 2)
        print("PASS: Mac Health warns before swap runs out of disk")
    }
}
