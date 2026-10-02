import Foundation
import IOKit

enum KeyboardInfo {
    /// Reads device names only; does not open devices or monitor their input.
    static func connectedNames() -> [String] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOHIDDevice"), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var names = Set<String>()
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let property = IORegistryEntryCreateCFProperty(service, "Product" as CFString, kCFAllocatorDefault, 0),
                  let name = property.takeRetainedValue() as? String else { continue }
            if name.localizedCaseInsensitiveContains("keyboard") || name.localizedCaseInsensitiveContains("GMMK") {
                names.insert(name)
            }
        }
        return names.sorted()
    }

    static func fnNote(for names: [String]) -> String? {
        guard let name = names.first(where: { $0.localizedCaseInsensitiveContains("GMMK 3") }) else { return nil }
        return "\(name) detected. Its Fn key controls built-in keyboard layers, and Glorious Core does not offer that key for remapping. It may not send an Apple Fn event to your Mac. Check the physical key below."
    }
}
