import SwiftUI
import AppKit
import AVFoundation

enum Palette {
    static let ink = Color(hex: 0x20242B)
    static let muted = Color(hex: 0x707780)
    static let accent = Color(hex: 0x3766CC)
    static let purple = accent
    static let lilac = Color(hex: 0xEDF2FC)
    static let canvas = Color(hex: 0xFAFAFB)
    static let surface = Color.white
    static let sidebar = Color(hex: 0xF0F1F3)
    static let line = Color(hex: 0xE2E5E9)
    static let mint = Color(hex: 0xE8F3ED)
    static let green = Color(hex: 0x397859)
}
extension Color {
    init(hex: UInt32) { self.init(.sRGB, red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, opacity: 1) }
}

extension Notification.Name {
    static let murmurSearch = Notification.Name("app.murmur.search")
}

struct CapsuleButtonStyle: ButtonStyle {
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .medium))
            .foregroundStyle(prominent ? Color.white : Palette.ink)
            .padding(.horizontal, 14).frame(height: 34)
            .background(prominent ? Palette.accent : Palette.surface, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(prominent ? Color.clear : Palette.line, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.78 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct SmallIconButton: View {
    var symbol: String
    var help: String
    var action: () -> Void
    @State private var hovered = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .regular))
                .foregroundStyle(hovered ? Palette.ink : Palette.muted)
                .frame(width: 30, height: 30)
                .background(hovered ? Palette.line.opacity(0.5) : .clear, in: RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain).help(help).accessibilityLabel(help).onHover { hovered = $0 }
    }
}

struct ShortcutKeys: View {
    var light = false
    var fn = false
    var selectedKey: DictationKey = .fn
    var body: some View {
        HStack(spacing: 3) {
            ForEach(fn ? [selectedKey.keyCap] : ["⌃", "⌥", "space"], id: \.self) { key in
                Text(key).font(.system(size: key == "space" ? 10 : 12, weight: .medium))
                    .padding(.horizontal, key == "space" ? 7 : 6).frame(height: 23)
                    .background(light ? Color.white.opacity(0.10) : Palette.surface, in: RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(light ? Color.white.opacity(0.12) : Palette.line, lineWidth: 1))
            }
        }.foregroundStyle(light ? Color.white.opacity(0.85) : Palette.muted)
            .accessibilityElement(children: .ignore).accessibilityLabel(fn ? "\(selectedKey.name) key" : "Control Option Space")
    }
}

struct WaveMark: View {
    var size: CGFloat = 32
    var body: some View {
        HStack(spacing: size * 0.075) {
            ForEach(0..<5) { index in
                Capsule().fill(Color.white).frame(width: size * 0.075, height: size * [0.22, 0.42, 0.60, 0.42, 0.22][index])
            }
        }.frame(width: size, height: size)
            .background(Palette.ink, in: RoundedRectangle(cornerRadius: size * 0.24))
    }
}

