import SwiftUI
import Charts
import AppKit

/// Mac Health: a page of its own. One score for how the Mac is doing, a checkup in
/// plain words from your AI account, every vital live, the last hour, what's using
/// it, what Murmur itself is holding, and what to do about it.
struct MacHealthView: View {
    @ObservedObject var health: MacHealth
    @ObservedObject var preferences: Preferences
    var assistant: AssistantCenter?
    var live = true
    @State var metric = Metric.disk
    @State private var hovered: Date?
    @State private var clearedMessage: String?
    @State private var checkup = ""
    @State private var checking = false
    @State private var checkupFailed: String?
    @State private var shown = false
    @State private var spins = 0.0

    init(health: MacHealth, preferences: Preferences, assistant: AssistantCenter? = nil, live: Bool = true, metric: Metric = .disk, checkup: String = "") {
        self.health = health; self.preferences = preferences; self.assistant = assistant; self.live = live
        _metric = State(initialValue: metric)
        // A still picture (the screen renderer) starts with the ring already filled.
        _shown = State(initialValue: !live)
        _checkup = State(initialValue: checkup)
    }

    enum Metric: String, CaseIterable, Identifiable {
        case disk = "Free disk", swap = "Swap used"
        var id: String { rawValue }
    }

    private struct Status { var color: Color; var symbol: String; var label: String }

    private var status: Status {
        switch health.reading.level {
        case .ok: return Status(color: Palette.green, symbol: "checkmark.circle.fill", label: "Healthy")
        case .warning: return Status(color: Palette.star, symbol: "exclamationmark.triangle.fill", label: "Keep an eye on it")
        case .danger: return Status(color: Palette.red, symbol: "exclamationmark.octagon.fill", label: "At risk")
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                hero
                if let sample = health.sample {
                    vitals(sample)
                    trendCard(sample)
                }
                HStack(alignment: .top, spacing: 16) {
                    if !health.biggest.isEmpty { usageCard(title: "Using the most memory", symbol: "memorychip", rows: health.biggest, memory: true) }
                    if !health.busiest.isEmpty { usageCard(title: "Working the hardest", symbol: "flame", rows: health.busiest, memory: false) }
                }
                murmurCard
                if let sample = health.sample { explainer(sample) }
                actionsCard
            }
            .padding(.horizontal, 32).padding(.top, 30).padding(.bottom, 36)
            .frame(maxWidth: 940)
            .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
        .background(Palette.canvas)
        .onAppear { withAnimation(.spring(response: 1.1, dampingFraction: 0.86).delay(0.1)) { shown = true } }
        .task {
            // Everything stays live while this page is open.
            guard live else { return }
            var round = 0
            while !Task.isCancelled {
                await health.check()
                if round % 3 == 0 {
                    await health.refreshBiggest()
                    await health.refreshDetail()
                }
                round += 1
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("Mac Health").font(.system(size: 24, weight: .bold))
            if live {
                HStack(spacing: 5) {
                    LivePulse()
                    Text("Live").font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.muted)
                }
            }
            Spacer()
            if let vitals = health.vitals {
                Text("Up \(Self.uptime(vitals.uptime)) · \(ProcessInfo.processInfo.processorCount) cores · \(MacHealthRules.gb(vitals.memoryTotal).replacingOccurrences(of: ".0 GB", with: " GB")) memory")
                    .font(.system(size: 11.5)).foregroundStyle(Palette.muted)
            }
            refreshButton
        }
    }

