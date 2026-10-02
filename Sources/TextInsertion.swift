import AppKit
import ApplicationServices

enum InsertionResult: Equatable {
    case inserted(String), permissionRequired, focusChanged, noTextField, modifiersHeld, pasteUnconfirmed, clipboardChanged
    var hudMessage: String {
        if case .inserted = self { return "Inserted · saved" }
        if self == .clipboardChanged { return "Saved · ready to copy" }
        return "Copied · ready to paste"
    }
    var message: String {
        switch self {
        case .inserted(let app): return "Saved & inserted into \(app)"
        case .permissionRequired: return "Copied · enable Accessibility in Settings to insert text"
        case .focusChanged: return "Copied · the original text box is no longer focused"
        case .noTextField: return "Copied · select a text box before recording"
        case .modifiersHeld: return "Copied · release the shortcut keys to paste"
        case .pasteUnconfirmed: return "Saved & copied to clipboard"
        case .clipboardChanged: return "Transcript saved · the clipboard changed before insertion"
        }
    }
}

@MainActor final class TextInsertion {
    struct Destination {
        let application: NSRunningApplication
        let element: AXUIElement?
        let permissionGranted: Bool
    }

    func captureDestination() -> Destination? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier else { return nil }
        let trusted = AXIsProcessTrusted()
        return Destination(application: app, element: trusted ? focusedElement(pid: app.processIdentifier) : nil,
                           permissionGranted: trusted)
    }

    func insert(_ text: String, into destination: Destination?) async -> InsertionResult {
        guard AXIsProcessTrusted() else { return .permissionRequired }
        guard let destination else { return .noTextField }
        guard destination.permissionGranted else { return .permissionRequired }
        guard let element = destination.element, isEditable(element) else { return .noTextField }
        // A Control hold can still be down when a hands-free recording finishes.
        // Do not turn Command-V into a different shortcut while those keys are held.
        let modifiers: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand, .maskShift, .maskSecondaryFn]
        for _ in 0..<60 {
            guard !Task.isCancelled, isStillFocused(destination) else { return .focusChanged }
            if CGEventSource.flagsState(.combinedSessionState).intersection(modifiers).isEmpty { break }
            try? await Task.sleep(for: .milliseconds(15))
        }
        guard CGEventSource.flagsState(.combinedSessionState).intersection(modifiers).isEmpty else { return .modifiersHeld }
        guard isStillFocused(destination) else { return .focusChanged }
        guard NSPasteboard.general.string(forType: .string) == text else { return .clipboardChanged }
        let before = stringAttribute(element, kAXValueAttribute)
        let selection = selectedRange(element)
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else { return .pasteUnconfirmed }
        down.flags = .maskCommand; up.flags = .maskCommand
        down.postToPid(destination.application.processIdentifier)
        up.postToPid(destination.application.processIdentifier)
        // Confirm the receiver changed, rather than claiming success after dispatch.
        for _ in 0..<10 {
            guard !Task.isCancelled else { return .pasteUnconfirmed }
            try? await Task.sleep(for: .milliseconds(20))
            guard !Task.isCancelled else { return .pasteUnconfirmed }
            if TextInsertion.insertionConfirmed(before: before, after: stringAttribute(element, kAXValueAttribute),
                                                selection: selection, finalSelection: selectedRange(element), text: text) {
                return .inserted(destination.application.localizedName ?? "your app")
            }
        }
        return .pasteUnconfirmed
    }

    static func replacingSelection(in value: String, range: NSRange?, with text: String) -> String? {
        guard let range, range.location != NSNotFound, range.location >= 0, range.length >= 0,
              range.location <= (value as NSString).length,
              range.length <= (value as NSString).length - range.location else { return nil }
        return (value as NSString).replacingCharacters(in: range, with: text)
    }

    static func insertionConfirmed(before: String?, after: String?, selection: NSRange?, finalSelection: NSRange?, text: String) -> Bool {
        if let before, let after {
            guard let expected = replacingSelection(in: before, range: selection, with: text) else { return false }
            return after == expected
        }
        guard let selection, let finalSelection, selection.location != NSNotFound,
              selection.location >= 0, selection.length >= 0, finalSelection.length == 0,
              finalSelection.location >= 0, finalSelection.location != NSNotFound else { return false }
        let (expectedLocation, overflow) = selection.location.addingReportingOverflow((text as NSString).length)
        return !overflow && expectedLocation != NSNotFound && finalSelection.location == expectedLocation
    }

    private func isStillFocused(_ destination: Destination) -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == destination.application.processIdentifier,
              let original = destination.element,
              let current = focusedElement(pid: destination.application.processIdentifier) else { return false }
        return CFEqual(original, current)
    }

    private func focusedElement(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let element = value as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.15)
        return element
    }

    private func isEditable(_ element: AXUIElement) -> Bool {
        if stringAttribute(element, kAXSubroleAttribute) == (kAXSecureTextFieldSubrole as String) { return false }
        let role = stringAttribute(element, kAXRoleAttribute)
        return role == (kAXTextFieldRole as String) || role == (kAXTextAreaRole as String)
            || role == (kAXComboBoxRole as String) || selectedRange(element) != nil
    }

    private func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private func selectedRange(_ element: AXUIElement) -> NSRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        return NSRange(location: range.location, length: range.length)
    }
}
