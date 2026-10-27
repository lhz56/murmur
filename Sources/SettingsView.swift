import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var preferences: Preferences
    @ObservedObject var speech: DictationEngine
    @ObservedObject var microphoneCheck: MicrophoneCheck
    @Environment(\.dismiss) private var dismiss
    @State private var heardWord = ""
    @State private var desiredWord = ""
    private var shortcutInstruction: String {
        if preferences.dictationKey == .fn { return "Hold Fn to record, then release to finish. Double-tap Fn or press Fn + Space for hands-free recording." }
        if preferences.fnBehavior == .hold { return "Hold Control to record, then release to finish. Short taps are ignored. Choose Press to toggle for hands-free recording." }
        return "Tap Control to record. Tap again to finish."
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Settings").font(.system(size: 23, weight: .semibold))
                    Text("Recording, shortcuts, and transcription.").font(.system(size: 12)).foregroundStyle(Palette.muted)
                }
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(.borderedProminent).tint(Palette.accent).keyboardShortcut(.defaultAction)
            }.padding(.horizontal, 24).padding(.vertical, 22)
            Divider().overlay(Palette.line)
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    section("Shortcut") {
                        HStack(alignment: .top, spacing: 20) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("Record from any app").font(.system(size: 13, weight: .medium))
                                Text(shortcutInstruction).font(.system(size: 12)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                            ShortcutKeys(keys: [preferences.dictationKey.keyCap])
                        }
                        Divider().overlay(Palette.line)
                        HStack {
                            Text("Dictation key")
                            Spacer()
                            Picker("Dictation key", selection: $preferences.dictationKey) {
                                ForEach(DictationKey.allCases, id: \.self) { key in Text(key.rawValue).tag(key) }
                            }.labelsHidden().frame(width: 180)
                        }
                        settingToggle("Enable shortcut", subtitle: "Record using your selected dictation key.", value: $preferences.fnEnabled)
                        if preferences.fnEnabled {
                            HStack {
                                Text("Key behavior")
                                Spacer()
                                Picker("Key behavior", selection: $preferences.fnBehavior) {
                                    ForEach(FnBehavior.allCases, id: \.self) { behavior in Text(behavior.rawValue).tag(behavior) }
                                }.labelsHidden().frame(width: 180)
                            }
                            HStack(alignment: .center, spacing: 10) {
                                Image(systemName: model.fnSignalSeen ? "checkmark.circle.fill" : "keyboard")
                                    .foregroundStyle(model.fnSignalSeen ? Palette.green : Palette.muted)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(model.fnAvailable ? (model.fnSignalSeen ? "\(preferences.dictationKey.name) detected" : "Shortcut ready") : "Accessibility permission required")
                                        .font(.system(size: 12, weight: .medium))
                                    Text(preferences.dictationKey == .control ? "Control combinations continue to work normally." : model.fnAvailable ? "Test your key to check that this keyboard sends an Fn signal." : "Allow Accessibility access to use Fn in other apps.")
                                        .font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 8)
                                if !model.fnAvailable { Button("Enable") { model.requestAccessibility() }.buttonStyle(.bordered) }
                                Button("Test key") { model.startFnTest() }.buttonStyle(.bordered).disabled(speech.phase.isBusy)
                            }
                            if preferences.dictationKey == .fn, let note = KeyboardInfo.fnNote(for: model.keyboardNames) {
                                Text(note).font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(3)
                            }
                            if preferences.dictationKey == .fn {
                                Text("To prevent emoji or Dictation from opening, select “Do Nothing” for “Press 🌐 key to” in System Settings → Keyboard.")
                                    .font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(3)
                            }
                        }
                        Divider().overlay(Palette.line)
                        HStack {
                            Text("Alternate shortcut").foregroundStyle(Palette.muted)
                            Spacer()
                            ShortcutKeys()
                        }
                        HStack {
                            Text("Paste last transcript").foregroundStyle(Palette.muted)
                            Spacer()
                            ShortcutKeys(keys: ["⌃", "⌥", "V"])
                        }
                        Text("Press Esc to stop and keep an unfinished recording.").font(.system(size: 11)).foregroundStyle(Palette.muted)
                    }
                    section("Microphone") {
                        HStack {
                            Text("Input device")
                            Spacer()
                            Picker("Microphone", selection: $preferences.microphoneUID) {
                                Text("System default").tag("")
                                if !preferences.microphoneUID.isEmpty && !model.microphones.contains(where: { $0.id == preferences.microphoneUID }) {
                                    Text("Selected microphone · disconnected").tag(preferences.microphoneUID)
                                }
                                ForEach(model.microphones) { microphone in Text(microphone.name).tag(microphone.id) }
                            }.labelsHidden().frame(width: 280).disabled(speech.phase.isBusy)
                        }
                        Divider().overlay(Palette.line)
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(microphoneCheck.isRunning ? microphoneCheck.name : "Input level test").font(.system(size: 12, weight: .medium))
                                Text(microphoneCheck.isRunning ? microphoneCheck.signal.label : "Speak normally to check your microphone. Audio is not saved.")
                                    .font(.system(size: 11)).foregroundStyle(Palette.muted)
                            }
                            Spacer()
                            Button(microphoneCheck.isRunning ? "Stop test" : "Test microphone") { model.toggleMicrophoneCheck() }
                                .buttonStyle(.bordered).disabled(speech.phase.isBusy)
                        }
                        if microphoneCheck.isRunning {
                            HStack(spacing: 12) {
                                ProgressView(value: Double(microphoneCheck.signal.level)).tint(Palette.green)
                                Text(String(format: "%.0f dB", microphoneCheck.signal.decibels)).font(.system(size: 11)).monospacedDigit().foregroundStyle(Palette.muted).frame(width: 48)
                            }.accessibilityLabel("Microphone input level \(Int(microphoneCheck.signal.decibels)) decibels")
                        }
                        if let error = microphoneCheck.error { Text(error).font(.system(size: 11)).foregroundStyle(Palette.accent) }
                        Button("Refresh devices") { model.refreshPermissions() }.font(.system(size: 12)).buttonStyle(.link)
                    }
                    section("Transcription") {
                        HStack {
                            Text("Speech engine")
                            Spacer()
                            Picker("Speech engine", selection: $preferences.recognitionEngine) {
                                ForEach(RecognitionEngine.allCases, id: \.self) { engine in Text(engine.rawValue).tag(engine) }
                            }.labelsHidden().frame(width: 180).disabled(speech.phase.isBusy)
                        }
                        Text(preferences.recognitionEngine.subtitle).font(.system(size: 11)).foregroundStyle(Palette.muted)
                        if preferences.recognitionEngine == .parakeet {
                            HStack(spacing: 12) {
                                Label(model.parakeetReady ? "Model ready · available offline" : model.parakeetInstalling ? "Preparing model…" : model.parakeetPreparationError != nil ? "Couldn’t prepare model" : "Download the model to transcribe offline.", systemImage: model.parakeetReady ? "checkmark.circle" : model.parakeetPreparationError != nil ? "exclamationmark.circle" : "arrow.down.circle")
                                    .font(.system(size: 11)).foregroundStyle(model.parakeetReady ? Palette.green : Palette.muted)
                                Spacer()
                                if !model.parakeetReady {
                                    Button(model.parakeetPreparationError != nil ? "Retry preparation" : "Download model") { model.prepareParakeet() }.buttonStyle(.bordered).disabled(model.parakeetInstalling)
                                }
                            }
                            if let preparationError = model.parakeetPreparationError, !model.parakeetInstalling {
                                Text(preparationError).font(.system(size: 11)).foregroundStyle(Palette.muted)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if model.parakeetInstalling { ProgressView(value: model.parakeetProgress).tint(Palette.accent) }
                        }
                        HStack {
                            Text("Language")
                            Spacer()
                            Picker("Speech language", selection: $preferences.locale) {
                                if !speech.supportedLanguages.contains(where: { $0.identifier == preferences.locale }) {
                                    Text(Locale.current.localizedString(forIdentifier: preferences.locale) ?? preferences.locale).tag(preferences.locale)
                                }
                                ForEach(speech.supportedLanguages, id: \.identifier) { locale in
                                    Text(Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier).tag(locale.identifier)
                                }
                            }.labelsHidden().frame(width: 250).disabled(speech.phase.isBusy)
                        }
                        Divider().overlay(Palette.line)
                        settingToggle("Copy to clipboard", subtitle: preferences.autoCopy ? "Keep each finished transcript on the clipboard." : "Your clipboard is restored after a confirmed insertion.", value: $preferences.autoCopy)
                        settingToggle("Insert into active app", subtitle: "Paste the transcript at your cursor when recording finishes.", value: $preferences.autoPaste)
                        if preferences.autoPaste {
                            HStack(spacing: 10) {
                                Image(systemName: model.accessibilityEnabled ? "checkmark.shield" : "cursorarrow.click.2").foregroundStyle(model.accessibilityEnabled ? Palette.green : Palette.muted)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(model.accessibilityEnabled ? "Insertion enabled" : "Accessibility permission required").font(.system(size: 12, weight: .medium))
                                    Text(model.accessibilityEnabled ? "Keep the destination app focused when recording finishes." : "Allow Murmur in Accessibility to insert text into other apps.")
                                        .font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer()
                                if !model.accessibilityEnabled { Button("Enable") { model.requestAccessibility() }.buttonStyle(.bordered) }
                            }
                            Button("Test insertion") { model.testInsertion() }
                                .buttonStyle(.bordered).disabled(!model.accessibilityEnabled || speech.phase.isBusy)
                            Text("Click a text box within 8 seconds. Murmur will insert a test sentence without recording audio.")
                                .font(.system(size: 11)).foregroundStyle(Palette.muted)
                            if let result = model.deliveryResult {
                                Text("Last insertion: \(result.message)")
                                    .font(.system(size: 11)).foregroundStyle(Palette.muted)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    section("Recordings") {
                        settingToggle("Save audio", subtitle: "Keep recordings on this Mac for playback and transcription retries.", value: $preferences.keepAudio)
                        settingToggle("Recording sounds", subtitle: "Play a sound when recording starts and stops.", value: $preferences.sounds)
                        HStack(spacing: 10) {
                            Button { model.playSound("start") } label: { Label("Preview start", systemImage: "speaker.wave.1") }
                            Button { model.playSound("finish") } label: { Label("Preview stop", systemImage: "speaker.wave.1") }
                        }.buttonStyle(.bordered).disabled(!preferences.sounds)
                        Divider().overlay(Palette.line)
                        HStack {
                            Text("Saved in Application Support / Murmur.").font(.system(size: 11)).foregroundStyle(Palette.muted)
                            Spacer()
                            Button("Show folder") { NSWorkspace.shared.open(model.storage.root) }.font(.system(size: 12)).buttonStyle(.link)
                        }
                    }
                    section("Vocabulary") {
                        Text("Add names or phrases that need correction. Replacements apply to every engine; Whisper also uses them as recognition hints.")
                            .font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(3)
                        HStack(spacing: 8) {
                            TextField("Recognized text", text: $heardWord).textFieldStyle(.roundedBorder)
                            Image(systemName: "arrow.right").foregroundStyle(Palette.muted)
                            TextField("Replacement", text: $desiredWord).textFieldStyle(.roundedBorder)
                            Button("Add") {
                                model.rememberCorrection(heard: heardWord, desired: desiredWord); heardWord = ""; desiredWord = ""
                            }.buttonStyle(.bordered).disabled(heardWord.trimmingCharacters(in: .whitespaces).isEmpty || desiredWord.trimmingCharacters(in: .whitespaces).isEmpty)
                        }.font(.system(size: 12))
                        TextEditor(text: $preferences.vocabulary).font(.system(size: 12, design: .monospaced))
                            .scrollContentBackground(.hidden).padding(8).frame(height: 90)
                            .background(Palette.canvas, in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Palette.line, lineWidth: 1))
                            .overlay(alignment: .topLeading) {
                                if preferences.vocabulary.isEmpty { Text("mer mer => Murmur\nfig ma => Figma").font(.system(size: 12, design: .monospaced)).foregroundStyle(Palette.muted.opacity(0.6)).padding(13).allowsHitTesting(false) }
                            }.accessibilityLabel("Vocabulary replacements")
                    }
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "lock.shield").font(.system(size: 14)).foregroundStyle(Palette.muted)
                        Text("Transcription runs on your Mac. Models may download during setup; your recordings stay on this device.")
                            .font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(3)
                    }.padding(.horizontal, 4)
                }.padding(24)
            }
        }.font(.system(size: 13)).frame(width: 660, height: 690).background(Palette.canvas).foregroundStyle(Palette.ink)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refreshPermissions() }
        .onAppear { model.refreshPermissions() }
        .onDisappear { microphoneCheck.stop() }
        .onChange(of: preferences.microphoneUID) { _, _ in microphoneCheck.stop() }
        .onChange(of: preferences.recognitionEngine) { _, engine in if engine == .parakeet { model.prepareParakeet(install: false) } }
        .sheet(isPresented: $model.isTestingFn) { FnTestView(model: model) }
    }
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink).padding(.horizontal, 2)
            VStack(alignment: .leading, spacing: 15) {
                content()
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading).card()
        }
    }
    private func settingToggle(_ title: String, subtitle: String, value: Binding<Bool>) -> some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(subtitle).font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle(title, isOn: value).toggleStyle(.switch).labelsHidden().tint(Palette.accent).controlSize(.small)
        }
    }
}

