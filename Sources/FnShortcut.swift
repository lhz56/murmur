import Foundation
import AppKit
import ApplicationServices
import Carbon

enum FnBehavior: String, CaseIterable { case hold = "Hold to talk", toggle = "Press to toggle" }
enum DictationKey: String, CaseIterable {
    case control = "Control", rightOption = "Right Option", rightCommand = "Right Command", fn = "Fn / Globe"
    var keyCap: String {
        switch self {
        case .control: return "⌃"
        case .rightOption: return "Right ⌥"
        case .rightCommand: return "Right ⌘"
        case .fn: return "fn"
        }
    }
    var name: String { self == .fn ? "Fn" : rawValue }
    /// Modifier-only keys are watched without swallowing any events, so every
    /// normal shortcut that uses the key keeps working.
    var isModifierHold: Bool { self != .fn }
    /// The flag that is set while this key is down. Right-hand keys use the
    /// device-specific bits so the left key keeps its usual job.
    var flag: CGEventFlags {
        switch self {
        case .control: return .maskControl
        case .rightOption: return CGEventFlags(rawValue: 0x40)
        case .rightCommand: return CGEventFlags(rawValue: 0x10)
        case .fn: return .maskSecondaryFn
        }
    }
    /// Modifiers that turn a hold into a chord, e.g. Right Option + Shift.
    var otherModifiers: CGEventFlags {
        let all: CGEventFlags = [.maskControl, .maskCommand, .maskAlternate, .maskShift, .maskSecondaryFn]
        switch self {
        case .control: return all.subtracting(.maskControl)
        case .rightOption: return all.subtracting(.maskAlternate)
        case .rightCommand: return all.subtracting(.maskCommand)
        case .fn: return all.subtracting(.maskSecondaryFn)
        }
    }
}

/// Pure key state, kept separate from the system hook so timing and chord behavior can be tested.
struct FnKeyState {
    enum Action: Equatable { case startHold, finishHold, toggle, latchHold, cancelHold }
    var isDown = false
    var isChord = false
    var didTrigger = false
    var wasBusy = false
    var behavior: FnBehavior = .hold

    mutating func press(behavior: FnBehavior, busy: Bool) {
        isDown = true; isChord = false; didTrigger = false; wasBusy = busy; self.behavior = behavior
    }
    mutating func thresholdReached() -> Action? {
        guard isDown, !isChord, !didTrigger else { return nil }
        if behavior == .hold && wasBusy { return nil }
        didTrigger = true
        return behavior == .hold ? .startHold : .toggle
    }
    mutating func release() -> Action? {
        defer { isDown = false; isChord = false; didTrigger = false }
        guard isDown, !isChord else { return nil }
        if behavior == .toggle { return didTrigger ? nil : .toggle }
        return didTrigger || wasBusy ? .finishHold : nil
    }
    mutating func space() -> Action? {
        guard isDown, !isChord else { return nil }
        isChord = true
        if wasBusy { return .toggle }
        return didTrigger && behavior == .hold ? .latchHold : .toggle
    }
    mutating func otherKey() -> Action? {
        guard isDown, !isChord else { return nil }
        isChord = true
        return didTrigger && behavior == .hold ? .cancelHold : nil
    }
    mutating func reset() { isDown = false; isChord = false; didTrigger = false }
}

@MainActor
final class FnShortcut {
    var trigger: () -> DictationKey = { .fn }
    var behavior: () -> FnBehavior = { .hold }
    var enabled: () -> Bool = { true }
    var isBusy: () -> Bool = { false }
    var onAction: ((FnKeyState.Action) -> Void)?
    var onAvailability: ((Bool) -> Void)?
    var onFnSignal: ((Bool) -> Void)?
    /// Mouse button number to hold for dictation (2 middle, 3 back, 4 forward); 0 is off.
    var mouseButton: () -> Int = { 0 }
    var onMouse: ((Bool) -> Void)?
    private var installedMouse = 0
    private var mouseDown = false
    var clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var localMonitor: Any?
    private var pending: DispatchWorkItem?
    private var state = FnKeyState()
    private var consumedSpace = false
    private var handsFreeChord = false
    private var lastShortTap: TimeInterval?
    private var controlTimer: Timer?
    private var controlPolling: ControlPolling = .off
    private var holdCheck: Timer?
    private var controlStartCount: UInt32?
    private var previousControlCount: UInt32?
    private var controlPressedAt: TimeInterval?
    static let controlHoldDelay: TimeInterval = 0.10
    private var installedKey: DictationKey?
    private var releaseRequiredFor: DictationKey?

