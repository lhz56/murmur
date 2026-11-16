import AppKit
import ApplicationServices

/// Clicks something on screen for Ask. Presses the control through Accessibility,
/// only when it's the one you named. Unknown controls are left for you.
enum ScreenClick {
    /// Buttons Ask leaves for you: sending, paying, deleting, posting, signing out.
    static let riskyWords = [
        "send", "delete", "remove", "erase", "wipe", "format", "discard", "empty trash", "move to trash", "buy", "purchase",
        "pay", "checkout", "check out", "place order", "order now", "subscribe", "transfer", "submit", "post", "publish",
        "reply all", "sign out", "log out", "uninstall", "reset", "factory", "confirm", "deactivate", "close account",
    ]

    static func isRisky(_ text: String) -> Bool {
        let words = " " + AssistantIntent.plain(text) + " "
        return riskyWords.contains { words.contains(" " + AssistantIntent.plain($0) + " ") }
    }

    /// AppKit point (y up) → the global coordinates CGEvent and Accessibility use (y down).
    static func global(_ point: CGPoint) -> CGPoint {
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        return CGPoint(x: point.x, y: top - point.y)
    }

    /// Roles Ask can press for you.
    static let pressableRoles: Set<String> = ["AXButton", "AXCheckBox", "AXRadioButton", "AXLink", "AXMenuItem", "AXMenuBarItem",
                                              "AXPopUpButton", "AXMenuButton", "AXTab", "AXDisclosureTriangle", "AXSwitch", "AXToggle"]

    /// A real, named control that matches the name you said, and nothing risky.
    /// Unknown controls are left for you, never clicked by coordinates.
    static func permits(role: String, name: String, label: String) -> Bool {
        let name = AssistantIntent.plain(name), label = AssistantIntent.plain(label)
        guard !name.isEmpty, !label.isEmpty, !isRisky(name), !isRisky(label), pressableRoles.contains(role) else { return false }
        // "Wi-Fi" matches "Wi‑Fi"; "Bluetooth" matches a switch called "Bluetooth on/off".
        return name == label || " \(name) ".contains(" \(label) ")
    }

    struct Target {
        let element: AXUIElement
        let name: String
        let role: String
        let frame: CGRect
    }

    /// Which app and window a screenshot showed. Cheap: two Accessibility calls.
    struct Observation {
        let pid: pid_t
        let window: AXUIElement

        @MainActor var isCurrent: Bool {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                  let current = ScreenClick.focusedWindow(pid) else { return false }
            return CFEqual(window, current)
        }
    }

