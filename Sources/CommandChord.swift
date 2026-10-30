import AppKit
import ApplicationServices

/// Space + Down Arrow opens Commands: press them together (either order) to
/// type, hold them to talk. A Space on its own still types a space: it's held
/// back for a moment and sent as soon as another key, a click, its release or
/// half a second shows it wasn't the shortcut, in the order you typed.
///
/// Every key's release is treated the same way as its press: a press that
/// reached the app gets its release, a press Murmur kept never does.
struct SpaceArrowChord {
    enum Key: Equatable { case space, down, other }
    enum Decision: Equatable {
        /// Let the event through untouched.
        case pass
        /// Drop the event.
        case swallow
        /// Drop the event, then send the held-back Space followed by this event.
        case replaySpaceThen
    }

    static let spaceKey: Int64 = 49
    static let downKey: Int64 = 125
    /// Holding Space this long without the arrow means you're holding Space.
    static let holdBack: TimeInterval = 0.5

    private(set) var active = false
    private var spaceHeld = false, downHeld = false
    /// Space was pressed and is being held back to see if Down follows.
    private(set) var spaceDeferred = false
    private var deferredAt: TimeInterval = 0
    /// The press was kept by Murmur, so its repeats and release are kept too.
    private var spaceConsumed = false, downConsumed = false

    /// `chord` is called with true when the shortcut goes down and false when it's released.
    mutating func handle(_ key: Key, down: Bool, isRepeat: Bool, modified: Bool, at time: TimeInterval,
                         chord: (Bool) -> Void) -> Decision {
        switch (key, down) {
        case (.space, true):
            if isRepeat {
                if spaceConsumed { return .swallow }
                if spaceDeferred {
                    // A long press of Space: type it and let the repeats through.
                    guard time - deferredAt >= Self.holdBack else { return .swallow }
                    spaceDeferred = false
                    return .replaySpaceThen
                }
                return .pass
            }
            if modified { return .pass }
            spaceHeld = true
            if downHeld, !active {
                // Down first, then Space: Down already reached the app, so only Space is kept.
                active = true; spaceConsumed = true
                chord(true)
                return .swallow
            }
            spaceDeferred = true; deferredAt = time
            return .swallow
        case (.space, false):
            spaceHeld = false
            if active { active = false; chord(false) }
            if spaceConsumed { spaceConsumed = false; return .swallow }
            if spaceDeferred { spaceDeferred = false; return .replaySpaceThen }
            return .pass
        case (.down, true):
            // Repeats of a kept press stay kept; while listening, the arrow doesn't scroll the app.
            if isRepeat { return downConsumed || active ? .swallow : .pass }
            downHeld = true
            if spaceHeld, spaceDeferred, !modified {
                spaceDeferred = false
                active = true; spaceConsumed = true; downConsumed = true
                chord(true)
                return .swallow
            }
            if spaceDeferred { spaceDeferred = false; return .replaySpaceThen }
            return .pass
        case (.down, false):
            downHeld = false
            if active { active = false; chord(false) }
            if downConsumed { downConsumed = false; return .swallow }
            return .pass
        case (.other, true):
            if spaceDeferred { spaceDeferred = false; return .replaySpaceThen }
            return .pass
        case (.other, false):
            return .pass
        }
    }

    /// Half a second passed with Space held and no arrow: it's a held Space.
    mutating func holdBackExpired(at time: TimeInterval) -> Bool {
        guard spaceDeferred, time - deferredAt >= Self.holdBack - 0.01 else { return false }
        spaceDeferred = false
        return true
    }

    /// Lets go of everything, e.g. when the event tap was interrupted.
    /// Returns whether a Space was still held back.
    mutating func reset(chord: (Bool) -> Void) -> Bool {
        let hadSpace = spaceDeferred
        if active { chord(false) }
        self = SpaceArrowChord()
        return hadSpace
    }
}

