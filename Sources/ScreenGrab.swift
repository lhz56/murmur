import AppKit
import CoreGraphics
import ScreenCaptureKit

/// Screenshot pixels → a point on the Mac's screen (AppKit coordinates, y up).
enum ScreenPoint {
    static func map(x: Double, y: Double, imageSize: CGSize, screenFrame: CGRect) -> CGPoint {
        guard imageSize.width > 0, imageSize.height > 0 else { return CGPoint(x: screenFrame.midX, y: screenFrame.midY) }
        let px = min(max(x, 0), imageSize.width), py = min(max(y, 0), imageSize.height)
        return CGPoint(x: screenFrame.minX + px * screenFrame.width / imageSize.width,
                       y: screenFrame.maxY - py * screenFrame.height / imageSize.height)
    }
}

/// A picture of the screen you're looking at, for Ask. Taken only when you ask,
/// without Murmur's floating panels, and deleted after the answer.
struct ScreenShot {
    let url: URL
    let pixelSize: CGSize
    /// The screen it shows, in AppKit coordinates.
    let screenFrame: CGRect
    var observation: ScreenClick.Observation? = nil

    func contains(_ point: AssistantReply.Point) -> Bool {
        point.x.isFinite && point.y.isFinite && point.x >= 0 && point.y >= 0
            && point.x < pixelSize.width && point.y < pixelSize.height
    }

    func point(_ point: AssistantReply.Point) -> CGPoint {
        ScreenPoint.map(x: point.x, y: point.y, imageSize: pixelSize, screenFrame: screenFrame)
    }
}

enum ScreenGrab {
    /// The longest side sent to the model. Plenty to read text; keeps answers quick.
    static let maxSide: CGFloat = 1600

    static var allowed: Bool { CGPreflightScreenCaptureAccess() }

    /// Shows the system prompt the first time; afterwards it opens System Settings.
    static func requestAccess() {
        if !CGRequestScreenCaptureAccess() {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
    }

    /// The screen the mouse is on.
    @MainActor static var currentScreen: NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    }

    @MainActor static func capture() async throws -> ScreenShot {
        try Task.checkCancellation()
        guard let screen = currentScreen,
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            throw AssistantError.failed("Couldn’t find the screen.")
        }
        let frame = screen.frame
        let observation = ScreenClick.observe()
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == number }) else {
            throw AssistantError.failed("Couldn’t find the screen.")
        }
        // Leave out Murmur's floating bubble, pill and pointer, but keep its main window:
        // you might be asking about Murmur itself.
        let pid = ProcessInfo.processInfo.processIdentifier
        let floating = content.windows.filter { $0.owningApplication?.processID == pid && $0.windowLayer != 0 }
        let filter = SCContentFilter(display: display, excludingWindows: floating)
        let configuration = SCStreamConfiguration()
        // One pixel per point, shrunk to fit `maxSide`: a 1512 × 982 screen stays 1512 × 982.
        let factor = min(1, maxSide / max(frame.width, frame.height))
        configuration.width = Int((frame.width * factor).rounded())
        configuration.height = Int((frame.height * factor).rounded())
        configuration.showsCursor = false
        configuration.capturesAudio = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        try Task.checkCancellation()
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.72]) else {
            throw AssistantError.failed("Couldn’t save the screenshot.")
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Murmur-assistant", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let file = url.appendingPathComponent("screen-\(UUID().uuidString).jpg")
        try data.write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return ScreenShot(url: file, pixelSize: CGSize(width: image.width, height: image.height), screenFrame: frame, observation: observation)
    }
}
