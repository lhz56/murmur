import Foundation
import UserNotifications

/// One look at the things that freeze a Mac when they run out.
struct HealthSample: Equatable {
    var date: Date
    var freeDisk: UInt64
    var swapUsed: UInt64
    var swapTotal: UInt64
    /// 1 normal, 2 warning, 4 critical.
    var pressure: Int32
    var totalDisk: UInt64 = 0
    var swapFree: UInt64 { swapTotal > swapUsed ? swapTotal - swapUsed : 0 }
}

enum HealthLevel: Int, Comparable {
    case ok, warning, danger
    static func < (a: HealthLevel, b: HealthLevel) -> Bool { a.rawValue < b.rawValue }
}

struct HealthReading: Equatable {
    var level: HealthLevel
    var title: String
    var detail: String
    static let ok = HealthReading(level: .ok, title: "Your Mac has room to work", detail: "Murmur will warn you before the disk or memory runs out.")
}

/// macOS keeps memory it can't hold in swap files on the disk. When the disk is
/// full those files can't grow, and the system starts freezing apps one by one.
/// "Memory free" still looks fine at that point, so these rules watch free disk,
/// swap room and how fast the disk is filling instead.
enum MacHealthRules {
    static let gigabyte: UInt64 = 1_073_741_824

    static func gb(_ bytes: UInt64) -> String { String(format: "%.1f GB", Double(bytes) / Double(gigabyte)) }

    /// Minutes until the disk is full at the pace of the last two minutes, if it's dropping fast.
    static func minutesUntilFull(_ sample: HealthSample, history: [HealthSample]) -> Double? {
        guard let oldest = history.first(where: { sample.date.timeIntervalSince($0.date) <= 120 }),
              oldest.freeDisk > sample.freeDisk else { return nil }
        let seconds = sample.date.timeIntervalSince(oldest.date), lost = oldest.freeDisk - sample.freeDisk
        guard seconds >= 30, lost >= 2 * gigabyte else { return nil }
        return Double(sample.freeDisk) / (Double(lost) / seconds) / 60
    }

    static func read(_ sample: HealthSample, history: [HealthSample]) -> HealthReading {
        let free = gb(sample.freeDisk), minutes = minutesUntilFull(sample, history: history)
        if sample.freeDisk < 5 * gigabyte {
            return HealthReading(level: .danger, title: "Your disk is almost full", detail: "Only \(free) left. Apps will start to freeze if it runs out.")
        }
        if let minutes, minutes < 3 {
            return HealthReading(level: .danger, title: "Your disk is filling fast", detail: "\(free) left, gone in about \(max(1, Int(minutes))) min at this pace.")
        }
        if sample.freeDisk < 20 * gigabyte, sample.swapUsed >= 3 * gigabyte, sample.swapFree < 3 * gigabyte / 2 {
            return HealthReading(level: .danger, title: "Your Mac is running out of memory room", detail: "Swap is nearly full and only \(free) of disk is left for it to grow. Free up space or quit something heavy.")
        }
        if sample.pressure >= 4 {
            return HealthReading(level: .danger, title: "Memory is critically low", detail: "Quit something heavy before your Mac slows to a crawl.")
        }
        if let minutes, minutes < 10 {
            return HealthReading(level: .warning, title: "Your disk is filling fast", detail: "\(free) left, gone in about \(Int(minutes)) min at this pace.")
        }
        if sample.freeDisk < 15 * gigabyte {
            return HealthReading(level: .warning, title: "Your disk is getting full", detail: "\(free) left. A Mac needs room on its disk to use as memory.")
        }
        if sample.pressure >= 2 {
            return HealthReading(level: .warning, title: "Memory is running low", detail: "Quitting something heavy will keep your Mac quick.")
        }
        return .ok
    }

    /// Alerts go out when things get worse, then repeat slowly while they stay bad.
    static func shouldAlert(_ level: HealthLevel, lastSent: [HealthLevel: Date], now: Date) -> Bool {
        guard level > .ok else { return false }
        if let sent = lastSent.filter({ $0.key >= level }).values.max() {
            return now.timeIntervalSince(sent) >= (level == .danger ? 3600 : 21600)
        }
        return true
    }

