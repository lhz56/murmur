import SwiftUI
import AppKit

/// Sidebar · transcript list · page.
struct MainView: View {
    @ObservedObject var model: AppModel
    @FocusState private var searchFocused: Bool
    @FocusState private var listFocused: Bool

    var body: some View {
        // Filter once per render; rows, headers and keyboard navigation share it.
        let visible = model.visibleTranscripts
        HStack(spacing: 0) {
            SidebarView(model: model, speech: model.speech).frame(width: 228)
            Hairline(vertical: true)
            listColumn(visible).frame(width: 312)
            Hairline(vertical: true)
            Group {
                if let entry = model.selected {
                    TranscriptPage(model: model, entry: entry).id(entry.id)
                } else {
                    EmptyPage(model: model)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Palette.canvas)
        .foregroundStyle(Palette.ink)
        .frame(minWidth: 980, minHeight: 640)
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                ToastView(message: toast).padding(.bottom, 20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.88), value: model.toast)
        .sheet(isPresented: $model.showSettings) {
            SettingsView(model: model, preferences: model.preferences, speech: model.speech, microphoneCheck: model.microphoneCheck)
        }
        .sheet(isPresented: $model.showStats) { StatsView(model: model, preferences: model.preferences) }
        .sheet(isPresented: $model.showOnboarding) {
            OnboardingView(model: model, preferences: model.preferences, speech: model.speech)
        }
        .alert("Murmur needs your attention", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
            Button("Open Settings") { model.errorMessage = nil; model.showSettings = true }
        } message: { Text(model.errorMessage ?? "") }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refreshPermissions() }
        .onReceive(NotificationCenter.default.publisher(for: .murmurSearch)) { _ in searchFocused = true }
    }

    // MARK: List column