    func refresh() {
        if !enabled() { stop(); onAvailability?(false); return }
        if installedKey != trigger() || installedMouse != mouseButton() { stop() }
        installedKey = trigger()
        installedMouse = mouseButton()
        defer { updateControlPolling() }
        if let tap, AXIsProcessTrusted(), CFMachPortIsValid(tap) { onAvailability?(true); return }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes); self.source = nil }
        if let tap { CFMachPortInvalidate(tap); self.tap = nil }
        if let localMonitor { NSEvent.removeMonitor(localMonitor); self.localMonitor = nil }
        if AXIsProcessTrusted() {
            var mask = (CGEventMask(1) << CGEventType.flagsChanged.rawValue) |
                       (CGEventMask(1) << CGEventType.keyDown.rawValue) |
                       (CGEventMask(1) << CGEventType.keyUp.rawValue)
            if installedMouse != 0 {
                mask |= (CGEventMask(1) << CGEventType.otherMouseDown.rawValue) | (CGEventMask(1) << CGEventType.otherMouseUp.rawValue)
            }
            let callback: CGEventTapCallBack = { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let shortcut = Unmanaged<FnShortcut>.fromOpaque(context).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    shortcut.handleTapInterruption()
                    return Unmanaged.passUnretained(event)
                }
                return shortcut.handle(type: type, event: event) ? nil : Unmanaged.passUnretained(event)
            }
            // HID intercepts the bare Fn key before macOS opens the emoji/dictation action.
            tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
                                    eventsOfInterest: mask, callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque())
            if tap == nil {
                tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: mask, callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque())
            }
            if let tap {
                source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
                CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
                CGEvent.tapEnable(tap: tap, enable: true)
                onAvailability?(true)
                return
            }
        }
        // Fn remains usable inside Murmur while the global permission is pending.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown, .keyUp]) { [weak self] event in
            guard let self, let cgEvent = event.cgEvent else { return event }
            return handle(type: cgEvent.type, event: cgEvent) ? nil : event
        }
        onAvailability?(trigger().isModifierHold)
    }

    private enum ControlPolling { case off, watch, fast }

    /// With an event tap, Control presses arrive as events and the app stays idle.
    /// Without one, or while Secure Keyboard Entry hides key events from taps,
    /// poll the modifier state instead. Flags and counters contain no typed text.
    private func updateControlPolling() {
        let wanted: ControlPolling
        if !enabled() || !trigger().isModifierHold { wanted = .off }
        else if tap == nil || IsSecureEventInputEnabled() { wanted = .fast }
        else { wanted = .watch }
        guard wanted != controlPolling else { return }
        controlTimer?.invalidate(); controlTimer = nil
        controlPolling = wanted
        guard wanted != .off else { return }
        let fast = wanted == .fast
        let timer = Timer(timeInterval: fast ? 0.01 : 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.controlPolling == .fast { self.sampleCurrentControl() }
                self.updateControlPolling()
            }
        }
        timer.tolerance = fast ? 0.002 : 0.1
        controlTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func sampleCurrentControl() {
        sampleControl(flags: CGEventSource.flagsState(.combinedSessionState),
                      keyDownCount: CGEventSource.counterForEventType(.combinedSessionState, eventType: .keyDown))
    }

    /// Event-driven holds get no further events while Control stays down, so
    /// check once when the hold threshold elapses.
    private func scheduleHoldCheck() {
        holdCheck?.invalidate()
        let timer = Timer(timeInterval: Self.controlHoldDelay + 0.005, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.holdCheck = nil
                if self.state.isDown { self.sampleCurrentControl() }
            }
        }
        holdCheck = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func sampleControl(flags: CGEventFlags, keyDownCount: UInt32) {
        let key = trigger()
        guard enabled(), key.isModifierHold else { return }
        defer { previousControlCount = keyDownCount }
        if let held = releaseRequiredFor {
            if flags.contains(held.flag) { return }
            releaseRequiredFor = nil
        }
        let down = flags.contains(key.flag)
        let other = key.otherModifiers
        if down && !state.isDown {
            state.press(behavior: behavior(), busy: isBusy())
            controlPressedAt = clock()
            controlStartCount = keyDownCount
            if let previousControlCount, previousControlCount != keyDownCount { _ = state.otherKey() }
            onFnSignal?(true)
            if controlPolling == .watch, state.behavior == .hold { scheduleHoldCheck() }
        }
        if state.isDown {
            if !flags.intersection(other).isEmpty || controlStartCount != keyDownCount {
                if let action = state.otherKey() { onAction?(action) }
            }
            if down, state.behavior == .hold, let pressed = controlPressedAt,
               clock() - pressed >= Self.controlHoldDelay,
               let action = state.thresholdReached() { onAction?(action) }
            if !down {
                let action = state.release()
                if let action { onAction?(action) }
                controlStartCount = nil
                controlPressedAt = nil
                onFnSignal?(false)
            }
        }
    }

    func handle(type: CGEventType, event: CGEvent) -> Bool {
        guard enabled() else { return false }
        if type == .otherMouseDown || type == .otherMouseUp {
            let button = mouseButton()
            guard button != 0, event.getIntegerValueField(.mouseEventButtonNumber) == Int64(button) else { return false }
            let down = type == .otherMouseDown
            // The press is ours: don't also send the browser Back or Forward.
            if down != mouseDown { mouseDown = down; onMouse?(down) }
            return true
        }
        if let held = releaseRequiredFor {
            if event.flags.contains(held.flag) { return false }
            releaseRequiredFor = nil
        }
        if trigger().isModifierHold {
            if type == .flagsChanged {
                sampleControl(flags: event.flags,
                              keyDownCount: CGEventSource.counterForEventType(.combinedSessionState, eventType: .keyDown))
            } else if type == .keyDown && state.isDown {
                if let action = state.otherKey() { onAction?(action) }
            }
            return false // All normal modifier shortcuts continue to the foreground app.
        }
        let key = event.getIntegerValueField(.keyboardEventKeycode)
        let otherModifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
        // Fn+Space carries the Fn modifier itself. Do not depend on a prior Fn-down
        // event: macOS can swallow it or a hook may be installed while Fn is held.
        if type == .keyDown && key == 49 && event.flags.contains(.maskSecondaryFn) &&
            event.flags.intersection(otherModifiers).isEmpty {
            pending?.cancel()
            if consumedSpace { return true }
            if !state.isDown {
                state.press(behavior: behavior(), busy: isBusy())
                onFnSignal?(true)
            }
            lastShortTap = nil
            if !state.isChord {
                consumedSpace = true; handsFreeChord = true
                if let action = state.space() { onAction?(action) }
                return true
            }
        }
        if type == .flagsChanged {
            let down = event.flags.contains(.maskSecondaryFn)
            if down && !state.isDown {
                guard event.flags.intersection(otherModifiers).isEmpty else { return false }
                state.press(behavior: behavior(), busy: isBusy())
                onFnSignal?(true)
                handsFreeChord = false
                pending?.cancel()
                // Like the standard dictation gesture, a second short Fn tap
                // starts hands-free recording. Its release must not stop it.
                if state.behavior == .hold && !state.wasBusy,
                   let lastShortTap, clock() - lastShortTap <= 0.35 {
                    self.lastShortTap = nil
                    state.isChord = true; handsFreeChord = true
                    onAction?(.toggle)
                    return true
                }
                let work = DispatchWorkItem { [weak self] in
                    guard let self, let action = state.thresholdReached() else { return }
                    lastShortTap = nil
                    onAction?(action)
                }
                pending = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
                return true
            }
            if !down && state.isDown {
                pending?.cancel(); pending = nil
                let wasChord = state.isChord
                let wasHandsFree = handsFreeChord
                lastShortTap = !state.didTrigger && !wasChord && !state.wasBusy && state.behavior == .hold ? clock() : nil
                onFnSignal?(false)
                if let action = state.release() { onAction?(action) }
                handsFreeChord = false
                return !wasChord || wasHandsFree
            }
        }
        if type == .keyUp && key == 49 && consumedSpace { consumedSpace = false; return true }
        if type == .keyDown && state.isDown {
            pending?.cancel()
            lastShortTap = nil
            if key == 49 && consumedSpace { return true }
            if key == 49 && !state.isChord {
                consumedSpace = true
                handsFreeChord = true
                if let action = state.space() { onAction?(action) }
                return true
            }
            if let action = state.otherKey() { onAction?(action) }
            return false
        }
        return false
    }

    func resetInput() {
        pending?.cancel(); pending = nil; state.reset(); consumedSpace = false; handsFreeChord = false
        holdCheck?.invalidate(); holdCheck = nil
        lastShortTap = nil
        controlStartCount = nil
        previousControlCount = nil
        controlPressedAt = nil
        releaseRequiredFor = nil
    }

    private func abandonHeldInput() {
        // Reconfiguring or disabling the hook must not lose the release of an
        // active hold. Chords and explicitly latched recordings remain untouched.
        let finishHold = state.isDown && !state.isChord && state.behavior == .hold && (state.didTrigger || state.wasBusy)
        let heldKey = state.isDown ? installedKey ?? trigger() : releaseRequiredFor
        resetInput()
        // A mouse release can be lost while the hook restarts; finish the hold.
        if mouseDown { mouseDown = false; onMouse?(false) }
        releaseRequiredFor = heldKey
        if finishHold { onAction?(.finishHold) }
    }

    func handleTapInterruption() {
        abandonHeldInput()
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    func stop() {
        abandonHeldInput()
        installedMouse = 0
        controlTimer?.invalidate(); controlTimer = nil; controlPolling = .off
        installedKey = nil
        if let localMonitor { NSEvent.removeMonitor(localMonitor); self.localMonitor = nil }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes); self.source = nil }
        if let tap { CFMachPortInvalidate(tap); self.tap = nil }
    }
}
