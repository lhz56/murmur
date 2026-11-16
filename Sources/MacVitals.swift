import Foundation
import IOKit
import IOKit.ps

/// Everything else worth knowing about the Mac right now: how hard it's working,
/// where the memory went, the battery, and how warm it's running.
struct MacVitals: Equatable {
    struct Battery: Equatable {
        var percent: Int
        var charging: Bool
        var pluggedIn: Bool
        /// How much of its original capacity it still holds, in percent.
        var health: Int?
        var cycles: Int?
        var minutesLeft: Int?
    }

    var date = Date()
    /// Share of all cores in use, 0…1.
    var cpu: Double = 0
    var memoryTotal: UInt64 = 0
    var appMemory: UInt64 = 0
    var wired: UInt64 = 0
    var compressed: UInt64 = 0
    var battery: Battery?
    /// ProcessInfo.ThermalState: 0 nominal, 1 fair, 2 serious, 3 critical.
    var thermal: Int = 0
    var uptime: TimeInterval = 0

    var memoryUsed: UInt64 { appMemory + wired + compressed }

    var thermalLabel: String { ["Cool", "Warm", "Hot", "Too hot"][min(max(thermal, 0), 3)] }

    /// Busy and total CPU ticks since boot, across every core.
    nonisolated static func cpuTicks() -> (busy: UInt64, total: UInt64)? {
        var load = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &load) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count) }
        }
        guard status == KERN_SUCCESS else { return nil }
        let user = UInt64(load.cpu_ticks.0), system = UInt64(load.cpu_ticks.1), idle = UInt64(load.cpu_ticks.2), nice = UInt64(load.cpu_ticks.3)
        return (user + system + nice, user + system + idle + nice)
    }

    /// The share of time busy between two readings of `cpuTicks`.
    static func cpuShare(from a: (busy: UInt64, total: UInt64), to b: (busy: UInt64, total: UInt64)) -> Double {
        guard b.total > a.total, b.busy >= a.busy else { return 0 }
        return min(1, Double(b.busy - a.busy) / Double(b.total - a.total))
    }

    nonisolated static func measure(cpu: Double) -> MacVitals {
        var vitals = MacVitals()
        vitals.cpu = cpu
        vitals.memoryTotal = ProcessInfo.processInfo.physicalMemory
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        if status == KERN_SUCCESS {
            let page = UInt64(vm_kernel_page_size)
            let inUse = UInt64(stats.internal_page_count), purgeable = UInt64(stats.purgeable_count)
            vitals.appMemory = (inUse > purgeable ? inUse - purgeable : 0) * page
            vitals.wired = UInt64(stats.wire_count) * page
            vitals.compressed = UInt64(stats.compressor_page_count) * page
        }
        vitals.battery = battery()
        vitals.thermal = ProcessInfo.processInfo.thermalState.rawValue
        vitals.uptime = ProcessInfo.processInfo.systemUptime
        return vitals
    }

    /// The battery, or nil on a Mac without one.
    nonisolated static func battery() -> Battery? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  (description[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
            let current = description[kIOPSCurrentCapacityKey] as? Int ?? 0
            let maximum = max(1, description[kIOPSMaxCapacityKey] as? Int ?? 100)
            let left = description[kIOPSTimeToEmptyKey] as? Int
            var battery = Battery(percent: current * 100 / maximum,
                                  charging: description[kIOPSIsChargingKey] as? Bool ?? false,
                                  pluggedIn: (description[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue,
                                  minutesLeft: left.flatMap { $0 > 0 ? $0 : nil })
            let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
            if service != 0 {
                defer { IOObjectRelease(service) }
                func number(_ key: String) -> Int? {
                    IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int
                }
                battery.cycles = number("CycleCount")
                if let raw = number("AppleRawMaxCapacity"), let design = number("DesignCapacity"), design > 0 {
                    battery.health = min(100, raw * 100 / design)
                }
            }
            return battery
        }
        return nil
    }

    /// Apps by CPU over a short window, in percent of one core (so 250 means two and a half cores).
    nonisolated static func busiestProcesses(window: TimeInterval = 0.6, limit: Int = 5) -> [HealthProcess] {
        func times() -> [pid_t: (String, UInt64)] {
            var pids = [pid_t](repeating: 0, count: 8192)
            let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
            var result: [pid_t: (String, UInt64)] = [:]
            for pid in pids.prefix(max(0, count)) {
                var usage = rusage_info_v4()
                let status = withUnsafeMutablePointer(to: &usage) {
                    $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
                }
                guard status == 0 else { continue }
                var name = [CChar](repeating: 0, count: 256)
                proc_name(pid, &name, 256)
                result[pid] = (MacHealthRules.appName(String(cString: name)), usage.ri_user_time + usage.ri_system_time)
            }
            return result
        }
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let first = times()
        Thread.sleep(forTimeInterval: window)
        let second = times()
        var totals: [String: Double] = [:]
        for (pid, (name, time)) in second {
            guard let before = first[pid]?.1, time > before, !name.isEmpty else { continue }
            let nanoseconds = Double(time - before) * Double(timebase.numer) / Double(timebase.denom)
            totals[name, default: 0] += nanoseconds / (window * 1e9) * 100
        }
        // HealthProcess carries the percent in `footprint`, in hundredths, to share the row view.
        return totals.filter { $0.value >= 0.5 }.map { HealthProcess(name: $0.key, footprint: UInt64($0.value * 100)) }
            .sorted { $0.footprint > $1.footprint }.prefix(limit).map { $0 }
    }

    /// Murmur's own memory, helpers included.
    nonisolated static func murmurFootprint() -> UInt64 {
        var usage = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
        }
        return status == 0 ? usage.ri_phys_footprint : 0
    }
}

/// A model Ollama is holding in memory right now.
struct LoadedModel: Identifiable, Equatable {
    var name: String
    var bytes: UInt64
    var until: Date?
    var id: String { name }
    private static let ollama = URL(string: "http://127.0.0.1:11434")!

    static func current() async -> [LoadedModel] {
        var request = URLRequest(url: ollama.appendingPathComponent("api/ps"))
        request.timeoutInterval = 1.5
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else { return [] }
        let dates = ISO8601DateFormatter()
        dates.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return models.compactMap { model in
            guard let name = model["name"] as? String else { return nil }
            let bytes = (model["size"] as? NSNumber)?.uint64Value ?? 0
            return LoadedModel(name: name, bytes: bytes, until: (model["expires_at"] as? String).flatMap { dates.date(from: $0) })
        }
    }

    /// Lets Ollama drop it from memory now.
    static func unload(_ name: String) async {
        var request = URLRequest(url: ollama.appendingPathComponent("api/generate"))
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["model": name, "keep_alive": 0])
        _ = try? await URLSession.shared.data(for: request)
    }
}
