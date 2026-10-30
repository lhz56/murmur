import AppKit
import SwiftUI

/// A floating panel that can take typing without bringing Murmur's window forward.
final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    var onEscape: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

/// Space + Down Arrow: the command palette.
struct CommandPaletteView: View {
    @ObservedObject var center: CommandCenter
    @ObservedObject var speech: DictationEngine
    @FocusState private var focused: Bool
    @State private var appeared = false

    private var listening: Bool { center.phase == .listening }

    var body: some View {
        VStack(spacing: 0) {
            inputRow
            if showsBody {
                Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
                content.frame(maxWidth: .infinity, alignment: .topLeading)
                    .transition(.opacity)
                footer
            }
        }
        .frame(width: 660)
        .background(PaletteGlass())
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.14), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 30, y: 14)
        .scaleEffect(appeared ? 1 : 0.97).opacity(appeared ? 1 : 0)
        .padding(30)
        .environment(\.colorScheme, .dark)
        .animation(.spring(response: 0.26, dampingFraction: 0.86), value: center.phase)
        .animation(.spring(response: 0.24, dampingFraction: 0.9), value: center.rows.count)
        .onAppear {
            focused = true
            withAnimation(.spring(response: 0.22, dampingFraction: 0.86)) { appeared = true }
        }
        .onDisappear { appeared = false }
        .onReceive(NotificationCenter.default.publisher(for: .murmurPaletteFocus)) { _ in focused = true }
    }

    private var showsBody: Bool { true }

    // MARK: Input

    private var inputRow: some View {
        HStack(spacing: 14) {
            ZStack {
                if listening {
                    Circle().fill(Color.red.opacity(0.2)).frame(width: 34, height: 34)
                    Image(systemName: "waveform").font(.system(size: 15, weight: .semibold)).foregroundStyle(Color(hex: 0xFF8A80))
                        .symbolEffect(.variableColor.iterative, isActive: true)
                } else if center.phase == .thinking || center.phase == .running {
                    ProgressView().controlSize(.small).tint(.white)
                } else {
                    Image(systemName: "command").font(.system(size: 16, weight: .medium)).foregroundStyle(.white.opacity(0.55))
                }
            }.frame(width: 34, height: 34)
            if listening {
                Text(speech.liveText.isEmpty ? "Listening…" : speech.liveText)
                    .font(.system(size: 20, weight: .regular)).foregroundStyle(speech.liveText.isEmpty ? .white.opacity(0.4) : .white)
                    .lineLimit(1).truncationMode(.head).frame(maxWidth: .infinity, alignment: .leading)
                LiveWaveform(level: speech.level, bars: 12, color: Color(hex: 0xFF8A80), maxHeight: 26)
            } else {
                TextField("", text: $center.query, prompt: Text(center.liveText.isEmpty ? "Open, play, search, or ask…" : center.liveText)
                    .foregroundStyle(.white.opacity(0.35)))
                    .textFieldStyle(.plain).font(.system(size: 20)).foregroundStyle(.white)
                    .focused($focused)
                    .onSubmit { center.submit() }
                    .onKeyPress(.downArrow) { center.move(1); return .handled }
                    .onKeyPress(.upArrow) { center.move(-1); return .handled }
                    .onKeyPress(.tab) { center.move(1); return .handled }
                    .onKeyPress(characters: .decimalDigits, phases: .down) { press in
                        // ⌘1–⌘9 runs that row.
                        guard press.modifiers.contains(.command), let digit = Int(press.characters), digit >= 1 else { return .ignored }
                        let rows = center.rows
                        guard digit <= min(rows.count, 9) else { return .ignored }
                        center.selection = digit - 1
                        center.submit()
                        return .handled
                    }
                if let selection = center.selectionPreview, center.query.isEmpty {
                    Label(selection, systemImage: "text.cursor").labelStyle(.titleAndIcon).lineLimit(1)
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.6))
                        .padding(.horizontal, 8).frame(height: 22).frame(maxWidth: 170)
                        .background(.white.opacity(0.08), in: Capsule())
                        .help("“this” means: \(selection)")
                }
            }
            Button { listening ? center.endListening() : center.beginListening() } label: {
                Image(systemName: listening ? "stop.fill" : "mic.fill")
                    .font(.system(size: listening ? 11 : 13, weight: .semibold))
                    .foregroundStyle(listening ? .white : .white.opacity(0.75))
                    .frame(width: 32, height: 32)
                    .background(listening ? Color.red.opacity(0.75) : .white.opacity(0.1), in: Circle())
            }.buttonStyle(.plain).help(listening ? "Run what you said" : "Speak a command (or hold Space + ↓)")
                .accessibilityLabel(listening ? "Stop listening" : "Speak a command")
        }.padding(.horizontal, 18).frame(height: 66)
    }

    // MARK: Body

    @ViewBuilder private var content: some View {
        switch center.phase {
        case .listening:
            // As you speak, show what will happen, so letting go feels instant.
            if let preview = CommandParser.best(for: speech.liveText, context: center.voiceContext), CommandParser.isTrivial(preview, for: speech.liveText) {
                VStack(spacing: 2) {
                    PaletteRow(suggestion: preview, selected: true, index: 0) {}
                        .allowsHitTesting(false)
                    Text("Let go to run").font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
                        .frame(maxWidth: .infinity, alignment: .trailing).padding(.trailing, 12).padding(.bottom, 2)
                }.padding(8).transition(.opacity)
            } else {
                statusLine(symbol: "ear", text: "Say something like “open Spotify and play Drake”", detail: "Let go to run")
            }
        case .thinking:
            statusLine(symbol: "sparkles", text: center.liveText.isEmpty ? "Working it out…" : "“\(center.liveText)”", detail: "Working it out…")
        case .done(let message):
            statusLine(symbol: "checkmark.circle.fill", text: message, detail: nil, tint: Palette.pillSuccess)
        case .failed(let message):
            statusLine(symbol: "exclamationmark.circle.fill", text: message, detail: "Try saying it another way, or type it", tint: .orange)
        case .idle, .running:
            if let pending = center.pendingConfirmation {
                statusLine(symbol: "exclamationmark.triangle.fill", text: "\(pending.title)?", detail: "This can’t be undone. Press ↩ again to confirm, or Esc.", tint: .orange)
            } else if center.query.isEmpty && center.choices.isEmpty {
                home
            } else {
                results
            }
        }
    }

    private func statusLine(symbol: String, text: String, detail: String?, tint: Color = .white.opacity(0.7)) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(text).font(.system(size: 14, weight: .medium)).foregroundStyle(.white).lineLimit(2)
                if let detail { Text(detail).font(.system(size: 12)).foregroundStyle(.white.opacity(0.5)) }
            }
            Spacer(minLength: 0)
        }.padding(.horizontal, 22).padding(.vertical, 18)
    }

    private var results: some View {
        let rows = Array(center.rows.prefix(8))
        return VStack(spacing: 2) {
            if let prompt = center.choicePrompt, !center.choices.isEmpty {
                Text(prompt).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.55))
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.top, 4).padding(.bottom, 2)
            }
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                PaletteRow(suggestion: row, selected: index == center.selection, index: index) { center.choose(row) }
                    .onHover { if $0 { center.selection = index } }
            }
        }.padding(8)
    }

    private var home: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !center.timers.isEmpty {
                section("Timers") {
                    ForEach(center.timers) { timer in TimerRow(timer: timer) { center.cancelTimer(timer.id) } }
                }
            }
            if !center.history.isEmpty {
                section("Recent") {
                    ForEach(center.history.prefix(4)) { record in
                        Button { center.query = record.text; center.submit() } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "clock.arrow.circlepath").font(.system(size: 12)).foregroundStyle(.white.opacity(0.4)).frame(width: 22)
                                Text(record.text).font(.system(size: 13.5)).foregroundStyle(.white.opacity(0.88)).lineLimit(1)
                                Spacer()
                                Text(record.title).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.38)).lineLimit(1)
                            }.padding(.horizontal, 10).frame(height: 32).contentShape(Rectangle())
                        }.buttonStyle(HoverRowStyle())
                    }
                }
            }
            section("Try") {
                let examples = ["Open Spotify and play Drake", "Play lofi beats on YouTube", "Take meeting notes", "Timer 25 minutes",
                                "Open murmur in Cursor", "Ask ChatGPT for a dinner idea", "Search Reddit for standing desks", "Volume 40"]
                FlowLayout(spacing: 6) {
                    ForEach(examples, id: \.self) { example in
                        Button { center.query = example } label: {
                            Text(example).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.78))
                                .padding(.horizontal, 10).frame(height: 26)
                                .background(.white.opacity(0.08), in: Capsule())
                        }.buttonStyle(.plain)
                    }
                }.padding(.horizontal, 10)
            }
        }.padding(.horizontal, 8).padding(.vertical, 14)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased()).font(.system(size: 10.5, weight: .semibold)).tracking(0.6).foregroundStyle(.white.opacity(0.38))
                .padding(.horizontal, 10)
            content()
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            HStack(spacing: 6) {
                ShortcutKeys(keys: ["Space", "↓"], light: true)
                Text("hold to talk").foregroundStyle(.white.opacity(0.45))
            }
            Spacer()
            footerHint("↑↓", "move")
            footerHint("↩", center.pendingConfirmation != nil ? "confirm" : "run")
            footerHint("esc", "close")
        }.font(.system(size: 11)).padding(.horizontal, 18).frame(height: 38)
            .background(.white.opacity(0.035))
    }

    private func footerHint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Text(key).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.white.opacity(0.65))
            Text(label).foregroundStyle(.white.opacity(0.42))
        }
    }
}