struct MainView: View {
    @ObservedObject var model: AppModel
    @FocusState private var searchFocused: Bool
    private var title: String { model.filter == .all ? "Library" : model.filter.rawValue }
    private var caption: String {
        if model.filter == .trash { return "Deleted transcripts can be restored." }
        if !model.search.isEmpty { return "\(model.visibleTranscripts.count) matching transcript\(model.visibleTranscripts.count == 1 ? "" : "s")" }
        return "\(model.visibleTranscripts.count) transcript\(model.visibleTranscripts.count == 1 ? "" : "s") saved on this Mac"
    }

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(model: model).frame(width: 190)
            Rectangle().fill(Palette.line).frame(width: 1)
            VStack(alignment: .leading, spacing: 22) {
                header
                RecordingStatusView(model: model)
                library
            }.padding(.horizontal, 28).padding(.top, 38).padding(.bottom, 24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Palette.canvas)
        }
        .foregroundStyle(Palette.ink).frame(minWidth: 940, minHeight: 670)
        .preferredColorScheme(.light)
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.green)
                    Text(toast).font(.system(size: 12, weight: .medium)).lineLimit(2)
                }.padding(.horizontal, 16).padding(.vertical, 11)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.line, lineWidth: 1))
                    .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
                    .padding(.bottom, 16).transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: model.toast)
        .sheet(isPresented: $model.showSettings) { SettingsView(model: model, preferences: model.preferences) }
        .alert("Murmur needs your attention", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
            Button("Open Settings") { model.errorMessage = nil; model.showSettings = true }
        } message: { Text(model.errorMessage ?? "") }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refreshPermissions() }
        .onReceive(NotificationCenter.default.publisher(for: .murmurSearch)) { _ in searchFocused = true }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 25, weight: .semibold)).tracking(-0.5)
                Text(caption)
                    .font(.system(size: 12)).foregroundStyle(Palette.muted)
            }
            Spacer(minLength: 12)
            Button(action: model.toggleRecording) {
                HStack(spacing: 7) {
                    Image(systemName: model.speech.phase == .recording ? "stop.fill" : "mic.fill")
                    Text(model.speech.phase == .recording ? "Finish recording" : model.speech.phase.isBusy ? "Processing…" : "Record")
                }
            }.buttonStyle(CapsuleButtonStyle(prominent: true))
                .disabled(model.speech.phase.isBusy && model.speech.phase != .recording)
                .accessibilityLabel(model.speech.phase == .recording ? "Finish recording" : "Start recording")
        }
    }

    private var library: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Palette.muted)
                    TextField("Search transcripts", text: $model.search).textFieldStyle(.plain).focused($searchFocused)
                    if !model.search.isEmpty {
                        Button { model.search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.muted) }
                            .buttonStyle(.plain).accessibilityLabel("Clear search")
                    }
                }.font(.system(size: 12)).padding(.horizontal, 11).frame(width: 236, height: 34)
                    .background(Palette.surface, in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Palette.line, lineWidth: 1))
                Spacer(minLength: 0)
                SmallIconButton(symbol: "square.and.arrow.down", help: "Import audio") { model.importAudio() }.disabled(model.speech.phase.isBusy)
                SmallIconButton(symbol: "square.and.arrow.up", help: "Export library") { model.export() }
            }
            HStack(alignment: .top, spacing: 16) {
                if model.visibleTranscripts.isEmpty {
                    EmptyLibraryView(searching: !model.search.isEmpty, filter: model.filter, record: model.toggleRecording)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(model.visibleTranscripts.enumerated()), id: \.element.id) { index, entry in
                                if index == 0 || !Calendar.current.isDate(entry.createdAt, inSameDayAs: model.visibleTranscripts[index - 1].createdAt) {
                                    Text(dayLabel(entry.createdAt)).font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.muted)
                                        .padding(.horizontal, 16).padding(.top, index == 0 ? 15 : 22).padding(.bottom, 9)
                                }
                                TranscriptRow(entry: entry, selected: model.selectedID == entry.id, active: model.activeID == entry.id,
                                              select: { model.selectedID = model.selectedID == entry.id ? nil : entry.id },
                                              favorite: { model.favorite(entry.id) })
                                    .padding(.horizontal, 7)
                            }
                        }.padding(.bottom, 9)
                    }.scrollIndicators(.hidden).frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.line, lineWidth: 1))
                }
                if let entry = model.selected {
                    TranscriptDetail(model: model, entry: entry).id(entry.id).frame(width: 340)
                        .frame(maxHeight: .infinity)
                }
            }.frame(maxHeight: .infinity)
        }.frame(maxHeight: .infinity)
    }

    private func dayLabel(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.month(.wide).day())
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
                Button {
                    model.filter = filter; model.selectedID = nil; model.search = ""
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: filter == .all ? "doc.text" : filter == .favorites ? "star" : "trash")
                            .font(.system(size: 13)).frame(width: 18)
                        Text(filter == .all ? "All transcripts" : filter.rawValue).font(.system(size: 12, weight: model.filter == filter ? .medium : .regular))
                        Spacer(minLength: 0)
                        if filter == .all {
                            Text("\(model.savedTranscripts.count)").font(.system(size: 10)).foregroundStyle(Palette.muted)
                        }
                    }.foregroundStyle(model.filter == filter ? Palette.ink : Palette.muted)
                        .padding(.horizontal, 11).frame(height: 35)
                        .background(model.filter == filter ? Color.white.opacity(0.85) : .clear, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(model.filter == filter ? Palette.line : .clear, lineWidth: 0.5))
                }.buttonStyle(.plain).padding(.bottom, 3)
            }
            Spacer()
            HStack(spacing: 7) {
                Image(systemName: "lock.shield").font(.system(size: 12))
                Text("On-device transcription").font(.system(size: 10))
            }.foregroundStyle(Palette.muted).padding(.horizontal, 11).padding(.bottom, 16)
            Rectangle().fill(Palette.line).frame(height: 1).padding(.horizontal, 10).padding(.bottom, 9)
            Button { model.showSettings = true } label: {
                HStack(spacing: 9) {
                    Image(systemName: "gearshape").font(.system(size: 13)).frame(width: 18)
                    Text("Settings").font(.system(size: 12))
                    Spacer()
                    Text("⌘,").font(.system(size: 10)).foregroundStyle(Palette.muted)
                }.foregroundStyle(Palette.muted).padding(.horizontal, 11).frame(height: 35)
            }.buttonStyle(.plain)
        }.padding(.horizontal, 12).padding(.top, 45).padding(.bottom, 17).background(Palette.sidebar)
    }
}

