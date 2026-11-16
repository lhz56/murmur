import SwiftUI

/// The first thing you see: Murmur's three keys, and what you did recently.
struct HomeView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var assistant: AssistantCenter
    @ObservedObject var meetings: MeetingCenter
    @State private var stats = LibraryStats([], typingSpeed: 40)

    private var talkKeys: [String] {
        model.preferences.fnEnabled && model.fnAvailable ? [model.preferences.dictationKey.keyCap] : ["⌃", "⌥", "Space"]
    }
    private var talkHow: String {
        model.preferences.fnEnabled && model.fnAvailable
            ? (model.preferences.fnBehavior == .hold ? "Hold" : "Tap") : "Press"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(Self.greeting()).font(.system(size: 30, weight: .semibold)).tracking(-0.4)
                    Text("Talk to type, ask about your screen, or tell your Mac what to do.")
                        .font(.system(size: 14)).foregroundStyle(Palette.muted)
                }
                HStack(alignment: .top, spacing: 14) {
                    KeyCard(title: "Talk", line: "\(talkHow) and speak. Your words appear wherever you’re typing.",
                            keys: talkKeys, symbol: "waveform", tint: Color(hex: 0x3B82F6), action: "Try it") { model.toggleRecording() }
                    KeyCard(title: "Ask", line: assistant.enabled ? "Hold and ask about anything on your screen. It answers out loud and points."
                                                                  : "Turned off. Switch it on in Settings → Ask.",
                            keys: ["Space", "↑"], symbol: "eye", tint: Color(hex: 0x8B5CF6), action: assistant.enabled ? "Try it" : "Turn on",
                            featured: true) {
                        if assistant.enabled { model.askNow?() } else { model.settingsPane = .assistant; model.showSettings = true }
                    }
                    KeyCard(title: "Do", line: "Open apps, play music, set timers, control your Mac. Type or hold and say it.",
                            keys: ["Space", "↓"], symbol: "command", tint: Color(hex: 0x10B981), action: "Open") { model.openCommands?() }
                }
                if meetings.liveID != nil {
                    Button { model.section = .meetings; meetings.selectedID = meetings.liveID } label: {
                        HStack(spacing: 10) {
                            LivePulse()
                            Text("Taking meeting notes").font(.system(size: 13, weight: .semibold))
                            Text("Open the live transcript").font(.system(size: 13)).foregroundStyle(Palette.muted)
                            Spacer()
                            Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.faint)
                        }.padding(14).background(Palette.wash, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }.buttonStyle(.plain)
                }
                recent
                statsLine
            }
            .padding(.horizontal, 44).padding(.top, 58).padding(.bottom, 32)
            .frame(maxWidth: 960, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Palette.canvas)
        .onAppear(perform: recompute)
        .onChange(of: model.transcripts.count) { _, _ in recompute() }
    }

    private func recompute() { stats = LibraryStats(model.transcripts, typingSpeed: model.preferences.typingSpeed) }

    // MARK: Recent

    private enum Item: Identifiable {
        case ask(AssistantCenter.Ask)
        case dictation(Transcript)
        var id: UUID { switch self { case .ask(let ask): return ask.id; case .dictation(let entry): return entry.id } }
        var date: Date { switch self { case .ask(let ask): return ask.date; case .dictation(let entry): return entry.createdAt } }
    }

    private var items: [Item] {
        let asks = assistant.recent.prefix(6).map(Item.ask)
        let dictations = model.transcripts.lazy.filter { $0.deletedAt == nil && $0.status == .complete && !$0.text.isEmpty }
            .prefix(6).map(Item.dictation)
        return (asks + dictations).sorted { $0.date > $1.date }.prefix(8).map { $0 }
    }

    @ViewBuilder private var recent: some View {
        let items = items
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Recent").font(.system(size: 13, weight: .semibold))
                Spacer()
                if !model.transcripts.isEmpty {
                    Button("All dictations") { model.section = .transcripts; model.filter = .all }.buttonStyle(QuietButtonStyle())
                }
            }
            if items.isEmpty {
                Text("Nothing yet. Your dictations and questions show up here.")
                    .font(.system(size: 13)).foregroundStyle(Palette.muted)
                    .frame(maxWidth: .infinity, minHeight: 90)
                    .background(Palette.wash.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { Hairline().padding(.leading, 50) }
                        row(item)
                    }
                }
                .background(Palette.canvas, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.line, lineWidth: 1))
            }
        }
    }

    @ViewBuilder private func row(_ item: Item) -> some View {
        switch item {
        case .ask(let ask):
            RecentRow(symbol: "eye", tint: Color(hex: 0x8B5CF6), title: ask.question, detail: ask.answer,
                      meta: ask.date.formatted(.relative(presentation: .named))) { model.copy(ask.answer) }
                .help("Click to copy the answer")
        case .dictation(let entry):
            RecentRow(symbol: "waveform", tint: Color(hex: 0x3B82F6), title: entry.title, detail: entry.text,
                      meta: [entry.sourceApp.isEmpty ? nil : entry.sourceApp, entry.createdAt.formatted(.relative(presentation: .named))]
                        .compactMap { $0 }.joined(separator: " · ")) {
                model.section = .transcripts; model.filter = .all; model.selectedID = entry.id
            }
        }
    }

    @ViewBuilder private var statsLine: some View {
        if stats.totalWords > 0 {
            HStack(spacing: 6) {
                Image(systemName: "chart.bar").font(.system(size: 11))
                Text("\(stats.weekWords.formatted()) words this week · about \(stats.minutesSaved.formatted()) minutes saved in all")
                Spacer()
                Button("Insights") { model.showStats = true }.buttonStyle(QuietButtonStyle())
            }.font(.system(size: 12)).foregroundStyle(Palette.muted)
        }
    }

    static func greeting(now: Date = Date()) -> String {
        switch Calendar.current.component(.hour, from: now) {
        case 5..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        case 17..<22: return "Good evening"
        default: return "Hello"
        }
    }
}

