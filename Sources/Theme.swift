import SwiftUI
import AppKit

/// Semantic colors that follow the system appearance.
enum Palette {
    static let ink = Color(light: 0x20242B, dark: 0xECEDEF)
    static let muted = Color(light: 0x6B727B, dark: 0x9BA0A8)
    static let accent = Color(light: 0x3766CC, dark: 0x4C7EE0)
    static let lilac = Color(light: 0xEDF2FC, dark: 0x1F2A40)
    static let canvas = Color(light: 0xFAFAFB, dark: 0x1B1C1F)
    static let surface = Color(light: 0xFFFFFF, dark: 0x242529)
    static let sidebar = Color(light: 0xF0F1F3, dark: 0x161719)
    static let line = Color(light: 0xE2E5E9, dark: 0x34363B)
    static let green = Color(light: 0x397859, dark: 0x6FC096)
    static let star = Color(light: 0xB58B3B, dark: 0xE0B65C)
    /// The recording pill is always dark, on any desktop.
    static let pill = Color(hex: 0x17191D)
    static let pillMeter = Color(hex: 0xAFC4F5)
    static let pillSuccess = Color(hex: 0x96C8AA)
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
                  blue: CGFloat(hex & 255) / 255, alpha: 1)
    }
    static func adaptive(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(hex: dark) : NSColor(hex: light)
        }
    }
}

extension Color {
    init(hex: UInt32) { self.init(nsColor: NSColor(hex: hex)) }
    init(light: UInt32, dark: UInt32) { self.init(nsColor: .adaptive(light: light, dark: dark)) }
}

extension Notification.Name {
    static let murmurSearch = Notification.Name("app.murmur.search")
}

/// A bordered card used for every panel in the library and settings.
struct CardBackground: ViewModifier {
    var radius: CGFloat = 10
    var stroke: Color = Palette.line
    func body(content: Content) -> some View {
        content
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(stroke, lineWidth: 1))
    }
}

extension View {
    func card(radius: CGFloat = 10, stroke: Color = Palette.line) -> some View {
        modifier(CardBackground(radius: radius, stroke: stroke))
    }
}

struct CapsuleButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .medium))
            .foregroundStyle(prominent ? Color.white : Palette.ink)
            .padding(.horizontal, 14).frame(height: 34)
            .background(prominent ? Palette.accent : Palette.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(prominent ? Color.clear : Palette.line, lineWidth: 1))
            .opacity(isEnabled ? (configuration.isPressed ? 0.78 : 1) : 0.45)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct SmallIconButton: View {
    var symbol: String
    var help: String
    var action: () -> Void
    @State private var hovered = false
    @Environment(\.isEnabled) private var isEnabled
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13))
                .foregroundStyle(hovered && isEnabled ? Palette.ink : Palette.muted)
                .frame(width: 30, height: 30)
                .background(hovered && isEnabled ? Palette.line.opacity(0.6) : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).opacity(isEnabled ? 1 : 0.4)
            .help(help).accessibilityLabel(help).onHover { hovered = $0 }
    }
}

struct ShortcutKeys: View {
    var keys: [String] = ["⌃", "⌥", "space"]
    var light = false
    var body: some View {
        HStack(spacing: 3) {
            ForEach(keys, id: \.self) { key in
                Text(key).font(.system(size: key.count > 1 ? 10 : 12, weight: .medium))
                    .padding(.horizontal, key.count > 1 ? 7 : 6).frame(minWidth: 23, minHeight: 23)
                    .background(light ? Color.white.opacity(0.10) : Palette.surface, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(light ? Color.white.opacity(0.12) : Palette.line, lineWidth: 1))
                    .shadow(color: .black.opacity(light ? 0 : 0.04), radius: 0, y: 1)
            }
        }.foregroundStyle(light ? Color.white.opacity(0.85) : Palette.muted)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(keys.map { ["⌃": "Control", "⌥": "Option", "⌘": "Command"][$0] ?? $0 }.joined(separator: " "))
    }
}

struct WaveMark: View {
    var size: CGFloat = 32
    var body: some View {
        HStack(spacing: size * 0.075) {
            ForEach(0..<5) { index in
                Capsule().fill(Palette.canvas).frame(width: size * 0.075, height: size * [0.22, 0.42, 0.60, 0.42, 0.22][index])
            }
        }.frame(width: size, height: size)
            .background(Palette.ink, in: RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// A scrolling level history: each bar is a recent microphone level, so the
/// waveform reacts to your actual voice instead of a canned animation.
struct LiveWaveform: View {
    let level: Float
    var bars = 9
    var color: Color = Palette.accent
    var maxHeight: CGFloat = 22
    @State private var history: [CGFloat] = []

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(0..<bars, id: \.self) { index in
                Capsule().fill(color.opacity(0.9))
                    .frame(width: 2.5, height: height(at: index))
            }
        }
        .frame(height: maxHeight)
        .animation(.easeOut(duration: 0.12), value: history)
        .onAppear { history = Array(repeating: 0, count: bars) }
        .onChange(of: level) { _, value in
            var next = history.isEmpty ? Array(repeating: 0, count: bars) : history
            next.removeFirst(); next.append(CGFloat(value))
            history = next
        }
        .accessibilityHidden(true)
    }

    private func height(at index: Int) -> CGFloat {
        guard history.indices.contains(index) else { return 3 }
        // Emphasize the center so the shape reads as a voice, not a bar chart.
        let center = Double(bars - 1) / 2
        let taper = 1 - 0.45 * abs(Double(index) - center) / max(center, 1)
        return max(3, history[index] * maxHeight * CGFloat(taper))
    }
}
