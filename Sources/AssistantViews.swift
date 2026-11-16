import AppKit
import AVFoundation
import SwiftUI

// MARK: The companion

/// Which side of the cursor the companion sits on. It flips near the screen's edges.
@MainActor
final class CompanionPlacement: ObservableObject {
    @Published var right = true
    @Published var below = true

    var alignment: Alignment {
        switch (right, below) {
        case (true, true): return .topLeading
        case (false, true): return .topTrailing
        case (true, false): return .bottomLeading
        case (false, false): return .bottomTrailing
        }
    }
    var anchor: UnitPoint {
        switch (right, below) {
        case (true, true): return .topLeading
        case (false, true): return .topTrailing
        case (true, false): return .bottomLeading
        case (false, false): return .bottomTrailing
        }
    }
}

/// Murmur rides next to your cursor while you ask: a waveform while it listens,
/// a spinner while it works, each step ticking off the moment it's done, and the
/// answer in a small bubble. Click-through, and it never takes focus.
struct AssistantBubble: View {
    @ObservedObject var center: AssistantCenter
    @ObservedObject var speech: DictationEngine
    @ObservedObject var placement: CompanionPlacement
    /// The window it lives in; the card itself hugs its content in one corner.
    static let size = CGSize(width: 400, height: 380)
    static let snap = Animation.spring(response: 0.24, dampingFraction: 0.8)

    @MainActor init(center: AssistantCenter, speech: DictationEngine, placement: CompanionPlacement? = nil) {
        self.center = center; self.speech = speech; self.placement = placement ?? CompanionPlacement()
    }

    private enum Mode: Equatable { case hidden, listening, working, steps, answer, waiting, failed(String) }

    private var mode: Mode {
        switch center.phase {
        case .idle: return .hidden
        case .failed(let message): return .failed(message)
        case .listening: return .listening
        case .waiting: return .waiting
        case .thinking where center.ranLocally && !center.plannedSteps.isEmpty: return .steps
        case .done where center.ranLocally && !center.plannedSteps.isEmpty && center.answer.isEmpty: return .steps
        case .thinking: return .working
        case .answering, .done: return center.answer.isEmpty && center.outcomes.isEmpty ? .working : .answer
        }
    }

    var body: some View {
        ZStack(alignment: placement.alignment) {
            Color.clear
            if mode != .hidden {
                card.transition(.asymmetric(insertion: .scale(scale: 0.5, anchor: placement.anchor).combined(with: .opacity),
                                            removal: .opacity))
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .animation(Self.snap, value: mode == .hidden)
        .environment(\.colorScheme, .dark)
    }

    private var card: some View {
        Hug(maxWidth: 340) {
            content
                .padding(.horizontal, 12).padding(.vertical, 9)
        }
        .background(Color.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 17, style: .continuous).strokeBorder(.white.opacity(0.11), lineWidth: 0.8))
        .shadow(color: .black.opacity(0.32), radius: 14, y: 6)
        .animation(Self.snap, value: mode)
        .animation(Self.snap, value: center.stepAt)
        .animation(.easeOut(duration: 0.14), value: center.answer)
        .animation(.easeOut(duration: 0.12), value: liveLine)
        .padding(4)
    }

    @ViewBuilder private var content: some View {
        switch mode {
        case .hidden: EmptyView()
        case .listening:
            HStack(spacing: 9) {
                Waveform(level: center.isListening ? speech.level : 0, quiet: center.autoListening && speech.liveText.isEmpty)
                Text(liveLine.isEmpty ? listeningLabel : liveLine)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(liveLine.isEmpty ? 0.55 : 0.94))
                    .lineLimit(1).truncationMode(.head)
            }
        case .working:
            HStack(spacing: 9) {
                Spinner()
                Text(center.walkStep > 0 ? "Checking the screen" : center.sawScreen ? "Looking at your screen" : "Thinking")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.7))
            }
        case .steps:
            StepList(steps: center.plannedSteps, at: center.stepAt, gate: center.gateIndex, runsAt: center.runsAt,
                     finished: center.phase == .done, problem: center.outcomes.first?.problem)
        case .answer:
            VStack(alignment: .leading, spacing: 7) {
                if center.walkStep > 0 {
                    Text("Step \(center.walkStep + (center.phase.isWorking ? 1 : 0))")
                        .font(.system(size: 10.5, weight: .bold)).foregroundStyle(Companion.accent)
                        .contentTransition(.numericText())
                }
                if !center.answer.isEmpty {
                    Text(center.answer).font(.system(size: 13.5)).foregroundStyle(.white).lineSpacing(2.5)
                        .lineLimit(10).truncationMode(.head)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(center.outcomes) { outcome in
                    HStack(spacing: 7) {
                        StepGlyph(state: outcome.problem == nil ? .done : .failed)
                        Text(outcome.problem ?? outcome.title).font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.8)).lineLimit(2)
                    }
                }
            }
        case .waiting:
            HStack(spacing: 9) {
                Image(systemName: "cursorarrow.click.2").font(.system(size: 13, weight: .semibold)).foregroundStyle(Companion.gradient)
                Text("Your turn · click it").font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.85))
            }
        case .failed(let message):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.circle.fill").font(.system(size: 13)).foregroundStyle(Companion.amber)
                Text(message).font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.9)).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var liveLine: String {
        guard center.isListening else { return "" }
        return String(speech.liveText.trimmingCharacters(in: .whitespacesAndNewlines).suffix(140))
    }

    private var listeningLabel: String {
        if center.autoListening { return center.walkStep > 0 ? "Click it, or ask me something" : "Still listening" }
        return "Listening"
    }
}

