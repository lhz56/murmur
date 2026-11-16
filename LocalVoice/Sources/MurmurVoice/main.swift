import FluidAudio
import Foundation

/// Murmur's voice: turns Ask's answers into natural speech on this Mac with
/// Kokoro 82M (Core ML, mostly on the Neural Engine). No audio leaves the Mac.
///
///     MurmurVoice [--install]                     serve: one JSON request per line on stdin
///     MurmurVoice --check                         exit 0 if the voice is downloaded
///     MurmurVoice --bench <output folder>         write sample WAVs and timings
///
/// Requests: {"id": "1", "text": "Hello.", "voice": "af_heart"}
/// Replies:  {"type": "ready"} · {"type": "progress", "fraction": 0.4}
///           {"type": "audio", "id": "1", "path": "/tmp/…wav", "seconds": 1.8, "took": 0.2}
///           {"type": "error", "id": "1", "message": "…"}
struct Request: Decodable { let id: String?; let text: String?; let voice: String?; let speed: Float? }

let outputLock = NSLock()
func emit(_ value: [String: Any]) {
    guard var data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return }
    data.append(10)
    outputLock.lock(); defer { outputLock.unlock() }
    FileHandle.standardOutput.write(data)
}

/// Seconds of 24 kHz 16-bit mono audio in a WAV file.
func seconds(_ wav: Data) -> Double { Double(max(0, wav.count - 44)) / Double(KokoroAneConstants.sampleRate * 2) }

/// Trims the silence Kokoro leaves around speech and brings it up to a steady
/// level, so sentences follow each other without gaps and match other audio.
/// Input and output are 16-bit mono PCM WAV.
func polish(_ wav: Data, lead: Double = 0.03, tail: Double = 0.12, peak: Float = 0.89) -> Data {
    guard wav.count > 44 else { return wav }
    let rate = KokoroAneConstants.sampleRate
    var samples = wav.subdata(in: 44..<wav.count).withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
    let floor: Int16 = 300  // about -40 dBFS: below this is silence or breath noise.
    guard let first = samples.firstIndex(where: { abs(Int32($0)) > Int32(floor) }),
          let last = samples.lastIndex(where: { abs(Int32($0)) > Int32(floor) }) else { return wav }
    let start = max(0, first - Int(lead * Double(rate)))
    let end = min(samples.count, last + Int(tail * Double(rate)))
    samples = Array(samples[start..<end])
    let loudest = samples.reduce(Int32(1)) { max($0, abs(Int32($1))) }
    let gain = min(4, peak * Float(Int16.max) / Float(loudest))  // never more than +12 dB
    if gain > 1.05 { samples = samples.map { Int16(clamping: Int32((Float($0) * gain).rounded())) } }
    // A short fade at each end so a trimmed edge never clicks.
    let fade = min(samples.count / 2, rate / 200)
    for i in 0..<fade {
        let scale = Float(i) / Float(fade)
        samples[i] = Int16(Float(samples[i]) * scale)
        samples[samples.count - 1 - i] = Int16(Float(samples[samples.count - 1 - i]) * scale)
    }
    var out = Data(wav.prefix(44))
    let bytes = UInt32(samples.count * 2)
    out.replaceSubrange(4..<8, with: withUnsafeBytes(of: (36 + bytes).littleEndian) { Data($0) })
    out.replaceSubrange(40..<44, with: withUnsafeBytes(of: bytes.littleEndian) { Data($0) })
    samples.withUnsafeBytes { out.append(contentsOf: $0) }
    return out
}

/// Words the lexicon gets wrong, spelled as Kokoro's phonemes.
let pronunciations: [String: String] = [
    "Xcode": "ˈɛkskˌOd", "xcode": "ˈɛkskˌOd", "macOS": "mˌækˌOˈɛs", "iOS": "ˌIˌOˈɛs", "SwiftUI": "swˈɪftjˌuˈI",
    "GitHub": "ɡˈɪthˌʌb", "Murmur": "mˈɜɹmɚ", "Recallr": "ɹikˈɔlɚ",
]

/// Marks a finished download, so `--check` doesn't have to load anything.
var readyMarker: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Murmur/Models/voice-kokoro-ane-v3.ready")
}

func makeVoice() async throws -> KokoroAneManager {
    let manager = KokoroAneManager(variant: .english, version: .v3)
    try await manager.initialize()
    await manager.setEnglishCustomLexicon(pronunciations)
    // The first sentence is slow while Core ML settles; get it out of the way.
    _ = try await manager.synthesize(text: "Ready.")
    return manager
}

@main struct Voice {
    static func main() async {
        let arguments = CommandLine.arguments
        if arguments.count > 2, arguments[1] == "--bench" { await bench(URL(fileURLWithPath: arguments[2], isDirectory: true)); return }
        if arguments.contains("--check") { exit(FileManager.default.fileExists(atPath: readyMarker.path) ? 0 : 1) }
        guard FileManager.default.fileExists(atPath: readyMarker.path) || arguments.contains("--install") else {
            emit(["type": "error", "message": "Murmur’s voice isn’t downloaded yet. Download it in Settings → Ask."]); return
        }
        do {
            emit(["type": "progress", "fraction": 0.02])
            let manager = try await makeVoice()
            try? FileManager.default.createDirectory(at: readyMarker.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: readyMarker.path, contents: Data("1".utf8))
            emit(["type": "ready"])
            let output = FileManager.default.temporaryDirectory.appendingPathComponent("Murmur-voice", isDirectory: true)
            try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            while let line = readLine() {
                guard let data = line.data(using: .utf8), let request = try? JSONDecoder().decode(Request.self, from: data),
                      let id = request.id, let text = request.text else { continue }
                let started = Date()
                do {
                    let wav = polish(try await manager.synthesize(text: text, voice: request.voice, speed: request.speed ?? KokoroAneConstants.defaultSpeed))
                    let file = output.appendingPathComponent("\(UUID().uuidString).wav")
                    try wav.write(to: file)
                    emit(["type": "audio", "id": id, "path": file.path, "seconds": seconds(wav), "took": Date().timeIntervalSince(started)])
                } catch {
                    emit(["type": "error", "id": id, "message": error.localizedDescription])
                }
            }
        } catch {
            emit(["type": "error", "message": error.localizedDescription])
        }
    }

    /// Writes the same answers in several voices, with timings, to compare by ear.
    static func bench(_ folder: URL) async {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let lines = [
            "You’re looking at Xcode’s signing settings.",
            "Click Signing and Capabilities, then tick Automatically manage signing.",
            "Sure, playing a chill mix on Spotify now.",
            "That error just means Swift can’t find the file. Add it to the build list, and it’ll compile.",
            "Hmm, I don’t see a save button on this screen, but you can press Command S.",
        ]
        do {
            var started = Date()
            let manager = try await makeVoice()
            print("load \(String(format: "%.2f", Date().timeIntervalSince(started))) s")
            for voice in ["af_heart", "af_bella", "af_nicole", "am_michael", "am_puck", "bf_emma", "bm_george"] {
                for (index, line) in lines.enumerated() {
                    started = Date()
                    let wav = polish(try await manager.synthesize(text: line, voice: voice))
                    let took = Date().timeIntervalSince(started)
                    try wav.write(to: folder.appendingPathComponent("\(voice)-\(index).wav"))
                    print("\(voice) \(index): \(String(format: "%.2f", took)) s for \(String(format: "%.1f", seconds(wav))) s")
                }
            }
        } catch { print("failed: \(error)") }
    }
}