/// The palette's frosted, tinted glass.
struct PaletteGlass: View {
    var body: some View {
        ZStack {
            VisualEffect(material: .hudWindow)
            LinearGradient(colors: [Color(white: 0.13).opacity(0.78), Color(white: 0.07).opacity(0.86)], startPoint: .top, endPoint: .bottom)
        }
    }
}

struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material; view.blendingMode = .behindWindow; view.state = .active
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) { view.material = material }
}

struct PaletteRow: View {
    let suggestion: CommandSuggestion
    let selected: Bool
    let index: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                SuggestionIcon(icon: suggestion.icon, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(suggestion.title).font(.system(size: 14, weight: .medium)).foregroundStyle(.white).lineLimit(1)
                    Text(suggestion.subtitle).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
                }
                Spacer(minLength: 8)
                if selected {
                    Text("↩").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
                        .frame(width: 24, height: 20).background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 5))
                } else if index < 9 {
                    Text("⌘\(index + 1)").font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.28))
                }
            }.padding(.horizontal, 10).frame(height: 48)
                .background(selected ? Color.white.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

struct SuggestionIcon: View {
    let icon: CommandSuggestion.Icon
    var size: CGFloat = 30

    var body: some View {
        switch icon {
        case .app(let path):
            Image(nsImage: Self.icon(path)).resizable().interpolation(.high).frame(width: size, height: size)
        case .symbol(let name, let tint):
            Image(systemName: name).font(.system(size: size * 0.44, weight: .semibold)).foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(LinearGradient(colors: [color(tint).opacity(0.95), color(tint).opacity(0.7)], startPoint: .top, endPoint: .bottom),
                            in: RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
        }
    }

    /// Icons are looked up once; the palette redraws on every keystroke.
    private static let icons = NSCache<NSString, NSImage>()
    static func icon(_ path: String) -> NSImage {
        if let cached = icons.object(forKey: path as NSString) { return cached }
        let image = NSWorkspace.shared.icon(forFile: path)
        icons.setObject(image, forKey: path as NSString)
        return image
    }

    private func color(_ tint: CommandSuggestion.Icon.Tint) -> Color {
        switch tint {
        case .neutral: return Color(white: 0.38)
        case .blue: return Color(hex: 0x3B82F6)
        case .red: return Color(hex: 0xEF4444)
        case .green: return Color(hex: 0x1DB954)
        case .orange: return Color(hex: 0xF59E0B)
        case .purple: return Color(hex: 0x8B5CF6)
        case .pink: return Color(hex: 0xEC4899)
        }
    }
}

struct TimerRow: View {
    let timer: CommandCenter.RunningTimer
    let cancel: () -> Void
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let left = max(0, Int(timer.ends.timeIntervalSince(context.date)))
            HStack(spacing: 10) {
                Image(systemName: "timer").font(.system(size: 12, weight: .semibold)).foregroundStyle(.orange).frame(width: 22)
                Text(timer.label).font(.system(size: 13.5)).foregroundStyle(.white.opacity(0.88))
                Spacer()
                Text(String(format: "%d:%02d", left / 60, left % 60)).font(.system(size: 13, weight: .medium)).monospacedDigit().foregroundStyle(.white)
                Button(action: cancel) { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(0.5)) }
                    .buttonStyle(.plain).help("Cancel timer")
            }.padding(.horizontal, 10).frame(height: 32)
        }
    }
}

struct HoverRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { HoverRowBody(configuration: configuration) }
    private struct HoverRowBody: View {
        let configuration: Configuration
        @State private var hovered = false
        var body: some View {
            configuration.label
                .background(hovered || configuration.isPressed ? Color.white.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .onHover { hovered = $0 }
        }
    }
}

extension Notification.Name {
    static let murmurPaletteFocus = Notification.Name("app.murmur.palette.focus")
}
