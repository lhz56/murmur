import SwiftUI
import AppKit

/// Warm, quiet neutrals in the spirit of Notion, set in Apple's system type.
/// Every color follows the system appearance.
enum Palette {
    /// Primary text.
    static let ink = Color(light: 0x37352F, dark: 0xE3E2E0)
    /// Secondary text and icons.
    static let muted = Color(light: 0x787774, dark: 0x9B9A97)
    /// Placeholders and the faintest labels.
    static let faint = Color(light: 0xA9A8A4, dark: 0x5F5E5B)
    static let accent = Color(light: 0x2383E2, dark: 0x3291EF)
    /// The page and list background.
    static let canvas = Color(light: 0xFFFFFF, dark: 0x191919)
    static let sidebar = Color(light: 0xF7F7F5, dark: 0x202020)
    static let line = Color(light: 0xEDEDEC, dark: 0x2F2F2F)
    static let hover = Color(light: 0xEFEFED, dark: 0x2C2C2C)
    static let selection = Color(light: 0xEAEAE8, dark: 0x323232)
    /// Callout blocks and search fields.
    static let wash = Color(light: 0xF1F1EF, dark: 0x252525)
    static let green = Color(light: 0x448361, dark: 0x4DAB9A)
    static let red = Color(light: 0xE03E3E, dark: 0xEB5757)
    static let star = Color(light: 0xCB912F, dark: 0xCA9849)
    /// The recording pill is always dark, on any desktop.
    static let pill = Color(hex: 0x1F1F1F)
    static let pillMeter = Color(hex: 0xB7CDF5)
    static let pillSuccess = Color(hex: 0x7FC4A6)
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

/// A thin rule between regions.
struct Hairline: View {
    var vertical = false
    var body: some View {
        Rectangle().fill(Palette.line).frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
    }
}

/// Filled accent button for the one primary action in a region.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 12).frame(height: 30)
            .background(Palette.accent.opacity(configuration.isPressed ? 0.85 : 1), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .opacity(isEnabled ? 1 : 0.45)
    }
}

/// Text button that shows a soft fill only on hover, like Notion's toolbar.
struct QuietButtonStyle: ButtonStyle {
    var tint: Color = Palette.muted
    func makeBody(configuration: Configuration) -> some View {
        QuietButtonBody(configuration: configuration, tint: tint)
    }
    private struct QuietButtonBody: View {
        let configuration: Configuration
        let tint: Color
        @State private var hovered = false
        @Environment(\.isEnabled) private var isEnabled
        var body: some View {
            configuration.label.font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(hovered && isEnabled ? Palette.ink : tint)
                .padding(.horizontal, 8).frame(minHeight: 26)
                .background(configuration.isPressed ? Palette.selection : hovered && isEnabled ? Palette.hover : .clear,
                            in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .contentShape(Rectangle())
                .opacity(isEnabled ? 1 : 0.4)
                .onHover { hovered = $0 }
        }
    }
}

struct IconButton: View {
    var symbol: String
    var help: String
    var tint: Color = Palette.muted
    var action: () -> Void
    @State private var hovered = false
    @Environment(\.isEnabled) private var isEnabled
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13.5))
                .foregroundStyle(hovered && isEnabled ? Palette.ink : tint)
                .frame(width: 28, height: 28)
                .background(hovered && isEnabled ? Palette.hover : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).opacity(isEnabled ? 1 : 0.35)
            .help(help).accessibilityLabel(help).onHover { hovered = $0 }
    }
}

/// Small keyboard keycaps, e.g. ⌃ ⌥ Space.
struct ShortcutKeys: View {
    var keys: [String] = ["⌃", "⌥", "Space"]
    var light = false
    var body: some View {
        HStack(spacing: 3) {
            ForEach(keys, id: \.self) { key in
                Text(key).font(.system(size: key.count > 1 ? 10 : 11, weight: .medium))
                    .padding(.horizontal, key.count > 1 ? 6 : 0).frame(minWidth: 20, minHeight: 20)
                    .background(light ? Color.white.opacity(0.10) : Palette.canvas, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(light ? Color.white.opacity(0.14) : Palette.line, lineWidth: 1))
            }
        }.foregroundStyle(light ? Color.white.opacity(0.85) : Palette.muted)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(keys.map { ["⌃": "Control", "⌥": "Option", "⌘": "Command"][$0] ?? $0 }.joined(separator: " "))
    }
}

/// Murmur's mark, matching the app icon: a white glass waveform ending in a
/// text cursor, on a black glass tile.
struct WaveMark: View {
    var size: CGFloat = 32
    var body: some View {
        HStack(spacing: size * 0.05) {
            ForEach(0..<4) { index in
                Capsule().fill(LinearGradient(colors: [.white, Color(white: 0.78)], startPoint: .top, endPoint: .bottom))
                    .frame(width: size * 0.078, height: size * [0.21, 0.40, 0.57, 0.35][index])
            }
            Capsule().fill(Color.white).frame(width: size * 0.042, height: size * 0.63).padding(.leading, size * 0.03)
        }.frame(width: size, height: size)
            .background(LinearGradient(colors: [Color(white: 0.22), Color(white: 0.03)], startPoint: .top, endPoint: .bottom),
                        in: RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .strokeBorder(LinearGradient(colors: [.white.opacity(0.45), .white.opacity(0.06)], startPoint: .top, endPoint: .bottom),
                              lineWidth: max(0.5, size * 0.02)))
            .accessibilityHidden(true)
    }
}

/// Menu bar glyph: the same waveform-and-cursor mark as a template image.
enum MenuBarGlyph {
    static func image(recording: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setFill()
            if recording {
                NSBezierPath(roundedRect: NSRect(x: 0.5, y: 0.5, width: 17, height: 17), xRadius: 5, yRadius: 5).fill()
                NSGraphicsContext.current?.compositingOperation = .destinationOut
            }
            var x: CGFloat = 2.5
            for height: CGFloat in [4, 8, 11, 7] {
                NSBezierPath(roundedRect: NSRect(x: x, y: 9 - height / 2, width: 2, height: height), xRadius: 1, yRadius: 1).fill()
                x += 3
            }
            NSBezierPath(roundedRect: NSRect(x: x + 0.5, y: 2.5, width: 1.5, height: 13), xRadius: 0.75, yRadius: 0.75).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Murmur"
        return image
    }
}

/// A Notion-style callout: a tinted block with an icon and content.
struct Callout<Content: View>: View {
    let symbol: String
    var tint: Color = Palette.muted
    var background: Color = Palette.wash
    @ViewBuilder let content: Content
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 8) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
        }.font(.system(size: 13)).padding(.horizontal, 14).padding(.vertical, 12)
            .background(background, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
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
