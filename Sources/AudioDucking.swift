import Foundation
import CoreAudio
import AudioToolbox

/// Lowers the Mac's output volume while recording, so music or a video
/// doesn't compete with your voice, then fades it back. If you change the
/// volume yourself mid-recording, your setting wins and nothing is restored.
@MainActor
final class AudioDucking {
    /// Fraction of the current volume kept while recording.
    static let duckedLevel: Float32 = 0.3
    private let defaults: UserDefaults
    private var saved: (device: AudioObjectID, original: Float32, ducked: Float32)?
    private var ramp: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        recoverAfterCrash()
    }

    func duck(after delay: Duration = .milliseconds(250)) {
        guard saved == nil, let device = Self.outputDevice(), let volume = Self.volume(of: device),
              volume > 0.02, Self.isSettable(device) else { return }
        let target = volume * Self.duckedLevel
        saved = (device, volume, target)
        defaults.set([Double(volume), Double(target)], forKey: "duckedVolume")
        ramp?.cancel()
        // Let the start chime play at full volume first.
        ramp = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.fade(device, from: volume, to: target)
        }
    }

    func restore() {
        guard let saved else { return }
        self.saved = nil
        defaults.removeObject(forKey: "duckedVolume")
        ramp?.cancel()
        ramp = Task { [weak self] in
            guard let current = Self.volume(of: saved.device) else { return }
            // Outside the range we faded through, the user changed it; leave it alone.
            guard current >= saved.ducked - 0.02, current < saved.original - 0.005 else { return }
            await self?.fade(saved.device, from: current, to: saved.original)
        }
    }

    /// Murmur quit or crashed while ducked: put the volume back on next launch.
    private func recoverAfterCrash() {
        guard let values = defaults.array(forKey: "duckedVolume") as? [Double], values.count == 2 else { return }
        defaults.removeObject(forKey: "duckedVolume")
        guard let device = Self.outputDevice(), let current = Self.volume(of: device),
              abs(Double(current) - values[1]) < 0.03 else { return }
        Self.setVolume(Float32(values[0]), on: device)
    }

    /// Synchronous restore for app termination, when tasks won't get to run.
    func restoreNow() {
        guard let saved else { return }
        self.saved = nil
        ramp?.cancel()
        defaults.removeObject(forKey: "duckedVolume")
        if let current = Self.volume(of: saved.device), current < saved.original { Self.setVolume(saved.original, on: saved.device) }
    }

    private func fade(_ device: AudioObjectID, from start: Float32, to end: Float32) async {
        let steps = 8
        for step in 1...steps {
            guard !Task.isCancelled else { return }
            Self.setVolume(start + (end - start) * Float32(step) / Float32(steps), on: device)
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    // MARK: Core Audio

    private static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func outputDevice() -> AudioObjectID? {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = address(kAudioHardwarePropertyDefaultOutputDevice)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return nil }
        return device
    }

    private static var volumeAddress: AudioObjectPropertyAddress {
        address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioDevicePropertyScopeOutput)
    }

    private static func volume(of device: AudioObjectID) -> Float32? {
        var address = volumeAddress
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var volume: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &volume) == noErr else { return nil }
        return volume
    }

    private static func isSettable(_ device: AudioObjectID) -> Bool {
        var address = volumeAddress
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(device, &address, &settable) == noErr && settable.boolValue
    }

    private static func setVolume(_ volume: Float32, on device: AudioObjectID) {
        var address = volumeAddress
        var value = min(max(volume, 0), 1)
        AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
    }
}