struct RecordingStatusView: View {
    @ObservedObject var model: AppModel
    private var recording: Bool { model.speech.phase == .recording }
    private var primaryKey: Bool { model.preferences.fnEnabled && model.fnAvailable }
    private var instruction: String {
        if model.speech.phase == .finishing { return model.preferences.autoCopy ? "Finishing transcription. Text will copy when ready." : "Finishing transcription. Your transcript will appear in the library." }
        if model.speech.phase == .preparing || model.speech.phase == .downloading { return model.speech.phase == .downloading ? "Downloading the speech model…" : "Connecting your microphone…" }
        if recording { return model.speech.liveText.isEmpty ? (model.preferences.keepAudio ? "Speak naturally. Your audio is being saved." : "Speak naturally. Transcription runs on this Mac.") : model.speech.liveText }
        if primaryKey && model.preferences.fnBehavior == .hold { return "Hold \(model.preferences.dictationKey.name) to talk. Release to finish." }
        return primaryKey ? "Press \(model.preferences.dictationKey.name) to start or finish." : "Use the shortcut or click Record to start."
    }
    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(recording ? Palette.lilac : Palette.sidebar).frame(width: 40, height: 40)
                if recording {
                    MeterBars(level: model.speech.level, active: true, color: Palette.accent).frame(width: 26)
                } else if model.speech.phase.isBusy {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "waveform").font(.system(size: 17)).foregroundStyle(Palette.muted)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(recording ? "Recording" : model.speech.phase.isBusy ? model.speech.phase.label : "Ready to dictate")
                        .font(.system(size: 13, weight: .medium))
                    if recording { Text(model.recordingTime).font(.system(size: 11)).monospacedDigit().foregroundStyle(Palette.muted) }
                }
                Text(instruction).font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(1)
            }.frame(maxWidth: .infinity, alignment: .leading)
            if !model.speech.phase.isBusy {
                ShortcutKeys(fn: primaryKey, selectedKey: model.preferences.dictationKey)
            }
        }.padding(.horizontal, 17).frame(height: 82)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(recording ? Palette.accent.opacity(0.4) : Palette.line, lineWidth: 1))
    }
}

struct EmptyLibraryView: View {
    var searching: Bool
    var filter: LibraryFilter
    var record: () -> Void
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: searching ? "magnifyingglass" : filter == .favorites ? "star" : filter == .trash ? "trash" : "doc.text")
                .font(.system(size: 26, weight: .light)).foregroundStyle(Palette.muted.opacity(0.7)).padding(.bottom, 4)
            Text(searching ? "No matching transcripts" : filter == .favorites ? "No favorites yet" : filter == .trash ? "Trash is empty" : "No transcripts yet")
                .font(.system(size: 15, weight: .medium))
            Text(searching ? "Try another word or app name." : filter == .favorites ? "Star a transcript to add it here." : filter == .trash ? "Deleted transcripts will appear here." : "Record your voice to save your first transcript.")
                .font(.system(size: 12)).foregroundStyle(Palette.muted).multilineTextAlignment(.center)
            if !searching && filter == .all {
                Button("Record") { record() }.buttonStyle(CapsuleButtonStyle()).padding(.top, 5)
            }
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.line, lineWidth: 1))
    }
}