    /// One click (or ⌘R) reads everything again, right now.
    private var refreshButton: some View {
        Button(action: refresh) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.clockwise").font(.system(size: 11.5, weight: .semibold))
                    .rotationEffect(.degrees(spins * 360))
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(health.refreshing ? "Refreshing" : Self.updated(health.updatedAt, now: context.date))
                        .font(.system(size: 11.5, weight: .medium)).monospacedDigit()
                        .contentTransition(.numericText())
                }
            }
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 11).frame(height: 28)
            .background(Palette.wash, in: Capsule())
            .overlay(Capsule().strokeBorder(Palette.line))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .keyboardShortcut("r", modifiers: .command)
        .help("Refresh now (⌘R)")
        .accessibilityLabel("Refresh")
    }

    private func refresh() {
        withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) { spins += 1 }
        Task { await health.refresh() }
    }

    static func updated(_ date: Date?, now: Date) -> String {
        guard let date else { return "Refresh" }
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 3 { return "Just now" }
        if seconds < 60 { return "\(seconds)s ago" }
        return "\(seconds / 60)m ago"
    }

    static func uptime(_ seconds: TimeInterval) -> String {
        let days = Int(seconds / 86400), hours = Int(seconds.truncatingRemainder(dividingBy: 86400) / 3600)
        return days > 0 ? "\(days)d \(hours)h" : "\(hours)h \(Int(seconds.truncatingRemainder(dividingBy: 3600) / 60))m"
    }

    // MARK: Score and checkup

    private var hero: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 26) {
                Button(action: refresh) {
                    ScoreRing(score: shown ? (health.score ?? 0) : 0, color: status.color, waiting: health.score == nil)
                        .frame(width: 148, height: 148)
                        .scaleEffect(health.refreshing ? 0.96 : 1)
                        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: health.refreshing)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Click to refresh")
                VStack(alignment: .leading, spacing: 8) {
                    Label(status.label, systemImage: status.symbol)
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(status.color)
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(status.color.opacity(0.13), in: Capsule())
                    Text(health.reading.title).font(.system(size: 21, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(health.reading.detail).font(.system(size: 13)).foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    if assistant != nil {
                        Button(action: runCheckup) {
                            HStack(spacing: 6) {
                                Image(systemName: "sparkles").symbolEffect(.pulse, isActive: checking)
                                Text(checking ? "Checking…" : checkup.isEmpty ? "Run a checkup" : "Check again")
                            }
                            .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 14).frame(height: 30)
                            .background(LinearGradient(colors: [Color(hex: 0x7C6CFF), Color(hex: 0x4F8BFF)], startPoint: .leading, endPoint: .trailing),
                                        in: Capsule())
                            .shadow(color: Color(hex: 0x7C6CFF).opacity(0.35), radius: 8, y: 3)
                        }
                        .buttonStyle(.plain).disabled(checking || health.sample == nil)
                        .padding(.top, 4)
                        .help("Your AI account reads these numbers and tells you what matters")
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(22)
            if checking || !checkup.isEmpty || checkupFailed != nil { checkupPanel.transition(.opacity.combined(with: .move(edge: .top))) }
        }
        .background {
            ZStack {
                Palette.sidebar
                RadialGradient(colors: [status.color.opacity(0.16), .clear], center: UnitPoint(x: 0.12, y: 0.35), startRadius: 10, endRadius: 360)
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(status.color.opacity(0.22)))
        .animation(.spring(response: 0.35, dampingFraction: 0.86), value: checkup.isEmpty)
        .animation(.spring(response: 0.35, dampingFraction: 0.86), value: checking)
    }

    private var checkupPanel: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: checkupFailed == nil ? "sparkles" : "exclamationmark.circle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(checkupFailed == nil ? Color(hex: 0x7C6CFF) : Palette.star)
                .frame(width: 26, height: 26)
                .background((checkupFailed == nil ? Color(hex: 0x7C6CFF) : Palette.star).opacity(0.13), in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text("Checkup").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.muted)
                if let checkupFailed {
                    Text(checkupFailed).font(.system(size: 13)).foregroundStyle(Palette.ink)
                } else if checkup.isEmpty {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Reading your Mac’s numbers…").font(.system(size: 13)).foregroundStyle(Palette.muted)
                    }
                } else {
                    Text(checkup).font(.system(size: 13.5)).foregroundStyle(Palette.ink).lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        .contentTransition(.opacity)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22).padding(.vertical, 16)
        .background(Palette.canvas.opacity(0.55))
        .overlay(alignment: .top) { Rectangle().fill(Palette.line).frame(height: 1) }
        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 18, bottomTrailingRadius: 18, style: .continuous))
    }

    private func runCheckup() {
        guard let assistant, !checking else { return }
        checking = true; checkup = ""; checkupFailed = nil
        Task {
            await health.refreshBiggest()
            await health.refreshDetail()
            do {
                let text = try await assistant.checkup(health.summary) { partial in
                    withAnimation(.easeOut(duration: 0.15)) { checkup = partial }
                }
                checkup = text
                if text.isEmpty { checkupFailed = "The checkup came back empty. Try again." }
            } catch {
                checkupFailed = "Couldn’t run a checkup: \(error.localizedDescription) Set up Ask in Settings to use your ChatGPT or Claude account."
            }
            checking = false
        }
    }

    // MARK: Vitals

    private func vitals(_ sample: HealthSample) -> some View {
        let gigabyte = MacHealthRules.gigabyte
        let used = sample.totalDisk > sample.freeDisk ? sample.totalDisk - sample.freeDisk : 0
        let swapShare = sample.swapTotal > 0 ? Double(sample.swapUsed) / Double(sample.swapTotal) : 0
        let diskTint = sample.freeDisk < 5 * gigabyte ? Palette.red : sample.freeDisk < 15 * gigabyte ? Palette.star : Color(hex: 0x4F8BFF)
        let swapTint = swapShare > 0.8 ? (sample.freeDisk < 20 * gigabyte ? Palette.red : Palette.star) : Color(hex: 0x8E7DFF)
        let critical = sample.pressure >= 4, high = sample.pressure >= 2
        let vitals = health.vitals
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 14)], spacing: 14) {
            if let vitals {
                let cpuTint = vitals.cpu > 0.85 ? Palette.red : vitals.cpu > 0.6 ? Palette.star : Color(hex: 0x30B0C7)
                VitalTile(title: "CPU", symbol: "cpu", tint: cpuTint, value: "\(Int((vitals.cpu * 100).rounded()))%",
                          caption: vitals.cpu > 0.85 ? "Working flat out" : vitals.cpu > 0.6 ? "Busy" : "Plenty to spare") {
                    Sparkline(values: health.pulse.map(\.cpu), tint: cpuTint).frame(height: 34)
                }
                let memoryTint = critical ? Palette.red : high ? Palette.star : Color(hex: 0xAF52DE)
                VitalTile(title: "Memory", symbol: "memorychip", tint: memoryTint,
                          value: MacHealthRules.gb(vitals.memoryUsed), unit: "of \(MacHealthRules.gb(vitals.memoryTotal))",
                          caption: critical ? "Pressure critical" : high ? "Pressure high" : "Pressure normal") {
                    SplitBar(parts: [(Double(vitals.appMemory), memoryTint), (Double(vitals.wired), memoryTint.opacity(0.6)),
                                     (Double(vitals.compressed), memoryTint.opacity(0.32))], total: Double(vitals.memoryTotal))
                    HStack(spacing: 10) {
                        legend("Apps", memoryTint); legend("System", memoryTint.opacity(0.6)); legend("Compressed", memoryTint.opacity(0.32))
                    }
                }
            }
            VitalTile(title: "Disk", symbol: "internaldrive", tint: diskTint, value: MacHealthRules.gb(sample.freeDisk), unit: "free",
                      caption: sample.totalDisk > 0 ? "\(Int(Double(used) / Double(sample.totalDisk) * 100))% of \(Int(Double(sample.totalDisk) / Double(gigabyte))) GB used" : "") {
                SplitBar(parts: [(Double(used), diskTint)], total: Double(max(sample.totalDisk, 1)))
            }
            VitalTile(title: "Swap", symbol: "arrow.left.arrow.right", tint: swapTint, value: MacHealthRules.gb(sample.swapUsed),
                      unit: sample.swapTotal > 0 ? "of \(MacHealthRules.gb(sample.swapTotal))" : nil,
                      caption: sample.swapTotal > 0 ? "Memory kept on disk" : "Not in use") {
                SplitBar(parts: [(Double(sample.swapUsed), swapTint)], total: Double(max(sample.swapTotal, 1)))
            }
            if let battery = vitals?.battery {
                let tint = battery.percent <= 15 && !battery.pluggedIn ? Palette.red : battery.percent <= 30 && !battery.pluggedIn ? Palette.star : Color(hex: 0x34C759)
                VitalTile(title: "Battery", symbol: battery.charging ? "battery.100percent.bolt" : "battery.75percent", tint: tint,
                          value: "\(battery.percent)%", unit: battery.charging ? "charging" : battery.pluggedIn ? "plugged in" : battery.minutesLeft.map { "\($0 / 60)h \($0 % 60)m left" },
                          caption: [battery.health.map { "Holds \($0)% of new" }, battery.cycles.map { "\($0) cycles" }].compactMap { $0 }.joined(separator: " · ")) {
                    SplitBar(parts: [(Double(battery.percent), tint)], total: 100)
                }
            }
            if let vitals {
                let tint = [Color(hex: 0x30B0C7), Palette.star, Color(hex: 0xFF9500), Palette.red][min(max(vitals.thermal, 0), 3)]
                VitalTile(title: "Temperature", symbol: "thermometer.medium", tint: tint, value: vitals.thermalLabel,
                          caption: vitals.thermal >= 2 ? "macOS is slowing things down to cool off" : "Running at full speed") {
                    HStack(spacing: 4) {
                        ForEach(0..<4, id: \.self) { step in
                            Capsule().fill(step <= vitals.thermal ? tint : Palette.line).frame(height: 6)
                        }
                    }
                }
            }
        }
    }

    private func legend(_ name: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(name).font(.system(size: 10)).foregroundStyle(Palette.muted)
        }
    }

    // MARK: The last hour

    private func gb(_ sample: HealthSample) -> Double {
        Double(metric == .disk ? sample.freeDisk : sample.swapUsed) / Double(MacHealthRules.gigabyte)
    }

    private func trendCard(_ sample: HealthSample) -> some View {
        let points = health.trend
        let top = max(metric == .disk ? 40 : 2, (points.map(gb).max() ?? 0) * 1.2)
        let latest = points.last?.date ?? sample.date
        let earliest = min(points.first?.date ?? latest, latest.addingTimeInterval(-600))
        let shown = hovered.flatMap { time in points.min { abs($0.date.timeIntervalSince(time)) < abs($1.date.timeIntervalSince(time)) } }
        let tint = metric == .disk ? Color(hex: 0x4F8BFF) : Color(hex: 0x8E7DFF)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("The last hour").font(.system(size: 14, weight: .semibold))
                    Text(readout(shown ?? sample, hovering: shown != nil)).font(.system(size: 11.5)).foregroundStyle(Palette.muted)
                        .monospacedDigit()
                }
                Spacer()
                Picker("Chart", selection: $metric) {
                    ForEach(Metric.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            if points.count < 2 {
                ContentUnavailableView {
                    Label("Collecting", systemImage: "chart.line.uptrend.xyaxis")
                } description: {
                    Text("The chart fills in over the next few minutes.")
                }
                .frame(height: 180)
            } else {
                Chart {
                    ForEach(points, id: \.date) { point in
                        AreaMark(x: .value("Time", point.date), yStart: .value("Base", 0), yEnd: .value(metric.rawValue, gb(point)))
                            .interpolationMethod(.monotone)
                            .foregroundStyle(LinearGradient(colors: [tint.opacity(0.28), tint.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                        LineMark(x: .value("Time", point.date), y: .value(metric.rawValue, gb(point)))
                            .interpolationMethod(.monotone)
                            .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
                            .foregroundStyle(tint)
                    }
                    if metric == .disk {
                        RuleMark(y: .value("Warning", 15))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            .foregroundStyle(Palette.star)
                            .annotation(position: .bottom, alignment: .leading, spacing: 2) {
                                Text("Warns below 15 GB").font(.system(size: 10)).foregroundStyle(Palette.muted)
                            }
                    }
                    if let shown {
                        RuleMark(x: .value("Time", shown.date)).lineStyle(StrokeStyle(lineWidth: 1)).foregroundStyle(Palette.faint)
                        PointMark(x: .value("Time", shown.date), y: .value(metric.rawValue, gb(shown)))
                            .symbolSize(60).foregroundStyle(tint)
                    }
                }
                .chartXSelection(value: $hovered)
                .chartXScale(domain: earliest...latest)
                .chartYScale(domain: 0...top)
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                        AxisGridLine().foregroundStyle(Palette.line)
                        AxisValueLabel { if let number = value.as(Double.self) { Text("\(Int(number)) GB") } }
                            .foregroundStyle(Palette.muted)
                    }
                }
                .chartXAxis {
                    // Set in from both ends so the first and last labels aren't clipped.
                    AxisMarks(values: [1.0, 3, 5].map { earliest.addingTimeInterval(latest.timeIntervalSince(earliest) * $0 / 6) }) { _ in
                        AxisValueLabel(format: .dateTime.hour().minute()).foregroundStyle(Palette.muted)
                    }
                }
                .frame(height: 180)
                .accessibilityLabel("\(metric.rawValue) over the last hour")
            }
        }
        .padding(18)
        .modifier(HealthCard())
    }

    private func readout(_ sample: HealthSample, hovering: Bool) -> String {
        let value = MacHealthRules.gb(metric == .disk ? sample.freeDisk : sample.swapUsed)
        return hovering ? "\(value) at \(sample.date.formatted(date: .omitted, time: .shortened))" : "\(value) now"
    }

    // MARK: What's using it

    private func usageCard(title: String, symbol: String, rows: [HealthProcess], memory: Bool) -> some View {
        let largest = Double(max(rows.first?.footprint ?? 1, 1))
        let tint = memory ? Color(hex: 0xAF52DE) : Color(hex: 0xFF9500)
        return VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: symbol).font(.system(size: 14, weight: .semibold)).labelStyle(TintedLabel(tint: tint))
            ForEach(rows) { process in
                HStack(spacing: 10) {
                    AppGlyph(name: process.name)
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(process.name).font(.system(size: 12.5)).lineLimit(1)
                            Spacer()
                            Text(memory ? MacHealthRules.gb(process.footprint) : "\(Int((Double(process.footprint) / 100).rounded()))%")
                                .font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.muted).monospacedDigit()
                                .contentTransition(.numericText())
                        }
                        GeometryReader { space in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Palette.line)
                                Capsule().fill(LinearGradient(colors: [tint.opacity(0.7), tint], startPoint: .leading, endPoint: .trailing))
                                    .frame(width: max(4, space.size.width * Double(process.footprint) / largest))
                            }
                        }
                        .frame(height: 5)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            if !memory {
                Text("100% is one core working flat out.").font(.system(size: 10.5)).foregroundStyle(Palette.faint)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .modifier(HealthCard())
        .animation(.easeOut(duration: 0.3), value: rows)
    }

    // MARK: Murmur itself

    private var murmurCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                WaveMark(size: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Murmur on this Mac").font(.system(size: 14, weight: .semibold))
                    Text("What Murmur itself is holding, so it’s never the thing slowing you down.")
                        .font(.system(size: 11.5)).foregroundStyle(Palette.muted)
                }
                Spacer()
                if health.murmurMemory > 0 {
                    Text(MacHealthRules.gb(health.murmurMemory)).font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
                }
            }
            if health.loadedModels.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "moon.zzz").foregroundStyle(Palette.muted).frame(width: 24)
                    Text("No on-Mac AI model is in memory right now. Space + ↓ loads it when you use it.")
                        .font(.system(size: 12)).foregroundStyle(Palette.muted)
                }
            }
            ForEach(health.loadedModels) { model in
                HStack(spacing: 10) {
                    Image(systemName: "brain").font(.system(size: 13)).foregroundStyle(Color(hex: 0x7C6CFF))
                        .frame(width: 24, height: 24).background(Color(hex: 0x7C6CFF).opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("On-Mac AI · \(model.name)").font(.system(size: 12.5))
                        Text("\(MacHealthRules.gb(model.bytes)) in memory" + (model.until.map { " · lets go \($0.formatted(.relative(presentation: .named)))" } ?? "")
                             + ". Keeps Space + ↓ instant.")
                            .font(.system(size: 11)).foregroundStyle(Palette.muted)
                    }
                    Spacer()
                    Button("Free it") { Task { await health.unload(model) } }
                        .help("Frees this memory now. The next Space + ↓ takes a moment longer while it loads again.")
                }
            }
        }
        .padding(18)
        .modifier(HealthCard())
    }

    // MARK: How it works

    private func explainer(_ sample: HealthSample) -> some View {
        let stage = MacHealthRules.stage(sample, level: health.reading.level)
        let steps: [(symbol: String, title: String, detail: String)] = [
            ("memorychip", "Memory fills", "Apps in use"),
            ("arrow.down.doc", "Swap takes over", "Overflow goes to disk"),
            ("internaldrive", "Swap needs disk", "It grows as it fills"),
            ("pause.circle", "Apps freeze", "macOS stops them")
        ]
        return VStack(alignment: .leading, spacing: 14) {
            Text("How a Mac freezes").font(.system(size: 14, weight: .semibold))
            HStack(alignment: .top, spacing: 0) {
                ForEach(steps.indices, id: \.self) { index in
                    let active = index == stage
                    let reached = index <= stage
                    VStack(spacing: 7) {
                        HStack(spacing: 0) {
                            Rectangle().fill(index == 0 ? .clear : reached ? status.color : Palette.line).frame(height: 2)
                            ZStack {
                                Circle().fill(active ? status.color.opacity(0.16) : Palette.wash)
                                Image(systemName: steps[index].symbol).font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(active ? status.color : reached ? Palette.ink : Palette.faint)
                            }
                            .frame(width: 36, height: 36)
                            .overlay(Circle().strokeBorder(active ? status.color : .clear, lineWidth: 1.5))
                            Rectangle().fill(index == steps.count - 1 ? .clear : index < stage ? status.color : Palette.line).frame(height: 2)
                        }
                        Text(steps[index].title).font(.system(size: 11.5, weight: active ? .semibold : .regular))
                            .foregroundStyle(reached ? Palette.ink : Palette.muted)
                            .multilineTextAlignment(.center).lineLimit(1)
                        Text(active ? "You’re here" : steps[index].detail).font(.system(size: 10.5, weight: active ? .medium : .regular))
                            .foregroundStyle(active ? status.color : Palette.muted).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(active ? .isSelected : [])
                }
            }
            Text("Your Mac keeps extra memory in swap files on its disk, so a full disk becomes a memory problem. Murmur watches all three and warns you before step four.")
                .font(.system(size: 11.5)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .modifier(HealthCard())
    }

    // MARK: Actions

    private var actionsCard: some View {
        VStack(spacing: 0) {
            actionRow(symbol: "sparkles", tint: Color(hex: 0x7C6CFF), title: "Clear developer caches",
                      detail: clearedMessage ?? "Xcode build files and Homebrew, Swift, pip and npm downloads. Apps rebuild these when they need them. Your files aren’t touched.") {
                Button(health.clearing ? "Clearing…" : "Clear") {
                    Task {
                        let freed = await health.clearCaches()
                        clearedMessage = "Cleared \(MacHealthRules.gb(freed))."
                    }
                }
                .disabled(health.clearing)
            }
            Hairline().padding(.leading, 52)
            actionRow(symbol: "externaldrive", tint: Color(hex: 0x4F8BFF), title: "See what’s on your disk", detail: "Open Storage in System Settings.") {
                Button("Open") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.settings.Storage")!)
                }
            }
            Hairline().padding(.leading, 52)
            actionRow(symbol: "gauge.with.dots.needle.67percent", tint: Color(hex: 0xFF9500), title: "See every process",
                      detail: "Open Activity Monitor.") {
                Button("Open") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
                }
            }
            Hairline().padding(.leading, 52)
            actionRow(symbol: "bell.badge", tint: Palette.green, title: "Warn me before my Mac runs out of room",
                      detail: "Checks every 15 seconds in the background. Nothing leaves your Mac.") {
                Toggle("Warn me", isOn: $preferences.macHealth).labelsHidden().toggleStyle(.switch)
            }
        }
        .padding(.vertical, 4)
        .modifier(HealthCard())
    }

    private func actionRow<Control: View>(symbol: String, tint: Color, title: String, detail: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 13, weight: .medium)).foregroundStyle(tint)
                .frame(width: 28, height: 28).background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12.5, weight: .medium))
                Text(detail).font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            control()
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }
}