enum Companion {
    static let accent = Color(hex: 0xA99BFF)
    static let amber = Color(hex: 0xF2B35B)
    static let green = Color(hex: 0x30D158)
    static let gradient = LinearGradient(colors: [Color(hex: 0xC4B5FF), Color(hex: 0x7C6CFF), Color(hex: 0x4F8BFF)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing)
}

/// The plan as a checklist: each step ticks off the moment it's done.
private struct StepList: View {
    let steps: [String]
    let at: Int
    let gate: Int?
    let runsAt: Date?
    let finished: Bool
    let problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                let state = state(index)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        StepGlyph(state: state)
                        Text(step).font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(state == .pending ? 0.42 : state == .done ? 0.72 : 0.96))
                            .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                    }
                    if state == .failed, let problem {
                        Text(problem).font(.system(size: 11.5)).foregroundStyle(Companion.amber)
                            .fixedSize(horizontal: false, vertical: true).padding(.leading, 23)
                    }
                }
            }
            if runsAt != nil {
                Text("esc to stop").font(.system(size: 10.5, weight: .medium)).foregroundStyle(.white.opacity(0.38))
                    .padding(.leading, 23).transition(.opacity)
            }
        }
    }

    private func state(_ index: Int) -> StepGlyph.State {
        if finished {
            if problem == nil { return .done }
            return index < at ? .done : index == at ? .failed : .pending
        }
        if index < at { return .done }
        if let runsAt, index == gate { return .countdown(runsAt) }
        return index == at ? .running : .pending
    }
}

/// One step's status: a dot, a spinner, the countdown before a click or typing, a tick, or a warning.
struct StepGlyph: View {
    enum State: Equatable { case pending, running, countdown(Date), done, failed }
    let state: State

    var body: some View {
        ZStack {
            switch state {
            case .pending:
                Circle().strokeBorder(.white.opacity(0.28), lineWidth: 1.4).frame(width: 9, height: 9)
            case .running:
                Spinner(size: 13)
            case .countdown(let runsAt):
                TimelineView(.animation) { context in
                    let left = max(0, runsAt.timeIntervalSince(context.date)) / AssistantCenter.previewTime
                    ZStack {
                        Circle().stroke(.white.opacity(0.14), lineWidth: 2)
                        Circle().trim(from: 0, to: 1 - left).stroke(Companion.gradient, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    .frame(width: 12, height: 12)
                }
            case .done:
                Image(systemName: "checkmark").font(.system(size: 7.5, weight: .heavy)).foregroundStyle(.white)
                    .frame(width: 15, height: 15).background(Companion.green, in: Circle())
                    .transition(.scale(scale: 0.3).combined(with: .opacity))
            case .failed:
                Image(systemName: "exclamationmark").font(.system(size: 8, weight: .heavy)).foregroundStyle(.black.opacity(0.8))
                    .frame(width: 15, height: 15).background(Companion.amber, in: Circle())
                    .transition(.scale(scale: 0.3).combined(with: .opacity))
            }
        }
        .frame(width: 15, height: 15)
        .accessibilityHidden(true)
    }
}

/// A small arc that spins.
struct Spinner: View {
    var size: CGFloat = 14
    var body: some View {
        TimelineView(.animation) { context in
            Circle().trim(from: 0.08, to: 0.78)
                .stroke(AngularGradient(colors: [Color(hex: 0x7C6CFF).opacity(0.1), Color(hex: 0xC4B5FF)], center: .center),
                        style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees((context.date.timeIntervalSinceReferenceDate * 1.3).truncatingRemainder(dividingBy: 1) * 360))
                .frame(width: size, height: size)
        }
        .frame(width: 15, height: 15)
        .accessibilityHidden(true)
    }
}

/// Five bars that move with your voice, and breathe a little when you're quiet.
struct Waveform: View {
    let level: Float
    var quiet = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 40)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2.5) {
                ForEach(0..<5, id: \.self) { bar in
                    Capsule().fill(Companion.gradient)
                        .frame(width: 3, height: height(bar, t))
                }
            }
            .frame(width: 25, height: 18)
        }
        .opacity(quiet ? 0.55 : 1)
        .animation(.linear(duration: 0.08), value: level)
        .accessibilityHidden(true)
    }

    private func height(_ bar: Int, _ t: TimeInterval) -> CGFloat {
        let shape: [CGFloat] = [0.55, 0.85, 1, 0.8, 0.6]
        let idle = (sin(t * 3.6 + Double(bar) * 0.8) + 1) / 2 * 2.5
        let voice = CGFloat(min(max(level, 0) * 1.6, 1)) * 13 * shape[bar] * CGFloat(0.75 + 0.25 * sin(t * 11 + Double(bar) * 1.7))
        return 4 + CGFloat(idle) + voice
    }
}

