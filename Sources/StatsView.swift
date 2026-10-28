import SwiftUI
import Charts

/// Insights: how much you've dictated, how fast you speak, and the time it saved.
struct StatsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var preferences: Preferences
    @Environment(\.dismiss) private var dismiss
    @State private var hovered: Date?
    /// Computed once per change, not on every hover.
    @State private var stats = LibraryStats([], typingSpeed: 40)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Insights").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction).buttonStyle(PrimaryButtonStyle())
            }.padding(.horizontal, 24).frame(height: 54)
            Hairline()
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 12) {
                    tile("Words this week", stats.weekWords.formatted())
                    tile("All time", stats.totalWords.formatted(), detail: "\(stats.dictations.formatted()) dictations")
                    tile("Speaking pace", stats.speakingPace.map { "\($0) wpm" } ?? "—",
                         detail: "Typing: \(preferences.typingSpeed) wpm")
                    tile("Time saved", duration(stats.minutesSaved), detail: "vs. typing")
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("Words per day · last 14 days").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.muted)
                    chart(stats.days)
                }
                HStack(spacing: 10) {
                    Text("Your typing speed").font(.system(size: 12.5)).foregroundStyle(Palette.muted)
                    Stepper("\(preferences.typingSpeed) wpm", value: $preferences.typingSpeed, in: 10...150, step: 5)
                        .font(.system(size: 12.5)).fixedSize()
                    Spacer()
                }
            }.padding(24)
        }
        .frame(width: 720, height: 500)
        .onAppear { recompute() }
        .onChange(of: preferences.typingSpeed) { _, _ in recompute() }
        .onChange(of: model.transcripts.count) { _, _ in recompute() }
        .background(Palette.canvas)
        .foregroundStyle(Palette.ink)
    }

    private func recompute() { stats = LibraryStats(model.transcripts, typingSpeed: preferences.typingSpeed) }

    private func tile(_ title: String, _ value: String, detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11.5)).foregroundStyle(Palette.muted)
            Text(value).font(.system(size: 24, weight: .semibold)).tracking(-0.5).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(detail ?? " ").font(.system(size: 11)).foregroundStyle(Palette.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Palette.sidebar, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.line))
    }

    private func chart(_ days: [LibraryStats.Day]) -> some View {
        Chart {
            ForEach(days) { day in
                BarMark(x: .value("Day", day.date, unit: .day), y: .value("Words", day.words), width: .ratio(0.55))
                    .foregroundStyle(Palette.accent.opacity(hovered == nil || hovered == day.date ? 1 : 0.45))
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4, style: .continuous))
                    .accessibilityLabel(day.date.formatted(.dateTime.weekday(.wide).month().day()))
                    .accessibilityValue("\(day.words) words")
            }
            if let hovered, let day = days.first(where: { $0.date == hovered }) {
                RuleMark(x: .value("Day", day.date, unit: .day))
                    .foregroundStyle(Palette.line).lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(day.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                                .font(.system(size: 11)).foregroundStyle(Palette.muted)
                            Text("\(day.words.formatted()) words").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Palette.ink)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 6)
                        .background(Palette.canvas, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Palette.line))
                    }
            }
        }
        .chartXSelection(value: Binding(get: { hovered }, set: { value in
            hovered = value.map { Calendar.current.startOfDay(for: $0) }
        }))
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: 2)) { _ in
                AxisValueLabel(format: .dateTime.month(.abbreviated).day()).foregroundStyle(Palette.muted)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine().foregroundStyle(Palette.line)
                AxisValueLabel().foregroundStyle(Palette.muted)
            }
        }
        .frame(height: 220)
    }

    private func duration(_ minutes: Int) -> String {
        minutes < 60 ? "\(minutes) min" : String(format: "%.1f h", Double(minutes) / 60)
    }
}
