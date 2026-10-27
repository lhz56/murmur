import SwiftUI
import AppKit
import AVFoundation

/// First-run welcome: what Murmur does, the two permissions it needs, a live
/// try-it step, and login. Every step can be skipped.
struct OnboardingView: View {
    enum Step: Int, CaseIterable { case welcome, permissions, tryIt, finish }

    @ObservedObject var model: AppModel
    @ObservedObject var preferences: Preferences
    @ObservedObject var speech: DictationEngine
    @StateObject private var login = LaunchAtLogin()
    @State private var step = Step.welcome
    @State private var microphone = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var tryStartedAt = Date()
    init(model: AppModel, preferences: Preferences, speech: DictationEngine, step: Step = .welcome) {
        self.model = model; self.preferences = preferences; self.speech = speech
        _step = State(initialValue: step)
    }

    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var keyName: String { preferences.dictationKey.name }
    private var holds: Bool { preferences.fnBehavior == .hold }
    private var latest: Transcript? {
        model.transcripts.first { $0.createdAt >= tryStartedAt && $0.status == .complete && !$0.text.isEmpty }
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case .welcome: welcome
                case .permissions: permissions
                case .tryIt: tryIt
                case .finish: finish
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 40).padding(.top, 40)
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
            .id(step)
            Hairline()
            HStack {
                HStack(spacing: 6) {
                    ForEach(Step.allCases, id: \.self) { item in
                        Capsule().fill(item == step ? Palette.ink : Palette.line)
                            .frame(width: item == step ? 16 : 6, height: 6)
                    }
                }.animation(.spring(response: 0.3, dampingFraction: 0.85), value: step)
                Spacer()
                if step != .welcome {
                    Button("Back") { go(-1) }.buttonStyle(QuietButtonStyle())
                }
                Button(primaryTitle) { step == .finish ? done() : go(1) }
                    .buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
            }.padding(.horizontal, 24).frame(height: 60)
        }
        .frame(width: 560, height: 470)
        .background(Palette.canvas)
        .foregroundStyle(Palette.ink)
        .tint(Palette.accent)
        .interactiveDismissDisabled()
        .onReceive(poll) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }

    private var primaryTitle: String {
        switch step {
        case .welcome: return "Get started"
        case .permissions: return model.accessibilityEnabled && microphone == .authorized ? "Continue" : "Continue anyway"
        case .tryIt: return latest == nil ? "Skip for now" : "Continue"
        case .finish: return "Start using Murmur"
        }
    }

    private func go(_ delta: Int) {
        guard let next = Step(rawValue: step.rawValue + delta) else { return }
        if next == .tryIt { tryStartedAt = Date() }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) { step = next }
    }

    private func done() {
        preferences.onboarded = true
        model.showOnboarding = false
    }

    private func refresh() {
        microphone = AVCaptureDevice.authorizationStatus(for: .audio)
        if model.accessibilityEnabled != AXIsProcessTrusted() { model.refreshPermissions() }
        login.refresh()
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 22) {
            WaveMark(size: 56)
            VStack(alignment: .leading, spacing: 8) {
                Text("Talk, and it types.").font(.system(size: 28, weight: .semibold)).tracking(-0.6)
                Text("Murmur turns your voice into text in any app on your Mac.")
                    .font(.system(size: 14)).foregroundStyle(Palette.muted)
            }
            VStack(alignment: .leading, spacing: 14) {
                feature("keyboard", "Hold a key, speak, let go", "Your words appear wherever you were typing.")
                feature("lock.shield", "Private by design", "Speech is recognized on this Mac. Nothing is uploaded.")
                feature("books.vertical", "Everything is kept", "Every recording is saved to a searchable library.")
            }.padding(.top, 4)
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 20) {
            header("Two quick permissions", "macOS asks you to allow these once.")
            VStack(spacing: 0) {
                permissionRow(symbol: "mic", title: "Microphone", detail: "So Murmur can hear you.",
                              granted: microphone == .authorized) {
                    if microphone == .notDetermined {
                        Task { _ = await AVCaptureDevice.requestAccess(for: .audio); refresh() }
                    } else {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                    }
                }
                Hairline().padding(.leading, 52)
                permissionRow(symbol: "accessibility", title: "Accessibility",
                              detail: "So the \(keyName) key works in every app and text lands where you type.",
                              granted: model.accessibilityEnabled) { model.requestAccessibility() }
            }
            .background(Palette.sidebar, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.line))
            if !model.accessibilityEnabled {
                Text("After you switch Murmur on in System Settings, come back here. This screen updates by itself.")
                    .font(.system(size: 12)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var tryIt: some View {
        VStack(alignment: .leading, spacing: 20) {
            header("Try it", holds ? "Hold \(keyName), say a sentence, then let go." : "Tap \(keyName), say a sentence, then tap it again.")
            HStack(spacing: 12) {
                Text("Dictation key").font(.system(size: 13)).foregroundStyle(Palette.muted)
                Picker("", selection: $preferences.dictationKey) {
                    ForEach(DictationKey.allCases, id: \.self) { key in Text(key.name).tag(key) }
                }.labelsHidden().fixedSize()
            }
            VStack(alignment: .leading, spacing: 10) {
                if let latest {
                    Label("It works", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.green)
                    Text(latest.text).font(.system(size: 15)).lineSpacing(3).lineLimit(5)
                } else {
                    HStack(spacing: 10) {
                        if speech.phase == .recording {
                            LiveWaveform(level: speech.level, color: Palette.accent, maxHeight: 18)
                            Text("Listening…").foregroundStyle(Palette.muted)
                        } else if speech.phase.isBusy {
                            ProgressView().controlSize(.small)
                            Text("Transcribing…").foregroundStyle(Palette.muted)
                        } else {
                            ShortcutKeys(keys: [preferences.dictationKey.keyCap])
                            Text(holds ? "Hold the key and speak" : "Tap the key and speak").foregroundStyle(Palette.muted)
                        }
                    }.font(.system(size: 13))
                }
            }
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
            .padding(18)
            .background(Palette.wash, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            Text("In other apps the text is typed in for you. Here it simply shows up above.")
                .font(.system(size: 12)).foregroundStyle(Palette.faint)
        }
    }

    private var finish: some View {
        VStack(alignment: .leading, spacing: 20) {
            header("You’re set", "Murmur lives in your menu bar. Close this window any time.")
            VStack(spacing: 0) {
                shortcutRow(holds ? "Dictate (hold)" : "Dictate (tap)", [preferences.dictationKey.keyCap])
                Hairline()
                shortcutRow("Hands-free start / finish", ["⌃", "⌥", "Space"])
                Hairline()
                shortcutRow("Paste last transcript", ["⌃", "⌥", "V"])
                Hairline()
                shortcutRow("Cancel", ["Esc"])
            }
            .background(Palette.sidebar, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.line))
            Toggle(isOn: Binding(get: { login.isEnabled }, set: { login.set($0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Open at login").font(.system(size: 13, weight: .medium))
                    Text("Start quietly in the menu bar, so the shortcut always works.")
                        .font(.system(size: 12)).foregroundStyle(Palette.muted)
                }
            }.toggleStyle(.switch)
        }
    }

    // MARK: Pieces

    private func header(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 24, weight: .semibold)).tracking(-0.5)
            Text(subtitle).font(.system(size: 14)).foregroundStyle(Palette.muted)
        }
    }

    private func feature(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol).font(.system(size: 15)).foregroundStyle(Palette.muted)
                .frame(width: 32, height: 32).background(Palette.wash, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13.5, weight: .medium))
                Text(detail).font(.system(size: 12.5)).foregroundStyle(Palette.muted)
            }
        }
    }

    private func permissionRow(symbol: String, title: String, detail: String, granted: Bool, allow: @escaping () -> Void) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 15)).foregroundStyle(Palette.muted).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13.5, weight: .medium))
                Text(detail).font(.system(size: 12)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if granted {
                Label("Allowed", systemImage: "checkmark.circle.fill").labelStyle(.titleAndIcon)
                    .font(.system(size: 12.5, weight: .medium)).foregroundStyle(Palette.green)
            } else {
                Button("Allow…", action: allow).buttonStyle(PrimaryButtonStyle())
            }
        }.padding(.horizontal, 14).padding(.vertical, 14)
    }

    private func shortcutRow(_ title: String, _ keys: [String]) -> some View {
        HStack {
            Text(title).font(.system(size: 13))
            Spacer()
            ShortcutKeys(keys: keys)
        }.padding(.horizontal, 14).frame(height: 40)
    }
}