/// Sizes its content to its natural width, up to `maxWidth`, wrapping past that,
/// so a one-line state is a small pill and a long answer is a tidy bubble.
struct Hug: Layout {
    var maxWidth: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let view = subviews.first else { return .zero }
        let ideal = view.sizeThatFits(.unspecified)
        let width = min(ideal.width, maxWidth, proposal.width ?? .infinity)
        return view.sizeThatFits(ProposedViewSize(width: width, height: nil))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

/// Lays chips out in rows, wrapping as needed.
struct FlowRow: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += row + spacing; row = 0 }
            x += size.width + spacing; row = max(row, size.height)
        }
        return CGSize(width: width == .infinity ? x : width, height: y + row)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += row + spacing; row = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing; row = max(row, size.height)
        }
    }
}

// MARK: Pointing

/// Flies a cursor to what the answer is talking about, locks a ring onto it, and
/// shows Murmur's own clicks. Every frame is worked out from the clock (not left
/// to implicit animations), so it stays crisp and quick at 120 Hz. Lives in a
/// click-through window over each screen, so it never gets in your way.
@MainActor
final class PointerOverlay: ObservableObject {
    struct Mark: Identifiable, Equatable {
        let id = UUID()
        let point: CGPoint
        let label: String
        /// When the cursor gets there and the ring locks on.
        let lands: TimeInterval
    }
    /// One flight of the cursor, in global AppKit coordinates.
    struct Leg: Equatable {
        let from: CGPoint, to: CGPoint, start: TimeInterval, duration: TimeInterval
        var end: TimeInterval { start + duration }
    }
    struct Press: Equatable { let point: CGPoint; let at: TimeInterval; let ok: Bool }

    @Published private(set) var marks: [Mark] = []
    @Published private(set) var legs: [Leg] = []
    @Published private(set) var presses: [Press] = []
    @Published private(set) var clearedAt: TimeInterval?
    private var panels: [NSPanel] = []
    private var hideTask: Task<Void, Never>?

    nonisolated static var now: TimeInterval { CACurrentMediaTime() }
    /// How long a ring stays on its own before the cursor hops to the next one.
    static let dwell: TimeInterval = 0.42

    /// Off for the frame renderer, which draws without any windows.
    var onScreen = true

    func show(_ points: [(CGPoint, String)], now: TimeInterval = PointerOverlay.now, from mouse: CGPoint? = nil) {
        if clearedAt != nil { reset() }
        let new = points.dropFirst(marks.count)
        guard !new.isEmpty else { return }
        hideTask?.cancel()
        var from = legs.last?.to ?? mouse ?? NSEvent.mouseLocation
        var start = legs.last.map { max(now, $0.end + Self.dwell) } ?? now
        for (point, label) in new {
            let duration = Self.flightTime(from, point)
            legs.append(Leg(from: from, to: point, start: start, duration: duration))
            // The ring locks on as the cursor visibly arrives (the curve is ~95% there by then).
            marks.append(Mark(point: point, label: label, lands: start + duration * 0.6))
            from = point; start += duration + Self.dwell
        }
        bringForward()
    }

    /// Murmur pressed something (or refused to): show it right where it happened.
    func press(at point: CGPoint, ok: Bool, now: TimeInterval = PointerOverlay.now) {
        guard clearedAt == nil else { return }
        presses.append(Press(point: point, at: now, ok: ok))
        bringForward()
    }

