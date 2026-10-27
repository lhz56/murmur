import SwiftUI
import AppKit

struct MainView: View {
    @ObservedObject var model: AppModel
    @FocusState private var searchFocused: Bool
    @FocusState private var listFocused: Bool

    var body: some View {
        // Filter once per render; rows, headers and keyboard navigation share it.
        let visible = model.visibleTranscripts
        HStack(spacing: 0) {
            SidebarView(model: model).frame(width: 200)
            Rectangle().fill(Palette.line).frame(width: 1)
            VStack(alignment: .leading, spacing: 20) {
                header(count: visible.count)
                RecordingStatusView(model: model, speech: model.speech)
                library(visible)
            }.padding(.horizontal, 28).padding(.top, 38).padding(.bottom, 24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Palette.canvas)
        }
        .foregroundStyle(Palette.ink).frame(minWidth: 940, minHeight: 670)
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                ToastView(message: toast)
                    .padding(.bottom, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.86), value: model.toast)
        .sheet(isPresented: $model.showSettings) {
            SettingsView(model: model, preferences: model.preferences, speech: model.speech, microphoneCheck: model.microphoneCheck)
        }
        .alert("Murmur needs your attention", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
            Button("Open Settings") { model.errorMessage = nil; model.showSettings = true }
        } message: { Text(model.errorMessage ?? "") }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refreshPermissions() }
        .onReceive(NotificationCenter.default.publisher(for: .murmurSearch)) { _ in searchFocused = true }
    }

    private var title: String { model.filter == .all ? "Library" : model.filter.rawValue }

    private func caption(count: Int) -> String {
        if model.filter == .trash { return "Deleted transcripts can be restored." }
        let noun = "transcript\(count == 1 ? "" : "s")"
        return model.search.isEmpty ? "\(count) \(noun) saved on this Mac" : "\(count) matching \(noun)"
    }

    private func header(count: Int) -> some View {
        let phase = model.speech.phase
        return HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 25, weight: .semibold)).tracking(-0.5)
                Text(caption(count: count)).font(.system(size: 12)).foregroundStyle(Palette.muted)
                    .contentTransition(.numericText())
            }
            Spacer(minLength: 12)
            Button(action: model.toggleRecording) {
                HStack(spacing: 7) {
                    Image(systemName: phase == .recording ? "stop.fill" : "mic.fill")
                    Text(phase == .recording ? "Finish recording" : phase.isBusy ? "Processing…" : "Record")
                }
            }.buttonStyle(CapsuleButtonStyle(prominent: true))
                .disabled(phase.isBusy && phase != .recording)
                .help(phase == .recording ? "Finish recording (⌘N)" : "Start recording (⌘N)")
                .accessibilityLabel(phase == .recording ? "Finish recording" : "Start recording")
        }
    }

    private func library(_ visible: [Transcript]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                SearchField(text: $model.search, focused: $searchFocused)
                Spacer(minLength: 0)
                SmallIconButton(symbol: "square.and.arrow.down", help: "Import audio") { model.importAudio() }
                    .disabled(model.speech.phase.isBusy)
                SmallIconButton(symbol: "square.and.arrow.up", help: "Export library") { model.export() }
            }
            HStack(alignment: .top, spacing: 16) {
                if visible.isEmpty {
                    EmptyLibraryView(searching: !model.search.isEmpty, filter: model.filter, record: model.toggleRecording)
                } else {
                    transcriptList(visible)
                }
                if let entry = model.selected {
                    TranscriptDetail(model: model, entry: entry).id(entry.id).frame(width: 340)
                        .frame(maxHeight: .infinity)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }.frame(maxHeight: .infinity)
                .animation(.spring(response: 0.32, dampingFraction: 0.9), value: model.selectedID == nil)
        }.frame(maxHeight: .infinity)
    }

    private func transcriptList(_ visible: [Transcript]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(DaySection.group(visible)) { section in
                        Section {
                            ForEach(section.entries) { entry in
                                row(entry).id(entry.id).padding(.horizontal, 7)
                            }
                        } header: {
                            Text(section.label).font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.muted)
                                .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Palette.surface)
                        }
                    }
                }.padding(.bottom, 9)
            }
            .scrollIndicators(.automatic)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .card()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        TranscriptRow(entry: entry, selected: model.selectedID == entry.id, active: model.activeID == entry.id,
                      select: {
                          model.selectedID = model.selectedID == entry.id ? nil : entry.id
                          listFocused = true
                      },
                      favorite: { model.favorite(entry.id) })
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

