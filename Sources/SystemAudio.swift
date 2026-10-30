import AVFoundation
import AppKit
import CoreAudio
import AudioToolbox

/// Core Audio helpers for meetings: which apps are using a microphone, and a
/// tap on what the Mac is playing (the other people on a call).
enum AudioProcesses {
    struct Client: Equatable {
        let pid: pid_t
        let bundleID: String
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    private static func objects(_ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var address = address(selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func pid(_ object: AudioObjectID) -> pid_t? {
        var address = address(kAudioProcessPropertyPID)
        var value: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func bundleID(_ object: AudioObjectID) -> String? {
        var address = address(kAudioProcessPropertyBundleID)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    /// Other apps capturing from a microphone right now. Murmur itself is left out.
    static func microphoneClients() -> [Client] {
        let own = ProcessInfo.processInfo.processIdentifier
        return objects(kAudioHardwarePropertyProcessObjectList).compactMap { object in
            guard uint32(object, kAudioProcessPropertyIsRunningInput) == 1, let pid = pid(object), pid != own else { return nil }
            return Client(pid: pid, bundleID: bundleID(object) ?? NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "")
        }
    }

    /// Murmur's own Core Audio process, so its sounds stay out of the tap.
    static func ownProcessObject() -> AudioObjectID? {
        var address = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = ProcessInfo.processInfo.processIdentifier
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                                UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    static func defaultOutputUID() -> String? {
        var address = address(kAudioHardwarePropertyDefaultSystemOutputDevice)
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else { return nil }
        return Microphones.string(device, kAudioDevicePropertyDeviceUID)
    }
}

/// Everything the Mac plays, except Murmur, as 16 kHz mono samples. Uses a
/// Core Audio process tap (macOS 14.2+); the first use asks for permission
/// to record system audio. Nothing is muted or changed for you.
final class SystemAudioTap: @unchecked Sendable {
    enum Failure: LocalizedError {
        case tap(OSStatus), device(OSStatus), format
        var errorDescription: String? {
            switch self {
            case .tap: return "Murmur couldn’t listen to your Mac’s audio. Allow it in System Settings → Privacy & Security → Screen & System Audio Recording."
            case .device, .format: return "Murmur couldn’t start capturing your Mac’s audio."
            }
        }
    }

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "app.murmur.system-audio", qos: .userInitiated)
    private var converter: MonoResampler?

    /// Receives 16 kHz mono samples on a background queue.
    func start(_ receive: @escaping ([Float]) -> Void) throws {
        let excluded = AudioProcesses.ownProcessObject().map { [$0] } ?? []
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        description.uuid = UUID()
        description.muteBehavior = .unmuted
        description.isPrivate = true
        description.name = "Murmur meeting audio"
        var status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else { throw Failure.tap(status) }

        var formatAddress = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var stream = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = AudioObjectGetPropertyData(tapID, &formatAddress, 0, nil, &size, &stream)
        guard status == noErr, let format = AVAudioFormat(streamDescription: &stream) else { stop(); throw Failure.format }

        var aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Murmur Meeting Tap",
            kAudioAggregateDeviceUIDKey: "app.murmur.tap.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        if let output = AudioProcesses.defaultOutputUID() {
            aggregate[kAudioAggregateDeviceMainSubDeviceKey] = output
            aggregate[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: output]]
        }
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID)
        guard status == noErr else { stop(); throw Failure.device(status) }

        let resampler = MonoResampler(input: format)
        converter = resampler
        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { _, input, _, _, _ in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil) else { return }
            let samples = resampler.convert(buffer)
            if !samples.isEmpty { receive(samples) }
        }
        guard status == noErr else { stop(); throw Failure.device(status) }
        status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else { stop(); throw Failure.device(status) }
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            if let procID { AudioDeviceDestroyIOProcID(aggregateID, procID) }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil; aggregateID = AudioObjectID(kAudioObjectUnknown); tapID = AudioObjectID(kAudioObjectUnknown)
    }

    deinit { stop() }
}

/// Converts any PCM buffer to 16 kHz mono floats, the format speech models use.
final class MonoResampler: @unchecked Sendable {
    static let rate: Double = 16_000
    private let converter: AVAudioConverter?
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: MonoResampler.rate, channels: 1, interleaved: false)!

    init(input: AVAudioFormat) {
        converter = AVAudioConverter(from: input, to: target)
        converter?.primeMethod = .none
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard let converter, buffer.frameLength > 0 else { return [] }
        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * Self.rate / buffer.format.sampleRate)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return [] }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            if supplied { state.pointee = .noDataNow; return nil }
            supplied = true; state.pointee = .haveData; return buffer
        }
        guard status != .error, error == nil, let data = output.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(output.frameLength)))
    }
}