    func clear(now: TimeInterval = PointerOverlay.now) {
        guard !marks.isEmpty || !presses.isEmpty, clearedAt == nil else { return }
        clearedAt = now
        guard onScreen else { return }
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .milliseconds(260))
            guard !Task.isCancelled else { return }
            reset()
            for panel in panels { panel.orderOut(nil) }
        }
    }

    func reset() { marks = []; legs = []; presses = []; clearedAt = nil }

    private func bringForward() {
        guard onScreen else { return }
        makePanels()
        for panel in panels { panel.orderFrontRegardless() }
    }

    /// Short hops are quick; long ones take a little longer, never sluggish.
    static func flightTime(_ a: CGPoint, _ b: CGPoint) -> TimeInterval {
        min(0.6, max(0.3, 0.24 + hypot(b.x - a.x, b.y - a.y) / 3800))
    }

    /// Where the cursor is at time `t` (global coordinates).
    func cursor(at t: TimeInterval) -> CGPoint? {
        guard let first = legs.first else { return nil }
        if t <= first.start { return first.from }
        for leg in legs where t < leg.end {
            return t < leg.start ? leg.from : Self.position(leg, t)
        }
        return legs.last?.to
    }

    /// A gentle arc, critically damped: leaves fast, lands without wobble.
    static func position(_ leg: Leg, _ t: TimeInterval) -> CGPoint {
        let p = Motion.clamp((t - leg.start) / leg.duration)
        let e = Motion.settle(p)
        let dx = leg.to.x - leg.from.x, dy = leg.to.y - leg.from.y, length = max(1, hypot(dx, dy))
        var nx = -dy / length, ny = dx / length
        if ny < 0 { nx = -nx; ny = -ny }                       // always bows upward
        let bend = min(140, length * 0.16)
        let c = CGPoint(x: (leg.from.x + leg.to.x) / 2 + nx * bend, y: (leg.from.y + leg.to.y) / 2 + ny * bend)
        let u = 1 - e
        return CGPoint(x: u * u * leg.from.x + 2 * u * e * c.x + e * e * leg.to.x,
                       y: u * u * leg.from.y + 2 * u * e * c.y + e * e * leg.to.y)
    }

    private func makePanels() {
        let frames = NSScreen.screens.map(\.frame)
        if panels.map(\.frame) == frames { return }
        for panel in panels { panel.orderOut(nil) }
        panels = frames.map { frame in
            let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = .statusBar
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            panel.backgroundColor = .clear; panel.isOpaque = false; panel.hasShadow = false
            panel.ignoresMouseEvents = true; panel.hidesOnDeactivate = false
            panel.contentView = NSHostingView(rootView: PointerScreen(overlay: self, frame: frame))
            panel.setFrame(frame, display: false)
            return panel
        }
    }
}

/// Small motion helpers, all pure functions of time.
enum Motion {
    static func clamp(_ x: Double, _ a: Double = 0, _ b: Double = 1) -> Double { min(b, max(a, x)) }
    /// Critically damped step, normalised to land exactly on 1.
    static func settle(_ p: Double, _ w: Double = 7.5) -> Double {
        guard p < 1 else { return 1 }
        return (1 - (1 + w * p) * exp(-w * p)) / (1 - (1 + w) * exp(-w))
    }
    /// Spring step response `dt` seconds after an event (0 → 1, may overshoot a little).
    static func spring(_ dt: Double, _ w: Double = 18, _ z: Double = 0.55) -> Double {
        guard dt > 0 else { return 0 }
        let wd = w * sqrt(1 - z * z)
        return 1 - exp(-z * w * dt) * (cos(wd * dt) + z / sqrt(1 - z * z) * sin(wd * dt))
    }
    static func easeOut(_ p: Double) -> Double { let q = clamp(p); return 1 - pow(1 - q, 3) }
}

private let pointerPurple = Color(hex: 0x8E7DFF)
private let pointerBlue = Color(hex: 0x7FB2FF)

private struct PointerScreen: View {
    @ObservedObject var overlay: PointerOverlay
    let frame: CGRect

    var body: some View {
        TimelineView(.animation(paused: overlay.marks.isEmpty && overlay.presses.isEmpty)) { _ in
            PointerFrame(overlay: overlay, frame: frame, t: PointerOverlay.now)
        }
        .frame(width: frame.width, height: frame.height, alignment: .topLeading)
        .allowsHitTesting(false)
    }
}

/// One frame of the overlay on one screen.
struct PointerFrame: View {
    let overlay: PointerOverlay
    let frame: CGRect
    let t: TimeInterval

