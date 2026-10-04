import Foundation
import CoreGraphics

@main struct FnTests {
    @MainActor static func main() {
        var key = FnKeyState()
        key.press(behavior: .hold, busy: false)
        assert(key.release() == nil) // A short tap never creates an empty recording.
        key.press(behavior: .hold, busy: false)
        assert(key.thresholdReached() == .startHold)
        assert(key.thresholdReached() == nil)
        assert(key.release() == .finishHold)
        key.press(behavior: .hold, busy: false)
        assert(key.otherKey() == nil)
        assert(key.thresholdReached() == nil && key.release() == nil)
        key.press(behavior: .hold, busy: false)
        assert(key.thresholdReached() == .startHold)
        assert(key.otherKey() == .cancelHold)
        assert(key.release() == nil)
        key.press(behavior: .hold, busy: false)
        assert(key.space() == .toggle && key.release() == nil)
        key.press(behavior: .hold, busy: false)
        assert(key.thresholdReached() == .startHold)
        assert(key.space() == .latchHold && key.release() == nil)
        key.press(behavior: .hold, busy: true)
        assert(key.space() == .toggle && key.release() == nil)
        key.press(behavior: .hold, busy: true)
        assert(key.thresholdReached() == nil && key.release() == .finishHold)
        key.press(behavior: .toggle, busy: false)
        assert(key.release() == .toggle)
        key.press(behavior: .toggle, busy: true)
        assert(key.thresholdReached() == .toggle && key.release() == nil)
        key.reset()
        assert(!key.isDown && !key.didTrigger && !key.isChord)
        let shortcut = FnShortcut()
        var actions: [FnKeyState.Action] = []
        shortcut.onAction = { actions.append($0) }
        let spaceDown = CGEvent(keyboardEventSource: nil, virtualKey: 49, keyDown: true)!
        spaceDown.flags = .maskSecondaryFn
        assert(shortcut.handle(type: .keyDown, event: spaceDown))
        assert(actions == [.toggle])
        // Key repeat must not flip recording straight back off.
        assert(shortcut.handle(type: .keyDown, event: spaceDown))
        assert(actions == [.toggle])
        let spaceUp = CGEvent(keyboardEventSource: nil, virtualKey: 49, keyDown: false)!
        spaceUp.flags = .maskSecondaryFn
        assert(shortcut.handle(type: .keyUp, event: spaceUp))
        let fnUp = CGEvent(keyboardEventSource: nil, virtualKey: 63, keyDown: false)!
        fnUp.flags = []
        assert(shortcut.handle(type: .flagsChanged, event: fnUp))
        assert(actions == [.toggle])
        shortcut.isBusy = { true }
        assert(shortcut.handle(type: .keyDown, event: spaceDown))
        assert(actions == [.toggle, .toggle])
        shortcut.stop()
        let control = FnShortcut()
        control.trigger = { .control }
        var controlTime: TimeInterval = 20
        control.clock = { controlTime }
        var controlActions: [FnKeyState.Action] = []
        control.onAction = { controlActions.append($0) }
        control.sampleControl(flags: .maskControl, keyDownCount: 100)
        assert(controlActions.isEmpty)
        control.sampleControl(flags: [], keyDownCount: 100)
        assert(controlActions.isEmpty) // Short taps in hold mode never start hands-free recording.
        control.sampleControl(flags: [], keyDownCount: 100)
        assert(controlActions.isEmpty)
        control.sampleControl(flags: .maskControl, keyDownCount: 100)
        control.sampleControl(flags: .maskControl, keyDownCount: 101)
        control.sampleControl(flags: [], keyDownCount: 101)
        assert(controlActions.isEmpty) // Control+C and any normal key chord are ignored.
        control.sampleControl(flags: [.maskControl, .maskShift], keyDownCount: 101)
        control.sampleControl(flags: [], keyDownCount: 101)
        assert(controlActions.isEmpty)
        control.sampleControl(flags: .maskControl, keyDownCount: 101)
        control.sampleControl(flags: [], keyDownCount: 101)
        assert(controlActions.isEmpty)
        control.sampleControl(flags: [], keyDownCount: 101)
        control.sampleControl(flags: .maskControl, keyDownCount: 102)
        control.sampleControl(flags: [], keyDownCount: 102)
        assert(controlActions.isEmpty) // A whole chord within the first polling interval is ignored.
        control.behavior = { .toggle }
        control.sampleControl(flags: .maskControl, keyDownCount: 102)
        control.sampleControl(flags: [], keyDownCount: 102)
        assert(controlActions == [.toggle]) // Hands-free remains explicitly available in toggle mode.
        control.sampleControl(flags: [], keyDownCount: 102)
        assert(controlActions == [.toggle])
        control.behavior = { .hold }
        control.resetInput(); controlActions = []
        control.sampleControl(flags: .maskControl, keyDownCount: 102)
        controlTime += FnShortcut.controlHoldDelay + 0.001
        control.sampleControl(flags: .maskControl, keyDownCount: 102)
        assert(controlActions == [.startHold])
        control.sampleControl(flags: .maskControl, keyDownCount: 102)
        assert(controlActions == [.startHold])
        control.sampleControl(flags: [], keyDownCount: 102)
        assert(controlActions == [.startHold, .finishHold]) // Release stops the same held session.
        control.sampleControl(flags: [], keyDownCount: 102)
        assert(controlActions == [.startHold, .finishHold])
        control.resetInput(); controlActions = []
        control.sampleControl(flags: .maskControl, keyDownCount: 102)
        controlTime += 0.2
        control.sampleControl(flags: .maskControl, keyDownCount: 102)
        control.sampleControl(flags: .maskControl, keyDownCount: 103)
        control.sampleControl(flags: [], keyDownCount: 103)
        assert(controlActions == [.startHold, .cancelHold]) // A late Control chord never delivers dictation.
        control.resetInput(); controlActions = []; control.isBusy = { true }
        control.sampleControl(flags: .maskControl, keyDownCount: 103)
        controlTime += 0.2
        control.sampleControl(flags: .maskControl, keyDownCount: 103)
        control.sampleControl(flags: [], keyDownCount: 103)
        assert(controlActions == [.finishHold]) // Tap to end hands-free never starts another session.
        control.stop()
        var timestamp: TimeInterval = 10
        shortcut.clock = { timestamp }
        shortcut.isBusy = { false }
        var signals: [Bool] = []
        shortcut.onFnSignal = { signals.append($0) }
        actions = []
        let fnDown = CGEvent(keyboardEventSource: nil, virtualKey: 63, keyDown: true)!
        fnDown.flags = .maskSecondaryFn
        assert(shortcut.handle(type: .flagsChanged, event: fnDown))
        timestamp += 0.06
        assert(shortcut.handle(type: .flagsChanged, event: fnUp))
        assert(actions.isEmpty && signals == [true, false])
        timestamp += 0.1
        assert(shortcut.handle(type: .flagsChanged, event: fnDown))
        assert(actions == [.toggle])
        timestamp += 0.05
        assert(shortcut.handle(type: .flagsChanged, event: fnUp))
        assert(actions == [.toggle]) // Releasing the second tap leaves hands-free recording running.
        shortcut.isBusy = { true }
        timestamp += 1
        assert(shortcut.handle(type: .flagsChanged, event: fnDown))
        assert(shortcut.handle(type: .flagsChanged, event: fnUp))
        assert(actions == [.toggle, .finishHold])
        shortcut.resetInput()
        shortcut.isBusy = { false }
        actions = []
        timestamp += 1
        assert(shortcut.handle(type: .flagsChanged, event: fnDown))
        assert(shortcut.handle(type: .flagsChanged, event: fnUp))
        timestamp += 0.5
        assert(shortcut.handle(type: .flagsChanged, event: fnDown))
        assert(shortcut.handle(type: .flagsChanged, event: fnUp))
        assert(actions.isEmpty) // Separate taps must not be mistaken for a double-tap.
        shortcut.stop()
        print("PASS: Fn hold/release, short taps, autorepeat, normal Fn chords, Fn+Space, latching, hands-free stop, toggle mode")
        print("PASS: Fn+Space event decoding without Fn-down, repeat suppression, key releases, and hands-free stop")
        print("PASS: Fn double-tap hands-free start, release latching, stop gesture, timing, and actual-signal callbacks")
        print("PASS: Control hold/release, ignored short taps, explicit toggle mode, immediate release, global modifier polling, duplicate suppression, and early/late Control chords")
    }
}