struct SearchField: View {
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").foregroundStyle(Palette.muted)
            TextField("Search transcripts", text: $text).textFieldStyle(.plain).focused(focused)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.muted) }
                    .buttonStyle(.plain).accessibilityLabel("Clear search")
            } else {
                Text("⌘F").font(.system(size: 10)).foregroundStyle(Palette.muted.opacity(0.7))
            }
        }.font(.system(size: 12)).padding(.horizontal, 11).frame(width: 250, height: 34)
            .card(radius: 8, stroke: focused.wrappedValue ? Palette.accent.opacity(0.5) : Palette.line)
            .onExitCommand { text = ""; focused.wrappedValue = false }
    }
}

struct ToastView: View {
    let message: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.green)
            Text(message).font(.system(size: 12, weight: .medium)).lineLimit(2)
        }.padding(.horizontal, 16).padding(.vertical, 11)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Palette.line, lineWidth: 1))
            .shadow(color: .black.opacity(0.10), radius: 14, y: 5)
            .accessibilityElement(children: .combine)
    }
}

struct SidebarView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                WaveMark(size: 27)
                Text("Murmur").font(.system(size: 17, weight: .semibold)).tracking(-0.3)
            }.padding(.horizontal, 11).padding(.bottom, 34)
            Text("Library").font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.muted)
                .padding(.horizontal, 12).padding(.bottom, 9)
            ForEach(LibraryFilter.allCases, id: \.self) { filter in
                SidebarItem(title: filter.rawValue, symbol: symbol(for: filter), selected: model.filter == filter,
                            badge: filter == .all ? "\(model.savedCount)" : nil) {
                    model.filter = filter; model.selectedID = nil; model.search = ""
                }.padding(.bottom, 3)
            }
            Spacer()
            HStack(spacing: 7) {
                Image(systemName: "lock.shield").font(.system(size: 12))
                Text("On-device transcription").font(.system(size: 10))
            }.foregroundStyle(Palette.muted).padding(.horizontal, 11).padding(.bottom, 16)
            Rectangle().fill(Palette.line).frame(height: 1).padding(.horizontal, 10).padding(.bottom, 9)
            SidebarItem(title: "Settings", symbol: "gearshape", selected: false, badge: "⌘,") { model.showSettings = true }
        }.padding(.horizontal, 12).padding(.top, 45).padding(.bottom, 17).background(Palette.sidebar)
    }

    private func symbol(for filter: LibraryFilter) -> String {
        switch filter {
        case .all: return "doc.text"
        case .favorites: return "star"
        case .trash: return "trash"
        }
    }
}