    /// Which of the four steps toward a freeze this Mac is on, from 0.
    static func stage(_ sample: HealthSample, level: HealthLevel) -> Int {
        // Step four means nothing is left; until then the warning is still in time.
        if sample.freeDisk < 3 * gigabyte { return 3 }
        if level > .ok { return 2 }
        return sample.swapUsed >= gigabyte ? 1 : 0
    }

    /// One number for how the Mac is doing, 0…100. Anything Murmur would warn about caps it.
    static func score(_ sample: HealthSample, vitals: MacVitals?, level: HealthLevel) -> Int {
        var score = 100.0
        let free = Double(sample.freeDisk) / Double(gigabyte)
        if free < 50 { score -= (50 - max(free, 0)) * 0.6 }
        if sample.pressure >= 4 { score -= 35 } else if sample.pressure >= 2 { score -= 15 }
        if sample.swapTotal > 0 { score -= 10 * Double(sample.swapUsed) / Double(sample.swapTotal) }
        if let vitals {
            score -= [0, 4, 15, 30][min(max(vitals.thermal, 0), 3)]
            if vitals.cpu > 0.85 { score -= 8 }
            if let health = vitals.battery?.health, health < 80 { score -= Double(80 - health) * 0.5 }
        }
        let cap: Double = level == .danger ? 40 : level == .warning ? 74 : 100
        return Int(min(cap, max(3, score)).rounded())
    }

    /// Helpers count toward the app they belong to.
    static func appName(_ process: String) -> String {
        if process.hasPrefix("com.apple.WebKit") { return "Web pages" }
        return process.components(separatedBy: " Helper").first ?? process
    }
}

struct HealthProcess: Identifiable, Equatable {
    var name: String
    var footprint: UInt64
    var id: String { name }
}

@MainActor
final class MacHealth: ObservableObject {
    @Published private(set) var sample: HealthSample?
    @Published private(set) var reading = HealthReading.ok
    @Published private(set) var biggest: [HealthProcess] = []
    /// One sample every 15 seconds for the last hour, for the chart.
    @Published private(set) var trend: [HealthSample] = []
    @Published private(set) var clearing = false
    @Published private(set) var vitals: MacVitals?
    /// Recent vitals, newest last, for the live sparklines.
    @Published private(set) var pulse: [MacVitals] = []
    /// Apps by CPU; `footprint` holds hundredths of a percent of one core.
    @Published private(set) var busiest: [HealthProcess] = []
    /// Models Ollama is holding in memory (Murmur keeps its planner there for quick Space + ↓).
    @Published private(set) var loadedModels: [LoadedModel] = []
    @Published private(set) var murmurMemory: UInt64 = 0
    var score: Int? { sample.map { MacHealthRules.score($0, vitals: vitals, level: reading.level) } }
    private var lastTicks: (busy: UInt64, total: UInt64)?
    /// When the numbers were last read.
    @Published private(set) var updatedAt: Date?
    @Published private(set) var refreshing = false

