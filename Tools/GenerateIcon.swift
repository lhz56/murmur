import AppKit

// Murmur's mark: a voice waveform that ends in a text cursor — speech becoming
// text. Drawn on Apple's macOS icon grid (an 824 pt squircle on a 1024 canvas).
let output = CommandLine.arguments[1]
let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let context = NSGraphicsContext.current!.cgContext

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: alpha)
}

let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let squircle = NSBezierPath(roundedRect: tile, xRadius: 186, yRadius: 186)

// Soft drop shadow, as on system icons.
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
shadow.shadowBlurRadius = 28
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.set()
color(0x1C1C1E).setFill()
squircle.fill()
NSGraphicsContext.restoreGraphicsState()

// Graphite body, lit softly from above.
NSGraphicsContext.saveGraphicsState()
squircle.addClip()
NSGradient(colors: [color(0x3A3A3D), color(0x232325), color(0x18181A)], atLocations: [0, 0.55, 1], colorSpace: .sRGB)!
    .draw(in: tile, angle: -90)
NSGradient(starting: color(0xFFFFFF, 0.10), ending: color(0xFFFFFF, 0))!
    .draw(in: NSRect(x: tile.minX, y: tile.midY + 120, width: tile.width, height: tile.height / 2 - 120), angle: -90)
NSGraphicsContext.restoreGraphicsState()

// Hairline rim so the tile holds its edge on dark wallpapers.
color(0xFFFFFF, 0.10).setStroke()
let rim = NSBezierPath(roundedRect: tile.insetBy(dx: 1.5, dy: 1.5), xRadius: 184.5, yRadius: 184.5)
rim.lineWidth = 3
rim.stroke()

// Waveform bars in warm white, then the blue caret.
let barWidth: CGFloat = 64
let gap: CGFloat = 42
let heights: [CGFloat] = [170, 330, 470, 290]
let caretWidth: CGFloat = 34
let caretHeight: CGFloat = 520
let total = CGFloat(heights.count) * barWidth + CGFloat(heights.count) * gap + 26 + caretWidth
var x = size / 2 - total / 2
for height in heights {
    let bar = NSRect(x: x, y: size / 2 - height / 2, width: barWidth, height: height)
    NSGradient(starting: color(0xFFFFFF), ending: color(0xE9E7E2))!
        .draw(in: NSBezierPath(roundedRect: bar, xRadius: barWidth / 2, yRadius: barWidth / 2), angle: -90)
    x += barWidth + gap
}
x += 26
let caret = NSRect(x: x, y: size / 2 - caretHeight / 2, width: caretWidth, height: caretHeight)
NSGraphicsContext.saveGraphicsState()
let glow = NSShadow()
glow.shadowColor = color(0x3291EF, 0.55)
glow.shadowBlurRadius = 36
glow.set()
NSGradient(starting: color(0x5AA9F5), ending: color(0x2383E2))!
    .draw(in: NSBezierPath(roundedRect: caret, xRadius: caretWidth / 2, yRadius: caretWidth / 2), angle: -90)
NSGraphicsContext.restoreGraphicsState()
_ = context

image.unlockFocus()
let representation = NSBitmapImageRep(data: image.tiffRepresentation!)!
try representation.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