struct FnTestView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var spaceReceived = false
    @State private var monitor: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Test shortcut").font(.system(size: 21, weight: .semibold))
                    Text("Check that your keyboard sends the selected key.").font(.system(size: 12)).foregroundStyle(Palette.muted)
                }
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(.borderedProminent).tint(Palette.accent).keyboardShortcut(.defaultAction)
            }
            HStack(spacing: 16) {
                Text(model.preferences.dictationKey.keyCap).font(.system(size: 23, weight: .medium))
                    .frame(width: 60, height: 60)
                    .foregroundStyle(model.fnTestPresses > 0 ? Palette.green : Palette.ink)
                    .background(model.fnTestPresses > 0 ? Palette.green.opacity(0.08) : Palette.canvas, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(model.fnTestPresses > 0 ? Palette.green.opacity(0.25) : Palette.line, lineWidth: 1))
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.fnTestPresses > 0 ? "\(model.preferences.dictationKey.name) detected · \(model.fnTestPresses) press\(model.fnTestPresses == 1 ? "" : "es")" : "Waiting for \(model.preferences.dictationKey.name)")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Press \(model.preferences.dictationKey.name), then release it.").font(.system(size: 12)).foregroundStyle(Palette.muted)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
                .card()
            Label(spaceReceived ? "Space detected. You can now test \(model.preferences.dictationKey.name)." : "Press Space to check that this window is receiving keys.",
                  systemImage: spaceReceived ? "checkmark.circle.fill" : "keyboard")
                .font(.system(size: 12)).foregroundStyle(spaceReceived ? Palette.green : Palette.muted)
            if model.preferences.dictationKey == .fn, model.fnTestPresses == 0, let note = KeyboardInfo.fnNote(for: model.keyboardNames) {
                Text(note).font(.system(size: 12)).foregroundStyle(Palette.muted).lineSpacing(4)
            }
            Text("This test does not use the microphone or save a recording.")
                .font(.system(size: 11)).foregroundStyle(Palette.muted)
        }.padding(24).frame(width: 560).background(Palette.canvas).foregroundStyle(Palette.ink)
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