// MARK: Pieces

/// The score: a ring that fills to it, colored by how things stand.
private struct ScoreRing: View {
    var score: Int
    var color: Color
    var waiting: Bool

    var body: some View {
        ZStack {
            Circle().fill(color.opacity(0.18)).blur(radius: 26).scaleEffect(0.8)
            Circle().stroke(Palette.line, lineWidth: 12)
            Circle().trim(from: 0, to: Double(score) / 100)
                .stroke(AngularGradient(colors: [color.opacity(0.55), color, color], center: .center, startAngle: .degrees(0), endAngle: .degrees(360 * Double(max(score, 1)) / 100)),
                        style: StrokeStyle(lineWidth: 12, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: color.opacity(0.4), radius: 6)
            VStack(spacing: 0) {
                Text(waiting ? "–" : "\(score)").font(.system(size: 44, weight: .bold, design: .rounded))
                    .contentTransition(.numericText(value: Double(score)))
                    .monospacedDigit()
                Text("health score").font(.system(size: 10.5, weight: .medium)).foregroundStyle(Palette.muted)
            }
        }
        .padding(6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Health score \(score) of 100")
    }
}

/// One vital: what it is, the number, a line about it, and a small picture of it.
private struct VitalTile<Picture: View>: View {
    let title: String
    let symbol: String
    let tint: Color
    let value: String
    var unit: String?
    var caption: String
    @ViewBuilder var picture: Picture

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(tint)
                    .frame(width: 26, height: 26).background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                Text(title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Palette.muted)
                Spacer(minLength: 0)
            }
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(value).font(.system(size: 24, weight: .semibold, design: .rounded))
                    .contentTransition(.numericText()).lineLimit(1).minimumScaleFactor(0.7)
                if let unit { Text(unit).font(.system(size: 12)).foregroundStyle(Palette.muted).lineLimit(1) }
            }
            VStack(alignment: .leading, spacing: 6) { picture }
            Spacer(minLength: 0)
            Text(caption).font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(1)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: 162)
        .modifier(HealthCard())
        .animation(.easeOut(duration: 0.35), value: value)
        .accessibilityElement(children: .combine)
    }
}