    private func listColumn(_ visible: [Transcript]) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.filter.rawValue).font(.system(size: 13, weight: .semibold))
                    Text(caption(count: visible.count)).font(.system(size: 11)).foregroundStyle(Palette.muted)
                        .contentTransition(.numericText())
                }
                Spacer(minLength: 8)
                IconButton(symbol: "square.and.arrow.down", help: "Import audio") { model.importAudio() }
                    .disabled(model.speech.phase.isBusy)
                IconButton(symbol: "square.and.arrow.up", help: "Export library") { model.export() }
            }.padding(.leading, 16).padding(.trailing, 8).frame(height: 52)
            SearchField(text: $model.search, focused: $searchFocused).padding(.horizontal, 10).padding(.bottom, 6)
                .onSubmit { if LibrarySearch.isQuestion(model.search), LocalModel.isAvailable { model.ask(model.search) } }
            if LibrarySearch.isQuestion(model.search) || model.answer?.question == model.search {
                AskPanel(model: model).padding(.horizontal, 10).padding(.bottom, 8)
            }
            if visible.isEmpty {
                EmptyList(searching: !model.search.isEmpty, filter: model.filter)
            } else {
                transcriptList(visible)
            }
        }.background(Palette.canvas)
    }

    private func caption(count: Int) -> String {
        let noun = "transcript\(count == 1 ? "" : "s")"
        if !model.search.isEmpty { return "\(count) matching" }
        if model.filter == .trash { return count == 0 ? "Empty" : "\(count) deleted \(noun)" }
        return "\(count) \(noun)"
    }

    private func transcriptList(_ visible: [Transcript]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1, pinnedViews: [.sectionHeaders]) {
                    ForEach(DaySection.group(visible)) { section in
                        Section {
                            ForEach(section.entries) { entry in row(entry).id(entry.id) }
                        } header: {
                            Text(section.label).font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.muted)
                                .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 5)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Palette.canvas)
                        }
                    }
                }.padding(.horizontal, 8).padding(.bottom, 12)
            }
            .scrollIndicators(.automatic)
            .focusable().focused($listFocused).focusEffectDisabled()
            .onKeyPress(.upArrow) { moveSelection(-1, in: visible) }
            .onKeyPress(.downArrow) { moveSelection(1, in: visible) }
            .onKeyPress(.escape) {
                guard model.selectedID != nil else { return .ignored }
                model.selectedID = nil; return .handled
            }
            .onDeleteCommand { trashSelection(in: visible) }
            .onCopyCommand {
                guard let text = model.selected?.text, !text.isEmpty else { return [] }
                model.notify("Copied to clipboard")
                return [NSItemProvider(object: text as NSString)]
            }
            .onChange(of: model.selectedID) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) }
            }
        }
    }

    private func row(_ entry: Transcript) -> some View {
        TranscriptRow(entry: entry, selected: model.selectedID == entry.id, active: model.activeID == entry.id) {
            model.selectedID = entry.id
            listFocused = true
        }
        .contextMenu {
            Button("Copy Text") { model.copy(entry.text) }.disabled(entry.text.isEmpty)
            if entry.deletedAt == nil {
                Button(entry.isFavorite ? "Remove from Favorites" : "Add to Favorites") { model.favorite(entry.id) }
                Button("Export…") { model.export(entry) }
                Divider()
                Button("Move to Trash", role: .destructive) { model.trash(entry.id) }
                    .disabled(model.activeID == entry.id)
            } else {
                Button("Restore") { model.restore(entry.id) }
            }
        }
    }

    /// Moves the selected transcript to Trash and selects its neighbor, so
    /// several can be cleared from the keyboard in a row.
    private func trashSelection(in visible: [Transcript]) {
        guard let index = visible.firstIndex(where: { $0.id == model.selectedID }),
              visible[index].deletedAt == nil, visible[index].id != model.activeID else { return }
        let neighbor = visible.indices.contains(index + 1) ? visible[index + 1].id : index > 0 ? visible[index - 1].id : nil
        model.trash(visible[index].id)
        model.selectedID = neighbor
    }

    private func moveSelection(_ offset: Int, in visible: [Transcript]) -> KeyPress.Result {
        guard !visible.isEmpty else { return .ignored }
        let current = visible.firstIndex { $0.id == model.selectedID }
        let next = current.map { min(max($0 + offset, 0), visible.count - 1) } ?? (offset > 0 ? 0 : visible.count - 1)
        model.selectedID = visible[next].id
        return .handled
    }
}

/// Consecutive transcripts from the same day, grouped in one pass.
struct DaySection: Identifiable {
    let id: Date
    let label: String
    var entries: [Transcript]

    static func group(_ entries: [Transcript], calendar: Calendar = .current) -> [DaySection] {
        var sections: [DaySection] = []
        for entry in entries {
            let day = calendar.startOfDay(for: entry.createdAt)
            if sections.last?.id == day { sections[sections.count - 1].entries.append(entry) }
            else { sections.append(DaySection(id: day, label: label(for: day, calendar: calendar), entries: [entry])) }
        }
        return sections
    }

    private static func label(for day: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        let sameYear = calendar.isDate(day, equalTo: Date(), toGranularity: .year)
        return sameYear ? day.formatted(.dateTime.weekday(.wide).month(.wide).day())
                        : day.formatted(.dateTime.month(.wide).day().year())
    }
}

// MARK: Sidebar