    private func local(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x - frame.minX, y: frame.maxY - point.y) }
    private var fade: Double { overlay.clearedAt.map { 1 - Motion.easeOut((t - $0) / 0.22) } ?? 1 }

    /// How hard a press near `point` is squeezing right now (0…1), and whether it was refused.
    private func squeeze(near point: CGPoint) -> (Double, Press?) {
        guard let press = overlay.presses.last(where: { hypot($0.point.x - point.x, $0.point.y - point.y) < 40 && t >= $0.at }) else { return (0, nil) }
        guard press.ok else { return (0, press) }      // refused: it shakes instead
        let dt = t - press.at
        let amount = dt < 0.06 ? dt / 0.06 : 1 - Motion.spring(dt - 0.06, 24, 0.5)
        return (max(0, amount), press)
    }
    private typealias Press = PointerOverlay.Press

    var body: some View {
        let cursor = overlay.cursor(at: t)
        ZStack(alignment: .topLeading) {
            Canvas { context, _ in
                drawTrail(&context)
                for mark in overlay.marks where t >= mark.lands { drawShockwave(&context, mark) }
                for press in overlay.presses where t >= press.at { drawPress(&context, press) }
            }
            ForEach(overlay.marks) { mark in
                if t >= mark.lands, frame.insetBy(dx: -60, dy: -60).contains(mark.point) {
                    ring(mark).position(local(mark.point))
                }
            }
            if let cursor, frame.insetBy(dx: -2, dy: -2).contains(cursor), t >= (overlay.legs.first?.start ?? .infinity) {
                cursorView(cursor)
            }
        }
        .opacity(fade)
    }

    // MARK: Ring

    private func ring(_ mark: PointerOverlay.Mark) -> some View {
        let dt = t - mark.lands
        let lock = Motion.spring(dt, 22, 0.52)                   // snaps in from wide to tight
        let breath = dt > 0.55 ? sin((dt - 0.55) * .pi * 2 / 1.5) : 0
        let (squeeze, press) = squeeze(near: mark.point)
        let refused = press.map { !$0.ok } ?? false
        let pressAge = press.map { t - $0.at } ?? 9
        let shake = refused ? sin(pressAge * 46) * 7 * exp(-pressAge * 7) : 0
        let scale = (1.75 - 0.75 * lock) * (1 + 0.035 * breath) * (1 - 0.24 * squeeze)
        let tint = refused ? Color(hex: 0xF2B35B) : pointerPurple
        let labelPop = Motion.spring(dt - 0.07, 20, 0.55)
        let ok = press.map(\.ok) ?? false
        let check = ok ? Motion.spring(pressAge - 0.1, 20, 0.5) : 0
        return ZStack {
            Circle().fill(RadialGradient(colors: [tint.opacity(0.2 + 0.08 * breath), .clear], center: .center, startRadius: 22, endRadius: 52))
                .frame(width: 104, height: 104)
            Circle().fill(tint.opacity(0.08 + 0.45 * squeeze)).frame(width: 40, height: 40)
            Circle()
                .stroke(AngularGradient(colors: refused ? [tint, tint] : [pointerPurple, pointerBlue, Color(hex: 0xC59BFF), pointerPurple],
                                        center: .center, angle: .degrees(t * 120)), lineWidth: 3.2)
                .frame(width: 46, height: 46)
                .shadow(color: tint.opacity(0.7), radius: 8)
            if !mark.label.isEmpty || overlay.marks.count > 1 {
                Text(labelText(mark))
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 10).frame(height: 26)
                    .background(refused ? Color(hex: 0x9A6A22) : Color(hex: 0x5B4BDB), in: Capsule())
                    .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
                    .fixedSize()
                    .scaleEffect(0.6 + 0.4 * labelPop)
                    .opacity(Motion.clamp((dt - 0.07) / 0.1))
                    .offset(y: 40 - 8 * (1 - labelPop))
            }
            if check > 0 {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .heavy)).foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(Color(hex: 0x30D158), in: Circle())
                    .shadow(color: Color(hex: 0x30D158).opacity(0.6), radius: 6)
                    .scaleEffect(check)
                    .offset(x: 19, y: -19)
            }
        }
        .scaleEffect(scale)
        .opacity(Motion.clamp(dt / 0.08))
        .offset(x: shake)
    }

    private func labelText(_ mark: PointerOverlay.Mark) -> String {
        let number = overlay.marks.count > 1 ? (overlay.marks.firstIndex(of: mark).map { "\($0 + 1)" }) : nil
        return [number, mark.label.isEmpty ? nil : mark.label].compactMap { $0 }.joined(separator: " · ")
    }

    // MARK: Cursor

    private func cursorView(_ cursor: CGPoint) -> some View {
        let before = overlay.cursor(at: t - 1.0 / 120) ?? cursor
        let vx = (cursor.x - before.x) * 120, vy = (before.y - cursor.y) * 120   // screen space, y down
        let speed = hypot(vx, vy)
        // Lean the dart toward where it's flying (at rest it points up-left).
        var lean = 0.0
        if speed > 60 {
            var turn = atan2(vy, vx) * 180 / .pi + 128.7
            turn = (turn + 540).truncatingRemainder(dividingBy: 360) - 180
            lean = Motion.clamp(turn * 0.4 * Motion.clamp(speed / 1600), -28, 28)
        }
        let (squeeze, _) = squeeze(near: cursor)
        let start = overlay.legs.first?.start ?? t
        // Once it lands, the cursor steps aside so you can see the control, and
        // darts back in to press it.
        var park = 0.0, sinceLanding = 9.0
        if let landed = overlay.legs.last(where: { $0.start + $0.duration * 0.6 <= t }) {
            sinceLanding = t - landed.start - landed.duration * 0.6
            park = Motion.spring(sinceLanding - 0.05, 15, 0.75)
            if let next = overlay.legs.first(where: { $0.start > landed.start }) { park *= 1 - Motion.clamp((t - next.start) / 0.09) }
        }
        if let press = overlay.presses.last(where: { $0.ok && t >= $0.at && hypot($0.point.x - cursor.x, $0.point.y - cursor.y) < 40 }) {
            let age = t - press.at
            park *= age < 0.06 ? 1 - Motion.easeOut(age / 0.06) : Motion.spring(age - 0.3, 14, 0.75)
        }
        var spot = local(cursor)
        spot.x += 31 * park; spot.y += 6 * park
        let appear = Motion.spring(t - start, 20, 0.6)
        // The name tag rides along in flight and while parked; it ducks out of the
        // way when the cursor is on the target, so it never covers the label.
        let flying = overlay.legs.contains { t >= $0.start && t < $0.start + $0.duration * 0.6 }
        let tag = flying ? 1 : max(1 - Motion.clamp(sinceLanding / 0.08), Motion.clamp(park))
        return AgentCursor(speed: speed, squeeze: squeeze, lean: lean, shimmer: t, tag: tag)
            .scaleEffect(0.5 + 0.5 * appear, anchor: UnitPoint(x: AgentCursor.tip.x / AgentCursor.box.width, y: AgentCursor.tip.y / AgentCursor.box.height))
            .opacity(Motion.clamp((t - start) / 0.08))
            .position(x: spot.x - AgentCursor.tip.x + AgentCursor.box.width / 2, y: spot.y - AgentCursor.tip.y + AgentCursor.box.height / 2)
    }

    // MARK: Canvas effects

    private func drawTrail(_ context: inout GraphicsContext) {
        guard let leg = overlay.legs.first(where: { t > $0.start && t < $0.end + 0.12 }) else { return }
        var previous = local(PointerOverlay.position(leg, min(t, leg.end)))
        for k in 1...12 {
            let tk = max(leg.start, min(t, leg.end) - Double(k) * 0.011)
            let point = local(PointerOverlay.position(leg, tk))
            let fresh = 1 - Double(k) / 12
            let speed = hypot(point.x - previous.x, point.y - previous.y) / 0.011
            let alpha = 0.5 * fresh * Motion.clamp(speed / 900) * (1 - Motion.clamp((t - leg.end) / 0.12))
            if alpha > 0.01 {
                var path = Path(); path.move(to: previous); path.addLine(to: point)
                context.stroke(path, with: .color(Color(hex: 0xB9ADFF).opacity(alpha)),
                               style: StrokeStyle(lineWidth: 2 + 7 * fresh, lineCap: .round))
            }
            previous = point
        }
    }

    private func drawShockwave(_ context: inout GraphicsContext, _ mark: PointerOverlay.Mark) {
        let center = local(mark.point)
        for k in 0..<2 {
            let q = (t - mark.lands - Double(k) * 0.09) / 0.5
            guard q > 0, q < 1 else { continue }
            let radius = 23 * (1 + 1.5 * Motion.easeOut(q))
            context.stroke(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)),
                           with: .color(Color(hex: 0xB9ADFF).opacity(0.75 * (1 - q))), lineWidth: 0.5 + 2.5 * (1 - q))
        }
    }

    private func drawPress(_ context: inout GraphicsContext, _ press: Press) {
        let center = local(press.point), dt = t - press.at
        let color = press.ok ? Color.white : Color(hex: 0xF2B35B)
        // two quick ripples
        for k in 0..<2 {
            let q = (dt - Double(k) * 0.07) / 0.42
            guard q > 0, q < 1 else { continue }
            let radius = 20 * (1 + 2 * Motion.easeOut(q))
            context.stroke(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)),
                           with: .color((k == 0 ? color : pointerPurple).opacity(0.85 * (1 - q))), lineWidth: 0.5 + 3 * (1 - q))
        }
        // sparks, only for a real press
        guard press.ok else { return }
        let q = dt / 0.36
        guard q > 0, q < 1 else { return }
        let e = Motion.easeOut(q)
        for k in 0..<8 {
            let angle = Double(k) * .pi / 4 + .pi / 8
            let r0 = 26 + 24 * e, r1 = r0 + 11 * (1 - q)
            var path = Path()
            path.move(to: CGPoint(x: center.x + cos(angle) * r0, y: center.y + sin(angle) * r0))
            path.addLine(to: CGPoint(x: center.x + cos(angle) * r1, y: center.y + sin(angle) * r1))
            context.stroke(path, with: .color(Color(hex: 0xD9D1FF).opacity(1 - q)), style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
        }
    }
}