struct SidebarItem: View {
    let title: String
    let symbol: String
    let selected: Bool
    var badge: String?
    let action: () -> Void
    @State private var hovered = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: selected ? "\(symbol).fill" : symbol).font(.system(size: 13)).frame(width: 18)
                Text(title).font(.system(size: 12, weight: selected ? .medium : .regular))
                Spacer(minLength: 0)
                if let badge { Text(badge).font(.system(size: 10)).foregroundStyle(Palette.muted).monospacedDigit() }
            }.foregroundStyle(selected ? Palette.ink : Palette.muted)
                .padding(.horizontal, 11).frame(height: 34)
                .background(selected ? Palette.surface : hovered ? Palette.line.opacity(0.45) : .clear,
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(selected ? Palette.line : .clear, lineWidth: 0.5))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).onHover { hovered = $0 }
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Observes the speech engine directly. It is the only part of the library
/// window that redraws for meter, clock and live-text updates.
struct RecordingStatusView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var speech: DictationEngine
    private var recording: Bool { speech.phase == .recording }
    private var primaryKey: Bool { model.preferences.fnEnabled && model.fnAvailable }
    private var heading: String {
        if recording { return "Recording" }
        return speech.phase.isBusy ? speech.phase.label : "Ready to dictate"
    }
    private var instruction: String {
        let preferences = model.preferences
        switch speech.phase {
        case .finishing:
            return preferences.autoCopy ? "Finishing transcription. Text will copy when ready."
                                        : "Finishing transcription. Your transcript will appear in the library."
        case .downloading: return "Downloading the speech model…"
        case .preparing: return "Connecting your microphone…"
        case .recording:
            if !speech.liveText.isEmpty { return speech.liveText }
            return preferences.keepAudio ? "Speak naturally. Your audio is being saved." : "Speak naturally. Transcription runs on this Mac."
        case .idle:
            if primaryKey && preferences.fnBehavior == .hold { return "Hold \(preferences.dictationKey.name) to talk. Release to finish." }
            return primaryKey ? "Press \(preferences.dictationKey.name) to start or finish." : "Use the shortcut or click Record to start."
        }
    }

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous).fill(recording ? Palette.lilac : Palette.sidebar)
                    .frame(width: 40, height: 40)
                if recording {
                    LiveWaveform(level: speech.level, bars: 7, color: Palette.accent, maxHeight: 22)
                } else if speech.phase.isBusy {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "waveform").font(.system(size: 17)).foregroundStyle(Palette.muted)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(heading).font(.system(size: 13, weight: .medium))
                    if recording {
                        Text(speech.clockLabel).font(.system(size: 11)).monospacedDigit().foregroundStyle(Palette.muted)
                    }
                }
                Text(instruction).font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(1).truncationMode(.head)
            }.frame(maxWidth: .infinity, alignment: .leading)
            if !speech.phase.isBusy {
                ShortcutKeys(keys: primaryKey ? [model.preferences.dictationKey.keyCap] : ["⌃", "⌥", "space"])
            }
        }.padding(.horizontal, 17).frame(height: 76)
            .card(stroke: recording ? Palette.accent.opacity(0.45) : Palette.line)
            .animation(.easeOut(duration: 0.2), value: speech.phase)
    }
}

struct EmptyLibraryView: View {
    var searching: Bool
    var filter: LibraryFilter
    var record: () -> Void
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: searching ? "magnifyingglass" : filter == .favorites ? "star" : filter == .trash ? "trash" : "waveform")
                .font(.system(size: 26, weight: .light)).foregroundStyle(Palette.muted.opacity(0.7)).padding(.bottom, 4)
            Text(searching ? "No matching transcripts" : filter == .favorites ? "No favorites yet" : filter == .trash ? "Trash is empty" : "No transcripts yet")
                .font(.system(size: 15, weight: .medium))
            Text(searching ? "Try another word or app name." : filter == .favorites ? "Star a transcript to add it here."
                 : filter == .trash ? "Deleted transcripts will appear here." : "Use your shortcut in any app and speak. Your words land where you’re typing.")
                .font(.system(size: 12)).foregroundStyle(Palette.muted).multilineTextAlignment(.center).frame(maxWidth: 300)
            if !searching && filter == .all {
                Button("Record") { record() }.buttonStyle(CapsuleButtonStyle()).padding(.top, 5)
            }
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity).card()
    }
}

struct TranscriptRow: View {
    let entry: Transcript
    let selected: Bool
    let active: Bool
    let select: () -> Void
    let favorite: () -> Void
    @State private var hovered = false

