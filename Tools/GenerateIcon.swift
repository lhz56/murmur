import AppKit

// Murmur's mark in black and white Liquid Glass: a voice waveform ending in a
// text cursor, as glossy white glass on a deep black glass tile. Drawn on
// Apple's macOS icon grid (an 824 pt squircle on a 1024 canvas).
let output = CommandLine.arguments[1]
let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

func gray(_ white: CGFloat, _ alpha: CGFloat = 1) -> NSColor { NSColor(white: white, alpha: alpha) }

let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let radius: CGFloat = 186
let squircle = NSBezierPath(roundedRect: tile, xRadius: radius, yRadius: radius)

// Drop shadow under the tile.
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = gray(0, 0.35); shadow.shadowBlurRadius = 30; shadow.shadowOffset = NSSize(width: 0, height: -14)
shadow.set()
gray(0.04).setFill(); squircle.fill()
NSGraphicsContext.restoreGraphicsState()

NSGraphicsContext.saveGraphicsState()
squircle.addClip()
// Deep black glass, slightly lit from above.
NSGradient(colors: [gray(0.20), gray(0.07), gray(0.02)], atLocations: [0, 0.5, 1], colorSpace: .deviceGray)!
    .draw(in: tile, angle: -90)
// A soft glow behind the mark, as light passing through the glass.
NSGradient(colors: [gray(1, 0.10), gray(1, 0)], atLocations: [0, 1], colorSpace: .deviceGray)!
    .draw(fromCenter: NSPoint(x: 512, y: 500), radius: 0, toCenter: NSPoint(x: 512, y: 500), radius: 380, options: [])
// Curved specular sheen across the top, like a glass lens.
let sheen = NSBezierPath()
sheen.move(to: NSPoint(x: tile.minX, y: tile.maxY))
sheen.line(to: NSPoint(x: tile.minX, y: 690))
sheen.curve(to: NSPoint(x: tile.maxX, y: 760), controlPoint1: NSPoint(x: 360, y: 610), controlPoint2: NSPoint(x: 700, y: 640))
sheen.line(to: NSPoint(x: tile.maxX, y: tile.maxY))
sheen.close()
NSGradient(colors: [gray(1, 0.16), gray(1, 0.02)], atLocations: [0, 1], colorSpace: .deviceGray)!.draw(in: sheen, angle: -90)
NSGraphicsContext.restoreGraphicsState()

// Glass rim: bright at the top edge, fading around the sides.
NSGraphicsContext.saveGraphicsState()
let rim = NSBezierPath(roundedRect: tile.insetBy(dx: 2, dy: 2), xRadius: radius - 2, yRadius: radius - 2)
rim.lineWidth = 4
rim.addClip()
NSGraphicsContext.restoreGraphicsState()
NSGraphicsContext.saveGraphicsState()
let rimPath = NSBezierPath(roundedRect: tile.insetBy(dx: 2, dy: 2), xRadius: radius - 2, yRadius: radius - 2)
rimPath.lineWidth = 4
let rimShape = CGPath.from(rimPath).copy(strokingWithWidth: 4, lineCap: .round, lineJoin: .round, miterLimit: 1)
let context = NSGraphicsContext.current!.cgContext
context.addPath(rimShape); context.clip()
NSGradient(colors: [gray(1, 0.55), gray(1, 0.10), gray(1, 0.04), gray(1, 0.18)], atLocations: [0, 0.35, 0.7, 1], colorSpace: .deviceGray)!
    .draw(in: tile, angle: -90)
NSGraphicsContext.restoreGraphicsState()

/// One liquid-glass capsule: a clear body that lets the tile's glow through,
/// a bright refracted rim (strongest along the top-left), an inner highlight,
/// and a soft caustic shadow beneath.
func glassCapsule(_ rect: NSRect) {
    let corner = rect.width / 2
    let path = NSBezierPath(roundedRect: rect, xRadius: corner, yRadius: corner)
    let ctx = NSGraphicsContext.current!.cgContext
    // Caustic: light focused through the glass onto the tile below it.
    NSGraphicsContext.saveGraphicsState()
    let lift = NSShadow()
    lift.shadowColor = gray(0, 0.6); lift.shadowBlurRadius = 26; lift.shadowOffset = NSSize(width: 0, height: -12)
    lift.set()
    gray(1, 0.10).setFill(); path.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    // Clear body: brighter at the top, darker where it bends light away.
    NSGradient(colors: [gray(1, 0.55), gray(1, 0.18), gray(1, 0.08), gray(1, 0.30)],
               atLocations: [0, 0.3, 0.75, 1], colorSpace: .deviceGray)!.draw(in: rect, angle: -90)
    // Side refraction: the edges gather light, the middle stays clear.
    NSGradient(colors: [gray(1, 0.35), gray(1, 0), gray(1, 0), gray(1, 0.22)],
               atLocations: [0, 0.3, 0.7, 1], colorSpace: .deviceGray)!.draw(in: rect, angle: 0)
    // Specular highlight near the top-left.
    let h = min(rect.height * 0.42, 170)
    let highlight = NSRect(x: rect.minX + rect.width * 0.2, y: rect.maxY - rect.width * 0.22 - h, width: rect.width * 0.26, height: h)
    NSGradient(colors: [gray(1, 1), gray(1, 0)], atLocations: [0, 1], colorSpace: .deviceGray)!
        .draw(in: NSBezierPath(roundedRect: highlight, xRadius: highlight.width / 2, yRadius: highlight.width / 2), angle: -90)
    NSGraphicsContext.restoreGraphicsState()
    // Rim light: a thin bright edge, strongest at the top.
    NSGraphicsContext.saveGraphicsState()
    let rimOutline = CGPath.from(path).copy(strokingWithWidth: 5, lineCap: .round, lineJoin: .round, miterLimit: 1)
    ctx.addPath(rimOutline); ctx.clip()
    NSGradient(colors: [gray(1, 1), gray(1, 0.55), gray(1, 0.35), gray(1, 0.85)],
               atLocations: [0, 0.35, 0.7, 1], colorSpace: .deviceGray)!.draw(in: rect.insetBy(dx: -4, dy: -4), angle: -90)
    NSGraphicsContext.restoreGraphicsState()
}

let barWidth: CGFloat = 66
let gap: CGFloat = 40
let heights: [CGFloat] = [170, 330, 470, 290]
let caretWidth: CGFloat = 36
let caretHeight: CGFloat = 520
let total = CGFloat(heights.count) * barWidth + CGFloat(heights.count) * gap + 24 + caretWidth
var x = size / 2 - total / 2
for height in heights {
    glassCapsule(NSRect(x: x, y: size / 2 - height / 2, width: barWidth, height: height))
    x += barWidth + gap
}
x += 24
glassCapsule(NSRect(x: x, y: size / 2 - caretHeight / 2, width: caretWidth, height: caretHeight))

image.unlockFocus()
let representation = NSBitmapImageRep(data: image.tiffRepresentation!)!
try representation.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))

extension CGPath {
    static func from(_ path: NSBezierPath) -> CGPath {
        let result = CGMutablePath()
        var points = [NSPoint](repeating: .zero, count: 3)
        for index in 0..<path.elementCount {
            switch path.element(at: index, associatedPoints: &points) {
            case .moveTo: result.move(to: points[0])
            case .lineTo: result.addLine(to: points[0])
            case .curveTo, .cubicCurveTo: result.addCurve(to: points[2], control1: points[0], control2: points[1])
            case .quadraticCurveTo: result.addQuadCurve(to: points[1], control: points[0])
            case .closePath: result.closeSubpath()
            @unknown default: break
            }
        }
        return result
    }
}