/// Murmur's own pointer: a gradient dart with a name tag, so it never looks like
/// your mouse. The tip is the exact spot it means.
struct AgentCursor: View {
    let speed: Double
    let squeeze: Double
    let lean: Double
    let shimmer: Double
    var tag: Double = 1

    static let box = CGSize(width: 120, height: 64)
    static let tip = CGPoint(x: 6, y: 6)
    private static let gradient = LinearGradient(colors: [Color(hex: 0xC4B5FF), Color(hex: 0x7C6CFF), Color(hex: 0x4F8BFF)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing)

    var body: some View {
        let stretch = 1 + min(0.14, speed / 20000)
        let tipAnchor = UnitPoint(x: Self.tip.x / Self.box.width, y: Self.tip.y / Self.box.height)
        ZStack(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                DartShape().fill(Color(hex: 0x7C6CFF).opacity(0.55)).blur(radius: 7 + min(6, speed / 450))
                DartShape().fill(Self.gradient)
                DartShape().fill(LinearGradient(colors: [.white.opacity(0.55), .clear], startPoint: .topLeading, endPoint: UnitPoint(x: 0.55, y: 0.6)))
                DartShape().stroke(.white, style: StrokeStyle(lineWidth: 1.8, lineJoin: .round))
            }
            .frame(width: 24, height: 26)
            .shadow(color: .black.opacity(0.35), radius: 2.5, y: 1.5)
            .offset(x: Self.tip.x - 1.5, y: Self.tip.y - 1.5)
            .scaleEffect(stretch * (1 - 0.22 * squeeze), anchor: tipAnchor)
            .rotationEffect(.degrees(lean), anchor: tipAnchor)

            nameTag
                .offset(x: Self.tip.x + 17, y: Self.tip.y + 22)
                .scaleEffect(tagScale, anchor: tipAnchor)
                .opacity(tag)
        }
        .frame(width: Self.box.width, height: Self.box.height, alignment: .topLeading)
    }