    private var symbol: String {
        if active { return "waveform" }
        if entry.reviewReason != nil { return "ear" }
        if entry.status == .failed || entry.status == .interrupted { return "exclamationmark.bubble" }
        return "text.alignleft"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Button(action: select) {
                HStack(alignment: .top, spacing: 11) {
                    Image(systemName: symbol)
                        .font(.system(size: 14)).foregroundStyle(selected || active ? Palette.accent : Palette.muted)
                        .symbolEffect(.variableColor.iterative, isActive: active)
                        .frame(width: 28, height: 28).padding(.top, 1)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(entry.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        let preview = entry.preview
                        if !preview.isEmpty {
                            Text(preview).font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(1)
                        }
                        HStack(spacing: 5) {
                            Text(entry.createdAt.formatted(.dateTime.hour().minute()))
                            Text("·"); Text(entry.durationLabel); Text("·"); Text(entry.sourceApp)
                            if entry.status == .interrupted || entry.status == .failed {
                                Text(entry.audioFile == nil ? "· No audio captured" : "· Audio kept")
                            }
                        }.font(.system(size: 10)).foregroundStyle(Palette.muted).lineLimit(1)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(entry.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
            Button(action: favorite) {
                Image(systemName: entry.isFavorite ? "star.fill" : "star").font(.system(size: 11))
                    .foregroundStyle(entry.isFavorite ? Palette.star : Palette.muted.opacity(hovered || selected ? 0.8 : 0))
                    .frame(width: 23, height: 23).contentShape(Rectangle())
            }.buttonStyle(.plain).help(entry.isFavorite ? "Remove from favorites" : "Add to favorites")
                .accessibilityLabel(entry.isFavorite ? "Remove from favorites" : "Add to favorites")
        }.padding(.horizontal, 10).padding(.vertical, 12)
            .background(selected ? Palette.lilac : hovered ? Palette.sidebar.opacity(0.8) : .clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .onHover { hovered = $0 }.accessibilityElement(children: .contain)
    }
}

struct TranscriptDetail: View {
    @ObservedObject var model: AppModel
    let entry: Transcript
    @State private var showOriginal = false
    @State private var confirmDelete = false
    @State private var copied = false

    private var needsRetry: Bool { entry.status == .failed || entry.status == .interrupted || entry.reviewReason != nil }
    private var isActive: Bool { model.activeID == entry.id }
    private var text: Binding<String> {
        Binding(get: { model.transcripts.first(where: { $0.id == entry.id })?.text ?? "" },
                set: { model.edit(entry.id, text: $0) })
    }

    var body: some View {
        GeometryReader { bounds in
            ScrollView {
                VStack(alignment: .leading, spacing: 15) {
                    heading
                    Rectangle().fill(Palette.line).frame(height: 1)
                    if let reason = entry.reviewReason {
                        Label(reason, systemImage: "ear.badge.waveform").font(.system(size: 11)).foregroundStyle(Palette.muted)
                            .padding(10).background(Palette.sidebar, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    editor.frame(height: editorHeight(available: bounds.size.height))
                    if entry.audioFile != nil { playback }
                    if entry.deletedAt == nil && needsRetry { retry }
                    actions
                    footnote
                }.padding(18).frame(maxWidth: .infinity, minHeight: bounds.size.height, alignment: .topLeading)
            }.scrollIndicators(.hidden)
        }
        .card()
        .alert("Permanently delete this transcript?", isPresented: $confirmDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete permanently", role: .destructive) { model.permanentlyDelete(entry.id) }
        } message: { Text("This removes the transcript and its saved audio from Murmur.") }
        .onChange(of: entry.id) { _, _ in showOriginal = false; confirmDelete = false; copied = false }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Transcript").font(.system(size: 13, weight: .semibold))
                Spacer()
                SmallIconButton(symbol: "xmark", help: "Close transcript (Esc)") { model.selectedID = nil }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(entry.createdAt.formatted(.dateTime.month(.wide).day().hour().minute())).font(.system(size: 12, weight: .medium))
                HStack(spacing: 6) {
                    Text("\(entry.wordCount) words"); Text("·"); Text(entry.durationLabel); Text("·"); Text(entry.sourceApp)
                    if let engine = entry.engineName { Text("·"); Text(engine) }
                }.font(.system(size: 10)).foregroundStyle(Palette.muted).lineLimit(1)
            }
        }
    }

    @ViewBuilder private var editor: some View {
        if showOriginal {
            ScrollView {
                Text(entry.originalText).font(.system(size: 14)).lineSpacing(6).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            TextEditor(text: text)
                .font(.system(size: 14)).lineSpacing(6).scrollContentBackground(.hidden)
                .disabled(isActive || entry.deletedAt != nil)
                .accessibilityLabel("Transcript text, edits save automatically")
        }
    }

    private var playback: some View {
        HStack(spacing: 10) {
            Button { model.togglePlayback(entry) } label: {
                Image(systemName: model.playingID == entry.id ? "pause.fill" : "play.fill").font(.system(size: 10))
                    .foregroundStyle(Palette.ink).frame(width: 27, height: 27).contentShape(Rectangle())
            }.buttonStyle(.plain).help("Play recording")
                .accessibilityLabel(model.playingID == entry.id ? "Pause recording" : "Play recording")
                .disabled(model.activeID != nil)
            ProgressView(value: model.playingID == entry.id ? model.playbackProgress : 0).tint(Palette.accent)
            Text(entry.durationLabel).font(.system(size: 10)).monospacedDigit().foregroundStyle(Palette.muted)
        }.padding(.horizontal, 8).padding(.vertical, 6)
            .background(Palette.sidebar.opacity(0.7), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    @ViewBuilder private var retry: some View {
        if entry.audioFile != nil {
            Button { model.retry(entry) } label: { Label("Transcribe saved audio", systemImage: "arrow.clockwise") }
                .buttonStyle(CapsuleButtonStyle()).disabled(model.speech.phase.isBusy || model.activeID != nil)
        } else {
            Text("No audio was captured. Check microphone access before recording again.")
                .font(.system(size: 11)).foregroundStyle(Palette.muted)
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            if entry.deletedAt != nil {
                Button { model.restore(entry.id) } label: { Label("Restore", systemImage: "arrow.uturn.backward") }
                    .buttonStyle(CapsuleButtonStyle(prominent: true))
                Spacer()
                SmallIconButton(symbol: "trash", help: "Delete permanently") { confirmDelete = true }
            } else {
                Button {
                    model.copy(entry.text)
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.4)); copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy text", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .contentTransition(.symbolEffect(.replace))
                }.buttonStyle(CapsuleButtonStyle(prominent: true)).disabled(entry.text.isEmpty)
                Spacer()
                SmallIconButton(symbol: "square.and.arrow.up", help: "Export transcript") { model.export(entry) }
                SmallIconButton(symbol: "trash", help: "Move to Trash (⌫)") { model.trash(entry.id) }.disabled(isActive)
            }
        }
    }

    @ViewBuilder private var footnote: some View {
        if entry.text != entry.originalText && !entry.originalText.isEmpty {
            Button(showOriginal ? "Show edited text" : "Show original transcript") { showOriginal.toggle() }
                .font(.system(size: 10)).foregroundStyle(Palette.muted).buttonStyle(.plain)
        } else {
            Text(isActive ? "Saving while you speak" : "Edits save automatically")
                .font(.system(size: 10)).foregroundStyle(Palette.muted)
        }
    }

    /// The editor takes whatever height the other controls leave, with a usable minimum.
    private func editorHeight(available: CGFloat) -> CGFloat {
        var controls: CGFloat = 250
        if entry.audioFile != nil { controls += 54 }
        if needsRetry { controls += 50 }
        if entry.reviewReason != nil { controls += 80 }
        return max(180, available - controls)
    }
}
