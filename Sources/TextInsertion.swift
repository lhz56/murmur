import AppKit
import ApplicationServices
import Carbon
import OSLog

enum InsertionResult: Equatable {
    case inserted(String), permissionRequired, focusChanged, noTextField, modifiersHeld, pasteUnavailable, pasteUnconfirmed, clipboardChanged
    var hudMessage: String {
        if case .inserted = self { return "Inserted · saved" }
        if self == .pasteUnconfirmed { return "Paste sent · saved" }
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
        case .pasteUnavailable: return "Copied · automatic paste couldn’t start"
        case .pasteUnconfirmed: return "Paste sent · this app didn’t confirm insertion"
        case .clipboardChanged: return "Transcript saved · the clipboard changed before insertion"
        }
    }
}

/// A copy of every item and type on a pasteboard, so a paste can borrow the
/// clipboard without losing what the user had copied.
struct PasteboardSnapshot {
    private let items: [[NSPasteboard.PasteboardType: Data]]

    /// Very large contents (for example, copied video) are not duplicated in memory.
    init?(_ pasteboard: NSPasteboard, byteLimit: Int = 64 << 20) {
        var total = 0
        var captured: [[NSPasteboard.PasteboardType: Data]] = []
        for item in pasteboard.pasteboardItems ?? [] {
            var types: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                guard let data = item.data(forType: type) else { continue }
                total += data.count
                if total > byteLimit { return nil }
                types[type] = data
            }
            if !types.isEmpty { captured.append(types) }
        }
        items = captured
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        pasteboard.writeObjects(items.map { types in
            let item = NSPasteboardItem()
            for (type, data) in types { item.setData(data, forType: type) }
            return item
        })
    }
}

@MainActor final class TextInsertion {
    private let log = Logger(subsystem: "app.murmur.mac", category: "Insertion")
    private var accessibilityPreparation: [pid_t: Date] = [:]

    struct ElementIdentity: Equatable {
        let element: AXUIElement
        static func == (lhs: Self, rhs: Self) -> Bool { CFEqual(lhs.element, rhs.element) }
    }

    struct EditorSignature: Equatable {
        let identifier: String
        let role: String
        let frame: CGRect
        let document: String?
        init(identifier: String, role: String, frame: CGRect, document: String? = nil) {
            self.identifier = identifier; self.role = role; self.frame = frame; self.document = document
        }
    }

    struct FocusSnapshot<Token: Equatable> {
        let pid: pid_t
        let window: Token?
        let focused: Token?
        let editor: Token?
        let signature: EditorSignature?
        let allowsPaste: Bool
    }

    struct Destination {
        let application: NSRunningApplication
        let focus: FocusSnapshot<ElementIdentity>
        let permissionGranted: Bool
        var element: AXUIElement? { focus.editor?.element }
    }