/// A bar split into parts of a whole.
private struct SplitBar: View {
    var parts: [(Double, Color)]
    var total: Double

    var body: some View {
        GeometryReader { space in
            HStack(spacing: 2) {
                ForEach(parts.indices, id: \.self) { index in
                    let share = total > 0 ? min(1, max(0, parts[index].0 / total)) : 0
                    Capsule().fill(parts[index].1).frame(width: max(share > 0 ? 4 : 0, space.size.width * share))
                }
                Spacer(minLength: 0)
            }
            .background(Capsule().fill(Palette.line))
            .clipShape(Capsule())
        }
        .frame(height: 8)
        .animation(.spring(response: 0.6, dampingFraction: 0.85), value: parts.map(\.0))
        .accessibilityHidden(true)
    }
}

/// The recent values as a soft line.
private struct Sparkline: View {
    var values: [Double]
    var tint: Color

    var body: some View {
        GeometryReader { space in
            let points = Self.points(values, in: space.size)
            ZStack {
                if points.count > 1 {
                    Path { path in
                        path.move(to: CGPoint(x: points[0].x, y: space.size.height))
                        points.forEach { path.addLine(to: $0) }
                        path.addLine(to: CGPoint(x: points.last!.x, y: space.size.height))
                    }
                    .fill(LinearGradient(colors: [tint.opacity(0.25), tint.opacity(0)], startPoint: .top, endPoint: .bottom))
                    Path { path in path.addLines(points) }
                        .stroke(tint, style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                    Circle().fill(tint).frame(width: 6, height: 6).position(points.last!)
                } else {
                    Capsule().fill(Palette.line).frame(height: 2)
                }
            }
        }
        .accessibilityHidden(true)
    }

    static func points(_ values: [Double], in size: CGSize) -> [CGPoint] {
        let recent = Array(values.suffix(45))
        guard recent.count > 1 else { return [] }
        // Scaled to the recent peak (never tighter than a quarter), so a quiet Mac still shows its rhythm.
        let top = max(0.25, (recent.max() ?? 0) * 1.25)
        let step = size.width / CGFloat(44)
        let start = size.width - step * CGFloat(recent.count - 1)
        return recent.enumerated().map { index, value in
            CGPoint(x: start + step * CGFloat(index), y: size.height - 3 - CGFloat(min(max(value / top, 0), 1)) * (size.height - 6))
        }
    }
}

private struct TintedLabel: LabelStyle {
    var tint: Color
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.icon.foregroundStyle(tint).font(.system(size: 12, weight: .semibold))
            configuration.title
        }
    }
}

/// The running app's own icon, or a plain symbol for background processes.
private struct AppGlyph: View {
    var name: String
    var body: some View {
        if let icon = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == name })?.icon {
            Image(nsImage: icon).resizable().frame(width: 26, height: 26)
        } else {
            Image(systemName: name == "Web pages" ? "safari" : "gearshape.2")
                .font(.system(size: 13)).foregroundStyle(Palette.muted)
                .frame(width: 26, height: 26).background(Palette.wash, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }
}

private struct HealthCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Palette.sidebar, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Palette.line))
    }
}

/// The sidebar entry: the score sits where the counts do, and a warning shows its color.
struct HealthSidebarItem: View {
    @ObservedObject var health: MacHealth
    var selected: Bool
    let action: () -> Void

    var body: some View {
        SidebarItem(title: "Mac Health", symbol: health.reading.level == .ok ? "heart.text.square" : "exclamationmark.triangle",
                    selected: selected, badge: health.score.map { "\($0)" }, action: action)
            .overlay(alignment: .leading) {
                if health.reading.level > .ok {
                    Circle().fill(health.reading.level == .danger ? Palette.red : Palette.star).frame(width: 6, height: 6)
                        .offset(x: 21, y: -6)
                }
            }
    }
}
