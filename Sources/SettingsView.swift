import SwiftUI
import AppKit

/// System Settings–style preferences: a category sidebar and native grouped forms.
struct SettingsView: View {
    enum Pane: String, CaseIterable, Identifiable {
        case shortcut = "Shortcut", microphone = "Microphone", transcription = "Transcription"
        case insertion = "Insertion", recordings = "Recordings", vocabulary = "Vocabulary"
        var id: Self { self }
        var symbol: String {
            switch self {
            case .shortcut: return "keyboard"
            case .microphone: return "mic"
            case .transcription: return "waveform"
            case .insertion: return "text.cursor"
            case .recordings: return "externaldrive"
            case .vocabulary: return "character.book.closed"
            }
        }
    }

    @ObservedObject var model: AppModel
    @ObservedObject var preferences: Preferences
    @ObservedObject var speech: DictationEngine
    @ObservedObject var microphoneCheck: MicrophoneCheck
    @Environment(\.dismiss) private var dismiss
    @State private var pane: Pane
    @State private var heardWord = ""
    @State private var desiredWord = ""
    @StateObject private var login = LaunchAtLogin()

    init(model: AppModel, preferences: Preferences, speech: DictationEngine, microphoneCheck: MicrophoneCheck, initialPane: Pane = .shortcut) {
        self.model = model; self.preferences = preferences; self.speech = speech; self.microphoneCheck = microphoneCheck
        _pane = State(initialValue: initialPane)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 200)
            Hairline(vertical: true)
            VStack(spacing: 0) {
                HStack {
                    Text(pane.rawValue).font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction).buttonStyle(PrimaryButtonStyle())
                }.padding(.horizontal, 24).frame(height: 54)
                Hairline()
                Form { content }
                    .formStyle(.grouped)
                    .scrollContentBackground(.hidden)
                    .background(Palette.canvas)
                    .id(pane)
            }.background(Palette.canvas)
        }
        .frame(width: 780, height: 600)
        .foregroundStyle(Palette.ink)
        .tint(Palette.accent)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refreshPermissions(); login.refresh() }
        .onAppear { model.refreshPermissions(); login.refresh() }
        .onDisappear { microphoneCheck.stop() }
        .onChange(of: pane) { _, _ in microphoneCheck.stop() }
        .onChange(of: preferences.microphoneUID) { _, _ in microphoneCheck.stop() }
        .onChange(of: preferences.recognitionEngine) { _, engine in if engine == .parakeet { model.prepareParakeet(install: false) } }
        .sheet(isPresented: $model.isTestingFn) { FnTestView(model: model) }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("Settings").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.faint)
                .padding(.horizontal, 10).padding(.top, 20).padding(.bottom, 6)
            ForEach(Pane.allCases) { item in
                SidebarItem(title: item.rawValue, symbol: item.symbol, selected: pane == item) { pane = item }
            }
            Spacer()
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "lock.shield").font(.system(size: 12))
                Text("Transcription runs on your Mac. Recordings never leave this device.")
                    .font(.system(size: 11)).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
            }.foregroundStyle(Palette.muted).padding(.horizontal, 10).padding(.bottom, 14)
        }.padding(.horizontal, 8).frame(maxHeight: .infinity, alignment: .top).background(Palette.sidebar)
    }

    @ViewBuilder private var content: some View {
        switch pane {
        case .shortcut: shortcutPane
        case .microphone: microphonePane
        case .transcription: transcriptionPane
        case .insertion: insertionPane
        case .recordings: recordingsPane
        case .vocabulary: vocabularyPane
        }
    }

    // MARK: Panes

    private var shortcutInstruction: String {
        if preferences.dictationKey == .fn { return "Hold Fn to record, then release to finish. Double-tap Fn or press Fn + Space for hands-free recording." }
        if preferences.fnBehavior == .hold { return "Hold Control to record, then release to finish. Short taps are ignored." }
        return "Tap Control to record. Tap again to finish."
    }

    @ViewBuilder private var shortcutPane: some View {
        Section {
            Toggle(isOn: $preferences.fnEnabled) {
                Text("Record from any app")
                Text(shortcutInstruction)
            }
            if preferences.fnEnabled {
                Picker("Dictation key", selection: $preferences.dictationKey) {
                    ForEach(DictationKey.allCases, id: \.self) { key in Text(key.rawValue).tag(key) }
                }
                Picker("Key behavior", selection: $preferences.fnBehavior) {
                    ForEach(FnBehavior.allCases, id: \.self) { behavior in Text(behavior.rawValue).tag(behavior) }
                }
            }
        }
        if preferences.fnEnabled {
            Section {
                LabeledContent {
                    HStack {
                        if !model.fnAvailable { Button("Allow…") { model.requestAccessibility() } }
                        Button("Test key") { model.startFnTest() }.disabled(speech.phase.isBusy)
                    }
                } label: {
                    Label {
                        Text(model.fnAvailable ? (model.fnSignalSeen ? "\(preferences.dictationKey.name) detected" : "Shortcut ready") : "Accessibility permission required")
                        Text(preferences.dictationKey == .control ? "Control combinations keep working normally."
                             : model.fnAvailable ? "Check that this keyboard sends an Fn signal." : "Allow Accessibility access to use Fn in other apps.")
                    } icon: {
                        Image(systemName: model.fnSignalSeen ? "checkmark.circle.fill" : "keyboard")
                            .foregroundStyle(model.fnSignalSeen ? Palette.green : Palette.muted)
                    }
                }
            } footer: {
                if preferences.dictationKey == .fn {
                    VStack(alignment: .leading, spacing: 6) {
                        if let note = KeyboardInfo.fnNote(for: model.keyboardNames) { Text(note) }
                        Text("To stop emoji or Dictation from opening, set “Press 🌐 key to” to “Do Nothing” in System Settings → Keyboard.")
                    }
                }
            }
        }
        Section {
            LabeledContent("Start or finish") { ShortcutKeys() }
            LabeledContent("Paste last transcript") { ShortcutKeys(keys: ["⌃", "⌥", "V"]) }
            LabeledContent("Stop and keep a recording") { ShortcutKeys(keys: ["Esc"]) }
        } header: { Text("Always available") }
        Section {
            Toggle(isOn: Binding(get: { login.isEnabled }, set: { login.set($0) })) {
                Text("Open at login")
                Text("Start Murmur quietly in the menu bar when you log in, so the shortcut always works.")
            }
            if login.needsApproval {
                LabeledContent("Waiting for approval in System Settings") {
                    Button("Open Login Items…") { login.openSystemSettings() }
                }
            }
            if let error = login.error { Text(error).foregroundStyle(Palette.red) }
        }
    }

    @ViewBuilder private var microphonePane: some View {
        Section {
            Picker("Input device", selection: $preferences.microphoneUID) {
                Text("System default").tag("")
                if !preferences.microphoneUID.isEmpty && !model.microphones.contains(where: { $0.id == preferences.microphoneUID }) {
                    Text("Selected microphone · disconnected").tag(preferences.microphoneUID)
                }
                ForEach(model.microphones) { microphone in Text(microphone.name).tag(microphone.id) }
            }.disabled(speech.phase.isBusy)
        } footer: {
            Button("Refresh devices") { model.refreshPermissions() }.buttonStyle(.link)
        }
        Section {
            LabeledContent {
                Button(microphoneCheck.isRunning ? "Stop" : "Test") { model.toggleMicrophoneCheck() }
                    .disabled(speech.phase.isBusy)
            } label: {
                Text(microphoneCheck.isRunning ? microphoneCheck.name : "Input level")
                Text(microphoneCheck.isRunning ? microphoneCheck.signal.label : "Speak normally to check your microphone. Audio isn’t saved.")
            }
            if microphoneCheck.isRunning {
                HStack(spacing: 12) {
                    ProgressView(value: Double(microphoneCheck.signal.level)).tint(Palette.green)
                    Text(String(format: "%.0f dB", microphoneCheck.signal.decibels)).monospacedDigit()
                        .foregroundStyle(Palette.muted).frame(width: 48, alignment: .trailing)
                }.accessibilityLabel("Microphone input level \(Int(microphoneCheck.signal.decibels)) decibels")
            }
            if let error = microphoneCheck.error { Text(error).foregroundStyle(Palette.red) }
        }
    }

    @ViewBuilder private var transcriptionPane: some View {
        Section {
            Picker(selection: $preferences.recognitionEngine) {
                ForEach(RecognitionEngine.allCases, id: \.self) { engine in Text(engine.rawValue).tag(engine) }
            } label: {
                Text("Speech engine")
                Text(preferences.recognitionEngine.subtitle)
            }.disabled(speech.phase.isBusy)
            if preferences.recognitionEngine == .parakeet {
                LabeledContent {
                    if !model.parakeetReady {
                        Button(model.parakeetPreparationError != nil ? "Retry" : "Download") { model.prepareParakeet() }
                            .disabled(model.parakeetInstalling)
                    }
                } label: {
                    Label {
                        Text(model.parakeetReady ? "Model ready · works offline" : model.parakeetInstalling ? "Preparing model…"
                             : model.parakeetPreparationError != nil ? "Couldn’t prepare model" : "Model not downloaded")
                        if let error = model.parakeetPreparationError, !model.parakeetInstalling { Text(error) }
                    } icon: {
                        Image(systemName: model.parakeetReady ? "checkmark.circle.fill" : model.parakeetPreparationError != nil ? "exclamationmark.circle" : "arrow.down.circle")
                            .foregroundStyle(model.parakeetReady ? Palette.green : Palette.muted)
                    }
                }
                if model.parakeetInstalling { ProgressView(value: model.parakeetProgress) }
            }
            Picker("Language", selection: $preferences.locale) {
                if !speech.supportedLanguages.contains(where: { $0.identifier == preferences.locale }) {
                    Text(Locale.current.localizedString(forIdentifier: preferences.locale) ?? preferences.locale).tag(preferences.locale)
                }
                ForEach(speech.supportedLanguages, id: \.identifier) { locale in
                    Text(Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier).tag(locale.identifier)
                }
            }.disabled(speech.phase.isBusy)
        }
    }

    @ViewBuilder private var insertionPane: some View {
        Section {
            Toggle(isOn: $preferences.autoPaste) {
                Text("Insert into active app")
                Text("Paste the transcript at your cursor when recording finishes.")
            }
            Toggle(isOn: $preferences.autoCopy) {
                Text("Keep on clipboard")
                Text(preferences.autoCopy ? "Each finished transcript stays on the clipboard."
                                          : "Your previous clipboard is restored after a confirmed insertion.")
            }
        }
        if preferences.autoPaste {
            Section {
                LabeledContent {
                    if !model.accessibilityEnabled { Button("Allow…") { model.requestAccessibility() } }
                } label: {
                    Label {
                        Text(model.accessibilityEnabled ? "Insertion enabled" : "Accessibility permission required")
                        Text(model.accessibilityEnabled ? "Keep the destination app focused while recording finishes."
                                                        : "Allow Murmur in Accessibility to insert text into other apps.")
                    } icon: {
                        Image(systemName: model.accessibilityEnabled ? "checkmark.shield.fill" : "exclamationmark.shield")
                            .foregroundStyle(model.accessibilityEnabled ? Palette.green : Palette.muted)
                    }
                }
                LabeledContent {
                    Button("Test") { model.testInsertion() }.disabled(!model.accessibilityEnabled || speech.phase.isBusy)
                } label: {
                    Text("Test insertion")
                    Text("Click a text box within 8 seconds. Murmur inserts a sentence without recording.")
                }
            } footer: {
                if let result = model.deliveryResult { Text("Last insertion: \(result.message)") }
            }
        }
    }

    @ViewBuilder private var recordingsPane: some View {
        Section {
            Toggle(isOn: $preferences.keepAudio) {
                Text("Save audio")
                Text("Keep recordings for playback and transcription retries.")
            }
            Toggle(isOn: $preferences.sounds) {
                Text("Recording sounds")
                Text("Play a soft chime when recording starts and stops.")
            }
            if preferences.sounds {
                LabeledContent("Preview") {
                    HStack {
                        Button("Start") { model.playSound("start") }
                        Button("Stop") { model.playSound("finish") }
                    }
                }
            }
        }
        Section {
            LabeledContent {
                Button("Show in Finder") { NSWorkspace.shared.open(model.storage.root) }
            } label: {
                Text("Library folder")
                Text("Application Support / Murmur")
            }
        }
    }

    @ViewBuilder private var vocabularyPane: some View {
        Section {
            HStack(spacing: 8) {
                TextField("Heard", text: $heardWord, prompt: Text("mer mer")).labelsHidden()
                Image(systemName: "arrow.right").foregroundStyle(Palette.faint)
                TextField("Replace with", text: $desiredWord, prompt: Text("Murmur")).labelsHidden()
                Button("Add") {
                    model.rememberCorrection(heard: heardWord, desired: desiredWord); heardWord = ""; desiredWord = ""
                }.disabled(heardWord.trimmingCharacters(in: .whitespaces).isEmpty || desiredWord.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: {
            Text("Add a correction")
        } footer: {
            Text("Replacements apply to every engine. Whisper also uses them as recognition hints.")
        }
        Section {
            TextEditor(text: $preferences.vocabulary).font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden).frame(height: 150)
                .overlay(alignment: .topLeading) {
                    if preferences.vocabulary.isEmpty {
                        Text("mer mer => Murmur\nfig ma => Figma").font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Palette.faint).padding(.leading, 5).allowsHitTesting(false)
                    }
                }.accessibilityLabel("Vocabulary replacements")
        } header: {
            Text("All replacements · one per line")
        }
    }
}