struct SidebarView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var speech: DictationEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 8) {
                WaveMark(size: 20)
                Text("Murmur").font(.system(size: 14, weight: .semibold))
            }.padding(.horizontal, 10).padding(.top, 48).padding(.bottom, 14)

            SidebarItem(title: speech.phase == .recording ? "Finish recording" : "New recording",
                        symbol: speech.phase == .recording ? "stop.circle" : "mic", badge: "⌘N") { model.toggleRecording() }
                .disabled(speech.phase.isBusy && speech.phase != .recording)
            SidebarItem(title: "Search", symbol: "magnifyingglass", badge: "⌘F") {
                NotificationCenter.default.post(name: .murmurSearch, object: nil)
            }

            Text("Library").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.faint)
                .padding(.horizontal, 10).padding(.top, 20).padding(.bottom, 4)
            ForEach(LibraryFilter.allCases, id: \.self) { filter in
                SidebarItem(title: filter.rawValue, symbol: symbol(for: filter), selected: model.filter == filter,
                            badge: filter == .all ? "\(model.savedCount)" : nil) {
                    model.filter = filter; model.selectedID = nil; model.search = ""
                }
            }

            Spacer(minLength: 16)
            RecordingDock(model: model, speech: speech).padding(.bottom, 8)
            Hairline().padding(.horizontal, 6).padding(.bottom, 6)
            SidebarItem(title: "Insights", symbol: "chart.bar") { model.showStats = true }
            SidebarItem(title: "Settings", symbol: "gearshape", badge: "⌘,") { model.showSettings = true }
        }.padding(.horizontal, 8).padding(.bottom, 10)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Palette.sidebar)
    }

    private func symbol(for filter: LibraryFilter) -> String {
        switch filter {
        case .all: return "tray.full"
        case .favorites: return "star"
        case .trash: return "trash"
        }
    }
}

struct SidebarItem: View {
    let title: String
    let symbol: String
    var selected = false
    var badge: String?
    let action: () -> Void
    @State private var hovered = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 13.5)).frame(width: 18)
                    .foregroundStyle(selected ? Palette.ink : Palette.muted)
                Text(title).font(.system(size: 13, weight: .medium))
                Spacer(minLength: 0)
                if let badge {
                    // Counts always show; shortcut hints appear on hover, like Notion.
                    Text(badge).font(.system(size: 11)).foregroundStyle(Palette.faint).monospacedDigit()
                        .opacity(hovered || selected || Int(badge) != nil ? 1 : 0)
                }
            }.foregroundStyle(selected ? Palette.ink : Palette.ink.opacity(0.82))
                .padding(.horizontal, 10).frame(height: 28)
                .background(selected ? Palette.selection : hovered && isEnabled ? Palette.hover : .clear,
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).onHover { hovered = $0 }.opacity(isEnabled ? 1 : 0.45)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The sidebar's live recording status. It observes the speech engine directly,
/// so meter and clock updates redraw only this small view.
struct RecordingDock: View {
    @ObservedObject var model: AppModel
    @ObservedObject var speech: DictationEngine
    @State private var pulse = false

    private var dictationKeys: [String] {
        model.preferences.fnEnabled && model.fnAvailable ? [model.preferences.dictationKey.keyCap] : ["⌃", "⌥", "Space"]
    }

    var body: some View {
        Group {
            switch speech.phase {
            case .recording: recording
            case .idle: hints
            default: working
            }
        }.animation(.easeOut(duration: 0.2), value: speech.phase)
    }

    private var hints: some View {
        VStack(alignment: .leading, spacing: 7) {
            hintRow(model.preferences.fnBehavior == .hold && dictationKeys.count == 1 ? "Hold to dictate" : "Dictate", keys: dictationKeys)
            hintRow("Paste last", keys: ["⌃", "⌥", "V"])
        }.padding(.horizontal, 10).padding(.vertical, 4)
    }

    private func hintRow(_ title: String, keys: [String]) -> some View {
        HStack {
            Text(title).font(.system(size: 12)).foregroundStyle(Palette.muted)
            Spacer()
            ShortcutKeys(keys: keys)
        }
    }