struct TranscriptRow: View {
    let entry: Transcript
    let selected: Bool
    let active: Bool
    let select: () -> Void
    let favorite: () -> Void
    @State private var hovered = false
    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Button(action: select) {
                HStack(alignment: .top, spacing: 11) {
            Image(systemName: active ? "waveform" : "doc.text")
                .font(.system(size: 15, weight: .regular)).foregroundStyle(selected ? Palette.accent : Palette.muted)
                .frame(width: 28, height: 28).padding(.top, 1)
            VStack(alignment: .leading, spacing: 5) {
                Text(entry.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                if !entry.text.isEmpty {
                    Text(entry.text).font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(1)
                }
                HStack(spacing: 5) {
                    Text(entry.createdAt.formatted(.dateTime.hour().minute()))
                    Text("·"); Text(entry.durationLabel); Text("·"); Text(entry.sourceApp)
                    if entry.status == .interrupted || entry.status == .failed {
                        Text("· Audio kept").foregroundStyle(Palette.muted)
                    }
                }.font(.system(size: 10)).foregroundStyle(Palette.muted).lineLimit(1)
            }.frame(maxWidth: .infinity, alignment: .leading)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(entry.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
            Button(action: favorite) {
                Image(systemName: entry.isFavorite ? "star.fill" : "star").font(.system(size: 11))
                    .foregroundStyle(entry.isFavorite ? Color(hex: 0xB58B3B) : Palette.muted.opacity(hovered || selected ? 0.8 : 0.45))
                    .frame(width: 23, height: 23)
            }.buttonStyle(.plain).help(entry.isFavorite ? "Remove from favorites" : "Add to favorites")
                .accessibilityLabel(entry.isFavorite ? "Remove from favorites" : "Add to favorites")
        }.padding(.horizontal, 10).padding(.vertical, 13)
            .background(selected ? Palette.lilac : hovered ? Palette.sidebar.opacity(0.65) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .onHover { hovered = $0 }.accessibilityElement(children: .contain)
    }
}

struct TranscriptDetail: View {
    @ObservedObject var model: AppModel
    let entry: Transcript
    @State private var showOriginal = false
    @State private var confirmDelete = false
    var body: some View {
        GeometryReader { bounds in
            ScrollView {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Text("Transcript").font(.system(size: 13, weight: .semibold))
                Spacer()
                SmallIconButton(symbol: "xmark", help: "Close transcript") { model.selectedID = nil }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(entry.createdAt.formatted(.dateTime.month(.wide).day().hour().minute())).font(.system(size: 12, weight: .medium))
                HStack(spacing: 6) {
                    Text("\(entry.wordCount) words"); Text("·"); Text(entry.durationLabel); Text("·"); Text(entry.sourceApp)
                }.font(.system(size: 10)).foregroundStyle(Palette.muted).lineLimit(1)
            }
            Rectangle().fill(Palette.line).frame(height: 1)
            if let reason = entry.reviewReason {
                Label(reason, systemImage: "ear.badge.waveform").font(.system(size: 11)).foregroundStyle(Palette.muted)
                    .padding(10).background(Palette.sidebar, in: RoundedRectangle(cornerRadius: 7))
            }
            if showOriginal {
                ScrollView {
                    Text(entry.originalText).font(.system(size: 14)).lineSpacing(6).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(height: editorHeight(available: bounds.size.height))
            } else {
                TextEditor(text: Binding(get: { model.transcripts.first(where: { $0.id == entry.id })?.text ?? "" }, set: { model.edit(entry.id, text: $0) }))
                    .font(.system(size: 14)).lineSpacing(6).scrollContentBackground(.hidden)
                    .disabled(model.activeID == entry.id || entry.deletedAt != nil)
                    .accessibilityLabel("Transcript text, edits save automatically")
                    .frame(height: editorHeight(available: bounds.size.height))
            }
            if entry.audioFile != nil {
                HStack(spacing: 10) {
                    Button { model.togglePlayback(entry) } label: {
                        Image(systemName: model.playingID == entry.id ? "pause.fill" : "play.fill").font(.system(size: 10))
                            .foregroundStyle(Palette.ink).frame(width: 27, height: 27)
                    }.buttonStyle(.plain).help("Play recording").accessibilityLabel(model.playingID == entry.id ? "Pause recording" : "Play recording").disabled(model.activeID != nil)
                    ProgressView(value: model.playingID == entry.id ? model.playbackProgress : 0).tint(Palette.accent)
                    Text(entry.durationLabel).font(.system(size: 10)).monospacedDigit().foregroundStyle(Palette.muted)
                }.padding(.horizontal, 8).padding(.vertical, 6).background(Palette.sidebar.opacity(0.7), in: RoundedRectangle(cornerRadius: 7))
            }
            if entry.status == .failed || entry.status == .interrupted || entry.reviewReason != nil {
                if entry.audioFile != nil {
                    Button { model.retry(entry) } label: { Label("Transcribe saved audio", systemImage: "arrow.clockwise") }
                        .buttonStyle(CapsuleButtonStyle()).disabled(model.speech.phase.isBusy)
                } else {
                    Text("No audio was captured. Check microphone access before recording again.").font(.system(size: 11)).foregroundStyle(Palette.muted)
                }
            }
            HStack(spacing: 8) {
                if entry.deletedAt != nil {
                    Button { model.restore(entry.id) } label: { Label("Restore", systemImage: "arrow.uturn.backward") }.buttonStyle(CapsuleButtonStyle(prominent: true))
                    Spacer()
                    SmallIconButton(symbol: "trash", help: "Delete permanently") { confirmDelete = true }
                } else {
                    Button { model.copy(entry.text) } label: { Label("Copy text", systemImage: "doc.on.doc") }.buttonStyle(CapsuleButtonStyle(prominent: true)).disabled(entry.text.isEmpty)
                    Spacer()
                    SmallIconButton(symbol: "square.and.arrow.up", help: "Export transcript") { model.export(entry) }
                    SmallIconButton(symbol: "trash", help: "Move to Trash") { model.trash(entry.id) }.disabled(model.activeID == entry.id)
                }
            }
            if entry.text != entry.originalText && !entry.originalText.isEmpty {
                Button(showOriginal ? "Show edited text" : "Show original transcript") { showOriginal.toggle() }
                    .font(.system(size: 10)).foregroundStyle(Palette.muted).buttonStyle(.plain)
            } else {
                Text(model.activeID == entry.id ? "Saving while you speak" : "Edits save automatically")
                    .font(.system(size: 10)).foregroundStyle(Palette.muted)
            }
        }.padding(18).frame(maxWidth: .infinity, minHeight: bounds.size.height, alignment: .topLeading)
            }.scrollIndicators(.hidden)
        }
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.line, lineWidth: 1))
            .alert("Permanently delete this transcript?", isPresented: $confirmDelete) {
                Button("Cancel", role: .cancel) {}
                Button("Delete permanently", role: .destructive) { model.permanentlyDelete(entry.id) }
            } message: { Text("This removes the transcript and its saved audio from Murmur.") }
    }
    private func editorHeight(available: CGFloat) -> CGFloat {
        var controls: CGFloat = 242
        if entry.audioFile != nil { controls += 54 }
        if entry.status == .failed || entry.status == .interrupted || entry.reviewReason != nil { controls += 50 }
        if entry.reviewReason != nil { controls += 80 }
        return max(180, available - controls)
    }
}


struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var preferences: Preferences
    @Environment(\.dismiss) private var dismiss
    @State private var heardWord = ""
    @State private var desiredWord = ""
    private var shortcutInstruction: String {
        if preferences.dictationKey == .fn { return "Hold Fn to record, then release to finish. Double-tap Fn or press Fn + Space for hands-free recording." }
        if preferences.fnBehavior == .hold { return "Hold Control to record, then release to finish. A quick tap starts hands-free recording." }
        return "Tap Control to record. Tap again to finish."
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Settings").font(.system(size: 23, weight: .semibold))
                    Text("Recording, shortcuts, and transcription.").font(.system(size: 12)).foregroundStyle(Palette.muted)
                }
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(.borderedProminent).tint(Palette.accent).keyboardShortcut(.defaultAction)
            }.padding(.horizontal, 24).padding(.vertical, 22)
            Divider().overlay(Palette.line)
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    section("Shortcut") {
                        HStack(alignment: .top, spacing: 20) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("Record from any app").font(.system(size: 13, weight: .medium))
                                Text(shortcutInstruction).font(.system(size: 12)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                            ShortcutKeys(fn: true, selectedKey: preferences.dictationKey)
                        }
                        Divider().overlay(Palette.line)
                        HStack {
                            Text("Dictation key")
                            Spacer()
                            Picker("Dictation key", selection: $preferences.dictationKey) {
                                ForEach(DictationKey.allCases, id: \.self) { key in Text(key.rawValue).tag(key) }
                            }.labelsHidden().frame(width: 180)
                        }
                        settingToggle("Enable shortcut", subtitle: "Record using your selected dictation key.", value: $preferences.fnEnabled)
                        if preferences.fnEnabled {
                            HStack {
                                Text("Key behavior")
                                Spacer()
                                Picker("Key behavior", selection: $preferences.fnBehavior) {
                                    ForEach(FnBehavior.allCases, id: \.self) { behavior in Text(behavior.rawValue).tag(behavior) }
                                }.labelsHidden().frame(width: 180)
                            }
                            HStack(alignment: .center, spacing: 10) {
                                Image(systemName: model.fnSignalSeen ? "checkmark.circle.fill" : "keyboard")
                                    .foregroundStyle(model.fnSignalSeen ? Palette.green : Palette.muted)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(model.fnAvailable ? (model.fnSignalSeen ? "\(preferences.dictationKey.name) detected" : "Shortcut ready") : "Accessibility permission required")
                                        .font(.system(size: 12, weight: .medium))
                                    Text(preferences.dictationKey == .control ? "Control combinations continue to work normally." : model.fnAvailable ? "Test your key to check that this keyboard sends an Fn signal." : "Allow Accessibility access to use Fn in other apps.")
                                        .font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 8)
                                if !model.fnAvailable { Button("Enable") { model.requestAccessibility() }.buttonStyle(.bordered) }
                                Button("Test key") { model.startFnTest() }.buttonStyle(.bordered).disabled(model.speech.phase.isBusy)
                            }
                            if preferences.dictationKey == .fn, let note = KeyboardInfo.fnNote(for: model.keyboardNames) {
                                Text(note).font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(3)
                            }
                            if preferences.dictationKey == .fn {
                                Text("To prevent emoji or Dictation from opening, select “Do Nothing” for “Press 🌐 key to” in System Settings → Keyboard.")
                                    .font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(3)
                            }
                        }
                        Divider().overlay(Palette.line)
                        HStack {
                            Text("Alternate shortcut").foregroundStyle(Palette.muted)
                            Spacer()
                            ShortcutKeys()
                        }
                        Text("Press Esc to stop and keep an unfinished recording.").font(.system(size: 11)).foregroundStyle(Palette.muted)
                    }
                    section("Microphone") {
                        HStack {
                            Text("Input device")
                            Spacer()
                            Picker("Microphone", selection: $preferences.microphoneUID) {
                                Text("System default").tag("")
                                if !preferences.microphoneUID.isEmpty && !model.microphones.contains(where: { $0.id == preferences.microphoneUID }) {
                                    Text("Selected microphone · disconnected").tag(preferences.microphoneUID)
                                }
                                ForEach(model.microphones) { microphone in Text(microphone.name).tag(microphone.id) }
                            }.labelsHidden().frame(width: 280).disabled(model.speech.phase.isBusy)
                        }
                        Divider().overlay(Palette.line)
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(model.microphoneCheck.isRunning ? model.microphoneCheck.name : "Input level test").font(.system(size: 12, weight: .medium))
                                Text(model.microphoneCheck.isRunning ? model.microphoneCheck.signal.label : "Speak normally to check your microphone. Audio is not saved.")
                                    .font(.system(size: 11)).foregroundStyle(Palette.muted)
                            }
                            Spacer()
                            Button(model.microphoneCheck.isRunning ? "Stop test" : "Test microphone") { model.toggleMicrophoneCheck() }
                                .buttonStyle(.bordered).disabled(model.speech.phase.isBusy)
                        }
                        if model.microphoneCheck.isRunning {
                            HStack(spacing: 12) {
                                ProgressView(value: Double(model.microphoneCheck.signal.level)).tint(Palette.green)
                                Text(String(format: "%.0f dB", model.microphoneCheck.signal.decibels)).font(.system(size: 11)).monospacedDigit().foregroundStyle(Palette.muted).frame(width: 48)
                            }.accessibilityLabel("Microphone input level \(Int(model.microphoneCheck.signal.decibels)) decibels")
                        }
                        if let error = model.microphoneCheck.error { Text(error).font(.system(size: 11)).foregroundStyle(Palette.accent) }
                        Button("Refresh devices") { model.refreshPermissions() }.font(.system(size: 12)).buttonStyle(.link)
                    }
                    section("Transcription") {
                        HStack {
                            Text("Speech engine")
                            Spacer()
                            Picker("Speech engine", selection: $preferences.recognitionEngine) {
                                ForEach(RecognitionEngine.allCases, id: \.self) { engine in Text(engine.rawValue).tag(engine) }
                            }.labelsHidden().frame(width: 180).disabled(model.speech.phase.isBusy)
                        }
                        Text(preferences.recognitionEngine.subtitle).font(.system(size: 11)).foregroundStyle(Palette.muted)
                        if preferences.recognitionEngine == .parakeet {
                            HStack(spacing: 12) {
                                Label(model.parakeetReady ? "Model ready · available offline" : model.parakeetInstalling ? "Preparing model…" : model.parakeetPreparationError != nil ? "Couldn’t prepare model" : "Download the model to transcribe offline.", systemImage: model.parakeetReady ? "checkmark.circle" : model.parakeetPreparationError != nil ? "exclamationmark.circle" : "arrow.down.circle")
                                    .font(.system(size: 11)).foregroundStyle(model.parakeetReady ? Palette.green : Palette.muted)
                                Spacer()
                                if !model.parakeetReady {
                                    Button(model.parakeetPreparationError != nil ? "Retry preparation" : "Download model") { model.prepareParakeet() }.buttonStyle(.bordered).disabled(model.parakeetInstalling)
                                }
                            }
                            if let preparationError = model.parakeetPreparationError, !model.parakeetInstalling {
                                Text(preparationError).font(.system(size: 11)).foregroundStyle(Palette.muted)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if model.parakeetInstalling { ProgressView(value: model.parakeetProgress).tint(Palette.accent) }
                        }
                        HStack {
                            Text("Language")
                            Spacer()
                            Picker("Speech language", selection: $preferences.locale) {
                                if !model.speech.supportedLanguages.contains(where: { $0.identifier == preferences.locale }) {
                                    Text(Locale.current.localizedString(forIdentifier: preferences.locale) ?? preferences.locale).tag(preferences.locale)
                                }
                                ForEach(model.speech.supportedLanguages, id: \.identifier) { locale in
                                    Text(Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier).tag(locale.identifier)
                                }
                            }.labelsHidden().frame(width: 250).disabled(model.speech.phase.isBusy)
                        }
                        Divider().overlay(Palette.line)
                        settingToggle("Copy to clipboard", subtitle: "Copy the finished transcript automatically.", value: $preferences.autoCopy)
                        settingToggle("Insert into active app", subtitle: "Paste the transcript at your cursor when recording finishes.", value: $preferences.autoPaste)
                        if preferences.autoPaste {
                            HStack(spacing: 10) {
                                Image(systemName: model.accessibilityEnabled ? "checkmark.shield" : "cursorarrow.click.2").foregroundStyle(model.accessibilityEnabled ? Palette.green : Palette.muted)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(model.accessibilityEnabled ? "Insertion enabled" : "Accessibility permission required").font(.system(size: 12, weight: .medium))
                                    Text(model.accessibilityEnabled ? "Keep the destination app focused when recording finishes." : "Allow Murmur in Accessibility to insert text into other apps.")
                                        .font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer()
                                if !model.accessibilityEnabled { Button("Enable") { model.requestAccessibility() }.buttonStyle(.bordered) }
                            }
                            Button("Test insertion") { model.testInsertion() }
                                .buttonStyle(.bordered).disabled(!model.accessibilityEnabled || model.speech.phase.isBusy)
                            Text("Click a text box within 8 seconds. Murmur will insert a test sentence without recording audio.")
                                .font(.system(size: 11)).foregroundStyle(Palette.muted)
                        }
                    }
                    section("Recordings") {
                        settingToggle("Save audio", subtitle: "Keep recordings on this Mac for playback and transcription retries.", value: $preferences.keepAudio)
                        settingToggle("Recording sounds", subtitle: "Play a sound when recording starts and stops.", value: $preferences.sounds)
                        HStack(spacing: 10) {
                            Button { model.playSound("start") } label: { Label("Preview start", systemImage: "speaker.wave.1") }
                            Button { model.playSound("finish") } label: { Label("Preview stop", systemImage: "speaker.wave.1") }
                        }.buttonStyle(.bordered).disabled(!preferences.sounds)
                        Divider().overlay(Palette.line)
                        HStack {
                            Text("Saved in Application Support / Murmur.").font(.system(size: 11)).foregroundStyle(Palette.muted)
                            Spacer()
                            Button("Show folder") { NSWorkspace.shared.open(model.storage.root) }.font(.system(size: 12)).buttonStyle(.link)
                        }
                    }
                    section("Vocabulary") {
                        Text("Add names or phrases that need correction. Replacements apply to every engine; Whisper also uses them as recognition hints.")
                            .font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(3)
                        HStack(spacing: 8) {
                            TextField("Recognized text", text: $heardWord).textFieldStyle(.roundedBorder)
                            Image(systemName: "arrow.right").foregroundStyle(Palette.muted)
                            TextField("Replacement", text: $desiredWord).textFieldStyle(.roundedBorder)
                            Button("Add") {
                                model.rememberCorrection(heard: heardWord, desired: desiredWord); heardWord = ""; desiredWord = ""
                            }.buttonStyle(.bordered).disabled(heardWord.trimmingCharacters(in: .whitespaces).isEmpty || desiredWord.trimmingCharacters(in: .whitespaces).isEmpty)
                        }.font(.system(size: 12))
                        TextEditor(text: $preferences.vocabulary).font(.system(size: 12, design: .monospaced))
                            .scrollContentBackground(.hidden).padding(8).frame(height: 90)
                            .background(Palette.canvas, in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Palette.line, lineWidth: 1))
                            .overlay(alignment: .topLeading) {
                                if preferences.vocabulary.isEmpty { Text("mer mer => Murmur\nfig ma => Figma").font(.system(size: 12, design: .monospaced)).foregroundStyle(Palette.muted.opacity(0.6)).padding(13).allowsHitTesting(false) }
                            }.accessibilityLabel("Vocabulary replacements")
                    }
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "lock.shield").font(.system(size: 14)).foregroundStyle(Palette.muted)
                        Text("Transcription runs on your Mac. Models may download during setup; your recordings stay on this device.")
                            .font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(3)
                    }.padding(.horizontal, 4)
                }.padding(24)
            }
        }.font(.system(size: 13)).frame(width: 660, height: 690).background(Palette.canvas).foregroundStyle(Palette.ink).preferredColorScheme(.light)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refreshPermissions() }
        .onAppear { model.refreshPermissions() }
        .onDisappear { model.microphoneCheck.stop() }
        .onChange(of: preferences.microphoneUID) { _, _ in model.microphoneCheck.stop() }
        .onChange(of: preferences.recognitionEngine) { _, engine in if engine == .parakeet { model.prepareParakeet(install: false) } }
        .sheet(isPresented: $model.isTestingFn) { FnTestView(model: model) }
    }
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink).padding(.horizontal, 2)
            VStack(alignment: .leading, spacing: 15) {
                content()
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.line, lineWidth: 1))
        }
    }
    private func settingToggle(_ title: String, subtitle: String, value: Binding<Bool>) -> some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(subtitle).font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle(title, isOn: value).toggleStyle(.switch).labelsHidden().tint(Palette.accent).controlSize(.small)
        }
    }
}

