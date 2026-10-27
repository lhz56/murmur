import AppKit
import SwiftUI
import Carbon
import Combine
import ApplicationServices

@MainActor
final class GlobalShortcut {
    private var hotKey: EventHotKeyRef?
    private var escapeKey: EventHotKeyRef?
    private var pasteKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    var onToggle: (() -> Void)?
    var onEscape: (() -> Void)?
    var onPasteLast: (() -> Void)?

    func register() -> OSStatus {
        var specification = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context -> OSStatus in
            guard let context, let event else { return noErr }
            let shortcut = Unmanaged<GlobalShortcut>.fromOpaque(context).takeUnretainedValue()
            var identifier = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            if identifier.id == 1 { shortcut.onToggle?() }
            if identifier.id == 2 { shortcut.onEscape?() }
            if identifier.id == 3 { shortcut.onPasteLast?() }
            return noErr
        }, 1, &specification, Unmanaged.passUnretained(self).toOpaque(), &handler)
        // Paste Last Transcript (Control-Option-V) is optional; a conflict leaves it unregistered.
        RegisterEventHotKey(9, UInt32(controlKey | optionKey), EventHotKeyID(signature: 0x4D524D52, id: 3), GetApplicationEventTarget(), 0, &pasteKey)
        return RegisterEventHotKey(49, UInt32(controlKey | optionKey), EventHotKeyID(signature: 0x4D524D52, id: 1), GetApplicationEventTarget(), 0, &hotKey)
    }

    func setRecording(_ recording: Bool) {
        if recording, escapeKey == nil {
            RegisterEventHotKey(53, 0, EventHotKeyID(signature: 0x4D524D52, id: 2), GetApplicationEventTarget(), 0, &escapeKey)
        } else if !recording, let escapeKey {
            UnregisterEventHotKey(escapeKey); self.escapeKey = nil
        }
    }
    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let escapeKey { UnregisterEventHotKey(escapeKey) }
        if let pasteKey { UnregisterEventHotKey(pasteKey) }
        if let handler { RemoveEventHandler(handler) }
    }
}

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    private var window: NSWindow!
    private var panel: FloatingPanel!
    private var statusItem: NSStatusItem!
    private let shortcut = GlobalShortcut()
    private let fnShortcut = FnShortcut()
    private var permissionTimer: Timer?
    private var subscriptions = Set<AnyCancellable>()
    let model = AppModel(preview: CommandLine.arguments.contains("--preview"))

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        makeMenu()
        makeWindow()
        makeHUD()
        makeStatusItem()
        model.showWindow = { [weak self] in self?.openLibrary() }
        model.showHUD = { [weak self] capturesEscape in
            if capturesEscape { self?.shortcut.setRecording(true) }
            self?.showRecorder()
        }
        model.hideHUD = { [weak self] in self?.panel.orderOut(nil) }
        model.onRecordingChanged = { [weak self] recording in
            self?.shortcut.setRecording(recording)
            self?.updateStatusItem(recording: recording)
        }
        shortcut.onToggle = { [weak self] in self?.model.toggleRecording() }
        shortcut.onEscape = { [weak self] in self?.model.cancelRecording() }
        shortcut.onPasteLast = { [weak self] in self?.model.pasteLastTranscript() }
        fnShortcut.behavior = { [weak self] in self?.model.preferences.fnBehavior ?? .hold }
        fnShortcut.trigger = { [weak self] in self?.model.preferences.dictationKey ?? .control }
        fnShortcut.enabled = { [weak self] in
            guard let self else { return false }
            return !model.isPreview && model.preferences.fnEnabled
        }
        fnShortcut.isBusy = { [weak self] in self?.model.speech.phase.isBusy ?? false }
        fnShortcut.onAction = { [weak self] action in self?.model.handleFn(action) }
        fnShortcut.onAvailability = { [weak self] available in
            if self?.model.fnAvailable != available { self?.model.fnAvailable = available }
        }
        fnShortcut.onFnSignal = { [weak self] down in
            guard let self, down else { return }
            model.fnSignalSeen = true
            if model.isTestingFn { model.fnTestPresses += 1 }
        }
        model.refreshFn = { [weak self] in self?.fnShortcut.refresh() }
        model.resetFnInput = { [weak self] in self?.fnShortcut.resetInput() }
        model.preferences.$fnEnabled.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.fnShortcut.refresh() }
        }.store(in: &subscriptions)
        model.preferences.$dictationKey.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.model.fnSignalSeen = false
                self?.fnShortcut.refresh()
            }
        }.store(in: &subscriptions)
        if !model.isPreview {
            fnShortcut.refresh()
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    if self.model.accessibilityEnabled != AXIsProcessTrusted() { self.model.refreshPermissions() }
                    if self.model.accessibilityEnabled && self.model.preferences.fnEnabled && !self.model.fnAvailable { self.fnShortcut.refresh() }
                }
            }
        }
        if !model.isPreview, shortcut.register() != noErr {
            model.errorMessage = "Control Option Space is already used by another app. Close that app to use Murmur’s global shortcut. Recording from Murmur still works."
        }
        openLibrary()
        if model.isPreview && CommandLine.arguments.contains("--island-preview") { previewIsland() }
        if CommandLine.arguments.contains("--smoke-test") {
            print("MURMUR_SMOKE_OK: window=\(window.frame.width)x\(window.frame.height), history=\(model.transcripts.count), root=\(model.storage.root.path)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { NSApp.terminate(nil) }
        }
    }

    private func makeWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1110, height: 790),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = model.isPreview ? "Murmur · Preview" : "Murmur"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 940, height: 670)
        window.backgroundColor = .adaptive(light: 0xFAFAFB, dark: 0x1B1C1F)
        window.contentView = NSHostingView(rootView: MainView(model: model))
        window.delegate = self
        window.setFrameAutosaveName(model.isPreview ? "MurmurPreview" : "MurmurMain")
        window.center()
    }

    private func previewIsland() {
        Task {
            for _ in 0..<12 {
                model.hudMessage = nil; model.hudVisible = true
                model.speech.liveText = ""; model.speech.phase = .preparing
                showRecorder()
                try? await Task.sleep(for: .milliseconds(850))
                model.speech.phase = .recording; model.playSound("start")
                for index in 0..<36 {
                    model.speech.elapsed = Double(index) / 5
                    model.speech.level = Float(0.35 + 0.35 * abs(sin(Double(index) * 0.7)))
                    if index > 5 { model.speech.liveText = "A little less typing. A lot more you. Every thought, safely at home on your Mac." }
                    try? await Task.sleep(for: .milliseconds(200))
                }
                model.speech.phase = .finishing
                try? await Task.sleep(for: .milliseconds(700))
                model.speech.phase = .idle; model.hudMessage = "Saved · 18 words"; model.playSound("finish")
                try? await Task.sleep(for: .milliseconds(1200))
                model.hudVisible = false
                try? await Task.sleep(for: .milliseconds(650))
            }
            panel.orderOut(nil)
        }
    }

    private func makeHUD() {
        panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 170),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.contentView = NSHostingView(rootView: RecorderHUD(model: model, speech: model.speech))
    }
    private func showRecorder() {
        let location = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(location, $0.frame, false) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.midX - 240, y: frame.minY + 20))
        }
        panel.orderFrontRegardless()
    }

    private func makeStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateStatusItem(recording: false)
    }

    private func updateStatusItem(recording: Bool) {
        let image = NSImage(systemSymbolName: recording ? "waveform.circle.fill" : "waveform", accessibilityDescription: "Murmur")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.toolTip = recording ? "Murmur is listening · Control Option Space to finish" : "Murmur · Control Option Space to talk"
    }

    /// Rebuilt each time it opens, so it always reflects the latest transcript.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let recording = model.speech.phase == .recording
        func item(_ title: String, _ action: Selector?, key: String = "", modifiers: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.target = self
            menu.addItem(item)
            return item
        }
        let title = item(recording ? "Recording…" : "Murmur", nil)
        title.isEnabled = false
        menu.addItem(.separator())
        _ = item(recording ? "Finish Recording" : "Record", #selector(toggleRecording), key: " ", modifiers: [.control, .option])
        let last = model.lastTranscript
        let busy = model.speech.phase.isBusy
        let copy = item("Copy Last Transcript", last == nil ? nil : #selector(copyLastTranscript))
        copy.toolTip = last?.title
        _ = item("Paste Last Transcript", last == nil || busy ? nil : #selector(pasteLastTranscript), key: "v", modifiers: [.control, .option])
        menu.addItem(.separator())
        _ = item("Open Library", #selector(openLibrary))
        _ = item("Settings…", #selector(openSettings))
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Murmur", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    private func makeMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let app = NSMenu(); appItem.submenu = app
        let about = NSMenuItem(title: "About Murmur", action: #selector(showAbout), keyEquivalent: ""); about.target = self; app.addItem(about)
        app.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ","); settings.target = self; app.addItem(settings)
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Murmur", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h").keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Murmur", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: ""); main.addItem(fileItem)
        let file = NSMenu(title: "File"); fileItem.submenu = file
        let record = NSMenuItem(title: "Start / Finish Dictation", action: #selector(toggleRecording), keyEquivalent: "n"); record.target = self; file.addItem(record)
        let show = NSMenuItem(title: "Open Library", action: #selector(openLibrary), keyEquivalent: "l"); show.target = self; file.addItem(show)
        let importItem = NSMenuItem(title: "Import Audio…", action: #selector(importAudio), keyEquivalent: "i"); importItem.target = self; file.addItem(importItem)
        file.addItem(.separator()); file.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: ""); main.addItem(editItem)
        let edit = NSMenu(title: "Edit"); editItem.submenu = edit
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        let find = NSMenuItem(title: "Search Library", action: #selector(focusSearch), keyEquivalent: "f"); find.target = self; edit.addItem(find)
        let windowItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: ""); main.addItem(windowItem)
        let windows = NSMenu(title: "Window"); windowItem.submenu = windows
        windows.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windows.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        NSApp.windowsMenu = windows
        NSApp.mainMenu = main
    }

    @objc func openLibrary() { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    @objc private func openSettings() { openLibrary(); model.showSettings = true }
    @objc private func toggleRecording() { model.toggleRecording() }
    @objc private func copyLastTranscript() { if let text = model.lastTranscript?.text { model.copy(text) } }
    @objc private func pasteLastTranscript() { model.pasteLastTranscript() }
    @objc private func importAudio() { openLibrary(); model.importAudio() }
    @objc private func focusSearch() { openLibrary(); NotificationCenter.default.post(name: .murmurSearch, object: nil) }
    @objc private func showAbout() {
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "Murmur", .applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0", .credits: NSAttributedString(string: "A little less typing. A lot more you.\nNative dictation. On-device speech. Your own library.")])
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { openLibrary(); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if model.speech.phase.isBusy || model.activeID != nil {
            Task { await model.prepareToQuit(); shortcut.unregister(); fnShortcut.stop(); NSApp.reply(toApplicationShouldTerminate: true) }
            return .terminateLater
        }
        model.flushEdits(); model.microphoneCheck.stop(); model.speech.localSpeech.parakeet.stop()
        shortcut.unregister(); fnShortcut.stop(); return .terminateNow
    }
}

@main
struct MurmurMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