    private var tagScale: Double { (0.7 + 0.3 * tag) * (1 - 0.08 * squeeze) }

    private var nameTag: some View {
        let dot: Double = 0.75 + 0.25 * sin(shimmer * 5)
        return HStack(spacing: 5) {
            Circle().fill(Color.white).frame(width: 5, height: 5).opacity(dot)
            Text("Murmur").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.white)
        }
        .padding(.horizontal, 8).frame(height: 20)
        .background(Self.gradient, in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.35), lineWidth: 0.8))
        .shadow(color: Color(hex: 0x7C6CFF).opacity(0.5), radius: 6)
        .fixedSize()
    }
}

/// A sleek arrowhead, tip at the top-left corner (1.5, 1.5) of a 24×26 box.
struct DartShape: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 24, sy = rect.height / 26
        func p(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: rect.minX + x * sx, y: rect.minY + y * sy) }
        var path = Path()
        path.move(to: p(1.5, 1.5))
        path.addLine(to: p(8.2, 23.6))
        path.addQuadCurve(to: p(10.4, 23.2), control: p(9.3, 24.6))
        path.addLine(to: p(12.4, 14.6))
        path.addLine(to: p(21.4, 12.4))
        path.addQuadCurve(to: p(21.5, 10.2), control: p(22.6, 11.3))
        path.closeSubpath()
        return path
    }
}

// MARK: Settings

/// Settings → Ask → Voice: Murmur's natural voice, or the Mac's own.
struct VoiceSettings: View {
    @ObservedObject var center: AssistantCenter
    @ObservedObject var natural: NaturalVoice
    private let macVoices = AssistantCenter.voices()

    var body: some View {
        Section("Voice") {
            Picker("Voice", selection: $center.naturalVoice) {
                Text("Murmur’s natural voice").tag(true)
                Text("Mac system voice").tag(false)
            }.pickerStyle(.radioGroup)
            if center.naturalVoice {
                natural.isAvailable ? AnyView(naturalRows) : AnyView(Text("This build doesn’t include the voice helper. Run Tools/BuildLocalSpeech.sh, then build again.")
                    .font(.system(size: 12)).foregroundStyle(Palette.muted))
            } else {
                Picker("Mac voice", selection: $center.voiceID) {
                    Text("Best available").tag("")
                    ForEach(macVoices, id: \.identifier) { voice in
                        Text(voice.name + (voice.quality == .premium ? " (Premium)" : voice.quality == .enhanced ? " (Enhanced)" : "")).tag(voice.identifier)
                    }
                }
                LabeledContent {
                    Button("Listen") { center.preview(voice: center.voiceID) }
                } label: {
                    Text("Sounds robotic?")
                    Text("Switch to Murmur’s natural voice above, or download a Premium voice in System Settings → Accessibility → Spoken Content.")
                }
            }
        }
    }