struct FnTestView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var spaceReceived = false
    @State private var monitor: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Test shortcut").font(.system(size: 21, weight: .semibold))
                    Text("Check that your keyboard sends the selected key.").font(.system(size: 12)).foregroundStyle(Palette.muted)
                }
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(.borderedProminent).tint(Palette.accent).keyboardShortcut(.defaultAction)
            }
            HStack(spacing: 16) {
                Text(model.preferences.dictationKey.keyCap).font(.system(size: 23, weight: .medium))
                    .frame(width: 60, height: 60)
                    .foregroundStyle(model.fnTestPresses > 0 ? Palette.green : Palette.ink)
                    .background(model.fnTestPresses > 0 ? Palette.green.opacity(0.08) : Palette.canvas, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(model.fnTestPresses > 0 ? Palette.green.opacity(0.25) : Palette.line, lineWidth: 1))
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.fnTestPresses > 0 ? "\(model.preferences.dictationKey.name) detected · \(model.fnTestPresses) press\(model.fnTestPresses == 1 ? "" : "es")" : "Waiting for \(model.preferences.dictationKey.name)")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Press \(model.preferences.dictationKey.name), then release it.").font(.system(size: 12)).foregroundStyle(Palette.muted)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.line, lineWidth: 1))
            Label(spaceReceived ? "Space detected. You can now test \(model.preferences.dictationKey.name)." : "Press Space to check that this window is receiving keys.",
                  systemImage: spaceReceived ? "checkmark.circle.fill" : "keyboard")
                .font(.system(size: 12)).foregroundStyle(spaceReceived ? Palette.green : Palette.muted)
            if model.preferences.dictationKey == .fn, model.fnTestPresses == 0, let note = KeyboardInfo.fnNote(for: model.keyboardNames) {
                Text(note).font(.system(size: 12)).foregroundStyle(Palette.muted).lineSpacing(4)
            }
            Text("This test does not use the microphone or save a recording.")
                .font(.system(size: 11)).foregroundStyle(Palette.muted)
        }.padding(24).frame(width: 560).background(Palette.canvas).foregroundStyle(Palette.ink)
            .animation(.easeOut(duration: 0.15), value: model.fnTestPresses)
            .onAppear {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    if event.keyCode == 49 && !event.modifierFlags.contains(.function) {
                        spaceReceived = true
                        return nil
                    }
                    return event
                }
            }
            .onDisappear {
                if let monitor { NSEvent.removeMonitor(monitor) }
                model.endFnTest()
            }
    }
}