    /// Everything at once, right now: the vitals, what's using the Mac, and Murmur's own share.
    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        await check()
        async let biggest: Void = refreshBiggest()
        async let detail: Void = refreshDetail()
        _ = await (biggest, detail)
    }
    /// Whether to keep watching in the background.
    var enabled: () -> Bool = { true }
    /// A Focus holds notifications back, so danger also shows on screen.
    var onDanger: ((HealthReading) -> Void)?
    private var loop: Task<Void, Never>?
    private var pressureSource: DispatchSourceMemoryPressure?
    private var history: [HealthSample] = []
    private var lastSent: [HealthLevel: Date] = [:]
    private var seeded = false

    func start() {
        guard loop == nil else { return }
        // The kernel's own signal arrives the moment pressure rises; the timer catches a filling disk.
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in Task { @MainActor in await self?.check() } }
        source.resume()
        pressureSource = source
        loop = Task { [weak self] in
            while !Task.isCancelled {
                if self?.enabled() == true { await self?.check() }
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    /// Fixed numbers for rendering the design.
    func seed(_ sample: HealthSample, trend: [HealthSample], biggest: [HealthProcess], vitals: MacVitals? = nil,
              pulse: [MacVitals] = [], busiest: [HealthProcess] = [], models: [LoadedModel] = [], murmur: UInt64 = 0) {
        seeded = true
        self.sample = sample; self.trend = trend; self.biggest = biggest
        self.vitals = vitals; self.pulse = pulse; self.busiest = busiest; loadedModels = models; murmurMemory = murmur
        updatedAt = sample.date
        reading = MacHealthRules.read(sample, history: [])
    }

    func check() async {
        guard !seeded else { return }
        guard let current = await Task.detached(priority: .utility, operation: { MacHealth.measure() }).value else { return }
        history.removeAll { current.date.timeIntervalSince($0.date) > 180 }
        reading = MacHealthRules.read(current, history: history)
        sample = current
        updatedAt = current.date
        measureVitals()
        history.append(current)
        if trend.last.map({ current.date.timeIntervalSince($0.date) >= 15 }) ?? true {
            trend.removeAll { current.date.timeIntervalSince($0.date) > 3600 }
            trend.append(current)
        }
        if reading.level > .ok { await refreshBiggest() }
        guard enabled(), MacHealthRules.shouldAlert(reading.level, lastSent: lastSent, now: current.date) else { return }
        lastSent[reading.level] = current.date
        alert(reading)
        if reading.level == .danger { onDanger?(reading) }
    }

    private func measureVitals() {
        let ticks = MacVitals.cpuTicks()
        var share = vitals?.cpu ?? 0
        if let lastTicks, let ticks { share = MacVitals.cpuShare(from: lastTicks, to: ticks) }
        lastTicks = ticks
        let now = MacVitals.measure(cpu: share)
        vitals = now
        pulse.append(now)
        if pulse.count > 90 { pulse.removeFirst(pulse.count - 90) }
    }

    /// The extra detail the Mac Health page shows: busiest apps, loaded models, Murmur itself.
    func refreshDetail() async {
        async let busy = Task.detached(priority: .utility) { MacVitals.busiestProcesses() }.value
        async let models = LoadedModel.current()
        busiest = await busy
        loadedModels = await models
        murmurMemory = MacVitals.murmurFootprint()
    }

    func unload(_ model: LoadedModel) async {
        await LoadedModel.unload(model.name)
        loadedModels = await LoadedModel.current()
    }

    /// The readings in plain words, for the AI checkup.
    var summary: String {
        guard let sample else { return "" }
        let gb = MacHealthRules.gb
        var lines = ["Overall: \(reading.title). \(reading.detail)",
                     "Free disk: \(gb(sample.freeDisk)) of \(gb(sample.totalDisk)).",
                     "Swap: \(gb(sample.swapUsed)) used of \(gb(sample.swapTotal)).",
                     "Memory pressure: \(sample.pressure >= 4 ? "critical" : sample.pressure >= 2 ? "high" : "normal")."]
        if let vitals {
            lines.append("CPU: \(Int(vitals.cpu * 100))% of all cores busy.")
            lines.append("Memory: \(gb(vitals.memoryUsed)) used of \(gb(vitals.memoryTotal)) (apps \(gb(vitals.appMemory)), compressed \(gb(vitals.compressed))).")
            lines.append("Temperature: \(vitals.thermalLabel). Up for \(Int(vitals.uptime / 86400)) days.")
            if let battery = vitals.battery {
                lines.append("Battery: \(battery.percent)%\(battery.charging ? ", charging" : ""), health \(battery.health.map { "\($0)%" } ?? "unknown"), \(battery.cycles.map { "\($0) cycles" } ?? "").")
            }
        }
        if !biggest.isEmpty { lines.append("Most memory: " + biggest.map { "\($0.name) \(gb($0.footprint))" }.joined(separator: ", ") + ".") }
        if !busiest.isEmpty { lines.append("Most CPU: " + busiest.map { "\($0.name) \($0.footprint / 100)%" }.joined(separator: ", ") + ".") }
        if !loadedModels.isEmpty { lines.append("Local AI models in memory: " + loadedModels.map { "\($0.name) \(gb($0.bytes))" }.joined(separator: ", ") + ".") }
        return lines.joined(separator: "\n")
    }

    func refreshBiggest() async {
        biggest = await Task.detached(priority: .utility, operation: { MacHealth.biggestProcesses() }).value
    }

    private func alert(_ reading: HealthReading) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        let content = UNMutableNotificationContent()
        content.title = reading.title
        content.body = reading.detail + (biggest.first.map { " Biggest: \($0.name), \(MacHealthRules.gb($0.footprint))." } ?? "")
        content.sound = reading.level == .danger ? .default : nil
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "mac-health", content: content, trigger: nil))
    }

    /// Clears caches apps rebuild on their own. Only runs when you press the button.
    func clearCaches() async -> UInt64 {
        clearing = true
        defer { clearing = false }
        let freed = await Task.detached(priority: .utility, operation: { MacHealth.removeCaches() }).value
        await check()
        return freed
    }

    private nonisolated static var cacheFolders: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return ["Library/Developer/Xcode/DerivedData", "Library/Caches/Homebrew", "Library/Caches/org.swift.swiftpm",
                "Library/Caches/pip", ".npm/_cacache"].map { home.appendingPathComponent($0) }
    }

    private nonisolated static func removeCaches() -> UInt64 {
        let manager = FileManager.default
        var freed: UInt64 = 0
        for folder in cacheFolders {
            guard let items = try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { continue }
            for item in items {
                let size = allocatedSize(of: item)
                if (try? manager.removeItem(at: item)) != nil { freed += size }
            }
        }
        return freed
    }

    private nonisolated static func allocatedSize(of url: URL) -> UInt64 {
        var total: UInt64 = 0
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey]
        let values = try? url.resourceValues(forKeys: keys)
        total += UInt64(values?.totalFileAllocatedSize ?? 0)
        guard let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys)) else { return total }
        for case let file as URL in files {
            total += UInt64((try? file.resourceValues(forKeys: keys))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    nonisolated static func measure() -> HealthSample? {
        // The Data volume shares its space with the swap files, and this is the number that hit zero.
        var disk = statfs()
        guard statfs("/System/Volumes/Data", &disk) == 0 else { return nil }
        var swap = xsw_usage(), size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 else { return nil }
        var pressure: Int32 = 1
        size = MemoryLayout<Int32>.size
        sysctlbyname("kern.memorystatus_vm_pressure_level", &pressure, &size, nil, 0)
        return HealthSample(date: Date(), freeDisk: UInt64(disk.f_bavail) * UInt64(disk.f_bsize),
                            swapUsed: swap.xsu_used, swapTotal: swap.xsu_total, pressure: pressure,
                            totalDisk: UInt64(disk.f_blocks) * UInt64(disk.f_bsize))
    }

    /// Apps by real memory use, including what's compressed or swapped out.
    nonisolated static func biggestProcesses(limit: Int = 5) -> [HealthProcess] {
        var pids = [pid_t](repeating: 0, count: 8192)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        guard count > 0 else { return [] }
        var totals: [String: UInt64] = [:]
        for pid in pids.prefix(count) {
            var usage = rusage_info_v4()
            let status = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            }
            guard status == 0 else { continue }
            var name = [CChar](repeating: 0, count: 256)
            proc_name(pid, &name, 256)
            totals[MacHealthRules.appName(String(cString: name)), default: 0] += usage.ri_phys_footprint
        }
        return totals.filter { !$0.key.isEmpty }.map { HealthProcess(name: $0.key, footprint: $0.value) }
            .sorted { $0.footprint > $1.footprint }.prefix(limit).map { $0 }
    }
}