    @ViewBuilder private var naturalRows: some View {
        switch natural.state {
        case .notInstalled, .failed:
            LabeledContent {
                Button("Download") { natural.install() }
            } label: {
                Text("Download the voice")
                Text(failure ?? "A one-time download of about 400 MB. It runs on this Mac: nothing you hear is made online.")
            }
        case .installing(let fraction):
            LabeledContent {
                ProgressView(value: fraction).frame(width: 140)
            } label: {
                Text("Downloading the voice…")
                Text("\(Int(fraction * 100))% · you can keep using Murmur")
            }
        case .starting, .ready:
            Picker("Speaker", selection: $center.naturalVoiceID) {
                ForEach(NaturalVoice.choices) { choice in
                    Text("\(choice.name) · \(choice.note)").tag(choice.id)
                }
            }
            LabeledContent {
                Button(natural.isSpeaking ? "Stop" : "Listen") {
                    if natural.isSpeaking { natural.stop() } else { natural.warm(); center.previewNatural(center.naturalVoiceID) }
                }
            } label: {
                Text("Hear it")
                Text(natural.state == .ready ? "Made on this Mac in a fraction of a second." : "The first sentence takes a moment while the voice loads.")
            }
        }
    }

    private var failure: String? { if case .failed(let message) = natural.state { return message }; return nil }
}

/// Settings → Ask: who answers, which model, and the voice.
struct AssistantSettings: View {
    @ObservedObject var center: AssistantCenter
    @State private var status: AssistantStatus?
    @State private var screenAllowed = ScreenGrab.allowed
    private let voices = AssistantCenter.voices()

    var body: some View {
        Group { sections }
            .task(id: center.provider) { status = nil; status = await AssistantStatus.check(center.provider) }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                screenAllowed = ScreenGrab.allowed
            }
    }

    @ViewBuilder private var sections: some View {
        Section {
            Toggle(isOn: $center.enabled) {
                Text("Ask about your screen")
                Text("Hold Space + ↓ and talk: ask about your screen, or tell it what to do (“open Slack, go to general and type I’m in”). Things it can do itself happen instantly; questions go to your ChatGPT or Claude plan.")
            }
        } footer: {
            Text("When you ask, that one screenshot and your words go to \(center.provider == .chatgpt ? "OpenAI" : "Anthropic") through your own \(center.provider.rawValue) plan. Your voice is turned into words on this Mac, and nothing is sent at any other time.")
                .font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
        }
        Section("Who answers") {
            Picker("Service", selection: $center.provider) {
                ForEach(AssistantProvider.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
            Picker("Model", selection: Binding(get: { center.model }, set: { center.model = $0 })) {
                ForEach(center.provider.models) { choice in
                    VStack(alignment: .leading) {
                        Text(choice.name)
                        Text(choice.note).font(.system(size: 11)).foregroundStyle(Palette.muted)
                    }.tag(choice.id)
                }
            }.pickerStyle(.radioGroup)
            LabeledContent {
                Button("Check again") { Task { status = nil; status = await AssistantStatus.check(center.provider) } }
            } label: {
                if let status {
                    Label {
                        Text(status.title)
                        Text(status.detail)
                    } icon: {
                        Image(systemName: status.ready ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(status.ready ? Palette.green : Palette.star)
                    }
                } else {
                    Text("Checking \(center.provider.appName)…")
                }
            }
        }
        Section("Seeing and speaking") {
            LabeledContent {
                if screenAllowed { Text("Allowed").foregroundStyle(Palette.green) }
                else { Button("Allow…") { ScreenGrab.requestAccess() } }
            } label: {
                Text("Screen Recording")
                Text(screenAllowed ? "Murmur captures the display under your pointer when you ask, and deletes it after the answer."
                                   : "Needed to see your screen. Without it, Ask still answers, without looking.")
            }
            Toggle("Speak answers", isOn: $center.speaks)
            Toggle(isOn: $center.keepsListening) {
                Text("Keep listening after answers")
                Text("Listens a few more seconds so you can just keep talking. Stay quiet and it closes.")
            }
            Toggle(isOn: $center.clicks) {
                Text("Let Ask click for you")
                Text("Name it when you ask (“turn on Wi-Fi”, “click Save”). It never clicks Send, Buy, Delete or anything like them.")
            }
        }
        if center.speaks { VoiceSettings(center: center, natural: center.natural) }
        if !center.recent.isEmpty {
            Section {
                LabeledContent("\(center.recent.count) recent question\(center.recent.count == 1 ? "" : "s")") {
                    Button("Clear") { center.clearRecent() }
                }
            } footer: {
                Text("Recent questions and answers are kept on this Mac, on the Home page.").font(.system(size: 11)).foregroundStyle(Palette.muted)
            }
        }
    }
}
