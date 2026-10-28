import SwiftUI
import AppKit

// Renders docs/demo.gif frames: a staged dictation using Murmur's real
// recording pill (RecorderHUD) over a mock Notes window. Run Tools/RenderDemo.sh.

@MainActor final class DemoState: ObservableObject {
    @Published var keyDown = false
    @Published var noteText = ""
    @Published var cursorOn = true
    @Published var caption = "Hold Control and talk"
}

struct DemoScene: View {
    @ObservedObject var model: AppModel
    @ObservedObject var speech: DictationEngine
    @ObservedObject var demo: DemoState

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.93), Color(white: 0.86)], startPoint: .top, endPoint: .bottom)
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    ForEach([Color(red: 1, green: 0.37, blue: 0.34), Color(red: 1, green: 0.74, blue: 0.18), Color(red: 0.16, green: 0.79, blue: 0.25)], id: \.self) {
                        Circle().fill($0).frame(width: 12, height: 12)
                    }
                    Spacer()
                    Text("Launch notes").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color(white: 0.3))
                    Spacer()
                    Color.clear.frame(width: 52, height: 1)
                }.padding(.horizontal, 16).frame(height: 44)
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    Text("Recallr launch").font(.system(size: 24, weight: .bold))
                    Text("• Final review with Nkechi on Thursday").font(.system(size: 16))
                    Text("• Recallr deck: pricing slide still open").font(.system(size: 16))
                    Text("\(demo.noteText)\(Text(demo.cursorOn ? "|" : " ").font(.system(size: 17, weight: .light)).foregroundStyle(Color(red: 0.95, green: 0.7, blue: 0.1)))")
                        .font(.system(size: 16)).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }.foregroundStyle(Color(white: 0.12)).padding(.horizontal, 28).padding(.top, 22)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: 620, height: 300)
            .background(.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color(white: 0.8)))
            .shadow(color: .black.opacity(0.14), radius: 22, y: 10)
            .offset(y: -22)

            VStack {
                HStack(spacing: 10) {
                    Text("⌃ control").font(.system(size: 13, weight: .medium)).foregroundStyle(Color(white: demo.keyDown ? 1 : 0.25))
                        .padding(.horizontal, 12).frame(height: 30)
                        .background(demo.keyDown ? Color(white: 0.15) : .white, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color(white: 0.75)))
                        .shadow(color: .black.opacity(demo.keyDown ? 0 : 0.12), radius: 0, y: demo.keyDown ? 0 : 2)
                        .offset(y: demo.keyDown ? 2 : 0)
                    Text(demo.caption).font(.system(size: 13, weight: .medium)).foregroundStyle(Color(white: 0.3))
                }.padding(.top, 22)
                Spacer()
            }

            VStack { Spacer(); RecorderHUD(model: model, speech: speech) }
        }
        .frame(width: 800, height: 560)
        .environment(\.colorScheme, .light)
    }
}

@main struct RenderDemo {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let model = AppModel(preview: true)
        let speech = model.speech
        let demo = DemoState()
        speech.inputName = "MacBook Microphone"

        let host = NSHostingView(rootView: DemoScene(model: model, speech: speech, demo: demo))
        host.frame = NSRect(x: 0, y: 0, width: 800, height: 560)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -4000, y: -4000))
        window.orderFrontRegardless()

        let fps = 15.0, duration = 9.0
        let preview = "remind me to send the recaller deck to nkechi before friday"
        let final = "• Remind me to send the Recallr deck to Nkechi before Friday."
        let previewWords = preview.split(separator: " ")
        var frame = 0
        while Double(frame) / fps < duration {
            let t = Double(frame) / fps
            demo.cursorOn = Int(t * 2) % 2 == 0 || (t > 1 && t < 5.4)
            switch t {
            case ..<1.0:
                demo.caption = "Hold Control and talk"
            case ..<1.25:
                if !demo.keyDown { demo.keyDown = true; model.hudVisible = true; speech.phase = .preparing }
                demo.caption = "Listening…"
            case ..<5.2:
                if speech.phase != .recording { speech.phase = .recording }
                speech.elapsed = t - 1.25
                // A speech-like level: syllable bumps with small pauses.
                let syllable = abs(sin(t * 9.3)) * (0.55 + 0.45 * abs(sin(t * 2.1)))
                speech.level = Float(t > 1.5 ? 0.12 + 0.75 * syllable : 0.05)
                let spoken = Int(max(0, (t - 1.6) / 3.2) * Double(previewWords.count))
                speech.liveText = previewWords.prefix(min(spoken, previewWords.count)).joined(separator: " ")
            case ..<5.6:
                if demo.keyDown { demo.keyDown = false; speech.level = 0; speech.phase = .finishing; demo.caption = "Let go" }
            case ..<6.9:
                if demo.noteText.isEmpty {
                    demo.noteText = final
                    speech.phase = .idle
                    model.hudDetail = "Recallr and Nkechi picked up from screen"
                    model.hudMessage = "Inserted · saved"
                    demo.caption = "Transcribed on your Mac · no cloud"
                }
            default:
                if model.hudVisible { model.hudVisible = false }
            }
            // Let SwiftUI's springs advance in real time before capturing.
            RunLoop.main.run(until: Date().addingTimeInterval(1 / fps))
            host.layoutSubtreeIfNeeded()
            let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: rep)
            let name = String(format: "frame-%04d.png", frame)
            try! rep.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name))
            frame += 1
        }
        print("Rendered \(frame) frames to \(output.path)")
        try? FileManager.default.removeItem(at: model.storage.root)
        _ = app
    }
}