/// Watches the keyboard for Space + Down Arrow. Needs Accessibility, which
/// Murmur already asks for to type dictations. Only these two keys are
/// looked at; other keys and clicks just flush a held-back Space.
@MainActor
final class CommandChordShortcut {
    var onChord: ((Bool) -> Void)?
    private var chord = SpaceArrowChord()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    /// The Space press being held back, exactly as typed (Shift and all).
    private var heldSpace: CGEvent?
    private var holdBackCheck = 0
    /// Marks the events Murmur sends back, so it doesn't catch them again.
    private static let marker: Int64 = 0x4D524D53

    var isRunning: Bool { tap.map(CFMachPortIsValid) ?? false }

    func start() {
        guard !isRunning, AXIsProcessTrusted() else { return }
        stop()
        var mask = (CGEventMask(1) << CGEventType.keyDown.rawValue) | (CGEventMask(1) << CGEventType.keyUp.rawValue)
        // A click while Space is held back sends the Space first, so it lands where you were typing.
        for type in [CGEventType.leftMouseDown, .rightMouseDown, .otherMouseDown] { mask |= CGEventMask(1) << type.rawValue }
        let callback: CGEventTapCallBack = { proxy, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let shortcut = Unmanaged<CommandChordShortcut>.fromOpaque(context).takeUnretainedValue()
            return MainActor.assumeIsolated { shortcut.handle(proxy, type, event) }
        }
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                eventsOfInterest: mask, callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap else { return }
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes); self.source = nil }
        if let tap { CFMachPortInvalidate(tap); self.tap = nil }
        releaseHeldSpace()
    }

    /// Resets after an interruption, giving back a held-back Space: a press, and
    /// its release too if the key was already let go while Murmur wasn't watching.
    private func releaseHeldSpace() {
        let hadSpace = chord.reset { [weak self] in self?.onChord?($0) }
        guard hadSpace, let space = heldSpace else { heldSpace = nil; return }
        heldSpace = nil
        post(space)
        if !CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(SpaceArrowChord.spaceKey)),
           let release = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(SpaceArrowChord.spaceKey), keyDown: false) {
            release.flags = space.flags
            post(release)
        }
    }

    private func handle(_ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            releaseHeldSpace()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard event.getIntegerValueField(.eventSourceUserData) != Self.marker else { return Unmanaged.passUnretained(event) }
        let isKey = type == .keyDown || type == .keyUp
        let code = isKey ? event.getIntegerValueField(.keyboardEventKeycode) : -1
        let key: SpaceArrowChord.Key = code == SpaceArrowChord.spaceKey ? .space : code == SpaceArrowChord.downKey ? .down : .other
        let modified = !event.flags.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty
        let isRepeat = isKey && event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        let wasDeferred = chord.spaceDeferred
        let decision = chord.handle(key, down: type != .keyUp, isRepeat: isRepeat, modified: modified,
                                    at: ProcessInfo.processInfo.systemUptime) { [weak self] down in
            // Out of the tap callback, so the keyboard never waits on Murmur.
            DispatchQueue.main.async { self?.onChord?(down) }
        }
        if !wasDeferred, chord.spaceDeferred {
            heldSpace = event.copy()
            scheduleHoldBackCheck()
        }
        switch decision {
        case .pass: return Unmanaged.passUnretained(event)
        case .swallow: return nil
        case .replaySpaceThen:
            // The held-back Space, then this event, both posted here so they keep their order.
            if let space = heldSpace { post(space, via: proxy) }
            heldSpace = nil
            if let copy = event.copy() { post(copy, via: proxy) }
            return nil
        }
    }

    /// Without key repeat, nothing would arrive while Space is held; this sends it on time anyway.
    private func scheduleHoldBackCheck() {
        holdBackCheck += 1
        let check = holdBackCheck
        DispatchQueue.main.asyncAfter(deadline: .now() + SpaceArrowChord.holdBack) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, check == self.holdBackCheck, self.chord.holdBackExpired(at: ProcessInfo.processInfo.systemUptime),
                      let space = self.heldSpace else { return }
                self.heldSpace = nil
                self.post(space)
            }
        }
    }

    private func post(_ event: CGEvent, via proxy: CGEventTapProxy? = nil) {
        event.setIntegerValueField(.eventSourceUserData, value: Self.marker)
        if let proxy { event.tapPostEvent(proxy) } else { event.post(tap: .cgSessionEventTap) }
    }
}
