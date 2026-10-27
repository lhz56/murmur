import AppKit
import ServiceManagement

/// Registers Murmur as a login item through the system's own list, so the
/// setting also appears (and can be turned off) in System Settings → General →
/// Login Items.
@MainActor
final class LaunchAtLogin: ObservableObject {
    @Published private(set) var status = SMAppService.mainApp.status
    @Published private(set) var error: String?

    var isEnabled: Bool { status == .enabled || status == .requiresApproval }
    var needsApproval: Bool { status == .requiresApproval }

    func refresh() { status = SMAppService.mainApp.status }

    func set(_ enabled: Bool) {
        error = nil
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            self.error = enabled ? "Couldn’t add Murmur to Login Items." : "Couldn’t remove Murmur from Login Items."
        }
        refresh()
    }

    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }

    /// True when the system started this process as a login item. Read it in
    /// `applicationWillFinishLaunching`, while the launch event is current.
    static var launchedAsLoginItem: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        return event.eventID == kAEOpenApplication
            && event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }
}
