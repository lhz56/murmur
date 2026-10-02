import AVFoundation
import AudioToolbox
import CoreAudio
import Combine

struct Microphone: Identifiable, Equatable {
    let id: String
    let deviceID: AudioDeviceID
    let name: String
}

enum Microphones {
    static func devices() -> [Microphone] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        let status = ids.withUnsafeMutableBytes { AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, $0.baseAddress!) }
        guard status == noErr else { return [] }
        return ids.compactMap { id in
            var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
            var bytes: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &bytes) == noErr, bytes > 0,
                  let uid = string(id, kAudioDevicePropertyDeviceUID), let name = string(id, kAudioObjectPropertyName) else { return nil }
            return Microphone(id: uid, deviceID: id, name: name)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeUnretainedValue() as String?
    }

    static var defaultID: AudioDeviceID {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        _ = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return id
    }

    /// Select only this engine's input; never change the Mac's system-wide microphone.
    static func selected(uid: String) throws -> Microphone {
        let available = devices()
        if uid.isEmpty {
            guard let device = available.first(where: { $0.deviceID == defaultID }) else { throw DictationError.noInput }
            return device
        }
        guard let device = available.first(where: { $0.id == uid }) else { throw DictationError.missingMicrophone }
        return device
    }

    static func configure(_ engine: AVAudioEngine, uid: String) async throws -> String {
        let device = try selected(uid: uid)
        guard let unit = engine.inputNode.audioUnit else { throw DictationError.noInput }
        var id = device.deviceID
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else { throw DictationError.noInput }
        // Selecting a device posts a format change asynchronously. Let it settle before
        // installing a tap; otherwise the graph can retain the previous device's rate.
        try await Task.sleep(for: .milliseconds(250))
        engine.reset()
        return device.name
    }

    /// A stopped graph can follow a system input change while it is waiting.
    static func isConfigured(_ engine: AVAudioEngine, for device: Microphone) -> Bool {
        guard let unit = engine.inputNode.audioUnit else { return false }
        var current = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global,
                                   0, &current, &size) == noErr, current == device.deviceID else { return false }
        let hardware = engine.inputNode.inputFormat(forBus: 0)
        let graph = engine.inputNode.outputFormat(forBus: 0)
        return hardware.sampleRate > 0 && hardware.channelCount > 0
            && hardware.sampleRate == graph.sampleRate && hardware.channelCount == graph.channelCount
    }
}

struct InputSignal: Equatable, Sendable {
    var decibels: Float = -100
    var peak: Float = 0
    var seconds: Double = 0
    var audibleSeconds: Double = 0
    var clippedSamples: Int = 0
    var samples: Int = 0
    var hasFrames: Bool { seconds > 0 }
    var level: Float { min(1, max(0, (decibels + 60) / 55)) }
    var label: String {
        if !hasFrames { return "Waiting for microphone audio…" }
        if decibels < -48 { return "Input is quiet · speak to check" }
        if decibels > -5 { return "Very loud · move a little farther away" }
        return "Your microphone is receiving sound"
    }
    mutating func observe(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return }
        var energy: Float = 0, maximum: Float = 0, clipped = 0
        let count = Int(buffer.frameLength)
        for channel in 0..<Int(buffer.format.channelCount) {
            for index in 0..<count {
                let sample = abs(channels[channel][index])
                energy += sample * sample
                maximum = max(maximum, sample)
                if sample >= 0.99 { clipped += 1 }
            }
        }
        let sampleCount = count * Int(buffer.format.channelCount)
        let db = 20 * log10(max(sqrt(energy / Float(sampleCount)), 0.00001))
        let duration = Double(buffer.frameLength) / buffer.format.sampleRate
        decibels = db; peak = max(peak, maximum); seconds += duration
        if db > -48 { audibleSeconds += duration }
        clippedSamples += clipped; samples += sampleCount
    }
}

@MainActor final class MicrophoneCheck: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var signal = InputSignal()
    @Published private(set) var name = ""
    @Published private(set) var error: String?
    private var engine: AVAudioEngine?
    private var session = UUID()
    func start(uid: String) async {
        stop(); session = UUID(); let current = session
        error = nil; signal = InputSignal()
        guard await AVCaptureDevice.requestAccess(for: .audio) else { error = DictationError.microphone.localizedDescription; return }
        guard current == session else { return }
        do {
            let audio = AVAudioEngine()
            name = try await Microphones.configure(audio, uid: uid)
            guard current == session else { return }
            let input = audio.inputNode
            let format = input.inputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { throw DictationError.noInput }
            input.installTap(onBus: 0, bufferSize: 2048, format: nil) { buffer, _ in
                var value = InputSignal(); value.observe(buffer)
                Task { @MainActor [weak self] in
                    guard let self, current == self.session else { return }
                    self.signal = value
                }
            }
            engine = audio; audio.prepare(); try audio.start(); isRunning = true
        } catch { stop(); self.error = error.localizedDescription }
    }
    func stop() {
        session = UUID()
        engine?.stop(); engine?.inputNode.removeTap(onBus: 0); engine = nil; isRunning = false
    }
}