    private var recording: some View {
        HStack(spacing: 10) {
            Circle().fill(Palette.red).frame(width: 8, height: 8)
                .opacity(pulse ? 0.35 : 1)
                .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)
                .onAppear { pulse = true }.onDisappear { pulse = false }
            VStack(alignment: .leading, spacing: 1) {
                Text("Recording").font(.system(size: 12.5, weight: .semibold))
                Text(speech.clockLabel).font(.system(size: 11)).foregroundStyle(Palette.muted).monospacedDigit()
            }
            Spacer(minLength: 4)
            LiveWaveform(level: speech.level, bars: 7, color: Palette.red, maxHeight: 18)
            IconButton(symbol: "stop.fill", help: "Finish recording", tint: Palette.ink) { model.toggleRecording() }
        }.padding(.leading, 12).padding(.trailing, 4).padding(.vertical, 6)
            .background(Palette.canvas, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Palette.line, lineWidth: 1))
    }

    private var working: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(speech.phase == .finishing ? "Transcribing…" : speech.phase == .downloading
                 ? "Downloading model · \(Int(speech.downloadProgress * 100))%" : "Getting ready…")
                .font(.system(size: 12.5)).foregroundStyle(Palette.muted)
            Spacer()
        }.padding(.horizontal, 12).frame(height: 44)
    }
}

// MARK: List

struct SearchField: View {
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Palette.muted)
            TextField("Search", text: $text).textFieldStyle(.plain).focused(focused)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.faint) }
                    .buttonStyle(.plain).accessibilityLabel("Clear search")
            }
        }.font(.system(size: 13)).padding(.horizontal, 9).frame(height: 28)
            .background(Palette.wash, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(focused.wrappedValue ? Palette.accent.opacity(0.55) : .clear, lineWidth: 1.5))
            .onExitCommand { text = ""; focused.wrappedValue = false }
    }
}

