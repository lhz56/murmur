import AppKit

@MainActor final class CountingTextView: NSTextView {
    var pasteCount = 0
    var changed: (() -> Void)?
    override func paste(_ sender: Any?) {
        pasteCount += 1
        super.paste(sender)
        changed?()
    }
}

@MainActor final class CompatibilityDelegate: NSObject, NSApplicationDelegate, NSTextFieldDelegate {
    var window: NSWindow!
    let field = NSTextField()
    let other = NSTextField()
    let textView = CountingTextView()
    let status = NSTextField(wrappingLabelWithString: "Waiting for a paste. Nothing is recorded or sent.")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let menu = NSMenu()
        let appItem = NSMenuItem(); menu.addItem(appItem)
        let appMenu = NSMenu(); appItem.submenu = appMenu
        appMenu.addItem(withTitle: "Quit compatibility check", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: ""); menu.addItem(fileItem)
        fileItem.submenu = NSMenu(title: "File")
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: ""); menu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit"); editItem.submenu = editMenu
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        NSApp.mainMenu = menu
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 460),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Murmur native compatibility check"
        func label(_ text: String, y: CGFloat) {
            let label = NSTextField(labelWithString: text)
            label.frame = NSRect(x: 24, y: y, width: 632, height: 22)
            window.contentView?.addSubview(label)
        }
        label("Native text field", y: 407)
        field.frame = NSRect(x: 24, y: 367, width: 632, height: 34)
        field.delegate = self; field.setAccessibilityLabel("Native text field")
        window.contentView?.addSubview(field)
        label("Second field — use to check that changing focus prevents insertion", y: 327)
        other.frame = NSRect(x: 24, y: 287, width: 632, height: 34)
        other.delegate = self; other.setAccessibilityLabel("Second text field")
        window.contentView?.addSubview(other)
        label("Native multiline text view", y: 247)
        let scroll = NSScrollView(frame: NSRect(x: 24, y: 122, width: 632, height: 118))
        scroll.borderType = .bezelBorder; scroll.hasVerticalScroller = true
        textView.frame = scroll.bounds
        textView.font = .systemFont(ofSize: 15)
        textView.isRichText = false; textView.setAccessibilityLabel("Native multiline text view")
        textView.changed = { [weak self] in self?.updateStatus() }
        scroll.documentView = textView; window.contentView?.addSubview(scroll)
        status.frame = NSRect(x: 24, y: 22, width: 632, height: 86)
        window.contentView?.addSubview(status)
        window.center(); window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(field)
        NSApp.activate(ignoringOtherApps: true)
    }

    func controlTextDidChange(_ obj: Notification) { updateStatus() }
    func updateStatus() {
        status.stringValue = "Field: \(field.stringValue)\nSecond: \(other.stringValue)\nMultiline: \(textView.string)\nMultiline paste calls: \(textView.pasteCount)"
    }
}

@main struct NativeCompatibilityFixture {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = CompatibilityDelegate()
        app.delegate = delegate; app.run()
        withExtendedLifetime(delegate) {}
    }
}