    @MainActor static func observe() -> Observation? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let window = focusedWindow(pid) else { return nil }
        return Observation(pid: pid, window: window)
    }

    /// An app that's hung mustn't freeze Murmur: Accessibility calls give up after a second.
    private static let systemWide: AXUIElement = {
        let element = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(element, 1)
        return element
    }()

    private static func focusedWindow(_ pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func frame(_ element: AXUIElement) -> CGRect? {
        var position: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size, CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point), AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }

    /// The control under a spot (AppKit coordinates): a button, row or cell, whatever you'd click.
    @MainActor static func control(at point: CGPoint) -> AXUIElement? {
        let spot = global(point)
        var found: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(spot.x), Float(spot.y), &found) == .success, var element = found else { return nil }
        let roles = pressableRoles.union(["AXRow", "AXCell", "AXOutlineRow", "AXListItem", "AXTextField", "AXComboBox", "AXSlider", "AXImage"])
        for _ in 0..<5 {
            if let role = string(element, kAXRoleAttribute), roles.contains(role) { return element }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parent) == .success, let parent,
                  CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
            element = parent as! AXUIElement
        }
        return found
    }

    @MainActor static func click(at point: CGPoint, label: String, observation: Observation?) async -> String? {
        guard !Task.isCancelled else { return "Cancelled" }
        guard AXIsProcessTrusted() else { return "Turn on Accessibility for Murmur so it can click" }
        if isRisky(label) { return "Left “\(label)” for you to click" }
        guard let observation, observation.isCurrent else { return "The window changed. Ask again before clicking." }
        guard let original = pressable(at: global(point)), permits(role: original.role, name: original.name, label: label) else {
            return "Left “\(label)” for you to click: couldn’t find a control by that name there"
        }
        // Let the ring land first, so you see what's about to be clicked.
        do { try await Task.sleep(for: .milliseconds(450)) } catch { return "Cancelled" }
        guard !Task.isCancelled, observation.isCurrent, let target = pressable(at: global(point)),
              CFEqual(target.element, original.element), target.frame == original.frame else {
            return "The screen changed. Ask again before clicking."
        }
        return AXUIElementPerformAction(target.element, kAXPressAction as CFString) == .success
            ? nil : "Couldn’t press “\(label)”"
    }

    /// The button, link, checkbox or menu at that spot, if Accessibility knows it.
    private static func pressable(at spot: CGPoint) -> Target? {
        var found: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(spot.x), Float(spot.y), &found) == .success,
              var element = found else { return nil }
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        if pid == ProcessInfo.processInfo.processIdentifier { return nil }
        for _ in 0..<4 {
            if let role = string(element, kAXRoleAttribute), pressableRoles.contains(role) {
                var actions: CFArray?
                if AXUIElementCopyActionNames(element, &actions) == .success,
                   (actions as? [String] ?? []).contains(kAXPressAction as String), let frame = frame(element) {
                    let name = [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute]
                        .compactMap { string(element, $0) }.first { !$0.isEmpty } ?? ""
                    return Target(element: element, name: name, role: role, frame: frame)
                }
            }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parent) == .success, let parent,
                  CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
            element = parent as! AXUIElement
        }
        return nil
    }

    // MARK: Press by name

    /// Presses the thing called `name` in the app in front: a button, tab, row or
    /// list item ("the thread called launch notes"). Found through Accessibility by
    /// its visible name, never by guessing a spot. Waits a moment for an app that's
    /// still drawing. Returns the problem, or nil once it's pressed.
    @MainActor static func press(named name: String, in pid: pid_t? = nil, timeout: TimeInterval = 2.5, onPress: ((CGPoint) -> Void)? = nil) async -> String? {
        guard AXIsProcessTrusted() else { return "Turn on Accessibility for Murmur so it can click" }
        guard !isRisky(name) else { return "Left “\(name)” for you to click" }
        let wanted = AssistantIntent.plain(name)
        guard !wanted.isEmpty else { return "Say what to open" }
        // "the general channel", "the save button": the name as said, then without the kind of thing it is.
        var names = [wanted]
        var parts = wanted.split(separator: " ").map(String.init)
        let kinds: Set<String> = ["button", "tab", "link", "row", "item", "option", "thread", "chat", "channel", "conversation", "menu", "icon", "page", "folder", "file", "section"]
        if parts.count > 1, let last = parts.last, kinds.contains(last) { parts.removeLast() }
        let shorter = parts.joined(separator: " ")
        if shorter != wanted, !shorter.isEmpty { names.append(shorter) }
        let deadline = Date().addingTimeInterval(timeout)
        var exposed = Set<pid_t>()
        repeat {
            guard !Task.isCancelled else { return "Cancelled" }
            if let app = pid.flatMap(NSRunningApplication.init(processIdentifier:)) ?? NSWorkspace.shared.frontmostApplication,
               app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                let pid = app.processIdentifier
                let root = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(root, 0.5)
                if exposed.insert(pid).inserted {
                    // Electron and Chromium apps (T3 Code, Slack, VS Code) only build their
                    // accessibility tree when asked to.
                    AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue)
                }
                for candidate in names {
                    // Off the main thread, so the pointer keeps moving smoothly while it looks.
                    let lookup = await Task.detached(priority: .userInitiated) { Box(find(candidate, in: root)) }.value.value
                    switch lookup {
                    case .found(let found):
                        if let frame = frame(found.pressable ?? found.row ?? found.element) {
                            let top = NSScreen.screens.first?.frame.maxY ?? 0
                            onPress?(CGPoint(x: frame.midX, y: top - frame.midY))
                        }
                        if found.press() { return nil }
                        // Accessibility wouldn't press it: a real click on the same spot, only if that
                        // spot is still this very thing, in the app in front.
                        if let frame = frame(found.row ?? found.pressable ?? found.element), NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                           clickReally(at: CGPoint(x: frame.midX, y: frame.midY), expecting: [found.row, found.pressable, found.element].compactMap { $0 }, in: root) {
                            return nil
                        }
                        return "Couldn’t press “\(name)”"
                    case .unclear(let problem):
                        return problem
                    case .notYet:
                        continue
                    }
                }
            }
            try? await Task.sleep(for: .milliseconds(140))
        } while Date() < deadline
        return "Couldn’t find “\(name)” on screen"
    }

    /// A mouse click at `point` (global, y down), only when the thing under it is one of
    /// `expected` or inside it. The pointer goes back where it was.
    private static func clickReally(at point: CGPoint, expecting expected: [AXUIElement], in root: AXUIElement) -> Bool {
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(root, Float(point.x), Float(point.y), &hit) == .success, var element = hit else { return false }
        var inside = false
        for _ in 0..<6 {
            if expected.contains(where: { CFEqual($0, element) }) { inside = true; break }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parent) == .success, let parent,
                  CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
            element = parent as! AXUIElement
        }
        guard inside else { return false }
        let back = CGEvent(source: nil)?.location
        let source = CGEventSource(stateID: .hidSystemState)
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        }
        if let back { CGWarpMouseCursorPosition(back) }
        return true
    }

    private struct Box<T>: @unchecked Sendable { let value: T; init(_ value: T) { self.value = value } }

    private struct Found {
        let element: AXUIElement
        let pressable: AXUIElement?
        let row: AXUIElement?
        func press() -> Bool {
            if let pressable, AXUIElementPerformAction(pressable, kAXPressAction as CFString) == .success { return true }
            if let row {
                if AXUIElementSetAttributeValue(row, kAXSelectedAttribute as CFString, kCFBooleanTrue) == .success { return true }
                // Some lists (Finder's sidebar) only take a selection through the list itself.
                var parent: CFTypeRef?
                if AXUIElementCopyAttributeValue(row, kAXParentAttribute as CFString, &parent) == .success, let parent,
                   CFGetTypeID(parent) == AXUIElementGetTypeID(),
                   AXUIElementSetAttributeValue(parent as! AXUIElement, kAXSelectedRowsAttribute as CFString, [row] as CFArray) == .success { return true }
            }
            return false
        }
    }

    private enum Lookup { case found(Found), notYet, unclear(String) }

    /// What `wanted` (plain words) names in the app's windows. Strict, because a wrong
    /// press is worse than none: an exact name wins; a name that only starts with or
    /// contains your words counts only when it's the one such thing on screen; two
    /// different things with the same name means it asks you to say more.
    /// Text you're typing (fields, editors) never counts.
    private static func find(_ wanted: String, in app: AXUIElement) -> Lookup {
        var windows: [AXUIElement] = []
        if let focused = element(app, kAXFocusedWindowAttribute) { windows.append(focused) }
        windows += children(app, kAXWindowsAttribute).filter { window in !windows.contains { CFEqual($0, window) } }
        let skipped: Set<String> = ["AXTextField", "AXTextArea", "AXSearchField", "AXComboBox", "AXScrollBar", "AXMenuBar"]
        var matches: [Int: [AXUIElement]] = [:]
        var queue = windows.map { ($0, 0) }, index = 0
        while index < queue.count, index < 8000 {
            let (node, depth) = queue[index]; index += 1
            // One round trip per element instead of five: big web apps have thousands.
            let read = Node(node)
            if skipped.contains(read.role) { continue }
            var score = 0
            for text in read.texts where text.count <= 160 {
                let plain = AssistantIntent.plain(text)
                score = max(score, plain == wanted ? 3 : plain.hasPrefix(wanted + " ") ? 2 : " \(plain) ".contains(" \(wanted) ") ? 1 : 0)
            }
            if score > 0 { matches[score, default: []].append(node) }
            if depth < 40 { queue += read.children.map { ($0, depth + 1) } }
        }
        // Several matches can be one control (its title and its text): count what they'd press.
        for score in [3, 2, 1] {
            guard let nodes = matches[score], !nodes.isEmpty else { continue }
            // One loose word inside a longer name ("notes") is too easy to mishear into the wrong thing.
            if score == 1, !wanted.contains(" ") { break }
            var targets: [Found] = []
            for node in nodes {
                guard let found = target(for: node) else { continue }
                let key = found.pressable ?? found.row!
                if !targets.contains(where: { CFEqual($0.pressable ?? $0.row!, key) }) { targets.append(found) }
            }
            if targets.count == 1 { return .found(targets[0]) }
            if targets.count > 1 { return .unclear("There’s more than one “\(wanted)” here. Say more of its name, or click it yourself.") }
        }
        return .notYet
    }

    /// What you'd click for this name: the nearest pressable thing around it, or its row.
    private static func target(for match: AXUIElement) -> Found? {
        var pressable: AXUIElement?, row: AXUIElement?, node = match
        let containers: Set<String> = ["AXWindow", "AXWebArea", "AXScrollArea", "AXApplication", "AXSplitGroup", "AXSheet", "AXDrawer"]
        for _ in 0..<8 {
            // Never climb out to the page or window: pressing those isn't pressing what you named.
            if let role = string(node, kAXRoleAttribute), containers.contains(role) { break }
            var actions: CFArray?
            if pressable == nil, AXUIElementCopyActionNames(node, &actions) == .success,
               (actions as? [String] ?? []).contains(kAXPressAction as String) { pressable = node }
            if row == nil, let role = string(node, kAXRoleAttribute), ["AXRow", "AXOutlineRow", "AXCell"].contains(role) { row = node }
            if pressable != nil { break }
            guard let parent = element(node, kAXParentAttribute) else { break }
            node = parent
        }
        guard pressable != nil || row != nil else { return nil }
        // Neither the name nor what it presses may be Send, Delete and the like.
        for candidate in [match, pressable, row].compactMap({ $0 }) {
            if let name = string(candidate, kAXTitleAttribute) ?? string(candidate, kAXDescriptionAttribute), isRisky(name) { return nil }
        }
        return Found(element: match, pressable: pressable, row: row)
    }

    /// An element's role, visible texts and children, read in one Accessibility call.
    private struct Node {
        var role = "", texts: [String] = [], children: [AXUIElement] = []
        private static let wanted = [kAXRoleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXChildrenAttribute] as CFArray
        init(_ element: AXUIElement) {
            var values: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(element, Node.wanted, AXCopyMultipleAttributeOptions(rawValue: 0), &values) == .success,
                  let list = values as? [Any], list.count == 5 else { return }
            role = list[0] as? String ?? ""
            texts = list[1...3].compactMap { $0 as? String }.filter { !$0.isEmpty }
            children = list[4] as? [AXUIElement] ?? []
        }
    }

    private static func element(_ node: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(node, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func children(_ node: AXUIElement, _ attribute: String) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(node, attribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }


    // MARK: Testing

    /// Testing only: every clickable name in an app's windows, and whether pressing
    /// it by that name would find exactly it. Presses nothing.
    @MainActor static func survey(appNamed name: String) async -> String {
        guard AXIsProcessTrusted() else { return "no Accessibility permission" }
        let running = NSWorkspace.shared.runningApplications
        guard let app = running.first(where: { ($0.localizedName ?? "").lowercased() == name.lowercased() })
            ?? running.first(where: { ($0.localizedName ?? "").lowercased().hasPrefix(name.lowercased()) }) else { return "\(name) isn't running" }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.5)
        AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        try? await Task.sleep(for: .milliseconds(800))
        var windows = children(root, kAXWindowsAttribute)
        if windows.isEmpty, let focused = element(root, kAXFocusedWindowAttribute) { windows = [focused] }
        var names: [String] = [], queue = windows.map { ($0, 0) }, index = 0
        let skipped: Set<String> = ["AXTextField", "AXTextArea", "AXSearchField", "AXComboBox", "AXScrollBar", "AXMenuBar"]
        while index < queue.count, index < 8000 {
            let (node, depth) = queue[index]; index += 1
            if skipped.contains(string(node, kAXRoleAttribute) ?? "") { continue }
            for attribute in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] {
                guard let text = string(node, attribute)?.trimmingCharacters(in: .whitespacesAndNewlines), (2...60).contains(text.count),
                      target(for: node) != nil, !names.contains(text) else { continue }
                names.append(text)
            }
            if depth < 40 { queue += children(node, kAXChildrenAttribute).map { ($0, depth + 1) } }
        }
        var found = 0, lines: [String] = []
        // The shape of the tree, to see where an app stops exposing itself.
        func outline(_ node: AXUIElement, _ depth: Int) {
            guard depth < 9, lines.count < 60 else { return }
            let kids = children(node, kAXChildrenAttribute)
            let label = [kAXTitleAttribute, kAXDescriptionAttribute].compactMap { string(node, $0) }.first { !$0.isEmpty } ?? ""
            lines.append(String(repeating: "  ", count: depth + 1) + (string(node, kAXRoleAttribute) ?? "?") + " \"\(label.prefix(40))\" [\(kids.count)]")
            kids.prefix(6).forEach { outline($0, depth + 1) }
        }
        if names.count < 3 { windows.forEach { outline($0, 0) } }
        // The one-call read has to see exactly what separate reads see, and be quicker.
        var checked = 0, differ = 0, nodes = [root], next = 0
        var slow: TimeInterval = 0, fast: TimeInterval = 0
        while next < nodes.count, checked < 400 {
            let node = nodes[next]; next += 1; checked += 1
            var started = Date()
            let one = Node(node)
            fast += Date().timeIntervalSince(started)
            started = Date()
            let role = string(node, kAXRoleAttribute) ?? ""
            let texts = [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute].compactMap { string(node, $0) }.filter { !$0.isEmpty }
            let kids = children(node, kAXChildrenAttribute)
            slow += Date().timeIntervalSince(started)
            if one.role != role || one.texts != texts || one.children.count != kids.count { differ += 1 }
            nodes += kids
        }
        lines.insert(String(format: "  batched read check: %d elements, %d differ; separate reads %.1f ms, one call %.1f ms", checked, differ, slow * 1000, fast * 1000), at: 0)
        for text in names {
            let plain = AssistantIntent.plain(text)
            guard !plain.isEmpty else { continue }
            switch find(plain, in: root) {
            case .found(let hit):
                found += 1
                let role = string(hit.pressable ?? hit.row ?? hit.element, kAXRoleAttribute) ?? "?"
                lines.append("  ✓ \(text) → \(role)\(hit.pressable == nil ? " (select row)" : "")")
            case .unclear: lines.append("  ? \(text) — more than one")
            case .notYet: lines.append("  ✗ \(text) — not found by its own name")
            }
        }
        return "\(app.localizedName ?? name): \(windows.count) window(s), \(names.count) clickable names, \(found) resolve to exactly one thing\n" + lines.joined(separator: "\n")
    }
}
