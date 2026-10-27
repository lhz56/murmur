import Foundation
import AppKit
import ApplicationServices

enum FnBehavior: String, CaseIterable { case hold = "Hold to talk", toggle = "Press to toggle" }
enum DictationKey: String, CaseIterable {
    case control = "Control", fn = "Fn / Globe"
    var keyCap: String { self == .control ? "⌃" : "fn" }
    var name: String { self == .control ? "Control" : "Fn" }
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
    private var controlStartCount: UInt32?
    private var previousControlCount: UInt32?
    private var controlPressedAt: TimeInterval?
    static let controlHoldDelay: TimeInterval = 0.10
    private var installedKey: DictationKey?
    private var releaseRequiredFor: DictationKey?

    func refresh() {
        if !enabled() { stop(); onAvailability?(false); return }
        if installedKey != trigger() { stop() }
        installedKey = trigger()
        if trigger() == .control && controlTimer == nil {
            // Modifier flags and the event count contain no typed text. They let
            // Control holds and taps work globally without an Accessibility tap.
            // The timer fires on the main run loop; sample inline rather than
            // allocating and scheduling a task 100 times per second.
            let timer = Timer(timeInterval: 0.01, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.sampleControl(flags: CGEventSource.flagsState(.combinedSessionState),
                                        keyDownCount: CGEventSource.counterForEventType(.combinedSessionState, eventType: .keyDown))
                }
            }
            timer.tolerance = 0.002
            controlTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
        if let tap, AXIsProcessTrusted(), CFMachPortIsValid(tap) { onAvailability?(true); return }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes); self.source = nil }
        if let tap { CFMachPortInvalidate(tap); self.tap = nil }
        if let localMonitor { NSEvent.removeMonitor(localMonitor); self.localMonitor = nil }
        if AXIsProcessTrusted() {
            let mask = (CGEventMask(1) << CGEventType.flagsChanged.rawValue) |
                       (CGEventMask(1) << CGEventType.keyDown.rawValue) |
                       (CGEventMask(1) << CGEventType.keyUp.rawValue)
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
        onAvailability?(trigger() == .control)
    }

    func sampleControl(flags: CGEventFlags, keyDownCount: UInt32) {
        guard enabled(), trigger() == .control else { return }
        defer { previousControlCount = keyDownCount }
        if let key = releaseRequiredFor {
            if flags.contains(key == .control ? .maskControl : .maskSecondaryFn) { return }
            releaseRequiredFor = nil
        }
        let down = flags.contains(.maskControl)
        let other: CGEventFlags = [.maskCommand, .maskAlternate, .maskShift, .maskSecondaryFn]
        if down && !state.isDown {
            state.press(behavior: behavior(), busy: isBusy())
            controlPressedAt = clock()
            controlStartCount = keyDownCount
            if let previousControlCount, previousControlCount != keyDownCount { _ = state.otherKey() }
            onFnSignal?(true)
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
        if let key = releaseRequiredFor {
            if event.flags.contains(key == .control ? .maskControl : .maskSecondaryFn) { return false }
            releaseRequiredFor = nil
        }
        if trigger() == .control {
            if type == .flagsChanged {
                sampleControl(flags: event.flags,
                              keyDownCount: CGEventSource.counterForEventType(.combinedSessionState, eventType: .keyDown))
            } else if type == .keyDown && state.isDown {
                if let action = state.otherKey() { onAction?(action) }
            }
            return false // All normal Control shortcuts continue to the foreground app.
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
        releaseRequiredFor = heldKey
        if finishHold { onAction?(.finishHold) }
    }

    func handleTapInterruption() {
        abandonHeldInput()
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    func stop() {
        abandonHeldInput()
        controlTimer?.invalidate(); controlTimer = nil
        installedKey = nil
        if let localMonitor { NSEvent.removeMonitor(localMonitor); self.localMonitor = nil }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes); self.source = nil }
        if let tap { CFMachPortInvalidate(tap); self.tap = nil }
    }
}