/// Ask your library a question; Apple's on-device model answers from your notes.
struct AskPanel: View {
    @ObservedObject var model: AppModel
    var body: some View {
        if let answer = model.answer, answer.question == model.search {
            Callout(symbol: "sparkles", tint: Palette.accent) {
                Text(answer.text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Button("Clear") { model.answer = nil }.buttonStyle(QuietButtonStyle()).padding(.leading, -8)
            }
        } else if let reason = LocalModel.unavailableReason {
            Callout(symbol: "sparkles") { Text("Ask questions about your notes. \(reason)").foregroundStyle(Palette.muted) }
        } else {
            Button { model.ask(model.search) } label: {
                HStack(spacing: 6) {
                    if model.answering { ProgressView().controlSize(.small) } else { Image(systemName: "sparkles") }
                    Text(model.answering ? "Thinking…" : "Ask your notes").lineLimit(1)
                    Spacer()
                    Text("↩").foregroundStyle(Palette.faint)
                }.frame(maxWidth: .infinity)
            }
            .buttonStyle(QuietButtonStyle(tint: Palette.accent))
            .background(Palette.wash, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .disabled(model.answering)
        }
    }
}

struct EmptyList: View {
    var searching: Bool
    var filter: LibraryFilter
    var body: some View {
        VStack(spacing: 6) {
            Text(searching ? "No results" : filter == .favorites ? "No favorites yet" : filter == .trash ? "Trash is empty" : "No transcripts yet")
                .font(.system(size: 13, weight: .medium))
            Text(searching ? "Try another word or app name." : filter == .favorites ? "Star a transcript to keep it here."
                 : filter == .trash ? "Deleted transcripts appear here." : "Your dictations will appear here.")
                .font(.system(size: 12)).foregroundStyle(Palette.muted)
        }.multilineTextAlignment(.center).padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct TranscriptRow: View {
    let entry: Transcript
    let selected: Bool
    let active: Bool
    let select: () -> Void
    @State private var hovered = false

    /// The second line continues the title, or explains a recording without text.
    private var detail: String {
        if active && entry.text.isEmpty { return "Listening…" }
        if entry.reviewReason != nil { return "Needs review" }
        if entry.status == .failed || entry.status == .interrupted, entry.text.isEmpty {
            return entry.audioFile == nil ? "No audio captured" : "Not transcribed · audio kept"
        }
        return entry.preview.isEmpty ? entry.sourceApp : entry.preview
    }

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if active { Circle().fill(Palette.red).frame(width: 6, height: 6) }
                    Text(entry.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                    if entry.isFavorite {
                        Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(Palette.star)
                    }
                }
                HStack(spacing: 6) {
                    Text(entry.createdAt.formatted(.dateTime.hour().minute())).foregroundStyle(Palette.ink.opacity(0.7))
                    Text(detail).foregroundStyle(Palette.muted).lineLimit(1)
                }.font(.system(size: 12))
            }.padding(.horizontal, 12).padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(selected ? Palette.selection : hovered ? Palette.hover : .clear,
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).onHover { hovered = $0 }
            .accessibilityLabel(entry.title)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: Page

struct EmptyPage: View {
    @ObservedObject var model: AppModel
    private var holdHint: String {
        let key = model.preferences.dictationKey.name
        guard model.preferences.fnEnabled && model.fnAvailable else { return "Press Control-Option-Space in any app and speak." }
        return model.preferences.fnBehavior == .hold ? "Hold \(key) in any app and speak. Let go, and your words land where you were typing."
                                                     : "Press \(key) in any app and speak. Press it again to finish."
    }

    var body: some View {
        VStack(spacing: 14) {
            WaveMark(size: 44).padding(.bottom, 4)
            Text("Dictate anywhere").font(.system(size: 22, weight: .semibold)).tracking(-0.4)
            Text(holdHint).font(.system(size: 13)).foregroundStyle(Palette.muted)
                .multilineTextAlignment(.center).frame(maxWidth: 340).lineSpacing(2)
            Button { model.toggleRecording() } label: { Label("New recording", systemImage: "mic.fill") }
                .buttonStyle(PrimaryButtonStyle()).padding(.top, 6)
                .disabled(model.speech.phase.isBusy)
            if !model.transcripts.isEmpty {
                Text("Or select a transcript to read and edit it.").font(.system(size: 12)).foregroundStyle(Palette.faint)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct TranscriptPage: View {
    @ObservedObject var model: AppModel
    let entry: Transcript
    @State private var showOriginal = false
    @State private var showDetails = false
    @State private var confirmDelete = false
    @State private var copied = false

    private var isActive: Bool { model.activeID == entry.id }
    private var needsRetry: Bool {
        entry.deletedAt == nil && !isActive && (entry.status == .failed || entry.status == .interrupted || entry.reviewReason != nil)
    }
    private var text: Binding<String> {
        Binding(get: { model.transcripts.first(where: { $0.id == entry.id })?.text ?? "" },
                set: { model.edit(entry.id, text: $0) })
    }

    var body: some View {
        VStack(spacing: 0) {
            if entry.deletedAt != nil { trashBanner }
            topBar
            VStack(alignment: .leading, spacing: 0) {
                Text(entry.createdAt.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                    .font(.system(size: 30, weight: .bold)).tracking(-0.6).lineLimit(1)
                    .padding(.bottom, 16)
                properties
                if showDetails, let details = entry.details { DetailsPanel(details: details).padding(.top, 8) }
                callouts
                Hairline().padding(.vertical, 18)
                editor.frame(minHeight: 120, maxHeight: .infinity)
                footer.padding(.top, 10)
            }
            .frame(maxWidth: 680, alignment: .leading)
            .padding(.horizontal, 52).padding(.top, 14).padding(.bottom, 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .alert("Permanently delete this transcript?", isPresented: $confirmDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete permanently", role: .destructive) { model.permanentlyDelete(entry.id) }
        } message: { Text("This removes the transcript and its saved audio from Murmur.") }
    }

    private var trashBanner: some View {
        HStack(spacing: 12) {
            Text("This transcript is in Trash.")
            Button("Restore") { model.restore(entry.id) }.buttonStyle(BannerButtonStyle())
            Button("Delete permanently") { confirmDelete = true }.buttonStyle(BannerButtonStyle())
        }.font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
            .frame(maxWidth: .infinity).frame(height: 40).background(Palette.red)
    }

    private var topBar: some View {
        HStack(spacing: 2) {
            HStack(spacing: 6) {
                Text(model.filter.rawValue).foregroundStyle(Palette.muted)
                Text("/").foregroundStyle(Palette.faint)
                Text(entry.title).lineLimit(1)
            }.font(.system(size: 12.5)).padding(.leading, 8)
            Spacer(minLength: 12)
            if entry.deletedAt == nil {
                IconButton(symbol: entry.isFavorite ? "star.fill" : "star",
                           help: entry.isFavorite ? "Remove from favorites" : "Add to favorites",
                           tint: entry.isFavorite ? Palette.star : Palette.muted) { model.favorite(entry.id) }
                IconButton(symbol: copied ? "checkmark" : "doc.on.doc", help: "Copy text (⌘C)",
                           tint: copied ? Palette.green : Palette.muted) {
                    model.copy(entry.text)
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.4)); copied = false }
                }.disabled(entry.text.isEmpty)
                IconButton(symbol: "square.and.arrow.up", help: "Export transcript") { model.export(entry) }
                IconButton(symbol: "trash", help: "Move to Trash (⌫)") { model.trash(entry.id) }.disabled(isActive)
            }
        }.padding(.horizontal, 10).frame(height: 52)
    }

    private var properties: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isActive {
                property("Status", symbol: "circle.dotted") {
                    HStack(spacing: 6) {
                        Circle().fill(Palette.red).frame(width: 6, height: 6)
                        Text(model.speech.phase == .recording ? "Recording" : "Transcribing…")
                    }
                }
            }
            property("Created", symbol: "clock") { Text(entry.createdAt.formatted(.dateTime.hour().minute())) }
            property("Source", symbol: "macwindow") { Text(entry.sourceApp) }
            property("Words", symbol: "text.alignleft") { Text("\(entry.wordCount)").monospacedDigit() }
            if let engine = entry.engineName { property("Engine", symbol: "cpu") { Text(engine) } }
            if let details = entry.details {
                property("Processing", symbol: "wand.and.stars") {
                    Button { withAnimation(.easeOut(duration: 0.15)) { showDetails.toggle() } } label: {
                        HStack(spacing: 4) {
                            Text(details.summary)
                            Image(systemName: showDetails ? "chevron.up" : "chevron.down").font(.system(size: 9, weight: .semibold))
                        }
                    }.buttonStyle(.plain).foregroundStyle(Palette.ink).help("What Murmur did")
                }
            }
            if entry.audioFile != nil {
                property("Audio", symbol: "waveform") { player }
            } else {
                property("Duration", symbol: "timer") { Text(entry.durationLabel).monospacedDigit() }
            }
        }
    }

    private func property<Value: View>(_ name: String, symbol: String, @ViewBuilder value: () -> Value) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 12)).frame(width: 16)
                Text(name)
            }.foregroundStyle(Palette.muted).frame(width: 132, alignment: .leading)
            value()
            Spacer(minLength: 0)
        }.font(.system(size: 13)).frame(height: 30)
    }

    private var player: some View {
        HStack(spacing: 10) {
            Button { model.togglePlayback(entry) } label: {
                Image(systemName: model.playingID == entry.id ? "pause.fill" : "play.fill").font(.system(size: 9))
                    .foregroundStyle(Palette.ink).frame(width: 22, height: 22)
                    .background(Palette.wash, in: Circle())
            }.buttonStyle(.plain)
                .help(model.playingID == entry.id ? "Pause" : "Play recording")
                .accessibilityLabel(model.playingID == entry.id ? "Pause recording" : "Play recording")
                .disabled(model.activeID != nil)
            ProgressView(value: model.playingID == entry.id ? model.playbackProgress : 0)
                .progressViewStyle(.linear).tint(Palette.ink.opacity(0.6)).frame(maxWidth: 180)
            Text(entry.durationLabel).foregroundStyle(Palette.muted).monospacedDigit()
        }
    }

    @ViewBuilder private var callouts: some View {
        if let reason = entry.reviewReason {
            Callout(symbol: "ear", tint: Palette.star) { Text(reason).fixedSize(horizontal: false, vertical: true) }
                .padding(.top, 14)
        }
        if needsRetry {
            if entry.audioFile != nil {
                Callout(symbol: "arrow.clockwise") {
                    Text(entry.text.isEmpty ? "This recording hasn’t been transcribed yet." : "Run transcription again on the saved audio.")
                    Button("Transcribe saved audio") { model.retry(entry) }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(model.speech.phase.isBusy || model.activeID != nil)
                }.padding(.top, 10)
            } else {
                Callout(symbol: "mic.slash") { Text("No audio was captured. Check microphone access before recording again.") }
                    .padding(.top, 10)
            }
        }
    }

    @ViewBuilder private var editor: some View {
        if showOriginal {
            ScrollView {
                Text(entry.originalText).font(.system(size: 15)).lineSpacing(6).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.scrollIndicators(.automatic)
        } else {
            TextEditor(text: text)
                .font(.system(size: 15)).lineSpacing(6).scrollContentBackground(.hidden)
                .padding(.horizontal, -5)
                .disabled(isActive || entry.deletedAt != nil)
                .overlay(alignment: .topLeading) {
                    if entry.text.isEmpty {
                        Text(isActive ? "Your words will appear here as you speak." : "Nothing was transcribed.")
                            .font(.system(size: 15)).foregroundStyle(Palette.faint).allowsHitTesting(false)
                    }
                }
                .accessibilityLabel("Transcript text, edits save automatically")
        }
    }

    private var footer: some View {
        HStack {
            Text(isActive ? "Saving while you speak" : entry.deletedAt != nil ? "Restore to edit" : "Edits save automatically")
                .font(.system(size: 11)).foregroundStyle(Palette.faint)
            Spacer()
            if entry.text != entry.originalText && !entry.originalText.isEmpty {
                Button(showOriginal ? "Show edited text" : "Show original") { showOriginal.toggle() }
                    .buttonStyle(QuietButtonStyle())
            }
        }
    }
}

/// "What Murmur did": context words, swapped-in words, cleanup steps, timings.
struct DetailsPanel: View {
    let details: DictationDetails
    var body: some View {
        Callout(symbol: "wand.and.stars") {
            if let seconds = details.transcribeSeconds {
                row("Timing", String(format: "Transcribed in %.2f s", seconds)
                    + (details.polishSeconds.map { String(format: " · cleaned up in %.2f s", $0) } ?? ""))
            }
            if !details.boostedWords.isEmpty { row("Recognized", details.boostedWords.joined(separator: ", ")) }
            row("Cleanup", details.steps.isEmpty ? "No changes" : details.steps.joined(separator: "\n"))
            if let insertion = details.insertion { row("Insertion", insertion) }
            if !details.contextWords.isEmpty {
                row("Listened for", details.contextWords.prefix(40).joined(separator: ", ")
                    + (details.contextWords.count > 40 ? " and \(details.contextWords.count - 40) more" : ""))
            }
        }
    }
    private func row(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.muted)
            Text(value).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
}

extension DictationDetails {
    var summary: String {
        var parts: [String] = []
        if !boostedWords.isEmpty { parts.append("\(boostedWords.count) word\(boostedWords.count == 1 ? "" : "s") recognized") }
        if !steps.isEmpty { parts.append("\(steps.count) cleanup step\(steps.count == 1 ? "" : "s")") }
        if parts.isEmpty, let seconds = transcribeSeconds { parts.append(String(format: "%.2f s", seconds)) }
        return parts.isEmpty ? "Details" : parts.joined(separator: " · ")
    }
}

/// White outlined button for use on the red Trash banner.
struct BannerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12.5, weight: .medium)).foregroundStyle(.white)
            .padding(.horizontal, 10).frame(height: 26)
            .background(.white.opacity(configuration.isPressed ? 0.25 : 0.12), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(.white.opacity(0.55), lineWidth: 1))
    }
}

struct ToastView: View {
    let message: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.white.opacity(0.85))
            Text(message).lineLimit(2)
        }.font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(Color(hex: 0x2F2F2F), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
            .accessibilityElement(children: .combine)
    }
}
