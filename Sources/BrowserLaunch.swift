import AppKit
import Darwin

/// Opens web links in a browser window you can see. Coding agents often run
/// Chrome headless in the background; macOS would hand a link to that
/// invisible copy. When every running Chrome is headless, a visible one is
/// started instead, and the background copies are left alone.
/// (From Relay's Chrome launch policy.)
enum BrowserLaunch {
    /// Set while a command asked for a particular browser ("…on Safari").
    @MainActor static var preferred: URL?

    /// The browser a link will open in.
    @MainActor static func browser(for url: URL) -> URL? { preferred ?? NSWorkspace.shared.urlForApplication(toOpen: url) }

    @MainActor static func open(_ url: URL) async -> Bool {
        guard let browser = browser(for: url) else { return NSWorkspace.shared.open(url) }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        if let id = Bundle(url: browser)?.bundleIdentifier, await needsVisibleInstance(bundleID: id) {
            configuration.createsNewApplicationInstance = true
        }
        do { _ = try await NSWorkspace.shared.open([url], withApplicationAt: browser, configuration: configuration); return true }
        catch { return NSWorkspace.shared.open(url) }
    }

    @MainActor static func needsVisibleInstance(bundleID: String) async -> Bool {
        guard bundleID == "com.google.Chrome" || bundleID.hasPrefix("com.google.Chrome.") else { return false }
        let pids = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == bundleID && !$0.isTerminated }.map(\.processIdentifier)
        guard !pids.isEmpty else { return false }
        return await Task.detached { ChromeLaunchPolicy.needsVisibleInstance(pids.map(headless)) }.value
    }

    /// Reads only the process's launch arguments; they're never stored or sent anywhere.
    nonisolated private static func headless(_ pid: pid_t) -> Bool? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4, size <= 2_097_152 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        let result = bytes.withUnsafeMutableBytes { sysctl(&mib, 3, $0.baseAddress, &size, nil, 0) }
        guard result == 0 else { return nil }
        return ChromeLaunchPolicy.isHeadless(Data(bytes.prefix(size)))
    }
}

enum ChromeLaunchPolicy {
    /// Decodes only argv from KERN_PROCARGS2; environment entries aren't arguments,
    /// so a URL or path containing "headless" doesn't count.
    static func isHeadless(_ data: Data) -> Bool? {
        let bytes = Array(data)
        guard bytes.count > 4 else { return nil }
        let count = (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[$1]) << ($1 * 8) }
        guard count > 0, count <= 4096 else { return nil }
        var cursor = 4
        // The executable path and its padding, then argc null-terminated arguments.
        while cursor < bytes.count, bytes[cursor] != 0 { cursor += 1 }
        while cursor < bytes.count, bytes[cursor] == 0 { cursor += 1 }
        var headless = false
        for index in 0..<Int(count) {
            let start = cursor
            while cursor < bytes.count, bytes[cursor] != 0 { cursor += 1 }
            guard cursor < bytes.count, let argument = String(bytes: bytes[start..<cursor], encoding: .utf8) else { return nil }
            if index > 0, argument == "--headless" || argument.hasPrefix("--headless=") { headless = true }
            cursor += 1
        }
        return headless
    }

    /// Only when every copy is known to be headless; unknown or mixed sets are left alone.
    static func needsVisibleInstance(_ states: [Bool?]) -> Bool {
        !states.isEmpty && states.allSatisfy { $0 == true }
    }
}
