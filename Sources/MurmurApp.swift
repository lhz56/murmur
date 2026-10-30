import AppKit
import SwiftUI
import UserNotifications
import Carbon
import Combine
import ApplicationServices

@MainActor
final class GlobalShortcut {
    private var hotKey: EventHotKeyRef?
    private var escapeKey: EventHotKeyRef?
    private var pasteKey: EventHotKeyRef?
    private var editKey: EventHotKeyRef?
    private var typeKey: EventHotKeyRef?
    private var commandKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    /// The Commands shortcut went down (true) or up (false).
    var onCommandKey: ((Bool) -> Void)?
    var onToggle: (() -> Void)?
    var onEscape: (() -> Void)?
    var onPasteLast: (() -> Void)?
    var onEdit: (() -> Void)?
    var onTypeLast: (() -> Void)?

    func register() -> OSStatus {
        var specifications = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                              EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context -> OSStatus in
            guard let context, let event else { return noErr }
            let shortcut = Unmanaged<GlobalShortcut>.fromOpaque(context).takeUnretainedValue()
            var identifier = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            let released = GetEventKind(event) == UInt32(kEventHotKeyReleased)
            if identifier.id == 6 { shortcut.onCommandKey?(!released); return noErr }
            if released { return noErr }
            if identifier.id == 1 { shortcut.onToggle?() }
            if identifier.id == 2 { shortcut.onEscape?() }
            if identifier.id == 3 { shortcut.onPasteLast?() }
            if identifier.id == 4 { shortcut.onEdit?() }
            if identifier.id == 5 { shortcut.onTypeLast?() }
            return noErr
        }, 2, &specifications, Unmanaged.passUnretained(self).toOpaque(), &handler)
        // Paste Last Transcript (Control-Option-V) is optional; a conflict leaves it unregistered.
        RegisterEventHotKey(9, UInt32(controlKey | optionKey), EventHotKeyID(signature: 0x4D524D52, id: 3), GetApplicationEventTarget(), 0, &pasteKey)
        // Edit Selection by Voice (Control-Option-E) is optional too.
        RegisterEventHotKey(14, UInt32(controlKey | optionKey), EventHotKeyID(signature: 0x4D524D52, id: 4), GetApplicationEventTarget(), 0, &editKey)
        // Type Last Transcript (Control-Option-T), for apps that block paste.
        RegisterEventHotKey(17, UInt32(controlKey | optionKey), EventHotKeyID(signature: 0x4D524D52, id: 5), GetApplicationEventTarget(), 0, &typeKey)
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
        if let editKey { UnregisterEventHotKey(editKey) }
        if let typeKey { UnregisterEventHotKey(typeKey) }
        if let commandKey { UnregisterEventHotKey(commandKey) }
        if let handler { RemoveEventHandler(handler) }
    }
}

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
    private var window: NSWindow!
    private var panel: FloatingPanel!
    private var statusItem: NSStatusItem!
    private let shortcut = GlobalShortcut()
    private let fnShortcut = FnShortcut()
    /// Space + Down Arrow: Commands.
    private let commandChord = CommandChordShortcut()
    private var permissionTimer: Timer?
    private var subscriptions = Set<AnyCancellable>()
    let model = AppModel(preview: CommandLine.arguments.contains("--preview"))
    private var launchedAtLogin = false
    private var ducking: AudioDucking?
    private var palette: KeyPanel!
    private var promptPanel: FloatingPanel!
    private var pillPanel: FloatingPanel!
    private var commandKeyDownAt: TimeInterval?
    private var commandHoldTask: Task<Void, Never>?
    private var liveTextTimer: Timer?

    // MARK: Notifications

    /// Timers and "notes ready" show even while Murmur is in front.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    /// Clicking "Notes ready" opens that meeting.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let identifier = response.notification.request.identifier
        guard identifier.hasPrefix("meeting-"), let id = UUID(uuidString: String(identifier.dropFirst(8))) else { return }
        await MainActor.run {
            model.meetings.selectedID = id
            model.section = .meetings
            openLibrary()
        }
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        launchedAtLogin = LaunchAtLogin.launchedAsLoginItem
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        makeMenu()
        makeWindow()
        makeHUD()
        makePalette()
        makeMeetingPanels()
        makeStatusItem()
        model.showWindow = { [weak self] in self?.openLibrary() }
        UNUserNotificationCenter.current().delegate = self
        model.showHUD = { [weak self] capturesEscape in
            if capturesEscape { self?.shortcut.setRecording(true) }
            self?.showRecorder()
        }
        model.hideHUD = { [weak self] in self?.panel.orderOut(nil) }
        if !model.isPreview { ducking = AudioDucking() }
        model.onRecordingChanged = { [weak self] recording in
            guard let self else { return }
            if recording, model.preferences.duckAudio { ducking?.duck() } else if !recording { ducking?.restore() }
            self.shortcut.setRecording(recording)
            self.updateStatusItem(recording: recording || self.model.meetings.liveID != nil)
        }
        shortcut.onToggle = { [weak self] in self?.model.toggleRecording() }
        commandChord.onChord = { [weak self] down in self?.commandKey(down) }
        model.openCommands = { [weak self] in self?.showPalette() }
        model.commands.close = { [weak self] in self?.hidePalette() }
        model.commands.reopen = { [weak self] in self?.showPalette(fresh: false) }
        model.meetings.onDetectedChanged = { [weak self] call in self?.updatePrompt(call) }
        model.meetings.onLiveChanged = { [weak self] live in
            self?.updatePill(live)
            self?.updateStatusItem(recording: live || self?.model.speech.phase == .recording)
        }
        shortcut.onEscape = { [weak self] in self?.model.cancelRecording() }
        shortcut.onPasteLast = { [weak self] in self?.model.pasteLastTranscript() }
        shortcut.onEdit = { [weak self] in self?.model.toggleEditRecording() }
        shortcut.onTypeLast = { [weak self] in self?.model.typeLastTranscript() }
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
        fnShortcut.mouseButton = { [weak self] in self?.model.preferences.mouseButton ?? 0 }
        fnShortcut.onMouse = { [weak self] down in self?.model.handleFn(down ? .startHold : .finishHold) }
        model.preferences.$mouseButton.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.fnShortcut.refresh() }
        }.store(in: &subscriptions)
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
            commandChord.start()
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    if self.model.accessibilityEnabled != AXIsProcessTrusted() { self.model.refreshPermissions() }
                    if self.model.accessibilityEnabled && self.model.preferences.fnEnabled && !self.model.fnAvailable { self.fnShortcut.refresh() }
                    if self.model.accessibilityEnabled && !self.commandChord.isRunning { self.commandChord.start() }
                }
            }
        }
        if !model.isPreview { model.cleanUpOldAudio() }
        if !model.isPreview, model.preferences.checkForUpdates { Task { await model.updates.check() } }
        if !model.isPreview, shortcut.register() != noErr {
            model.errorMessage = "Control Option Space is already used by another app. Close that app to use Murmur’s global shortcut. Recording from Murmur still works."
        }
        // At login, start quietly in the menu bar; the shortcut is what matters.
        if !model.isPreview && !model.preferences.onboarded && !CommandLine.arguments.contains("--smoke-test") {
            model.showOnboarding = true
        }
        if !launchedAtLogin || model.showOnboarding { openLibrary() }
        if model.isPreview && CommandLine.arguments.contains("--island-preview") { previewIsland() }
        if CommandLine.arguments.contains("--smoke-test") {
            print("MURMUR_SMOKE_OK: window=\(window.frame.width)x\(window.frame.height), history=\(model.transcripts.count), root=\(model.storage.root.path)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { NSApp.terminate(nil) }
        }
    }

    private func makeWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = model.isPreview ? "Murmur · Preview" : "Murmur"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 980, height: 640)
        window.backgroundColor = .adaptive(light: 0xFFFFFF, dark: 0x191919)
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

    // MARK: Commands palette

    private func makePalette() {
        palette = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 720, height: 620),
                           styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
        palette.isFloatingPanel = true
        palette.level = .modalPanel
        palette.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        palette.backgroundColor = .clear
        palette.isOpaque = false
        palette.hasShadow = false
        palette.hidesOnDeactivate = false
        palette.isReleasedWhenClosed = false
        palette.onEscape = { [weak self] in self?.paletteEscape() }
        let host = NSHostingView(rootView: CommandPaletteView(center: model.commands, speech: model.speech)
            .frame(width: 720, height: 620, alignment: .top))
        palette.contentView = host
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: palette, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.palette.isVisible, self.model.commands.phase != .listening else { return }
                self.hidePalette()
            }
        }
    }

    /// `fresh: false` shows it as it is, e.g. with "Which WorkLoom?" choices.
    private func showPalette(fresh: Bool = true) {
        guard !palette.isVisible else { NotificationCenter.default.post(name: .murmurPaletteFocus, object: nil); return }
        let center = model.commands
        if fresh {
            let preset = center.query
            center.prepare()
            if !preset.isEmpty { center.query = preset }
        }
        let location = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(location, $0.frame, false) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            palette.setFrameOrigin(NSPoint(x: frame.midX - 360, y: frame.maxY - frame.height * 0.2 - 620))
        }
        center.isOpen = true
        palette.makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name: .murmurPaletteFocus, object: nil)
    }

    private func hidePalette() {
        guard palette.isVisible else { return }
        // Closing while Murmur is still working out a request means "never mind".
        if model.commands.phase == .listening || model.commands.phase == .thinking { model.commands.cancel() }
        model.commands.isOpen = false
        palette.orderOut(nil)
        liveTextTimer?.invalidate(); liveTextTimer = nil
    }

    private func paletteEscape() {
        let center = model.commands
        if center.pendingConfirmation != nil { center.pendingConfirmation = nil; return }
        if center.phase == .listening { center.cancel(); return }
        if !center.query.isEmpty { center.query = ""; return }
        hidePalette()
    }

    /// Tap Space + Down Arrow to type; hold them to speak and let go to run.
    private func commandKey(_ down: Bool) {
        let center = model.commands
        if down {
            guard commandKeyDownAt == nil else { return }
            commandKeyDownAt = ProcessInfo.processInfo.systemUptime
            let wasOpen = palette.isVisible
            if !wasOpen { showPalette() }
            commandHoldTask?.cancel()
            commandHoldTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled, let self, self.commandKeyDownAt != nil else { return }
                guard self.model.speech.phase == .idle, self.model.activeID == nil else { return }
                center.beginListening()
            }
            if wasOpen { pendingToggleClose = true }
        } else {
            let heldFor = commandKeyDownAt.map { ProcessInfo.processInfo.systemUptime - $0 } ?? 0
            commandKeyDownAt = nil
            commandHoldTask?.cancel()
            if center.phase == .listening { center.endListening(); pendingToggleClose = false; return }
            // A quick second tap closes the palette.
            if pendingToggleClose, heldFor < 0.2 { hidePalette() }
            pendingToggleClose = false
        }
    }
    private var pendingToggleClose = false

    // MARK: Meeting panels

    private func makeMeetingPanels() {
        promptPanel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 412, height: 94),
                                    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        pillPanel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 230, height: 56),
                                  styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        for panel in [promptPanel!, pillPanel!] {
            panel.isFloatingPanel = true; panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.backgroundColor = .clear; panel.isOpaque = false; panel.hasShadow = false
            panel.hidesOnDeactivate = false; panel.isMovableByWindowBackground = true
        }
        promptPanel.contentView = NSHostingView(rootView: MeetingPromptView(center: model.meetings).frame(width: 412, height: 94))
        pillPanel.contentView = NSHostingView(rootView: MeetingPillView(center: model.meetings) { [weak self] in
            self?.model.section = .meetings; self?.model.meetings.selectedID = self?.model.meetings.liveID; self?.openLibrary()
        }.frame(width: 230, height: 56, alignment: .trailing))
    }

    private var promptDismissTask: Task<Void, Never>?
    private func updatePrompt(_ call: MeetingCenter.DetectedCall?) {
        promptDismissTask?.cancel()
        guard call != nil else { promptPanel.orderOut(nil); return }
        if let frame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame {
            promptPanel.setFrameOrigin(NSPoint(x: frame.maxX - 412 - 8, y: frame.maxY - 94 - 4))
        }
        promptPanel.orderFrontRegardless()
        playSound("start")
        // The offer goes away on its own; the call keeps going either way.
        promptDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(45))
            guard !Task.isCancelled else { return }
            self?.model.meetings.dismissDetected()
        }
    }

    private func playSound(_ name: String) { model.playSound(name) }

    private func updatePill(_ live: Bool) {
        guard live else { pillPanel.orderOut(nil); return }
        if let frame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame {
            pillPanel.setFrameOrigin(NSPoint(x: frame.maxX - 230 - 6, y: frame.maxY - 56 - 4))
        }
        pillPanel.orderFrontRegardless()
    }

    private func makeStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateStatusItem(recording: false)
    }

    private func updateStatusItem(recording: Bool) {
        statusItem.button?.image = MenuBarGlyph.image(recording: recording)
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
        _ = item("Type Last Transcript", last == nil || busy ? nil : #selector(typeLastTranscript), key: "t", modifiers: [.control, .option])
        _ = item("Edit Selection by Voice", busy ? nil : #selector(editSelectionByVoice), key: "e", modifiers: [.control, .option])
        menu.addItem(.separator())
        _ = item("Commands…", #selector(openCommands), key: " ", modifiers: [.option])
        _ = item(model.meetings.liveID == nil ? "Take Meeting Notes" : "End Meeting and Write Notes", #selector(toggleMeeting))
        menu.addItem(.separator())
        if let update = model.updates.available {
            _ = item("Update Available: Murmur \(update.version)…", #selector(openUpdate))
        }
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
        let welcome = NSMenuItem(title: "Welcome Guide…", action: #selector(showWelcome), keyEquivalent: ""); welcome.target = self; app.addItem(welcome)
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
    @objc private func openCommands() { showPalette() }
    @objc private func toggleMeeting() {
        if model.meetings.liveID == nil { model.meetings.start() } else { model.meetings.stop() }
    }
    @objc private func copyLastTranscript() { if let text = model.lastTranscript?.text { model.copy(text) } }
    @objc private func pasteLastTranscript() { model.pasteLastTranscript() }
    @objc private func importAudio() { openLibrary(); model.importAudio() }
    @objc private func focusSearch() { openLibrary(); NotificationCenter.default.post(name: .murmurSearch, object: nil) }
    @objc private func openUpdate() { if let url = model.updates.available?.url { NSWorkspace.shared.open(url) } }
    @objc private func typeLastTranscript() { model.typeLastTranscript() }
    @objc private func editSelectionByVoice() { model.toggleEditRecording() }
    @objc private func showWelcome() { openLibrary(); model.showSettings = false; model.showOnboarding = true }
    @objc private func showAbout() {
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "Murmur", .applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0", .credits: NSAttributedString(string: "A little less typing. A lot more you.\nNative dictation. On-device speech. Your own library.")])
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { openLibrary(); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        ducking?.restoreNow()
        if model.speech.phase.isBusy || model.activeID != nil || model.commandListening || model.meetings.hasUnsavedAudio {
            Task { await model.prepareToQuit(); shortcut.unregister(); fnShortcut.stop(); commandChord.stop(); NSApp.reply(toApplicationShouldTerminate: true) }
            return .terminateLater
        }
        model.meetings.saveForQuit()
        model.flushEdits(); model.microphoneCheck.stop(); model.speech.localSpeech.parakeet.stop()
        shortcut.unregister(); fnShortcut.stop(); commandChord.stop(); return .terminateNow
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
