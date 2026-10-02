import AppKit

let output = CommandLine.arguments[1]
let image = NSImage(size: NSSize(width: 1024, height: 1024))
image.lockFocus()
NSColor(calibratedRed: 0.967, green: 0.947, blue: 0.990, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 24, y: 24, width: 976, height: 976), xRadius: 220, yRadius: 220).fill()
NSColor(calibratedRed: 0.88, green: 0.82, blue: 0.97, alpha: 0.5).setFill()
NSBezierPath(ovalIn: NSRect(x: 125, y: 122, width: 774, height: 774)).fill()
NSGraphicsContext.saveGraphicsState()
let transform = NSAffineTransform()
transform.translateX(by: 512, yBy: 512)
transform.rotate(byDegrees: 10)
transform.concat()
let shadow = NSShadow(); shadow.shadowColor = NSColor(calibratedRed: 0.32, green: 0.17, blue: 0.59, alpha: 0.24); shadow.shadowBlurRadius = 35; shadow.shadowOffset = NSSize(width: 0, height: -24); shadow.set()
let body = NSBezierPath(roundedRect: NSRect(x: -292, y: -280, width: 584, height: 560), xRadius: 185, yRadius: 185)
NSGradient(starting: NSColor(calibratedRed: 0.68, green: 0.51, blue: 0.93, alpha: 1), ending: NSColor(calibratedRed: 0.37, green: 0.22, blue: 0.67, alpha: 1))!.draw(in: body, angle: -60)
NSShadow().set()
NSColor.white.setFill()
for (i, height) in [100.0, 173, 240, 173, 100].enumerated() {
    let x = -178 + Double(i) * 76
    NSBezierPath(roundedRect: NSRect(x: x, y: -height / 2, width: 43, height: height), xRadius: 21.5, yRadius: 21.5).fill()
}
NSGraphicsContext.restoreGraphicsState()
NSColor(calibratedRed: 0.68, green: 0.83, blue: 0.72, alpha: 1).setFill()
NSBezierPath(ovalIn: NSRect(x: 115, y: 236, width: 54, height: 54)).fill()
let sparkle = NSBezierPath()
sparkle.move(to: NSPoint(x: 840, y: 853)); sparkle.curve(to: NSPoint(x: 891, y: 799), controlPoint1: NSPoint(x: 843, y: 809), controlPoint2: NSPoint(x: 850, y: 802))
sparkle.curve(to: NSPoint(x: 840, y: 745), controlPoint1: NSPoint(x: 850, y: 796), controlPoint2: NSPoint(x: 843, y: 789))
sparkle.curve(to: NSPoint(x: 789, y: 799), controlPoint1: NSPoint(x: 837, y: 789), controlPoint2: NSPoint(x: 830, y: 796))
sparkle.curve(to: NSPoint(x: 840, y: 853), controlPoint1: NSPoint(x: 830, y: 802), controlPoint2: NSPoint(x: 837, y: 809)); sparkle.close()
NSColor(calibratedRed: 0.55, green: 0.39, blue: 0.77, alpha: 0.65).setFill(); sparkle.fill()
image.unlockFocus()
let representation = NSBitmapImageRep(data: image.tiffRepresentation!)!
try representation.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