    func captureDestination() -> Destination? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier else {
            log.info("Destination capture unavailable: no external foreground application")
            return nil
        }
        let trusted = AXIsProcessTrusted()
        let focus = trusted ? focusSnapshot(pid: app.processIdentifier) :
            FocusSnapshot<ElementIdentity>(pid: app.processIdentifier, window: nil, focused: nil, editor: nil, signature: nil, allowsPaste: false)
        log.info("Destination captured pid=\(app.processIdentifier, privacy: .public) trusted=\(trusted, privacy: .public) editorAvailable=\(focus.editor != nil, privacy: .public) compatibilityAvailable=\(focus.allowsPaste, privacy: .public)")
        return Destination(application: app, focus: focus, permissionGranted: trusted)
    }

    func insert(_ text: String, into destination: Destination?) async -> InsertionResult {
        let pid = destination?.application.processIdentifier ?? 0
        guard AXIsProcessTrusted() else { return outcome(.permissionRequired, pid: pid, stage: "currentPermission") }
        guard let destination else { return outcome(.noTextField, pid: pid, stage: "missingDestination") }
        guard destination.permissionGranted else { return outcome(.permissionRequired, pid: pid, stage: "capturePermission") }
        guard !IsSecureEventInputEnabled() else { return outcome(.noTextField, pid: pid, stage: "secureInput") }
        guard destination.focus.allowsPaste else { return outcome(.noTextField, pid: pid, stage: "missingEditor") }
        // A Control hold can still be down when a hands-free recording finishes.
        // Do not turn Command-V into a different shortcut while those keys are held.
        let modifiers: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand, .maskShift, .maskSecondaryFn]
        for _ in 0..<60 {
            guard !Task.isCancelled, isStillFocused(destination) else {
                return outcome(.focusChanged, pid: pid, stage: "modifierWaitFocus")
            }
            if CGEventSource.flagsState(.combinedSessionState).intersection(modifiers).isEmpty { break }
            try? await Task.sleep(for: .milliseconds(15))
        }
        guard CGEventSource.flagsState(.combinedSessionState).intersection(modifiers).isEmpty else {
            return outcome(.modifiersHeld, pid: pid, stage: "modifierWaitTimeout")
        }
        guard isStillFocused(destination) else { return outcome(.focusChanged, pid: pid, stage: "preflightFocus") }
        guard NSPasteboard.general.string(forType: .string) == text else {
            return outcome(.clipboardChanged, pid: pid, stage: "preflightClipboard")
        }
        // Prefer the application's actual Paste command. This also works in
        // rich editors whose key handlers intercept simulated shortcuts.
        let menu = pasteMenuItem(pid: pid)
        let element = destination.element
        let before = element.flatMap { stringAttribute($0, kAXValueAttribute) }
        let selection = element.flatMap { selectedRange($0) }
        // AX reads above can cross process boundaries. Recheck the destination
        // immediately before sending the shortcut through normal foreground routing.
        guard !Task.isCancelled, isStillFocused(destination) else {
            return outcome(.focusChanged, pid: pid, stage: "dispatchFocus")
        }
        guard CGEventSource.flagsState(.combinedSessionState).intersection(modifiers).isEmpty else {
            return outcome(.modifiersHeld, pid: pid, stage: "dispatchModifiers")
        }
        guard NSPasteboard.general.string(forType: .string) == text else {
            return outcome(.clipboardChanged, pid: pid, stage: "dispatchClipboard")
        }
        // The AX query above may block while the user switches applications.
        // Check the foreground again after all cross-process reads.
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
            return outcome(.focusChanged, pid: pid, stage: "dispatchForeground")
        }
        guard !IsSecureEventInputEnabled() else { return outcome(.noTextField, pid: pid, stage: "dispatchSecureInput") }
        // Exactly one route is attempted. Even an AX timeout can occur after
        // an action took effect, so never follow a menu attempt with a shortcut.
        if let menu {
            let error = AXUIElementPerformAction(menu, kAXPressAction as CFString)
            log.info("Paste dispatched once pid=\(pid, privacy: .public) route=menu axError=\(error.rawValue, privacy: .public)")
        } else {
            guard postPasteShortcut(pid: pid) else {
                return outcome(.pasteUnavailable, pid: pid, stage: "eventCreation")
            }
            log.info("Paste dispatched once pid=\(pid, privacy: .public) route=keyboard")
        }
        // Confirm the receiver changed, rather than claiming success after dispatch.
        let confirmationDeadline = ProcessInfo.processInfo.systemUptime + 0.5
        while ProcessInfo.processInfo.systemUptime < confirmationDeadline {
            guard !Task.isCancelled else { return outcome(.pasteUnconfirmed, pid: pid, stage: "confirmationCancelled", dispatched: true) }
            try? await Task.sleep(for: .milliseconds(20))
            guard !Task.isCancelled else { return outcome(.pasteUnconfirmed, pid: pid, stage: "confirmationCancelled", dispatched: true) }
            let current = focusSnapshot(pid: pid, original: destination.focus)
            let receiver = Self.matchesFocus(destination.focus, current) ? current.editor?.element ?? element : element
            if let receiver,
               TextInsertion.insertionConfirmed(before: before, after: stringAttribute(receiver, kAXValueAttribute),
                                                 selection: selection, finalSelection: selectedRange(receiver), text: text) {
                return outcome(.inserted(destination.application.localizedName ?? "your app"),
                               pid: pid, stage: "receiverConfirmed", dispatched: true)
            }
        }
        return outcome(.pasteUnconfirmed, pid: pid, stage: "confirmationExpired", dispatched: true)
    }

    static func replacingSelection(in value: String, range: NSRange?, with text: String) -> String? {
        guard let range, range.location != NSNotFound, range.location >= 0, range.length >= 0,
              range.location <= (value as NSString).length,
              range.length <= (value as NSString).length - range.location else { return nil }
        return (value as NSString).replacingCharacters(in: range, with: text)
    }

    static func insertionConfirmed(before: String?, after: String?, selection: NSRange?, finalSelection: NSRange?, text: String) -> Bool {
        if let before, let after {
            // Web composers often expose only their value, with a newline for
            // an empty paragraph, rather than a native selected range. A known
            // blank value becoming exactly the transcript still proves receipt.
            if selection == nil, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               after.trimmingCharacters(in: .whitespacesAndNewlines) == text.trimmingCharacters(in: .whitespacesAndNewlines) {
                return true
            }
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
        let pid = destination.application.processIdentifier
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return false }
        let current = focusSnapshot(pid: pid, original: destination.focus)
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == pid &&
            Self.matchesFocus(destination.focus, current)
    }

    static func matchesFocus<Token>(_ original: FocusSnapshot<Token>, _ current: FocusSnapshot<Token>) -> Bool {
        guard original.pid == current.pid, original.allowsPaste, current.allowsPaste else { return false }
        if let window = original.window, current.window != window { return false }
        if let document = original.signature?.document, current.signature?.document != document { return false }
        if let editor = original.editor {
            if current.editor == editor { return true }
            // A named editor can recreate its AX node. Require the same window,
            // identifier, role, and geometry before accepting its replacement.
            return original.window != nil && current.editor != nil && original.signature != nil &&
                original.signature == current.signature
        }
        if let focused = original.focused { return current.focused == focused }
        // Some custom editors expose no focused AX element. A known, unchanged
        // foreground window still lets its normal Paste command handle input.
        return original.window != nil && original.window == current.window
    }

    private func focusSnapshot(pid: pid_t, original: FocusSnapshot<ElementIdentity>? = nil) -> FocusSnapshot<ElementIdentity> {
        let focused = focusedElement(pid: pid)
        let editor = focused.flatMap { editableAncestor(of: $0, pid: pid) }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        let window = elementAttribute(app, kAXFocusedWindowAttribute).element ??
            focused.flatMap { elementAttribute($0, kAXWindowAttribute).element }
        let checkedWindow = window.flatMap { belongsToProcess($0, pid: pid) ? ElementIdentity(element: $0) : nil }
        let editorIdentity = editor.map { ElementIdentity(element: $0) }
        let signature: EditorSignature?
        if editorIdentity != nil, editorIdentity == original?.editor, let saved = original?.signature {
            if saved.document != nil, let editor {
                let context = documentContext(editor)
                signature = context.resolved ? EditorSignature(identifier: saved.identifier, role: saved.role,
                                                               frame: saved.frame, document: context.document) : nil
            } else { signature = saved }
        }
        else if original == nil || original?.signature != nil { signature = editor.flatMap(editorSignature) }
        else { signature = nil }
        let subrole = focused.flatMap { stringAttribute($0, kAXSubroleAttribute) }
        let enabled = focused.flatMap { boolAttribute($0, kAXEnabledAttribute) }
        var allowed = editor != nil || Self.allowsCompatibilityPaste(
            role: focused.flatMap { stringAttribute($0, kAXRoleAttribute) }, subrole: subrole, enabled: enabled)
        var focusedProof = focused.map { ElementIdentity(element: $0) }
        if original?.editor == nil, let originalFocus = original?.focused, let focused,
           focusedProof != originalFocus, subrole != (kAXSecureTextFieldSubrole as String), enabled != false,
           isDescendant(focused, of: originalFocus.element) {
            focusedProof = originalFocus
            allowed = original?.allowsPaste == true
        }
        return FocusSnapshot(pid: pid, window: checkedWindow, focused: focusedProof,
                             editor: editorIdentity, signature: signature, allowsPaste: allowed)
    }

    private func isDescendant(_ element: AXUIElement, of ancestor: AXUIElement) -> Bool {
        var current = element
        let deadline = ProcessInfo.processInfo.systemUptime + 0.08
        for _ in 0..<8 {
            guard ProcessInfo.processInfo.systemUptime < deadline,
                  let parent = elementAttribute(current, kAXParentAttribute).element, !CFEqual(current, parent) else { return false }
            if CFEqual(parent, ancestor) { return true }
            current = parent
        }
        return false
    }

    static func allowsCompatibilityPaste(role: String?, subrole: String?, enabled: Bool?) -> Bool {
        guard subrole != (kAXSecureTextFieldSubrole as String), enabled != false else { return false }
        let controls: Set<String> = ["AXButton", "AXCheckBox", "AXRadioButton", "AXSlider", "AXMenuItem", "AXMenuBarItem",
                                     "AXMenu", "AXPopUpButton", "AXTabGroup", "AXTab", "AXLink", "AXList", "AXTable",
                                     "AXOutline", "AXRow", "AXCell", "AXImage", "AXStaticText", "AXScrollBar", "AXSplitter"]
        return role.map { !controls.contains($0) } ?? true
    }

    private func editorSignature(_ element: AXUIElement) -> EditorSignature? {
        guard let identifier = stringAttribute(element, kAXIdentifierAttribute), !identifier.isEmpty,
              let role = stringAttribute(element, kAXRoleAttribute) else { return nil }
        var positionValue: CFTypeRef?, sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var position = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        let context = documentContext(element)
        guard context.resolved else { return nil }
        return EditorSignature(identifier: identifier, role: role, frame: CGRect(origin: position, size: size), document: context.document)
    }

    private func documentContext(_ element: AXUIElement) -> (document: String?, resolved: Bool) {
        var current = element
        let deadline = ProcessInfo.processInfo.systemUptime + 0.06
        for _ in 0..<16 {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return (nil, false) }
            let role = stringAttribute(current, kAXRoleAttribute)
            if role == "AXWebArea" {
                var value: CFTypeRef?
                guard AXUIElementCopyAttributeValue(current, kAXURLAttribute as CFString, &value) == .success else { return (nil, false) }
                let document = (value as? URL)?.absoluteString ?? value as? String
                return (document, document?.isEmpty == false)
            }
            if role == (kAXWindowRole as String) {
                return (stringAttribute(current, kAXDocumentAttribute), true)
            }
            guard let parent = elementAttribute(current, kAXParentAttribute).element, !CFEqual(current, parent) else { return (nil, false) }
            current = parent
        }
        return (nil, false)
    }

    static func isPasteMenuCommand(character: String?, modifiers: Int?, enabled: Bool?, pressSupported: Bool) -> Bool {
        character?.lowercased() == "v" && modifiers == 0 && enabled == true && pressSupported
    }

    private func pasteMenuItem(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.03)
        let deadline = ProcessInfo.processInfo.systemUptime + 0.15
        guard let menu = elementAttribute(app, kAXMenuBarAttribute).element else { return nil }
        AXUIElementSetMessagingTimeout(menu, 0.03)
        var stack: [AXUIElement] = [menu]
        var visited = 0
        while let item = stack.popLast(), visited < 120, ProcessInfo.processInfo.systemUptime < deadline {
            visited += 1
            AXUIElementSetMessagingTimeout(item, 0.03)
            if stringAttribute(item, kAXRoleAttribute) == (kAXMenuItemRole as String),
               stringAttribute(item, kAXMenuItemCmdCharAttribute)?.lowercased() == "v" {
                var modifiersValue: CFTypeRef?, actionsValue: CFArray?
                AXUIElementCopyAttributeValue(item, kAXMenuItemCmdModifiersAttribute as CFString, &modifiersValue)
                AXUIElementCopyActionNames(item, &actionsValue)
                let actions = actionsValue as? [String] ?? []
                if Self.isPasteMenuCommand(character: "v", modifiers: (modifiersValue as? NSNumber)?.intValue,
                                           enabled: boolAttribute(item, kAXEnabledAttribute),
                                           pressSupported: actions.contains(kAXPressAction as String)) { return item }
            }
            var childrenValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(item, kAXChildrenAttribute as CFString, &childrenValue) == .success,
               let children = childrenValue as? [AXUIElement] {
                // Edit is conventionally the third menu, regardless of language.
                // Try it first; all other menus are still searched within budget.
                let ordered = CFEqual(item, menu) && children.count > 2 ?
                    [children[2]] + Array(children.prefix(2)) + Array(children.dropFirst(3)) : children
                stack.append(contentsOf: ordered.reversed())
            }
        }
        return nil
    }

    private func postPasteShortcut(pid: pid_t) -> Bool {
        guard let source = CGEventSource(stateID: .privateState) else { return false }
        let keys: [(CGKeyCode, Bool, CGEventFlags)] = [(55, true, .maskCommand), (9, true, .maskCommand),
                                                     (9, false, .maskCommand), (55, false, [])]
        var events: [CGEvent] = []
        for (key, down, flags) in keys {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else { return false }
            event.flags = flags
            if key == 55 { event.type = .flagsChanged }
            events.append(event)
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return false }
        for event in events { event.post(tap: .cgSessionEventTap) }
        return true
    }

    private func focusedElement(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        let applicationResult = elementAttribute(app, kAXFocusedUIElementAttribute)
        if let element = applicationResult.element, belongsToProcess(element, pid: pid) { return element }
        // Electron documents this flag for assistive applications. Enable its
        // editor tree only when the focused-element query is unavailable.
        if let application = NSRunningApplication(processIdentifier: pid), let bundle = application.bundleURL,
           accessibilityPreparation[pid] != (application.launchDate ?? .distantPast),
           FileManager.default.fileExists(atPath: bundle.appendingPathComponent("Contents/Frameworks/Electron Framework.framework").path) {
            accessibilityPreparation[pid] = application.launchDate ?? .distantPast
            let error = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            log.debug("Electron editor accessibility requested pid=\(pid, privacy: .public) axError=\(error.rawValue, privacy: .public)")
            let retry = elementAttribute(app, kAXFocusedUIElementAttribute)
            if let element = retry.element, belongsToProcess(element, pid: pid) { return element }
        }
        log.debug("Application focus lookup unavailable pid=\(pid, privacy: .public) axError=\(applicationResult.error.rawValue, privacy: .public)")
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.15)
        let systemResult = elementAttribute(system, kAXFocusedUIElementAttribute)
        guard let element = systemResult.element, belongsToProcess(element, pid: pid) else {
            log.debug("System focus fallback unavailable pid=\(pid, privacy: .public) axError=\(systemResult.error.rawValue, privacy: .public)")
            return nil
        }
        log.debug("System focus fallback used pid=\(pid, privacy: .public)")
        return element
    }

    private func elementAttribute(_ element: AXUIElement, _ attribute: String) -> (element: AXUIElement?, error: AXError) {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard error == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return (nil, error) }
        let result = value as! AXUIElement
        AXUIElementSetMessagingTimeout(result, 0.15)
        return (result, error)
    }

    private func belongsToProcess(_ element: AXUIElement, pid: pid_t) -> Bool {
        var elementPID: pid_t = 0
        return AXUIElementGetPid(element, &elementPID) == .success && elementPID == pid
    }

    private func editableAncestor(of focused: AXUIElement, pid: pid_t) -> AXUIElement? {
        var current = focused
        let deadline = ProcessInfo.processInfo.systemUptime + 0.10
        // Rich editors can expose a focused text child beneath their editable
        // container. Stop at the nearest editor, a secure field, or a UI boundary.
        // The bound also prevents malformed parent chains from looping forever.
        for _ in 0..<8 {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
            guard belongsToProcess(current, pid: pid) else { return nil }
            if stringAttribute(current, kAXSubroleAttribute) == (kAXSecureTextFieldSubrole as String) { return nil }
            if isEditable(current) { return current }
            let role = stringAttribute(current, kAXRoleAttribute)
            if role == (kAXWindowRole as String) || role == (kAXApplicationRole as String) { return nil }
            let parentResult = elementAttribute(current, kAXParentAttribute)
            guard let parent = parentResult.element, !CFEqual(parent, current) else { return nil }
            current = parent
        }
        log.debug("Editable ancestor lookup reached traversal limit pid=\(pid, privacy: .public)")
        return nil
    }

    private func isEditable(_ element: AXUIElement) -> Bool {
        let role = stringAttribute(element, kAXRoleAttribute)
        let subrole = stringAttribute(element, kAXSubroleAttribute)
        let enabled = boolAttribute(element, kAXEnabledAttribute)
        if Self.isTextEditor(role: role, subrole: subrole, enabled: enabled, hasSelectedRange: false,
                             selectedTextWritable: false, valueWritable: false) { return true }
        guard subrole != (kAXSecureTextFieldSubrole as String), enabled != false else { return false }
        return Self.isTextEditor(role: role, subrole: subrole, enabled: enabled,
                                 hasSelectedRange: selectedRange(element) != nil,
                                 selectedTextWritable: attributeIsSettable(element, kAXSelectedTextAttribute),
                                 valueWritable: attributeIsSettable(element, kAXValueAttribute))
    }

    static func isTextEditor(role: String?, subrole: String?, enabled: Bool?, hasSelectedRange: Bool,
                             selectedTextWritable: Bool, valueWritable: Bool) -> Bool {
        guard subrole != (kAXSecureTextFieldSubrole as String), enabled != false else { return false }
        if role == (kAXTextFieldRole as String) || role == (kAXTextAreaRole as String)
            || role == (kAXComboBoxRole as String) { return true }
        // A selected range alone also exists on read-only web content. Require
        // a positive editing capability before treating a custom container as an editor.
        return hasSelectedRange && (selectedTextWritable || valueWritable)
    }

    private func attributeIsSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success && settable.boolValue
    }

    private func boolAttribute(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return CFBooleanGetValue((value as! CFBoolean))
    }

    private func outcome(_ result: InsertionResult, pid: pid_t, stage: String, dispatched: Bool = false) -> InsertionResult {
        let code: String
        switch result {
        case .inserted: code = "inserted"
        case .permissionRequired: code = "permissionRequired"
        case .focusChanged: code = "focusChanged"
        case .noTextField: code = "noTextField"
        case .modifiersHeld: code = "modifiersHeld"
        case .pasteUnavailable: code = "pasteUnavailable"
        case .pasteUnconfirmed: code = "pasteUnconfirmed"
        case .clipboardChanged: code = "clipboardChanged"
        }
        // Diagnostics intentionally contain only outcomes and process IDs: no
        // transcript, clipboard contents, AX text values, or field labels.
        log.info("Insertion outcome=\(code, privacy: .public) stage=\(stage, privacy: .public) pid=\(pid, privacy: .public) dispatched=\(dispatched, privacy: .public)")
        return result
    }

    /// The text currently selected in the destination editor, if any.
    func selectedText(in destination: Destination?) -> String? {
        guard let element = destination?.element else { return nil }
        return stringAttribute(element, kAXSelectedTextAttribute)
    }

    /// The character just before the caret in the destination editor, read as a
    /// one-character range so large documents are never copied across processes.
    func characterBeforeCaret(in destination: Destination?) -> Character? {
        guard let element = destination?.element, let selection = selectedRange(element), selection.location > 0 else { return nil }
        var range = CFRange(location: selection.location - 1, length: 1)
        guard let parameter = AXValueCreate(.cfRange, &range) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString, parameter, &value) == .success,
              let string = value as? String else { return nil }
        return string.last
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