/// One of the three keys: what it does, and its shortcut.
private struct KeyCard: View {
    let title: String
    let line: String
    let keys: [String]
    let symbol: String
    let tint: Color
    let action: String
    var featured = false
    let perform: () -> Void
    @State private var hovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(tint)
                    .frame(width: 34, height: 34).background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                Spacer()
                ShortcutKeys(keys: keys)
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(title).font(.system(size: 17, weight: .semibold))
                    if featured {
                        Text("New").font(.system(size: 10, weight: .bold)).foregroundStyle(tint)
                            .padding(.horizontal, 6).frame(height: 17).background(tint.opacity(0.12), in: Capsule())
                    }
                }
                Text(line).font(.system(size: 12.5)).foregroundStyle(Palette.muted).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button(action: perform) {
                Text(action).font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.ink)
                    .padding(.horizontal, 12).frame(height: 26)
                    .background(Palette.wash, in: Capsule())
            }.buttonStyle(.plain)
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 196, alignment: .topLeading)
        .background(Palette.canvas, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(featured ? AnyShapeStyle(LinearGradient(colors: [tint.opacity(0.55), tint.opacity(0.12)], startPoint: .topLeading, endPoint: .bottomTrailing))
                                   : AnyShapeStyle(Palette.line), lineWidth: featured ? 1.5 : 1))
        .shadow(color: .black.opacity(hovered ? 0.07 : 0.03), radius: hovered ? 14 : 6, y: hovered ? 6 : 2)
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.15), value: hovered)
    }
}

private struct RecentRow: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String
    let meta: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(tint)
                    .frame(width: 26, height: 26).background(tint.opacity(0.1), in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        Spacer(minLength: 8)
                        Text(meta).font(.system(size: 11)).foregroundStyle(Palette.faint).lineLimit(1)
                    }
                    Text(detail).font(.system(size: 12.5)).foregroundStyle(Palette.muted).lineLimit(2)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 11)
            .background(hovered ? Palette.hover.opacity(0.6) : .clear)
            .contentShape(Rectangle())
        }.buttonStyle(.plain).onHover { hovered = $0 }
    }
}
