import SwiftUI
import AppKit

// Renders the Ask pointer (flight, lock-on, clicks) frame by frame over a
// backdrop, for checking its motion. Run: Tools/RenderPointer.sh BACKDROP.png OUTPUT_DIR

@main struct RenderPointer {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let backdrop = NSImage(contentsOfFile: CommandLine.arguments[1])!
        let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        // Points are AppKit coordinates (y up), like the real overlay.
        func spot(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x, y: 1080 - y) }
        let overlay = PointerOverlay()
        overlay.onScreen = false

        // A script: (time, action)
        let toggle = spot(1758, 225), privacy = spot(800, 697), fileVault = spot(1290, 500), turnOn = spot(1700, 640)
        var script: [(Double, () -> Void)] = [
            (0.4, { overlay.show([(toggle, "Bluetooth")], now: 0.4, from: spot(1180, 900)) }),
            (1.55, { overlay.press(at: toggle, ok: true, now: 1.55) }),
            (3.0, { overlay.clear(now: 3.0) }),
            (3.4, { overlay.reset() }),
            (3.6, { overlay.show([(privacy, "1 · Privacy & Security")], now: 3.6, from: spot(1300, 950)) }),
            (4.9, { overlay.press(at: privacy, ok: true, now: 4.9) }),
            (5.6, { overlay.clear(now: 5.6) }),
            (5.95, { overlay.reset(); overlay.show([(fileVault, "2 · FileVault")], now: 5.95, from: privacy) }),
            (7.2, { overlay.clear(now: 7.2) }),
            (7.55, { overlay.reset(); overlay.show([(turnOn, "Turn On…")], now: 7.55, from: fileVault) }),
            (8.6, { overlay.press(at: turnOn, ok: false, now: 8.6) }),
            (10.0, { overlay.clear(now: 10.0) }),
        ]
        let fps = 60.0, duration = 10.5
        for index in 0..<Int(duration * fps) {
            let t = Double(index) / fps
            while let first = script.first, first.0 <= t { first.1(); script.removeFirst() }
            let view = ZStack(alignment: .topLeading) {
                Image(nsImage: backdrop).resizable().frame(width: 1920, height: 1080)
                PointerFrame(overlay: overlay, frame: frame, t: t)
            }
            .frame(width: 1920, height: 1080)
            .environment(\.colorScheme, .dark)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 1
            guard let image = renderer.cgImage else { continue }
            let rep = NSBitmapImageRep(cgImage: image)
            try! rep.representation(using: .png, properties: [:])!
                .write(to: output.appendingPathComponent(String(format: "f%04d.png", index)))
        }
    }
}