struct RecorderHUD: View {
    @ObservedObject var model: AppModel
    private var listening: Bool { model.speech.phase == .recording }
    private var hasWords: Bool { listening && !model.speech.liveText.isEmpty }
    private var width: CGFloat { !model.hudVisible ? 58 : hasWords ? 420 : listening ? 350 : model.hudMessage != nil ? 290 : 286 }
    private var height: CGFloat { hasWords && model.hudVisible ? 104 : 58 }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 11) {
                topRow
                if hasWords && model.hudVisible {
                    Text(String(model.speech.liveText.suffix(160)))
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.70))
                        .lineLimit(2).lineSpacing(3).frame(maxWidth: .infinity, alignment: .leading)
                        .transition(.opacity)
                }
            }.padding(.horizontal, 17).padding(.vertical, 13)
                .frame(width: width, height: height, alignment: .topLeading)
                .background(Color(hex: 0x17191D), in: RoundedRectangle(cornerRadius: hasWords ? 23 : 29))
                .overlay(RoundedRectangle(cornerRadius: hasWords ? 23 : 29).strokeBorder(.white.opacity(0.14), lineWidth: 1))
                .shadow(color: .black.opacity(0.22), radius: 14, y: 5)
                .opacity(model.hudVisible ? 1 : 0).scaleEffect(model.hudVisible ? 1 : 0.75)
                .animation(.spring(response: 0.34, dampingFraction: 0.88), value: model.hudVisible)
                .animation(.spring(response: 0.34, dampingFraction: 0.88), value: model.speech.phase)
                .animation(.spring(response: 0.34, dampingFraction: 0.88), value: hasWords)
                .animation(.spring(response: 0.34, dampingFraction: 0.88), value: model.hudMessage)
                .padding(.bottom, 18)
        }.frame(width: 480, height: 170).preferredColorScheme(.dark)
    }

    private var topRow: some View {
        HStack(spacing: 11) {
            ZStack {
                Circle().fill(.white.opacity(0.07)).frame(width: 30, height: 30)
                Image(systemName: model.hudMessage != nil ? "checkmark" : "waveform")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(model.hudMessage != nil ? Color(hex: 0x96C8AA) : .white.opacity(0.85))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(model.hudMessage ?? (listening ? "Recording" : model.speech.phase.label))
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
                Text(model.hudMessage != nil ? "Saved in your library" : listening ? (model.speech.signal.hasFrames && model.speech.signal.audibleSeconds < 0.5 && model.speech.elapsed > 3 ? "Quiet input · check your microphone" : model.fnHoldInProgress ? "Release \(model.preferences.dictationKey.name) to finish" : "\(model.recordingTime) · \(model.speech.inputName)") : "On-device transcription")
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.5)).monospacedDigit().lineLimit(1)
            }
            Spacer(minLength: 2)
            if listening {
                MeterBars(level: model.speech.level, active: true, color: Color(hex: 0xAFC4F5)).frame(width: 35, height: 25)
                Button(action: model.toggleRecording) {
                    Image(systemName: "stop.fill").font(.system(size: 8)).foregroundStyle(.white.opacity(0.85))
                        .frame(width: 24, height: 24).background(.white.opacity(0.1), in: Circle())
                }.buttonStyle(.plain).help("Finish recording").accessibilityLabel("Finish recording")
            } else if model.hudMessage == nil {
                ProgressView().controlSize(.small).tint(.white.opacity(0.6)).frame(width: 20)
            }
        }.opacity(model.hudVisible ? 1 : 0)
    }
}

struct MeterBars: View {
    let level: Float
    let active: Bool
    var color: Color = Palette.accent
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.05, paused: !active)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                ForEach(0..<7) { index in
                    Capsule().fill(color.opacity(0.85))
                        .frame(width: 2, height: active ? 4 + CGFloat(level) * 19 * (0.35 + 0.65 * abs(sin(time * 7 + Double(index)))) : 4)
                }
            }.frame(height: 25)
        }.accessibilityHidden(true)
    }
}