struct FnTestView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var spaceReceived = false
    @State private var monitor: Any?

    private var key: DictationKey { model.preferences.dictationKey }
    private var detected: Bool { model.fnTestPresses > 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Test shortcut").font(.system(size: 18, weight: .semibold))
                    Text("Check that your keyboard sends the selected key.").font(.system(size: 13)).foregroundStyle(Palette.muted)
                }
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
            }
            HStack(spacing: 16) {
                Text(key.keyCap).font(.system(size: 22, weight: .medium))
                    .frame(width: 56, height: 56)
                    .foregroundStyle(detected ? Palette.green : Palette.ink)
                    .background(detected ? Palette.green.opacity(0.1) : Palette.wash, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text(detected ? "\(key.name) detected · \(model.fnTestPresses) press\(model.fnTestPresses == 1 ? "" : "es")" : "Waiting for \(key.name)…")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Press \(key.name), then release it.").font(.system(size: 13)).foregroundStyle(Palette.muted)
                }
            }
            Callout(symbol: spaceReceived ? "checkmark.circle.fill" : "keyboard", tint: spaceReceived ? Palette.green : Palette.muted) {
                Text(spaceReceived ? "Space detected. This window is receiving keys." : "Press Space to check that this window is receiving keys.")
            }
            if key == .fn, !detected, let note = KeyboardInfo.fnNote(for: model.keyboardNames) {
                Text(note).font(.system(size: 12)).foregroundStyle(Palette.muted).lineSpacing(3)
            }
            Text("This test doesn’t use the microphone or save a recording.").font(.system(size: 11)).foregroundStyle(Palette.faint)
        }.padding(24).frame(width: 500).background(Palette.canvas).foregroundStyle(Palette.ink)
            .animation(.easeOut(duration: 0.15), value: model.fnTestPresses)
            .onAppear {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    if event.keyCode == 49 && !event.modifierFlags.contains(.function) {
                        spaceReceived = true
                        return nil
                    }
                    return event
                }
            }
            .onDisappear {
                if let monitor { NSEvent.removeMonitor(monitor) }
                model.endFnTest()
            }
    }
}
