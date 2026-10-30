import AppKit
import SwiftUI

// MARK: List column

struct MeetingsColumn: View {
    @ObservedObject var center: MeetingCenter
    @FocusState private var searchFocused: Bool

    var body: some View {
        let visible = center.visible
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Meetings").font(.system(size: 13, weight: .semibold))
                    Text(visible.isEmpty ? "Notes from your calls" : "\(visible.count) meeting\(visible.count == 1 ? "" : "s")")
                        .font(.system(size: 11)).foregroundStyle(Palette.muted)
                }
                Spacer(minLength: 8)
                IconButton(symbol: center.liveID == nil ? "record.circle" : "stop.circle", help: center.liveID == nil ? "Take meeting notes" : "End meeting",
                           tint: center.liveID == nil ? Palette.muted : Palette.red) {
                    center.liveID == nil ? center.start() : center.stop()
                }
            }.padding(.leading, 16).padding(.trailing, 8).frame(height: 52)
            SearchField(text: $center.search, focused: $searchFocused).padding(.horizontal, 10).padding(.bottom, 6)
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    if center.search.isEmpty { upcoming }
                    ForEach(MeetingDay.group(visible)) { day in
                        Text(day.label).font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.muted)
                            .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 5)
                        ForEach(day.meetings) { meeting in
                            MeetingRow(meeting: meeting, selected: center.selectedID == meeting.id, live: center.liveID == meeting.id,
                                       writing: center.writing[meeting.id] != nil) { center.selectedID = meeting.id }
                                .contextMenu {
                                    Button("Copy Notes") { copyNotes(meeting) }.disabled(meeting.notes == nil)
                                    Button("Rewrite Notes") { center.writeNotes(meeting.id) }.disabled(meeting.status == .live)
                                    Divider()
                                    Button("Delete Meeting", role: .destructive) { center.trash(meeting.id) }.disabled(meeting.status == .live)
                                }
                        }
                    }
                    if visible.isEmpty && !center.search.isEmpty {
                        Text("No meetings match.").font(.system(size: 12)).foregroundStyle(Palette.muted).frame(maxWidth: .infinity).padding(30)
                    }
                }.padding(.horizontal, 8).padding(.bottom, 12)
            }.scrollIndicators(.automatic)
        }.background(Palette.canvas)
            .onAppear { center.refreshCalendar() }
    }

    private func copyNotes(_ meeting: Meeting) {
        guard let notes = meeting.notes else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(notes.markdown(title: meeting.displayTitle, date: meeting.createdAt, myNotes: meeting.myNotes), forType: .string)
    }

    @ViewBuilder private var upcoming: some View {
        if center.calendarConnected {
            if !center.upcoming.isEmpty {
                Text("Coming up").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.muted)
                    .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 5)
                ForEach(center.upcoming.prefix(4)) { event in EventRow(event: event, center: center) }
            }
        } else {
            Button { center.connectCalendar() } label: {
                HStack(spacing: 10) {
                    Image(systemName: "calendar").font(.system(size: 14)).foregroundStyle(Palette.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Connect your calendar").font(.system(size: 12.5, weight: .medium))
                        Text("Name meetings and see who’s there").font(.system(size: 11)).foregroundStyle(Palette.muted)
                    }
                    Spacer()
                }.padding(10).background(Palette.wash, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }.buttonStyle(.plain).padding(.horizontal, 4).padding(.top, 6)
        }
    }
}

struct MeetingDay: Identifiable {
    let id: Date
    let label: String
    var meetings: [Meeting]
    static func group(_ meetings: [Meeting]) -> [MeetingDay] {
        var days: [MeetingDay] = []
        let calendar = Calendar.current
        for meeting in meetings {
            let day = calendar.startOfDay(for: meeting.createdAt)
            if days.last?.id == day { days[days.count - 1].meetings.append(meeting) }
            else {
                let label = calendar.isDateInToday(day) ? "Today" : calendar.isDateInYesterday(day) ? "Yesterday" : day.formatted(.dateTime.weekday(.wide).month(.wide).day())
                days.append(MeetingDay(id: day, label: label, meetings: [meeting]))
            }
        }
        return days
    }
}

struct EventRow: View {
    let event: MeetingCenter.CalendarEvent
    @ObservedObject var center: MeetingCenter
    @State private var hovered = false
    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2).fill(event.isNow ? Palette.red : Palette.accent).frame(width: 3, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                Text(event.isNow ? "Now · \(event.start.formatted(date: .omitted, time: .shortened))" :
                        "\(event.start.formatted(date: .omitted, time: .shortened)) – \(event.end.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 11)).foregroundStyle(event.isNow ? Palette.red : Palette.muted)
            }
            Spacer(minLength: 4)
            if hovered || event.isNow {
                Button(event.joinURL == nil ? "Notes" : "Join") { center.join(event) }
                    .buttonStyle(QuietButtonStyle(tint: Palette.accent)).disabled(center.liveID != nil)
            }
        }.padding(.horizontal, 8).padding(.vertical, 6)
            .background(hovered ? Palette.hover : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .onHover { hovered = $0 }
    }
}

struct MeetingRow: View {
    let meeting: Meeting
    let selected: Bool
    let live: Bool
    let writing: Bool
    let select: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if live { LivePulse() }
                    Text(meeting.displayTitle).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                }
                HStack(spacing: 6) {
                    Text(meeting.createdAt.formatted(.dateTime.hour().minute())).foregroundStyle(Palette.ink.opacity(0.7))
                    Text(detail).foregroundStyle(Palette.muted).lineLimit(1)
                }.font(.system(size: 12))
            }.padding(.horizontal, 12).padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(selected ? Palette.selection : hovered ? Palette.hover : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).onHover { hovered = $0 }
    }

    private var detail: String {
        if live { return "Recording · \(meeting.app.isEmpty ? "on this Mac" : meeting.app)" }
        if writing { return "Writing notes…" }
        var parts = [meeting.durationLabel]
        if !meeting.app.isEmpty { parts.append(meeting.app) }
        if let summary = meeting.notes?.summary, !summary.isEmpty { parts = [meeting.durationLabel, summary] }
        return parts.joined(separator: " · ")
    }
}

struct LivePulse: View {
    @State private var on = false
    var body: some View {
        Circle().fill(Palette.red).frame(width: 7, height: 7).opacity(on ? 0.35 : 1)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
    }
}

// MARK: Home (nothing selected)

struct MeetingsHome: View {
    @ObservedObject var center: MeetingCenter

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                ZStack {
                    Circle().fill(Palette.red.opacity(0.1)).frame(width: 74, height: 74)
                    Image(systemName: "person.2.wave.2.fill").font(.system(size: 28)).foregroundStyle(Palette.red)
                }.padding(.top, 70)
                Text("Notes for every meeting").font(.system(size: 24, weight: .semibold)).tracking(-0.4)
                Text("When a call starts in Zoom, Meet, Teams, Slack, FaceTime or anywhere else, Murmur offers to take notes. It listens to both sides on this Mac, then writes a summary, decisions and action items. Nothing leaves your Mac and nothing joins your call.")
                    .font(.system(size: 13)).foregroundStyle(Palette.muted).multilineTextAlignment(.center).lineSpacing(3).frame(maxWidth: 460)
                Button { center.start() } label: { Label("Start taking notes", systemImage: "record.circle") }
                    .buttonStyle(PrimaryButtonStyle()).disabled(center.liveID != nil)
                HStack(spacing: 10) {
                    HomeFact(symbol: "waveform.badge.mic", title: "Both sides", detail: "You from the mic, them from your Mac’s audio")
                    HomeFact(symbol: "text.bubble", title: "Live transcript", detail: "Words appear while people talk")
                    HomeFact(symbol: "sparkles", title: "Written for you", detail: "By a free AI model on this Mac")
                }.frame(maxWidth: 600).padding(.top, 10)
                MeetingSettings(center: center).frame(maxWidth: 600).padding(.top, 6)
            }.frame(maxWidth: .infinity).padding(.horizontal, 40).padding(.bottom, 40)
        }
    }
}

struct HomeFact: View {
    let symbol: String, title: String, detail: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: symbol).font(.system(size: 15)).foregroundStyle(Palette.accent)
            Text(title).font(.system(size: 12.5, weight: .semibold))
            Text(detail).font(.system(size: 11.5)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
        }.padding(12).frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
            .background(Palette.wash, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct MeetingSettings: View {
    @ObservedObject var center: MeetingCenter
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row("When a call starts", symbol: "phone.arrow.up.right") {
                Picker("", selection: $center.autoStart) { ForEach(MeetingCenter.AutoStart.allCases) { Text($0.rawValue).tag($0) } }
                    .labelsHidden().frame(width: 190)
            }
            Hairline()
            row("Stop when the call ends", symbol: "stop.circle") { Toggle("", isOn: $center.autoStop).labelsHidden().toggleStyle(.switch).controlSize(.small) }
            Hairline()
            row("Record the other side", symbol: "speaker.wave.2") { Toggle("", isOn: $center.captureSystemAudio).labelsHidden().toggleStyle(.switch).controlSize(.small) }
            Hairline()
            row("Notes style", symbol: "list.bullet.rectangle") {
                Picker("", selection: $center.defaultTemplate) { ForEach(MeetingTemplate.allCases) { Label($0.rawValue, systemImage: $0.symbol).tag($0) } }
                    .labelsHidden().frame(width: 190)
            }
            Hairline()
            row("Written by", symbol: "cpu") {
                Text(center.writerName.isEmpty ? "Checking…" : center.writerName == "Murmur" ? "Basic notes · install Ollama for AI notes" : "\(center.writerName) · on this Mac")
                    .font(.system(size: 12.5)).foregroundStyle(Palette.muted)
            }
        }.background(Palette.wash.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .onAppear { center.refreshWriter() }
    }

    private func row<Value: View>(_ title: String, symbol: String, @ViewBuilder value: () -> Value) -> some View {
        HStack {
            Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(Palette.muted).frame(width: 18)
            Text(title).font(.system(size: 13))
            Spacer()
            value()
        }.padding(.horizontal, 14).frame(height: 42)
    }
}

// MARK: Meeting page

struct MeetingPage: View {
    @ObservedObject var center: MeetingCenter
    let id: UUID
    @State private var tab: Tab = .notes
    @State private var showTranscript = true
    @State private var copied = false
    @State private var confirmDelete = false
    enum Tab: String, CaseIterable { case notes = "Notes", transcript = "Transcript", mine = "My notes" }

    private var meeting: Meeting? { center.meetings.first { $0.id == id } }

    var body: some View {
        if let meeting {
            VStack(spacing: 0) {
                topBar(meeting)
                if meeting.status == .live { livePage(meeting) } else { finishedPage(meeting) }
            }
            .alert("Delete this meeting?", isPresented: $confirmDelete) {
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) { center.trash(id) }
            } message: { Text("Its notes and transcript are removed from Murmur.") }
        }
    }

    // MARK: Top

    private func topBar(_ meeting: Meeting) -> some View {
        HStack(spacing: 2) {
            HStack(spacing: 6) {
                Button { center.selectedID = nil } label: { Text("Meetings").foregroundStyle(Palette.muted) }.buttonStyle(.plain)
                Text("/").foregroundStyle(Palette.faint)
                Text(meeting.displayTitle).lineLimit(1)
            }.font(.system(size: 12.5)).padding(.leading, 8)
            Spacer(minLength: 12)
            if meeting.status == .live {
                IconButton(symbol: "sidebar.right", help: showTranscript ? "Hide transcript" : "Show transcript") {
                    withAnimation(.easeOut(duration: 0.15)) { showTranscript.toggle() }
                }
            }
            if meeting.status != .live {
                Menu {
                    ForEach(MeetingTemplate.allCases) { template in
                        Button { center.writeNotes(id, template: template) } label: { Label(template.rawValue, systemImage: template.symbol) }
                    }
                } label: { Image(systemName: "wand.and.stars").font(.system(size: 13.5)).foregroundStyle(Palette.muted) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 28, height: 28)
                    .help("Rewrite notes in a style").disabled(center.writing[id] != nil)
                IconButton(symbol: copied ? "checkmark" : "doc.on.doc", help: "Copy notes as Markdown", tint: copied ? Palette.green : Palette.muted) {
                    copy(meeting); copied = true
                    Task { try? await Task.sleep(for: .seconds(1.4)); copied = false }
                }.disabled(meeting.notes == nil)
                IconButton(symbol: "envelope", help: "Email a follow-up") { email(meeting) }.disabled(meeting.notes == nil)
                IconButton(symbol: "square.and.arrow.up", help: "Export notes") { export(meeting) }.disabled(meeting.notes == nil)
                IconButton(symbol: "trash", help: "Delete meeting") { confirmDelete = true }
            }
        }.padding(.horizontal, 10).frame(height: 52)
    }

    private func header(_ meeting: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Untitled meeting", text: Binding(get: { center.meetings.first { $0.id == id }?.title ?? "" },
                                                       set: { value in center.update(id) { $0.title = value.replacingOccurrences(of: "\n", with: " ") } }),
                      prompt: Text(meeting.displayTitle), axis: .vertical)
                .textFieldStyle(.plain).font(.system(size: 28, weight: .bold)).tracking(-0.6).lineLimit(1...3)
            FlowLayout(spacing: 8) {
                Chip(symbol: "calendar", text: meeting.createdAt.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()))
                if !meeting.app.isEmpty { Chip(symbol: "video", text: meeting.app) }
                if meeting.status != .live { Chip(symbol: "clock", text: meeting.durationLabel) }
                if !meeting.attendees.isEmpty {
                    Chip(symbol: "person.2", text: meeting.attendees.prefix(3).joined(separator: ", ") + (meeting.attendees.count > 3 ? " +\(meeting.attendees.count - 3)" : ""))
                }
                Menu {
                    ForEach(MeetingTemplate.allCases) { template in
                        Button { center.update(id) { $0.template = template }; if meeting.status == .done { center.writeNotes(id, template: template) } } label: {
                            Label(template.rawValue, systemImage: template.symbol)
                        }
                    }
                } label: { Chip(symbol: meeting.template.symbol, text: meeting.template.rawValue) }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                    .help("Notes style")
            }
        }
    }

    // MARK: Live

    private func livePage(_ meeting: Meeting) -> some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                header(meeting).padding(.bottom, 16)
                LiveBar(center: center, meeting: meeting).padding(.bottom, 16)
                if center.otherSideSilent && center.systemAudioWarning == nil {
                    Callout(symbol: "speaker.slash", tint: Palette.star) {
                        Text("Murmur hears you but not the others. If they’re talking, allow Murmur in System Settings → Privacy & Security → Screen & System Audio Recording, under System Audio Recording Only.")
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Open Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!)
                        }.buttonStyle(QuietButtonStyle(tint: Palette.accent)).padding(.leading, -8)
                    }.padding(.bottom, 12)
                }
                if let warning = center.systemAudioWarning {
                    Callout(symbol: "speaker.slash", tint: Palette.star) { Text(warning).fixedSize(horizontal: false, vertical: true) }.padding(.bottom, 12)
                }
                Text("Your notes").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.muted).padding(.bottom, 6)
                NotesEditor(text: Binding(get: { center.meetings.first { $0.id == id }?.myNotes ?? "" },
                                          set: { value in center.update(id) { $0.myNotes = value } }),
                            placeholder: "Jot down anything that matters. Murmur fills in the rest from the conversation when the meeting ends.")
                LiveAnswer(center: center, meeting: meeting).padding(.bottom, 10)
                MeetingAskBar(center: center, id: id, prompts: MeetingAskBar.livePrompts, placeholder: "Ask about the meeting so far…")
            }.frame(maxWidth: 680, alignment: .leading)
                .padding(.horizontal, 44).padding(.top, 10).padding(.bottom, 20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            if showTranscript {
                Hairline(vertical: true)
                TranscriptPanel(meeting: meeting, me: center.userName, live: true, pending: center.pendingPieces).frame(width: 360)
            }
        }
    }

    // MARK: Finished

    private func finishedPage(_ meeting: Meeting) -> some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        header(meeting).padding(.bottom, 18)
                        Picker("", selection: $tab) { ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                            .pickerStyle(.segmented).labelsHidden().frame(width: 290).padding(.bottom, 20)
                        switch tab {
                        case .notes: notesBody(meeting)
                        case .transcript:
                            TranscriptList(meeting: meeting, me: center.userName).padding(.bottom, 20)
                        case .mine:
                            NotesEditor(text: Binding(get: { center.meetings.first { $0.id == id }?.myNotes ?? "" },
                                                      set: { value in center.update(id) { $0.myNotes = value } }),
                                        placeholder: "Your own notes. Rewrite the notes (wand button) to fold changes in.").frame(minHeight: 300)
                        }
                        if tab == .notes { chat(meeting).id("chat") }
                    }.frame(maxWidth: 700, alignment: .leading)
                        .padding(.horizontal, 52).padding(.top, 10).padding(.bottom, 24)
                        .frame(maxWidth: .infinity, alignment: .top)
                }.onChange(of: meeting.chat.count) { _, _ in withAnimation { proxy.scrollTo("chat", anchor: .bottom) } }
                    .onChange(of: center.answerDrafts[id]?.count ?? 0) { _, _ in proxy.scrollTo("chat", anchor: .bottom) }
            }
            if tab == .notes { askBar(meeting) }
        }
    }

    @ViewBuilder private func notesBody(_ meeting: Meeting) -> some View {
        if let step = center.writing[id] {
            if let draft = center.drafts[id], !draft.summary.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    WritingStatus(step: "Writing…")
                    NotesView(notes: draft, onToggle: { _ in }, writing: true)
                }
            } else {
                WritingPlaceholder(step: step)
            }
        } else if let notes = meeting.notes {
            NotesView(notes: notes, onToggle: { center.toggleAction(id, $0) })
        } else if meeting.status == .failed {
            Callout(symbol: "exclamationmark.triangle") {
                Text("The notes couldn’t be written.")
                Button("Try again") { center.writeNotes(id) }.buttonStyle(PrimaryButtonStyle())
            }
        } else {
            Callout(symbol: "sparkles") {
                Text("No notes yet.")
                Button("Write notes") { center.writeNotes(id) }.buttonStyle(PrimaryButtonStyle())
            }
        }
    }

    @ViewBuilder private func chat(_ meeting: Meeting) -> some View {
        if !meeting.chat.isEmpty || center.asking.contains(id) {
            VStack(alignment: .leading, spacing: 14) {
                Hairline().padding(.vertical, 8)
                ForEach(meeting.chat) { turn in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(turn.question).font(.system(size: 13, weight: .semibold))
                        Text(turn.answer).font(.system(size: 13.5)).lineSpacing(4).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if center.asking.contains(id) {
                    VStack(alignment: .leading, spacing: 6) {
                        if let pending = center.pendingQuestion[id] { Text(pending).font(.system(size: 13, weight: .semibold)) }
                        if let draft = center.answerDrafts[id], !draft.isEmpty {
                            Text(draft).font(.system(size: 13.5)).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                        } else {
                            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Thinking…").foregroundStyle(Palette.muted) }.font(.system(size: 13))
                        }
                    }
                }
            }.padding(.top, 10)
        }
    }

    private func askBar(_ meeting: Meeting) -> some View {
        MeetingAskBar(center: center, id: id, prompts: meeting.chat.isEmpty ? MeetingAskBar.afterPrompts : [])
            .frame(maxWidth: 700).padding(.horizontal, 52).padding(.bottom, 16).padding(.top, 6)
    }

    private func copy(_ meeting: Meeting) {
        guard let notes = meeting.notes else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(notes.markdown(title: meeting.displayTitle, date: meeting.createdAt, myNotes: meeting.myNotes), forType: .string)
    }

    private func email(_ meeting: Meeting) {
        guard let notes = meeting.notes else { return }
        let body = notes.markdown(title: meeting.displayTitle, date: meeting.createdAt)
        let subject = "Notes: \(meeting.displayTitle)"
        if let url = URL(string: "mailto:?subject=\(CommandParser.encode(subject))&body=\(CommandParser.encode(body))") { NSWorkspace.shared.open(url) }
    }

    private func export(_ meeting: Meeting) {
        guard let notes = meeting.notes else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(meeting.displayTitle.prefix(60)).md"
        panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var text = notes.markdown(title: meeting.displayTitle, date: meeting.createdAt, myNotes: meeting.myNotes)
        text += "\n## Transcript\n\n" + MeetingTranscript.formatted(meeting.segments, me: center.userName)
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}

/// Ask anything about a meeting, with a few one-click questions.
struct MeetingAskBar: View {
    @ObservedObject var center: MeetingCenter
    let id: UUID
    var prompts: [(label: String, question: String)]
    var placeholder = "Ask anything about this meeting…"
    @State private var question = ""
    @FocusState private var focused: Bool

    static let livePrompts: [(label: String, question: String)] = [
        ("Catch me up", "Catch me up in three short bullets: what has been discussed so far and where things stand right now."),
        ("What should I ask?", "Suggest one or two sharp questions I could ask next, based on what is being discussed right now."),
        ("Action items so far", "List the action items and commitments made so far, with who owns each."),
    ]
    static let afterPrompts: [(label: String, question: String)] = [
        ("What did I commit to?", "What did I commit to? List each with its deadline."),
        ("Follow-up email", "Write a short, friendly follow-up email to the other attendees recapping decisions and next steps."),
    ]

    var body: some View {
        let busy = center.asking.contains(id)
        HStack(spacing: 8) {
            Image(systemName: "sparkles").foregroundStyle(Palette.accent)
            TextField(placeholder, text: $question).textFieldStyle(.plain).focused($focused).onSubmit { send(question, label: nil) }
            if question.isEmpty && !busy {
                ForEach(prompts, id: \.label) { prompt in
                    Button(prompt.label) { send(prompt.question, label: prompt.label) }.buttonStyle(QuietButtonStyle(tint: Palette.muted)).fixedSize()
                }
            }
            if busy { ProgressView().controlSize(.small) }
        }.font(.system(size: 13)).padding(.horizontal, 14).frame(height: 44)
            .background(Palette.wash, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(focused ? Palette.accent.opacity(0.5) : Palette.line, lineWidth: 1))
            .animation(.easeOut(duration: 0.15), value: focused)
    }

    private func send(_ text: String, label: String?) {
        let text = text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !center.asking.contains(id) else { return }
        center.ask(text, in: id, label: label)
        question = ""
    }
}

/// During a meeting: the answer to what you just asked, in a card above the ask bar.
struct LiveAnswer: View {
    @ObservedObject var center: MeetingCenter
    let meeting: Meeting
    @State private var hiddenID: UUID?

    var body: some View {
        let asking = center.asking.contains(meeting.id)
        let last = meeting.chat.last
        if asking || (last != nil && last?.id != hiddenID) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(asking ? center.pendingQuestion[meeting.id] ?? "" : last?.question ?? "")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.muted).lineLimit(1)
                    Spacer()
                    if !asking { IconButton(symbol: "xmark", help: "Hide") { hiddenID = last?.id } }
                }
                ScrollView {
                    Group {
                        if asking {
                            if let draft = center.answerDrafts[meeting.id], !draft.isEmpty { Text(draft) }
                            else { HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Reading the conversation…").foregroundStyle(Palette.muted) } }
                        } else { Text(last?.answer ?? "").textSelection(.enabled) }
                    }.font(.system(size: 13.5)).lineSpacing(4).frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                }.frame(maxHeight: 200).fixedSize(horizontal: false, vertical: true)
            }.padding(14)
                .background(Palette.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.accent.opacity(0.18), lineWidth: 1))
                .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }
}

struct Chip: View {
    let symbol: String, text: String
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 10.5))
            Text(text).lineLimit(1)
        }.font(.system(size: 12)).foregroundStyle(Palette.muted)
            .padding(.horizontal, 9).frame(height: 24)
            .background(Palette.wash, in: Capsule())
    }
}

/// The live meeting's status: timer, both sides' levels, and Stop.
struct LiveBar: View {
    @ObservedObject var center: MeetingCenter
    let meeting: Meeting
    var body: some View {
        HStack(spacing: 14) {
            LivePulse()
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(MeetingTranscript.clock(context.date.timeIntervalSince(meeting.createdAt))).font(.system(size: 13, weight: .semibold)).monospacedDigit().fixedSize()
            }
            Divider().frame(height: 16)
            LevelLabel(title: "You", level: center.micLevel, color: Palette.accent)
            LevelLabel(title: "Them", level: center.systemLevel, color: Palette.green)
            Spacer()
            Button { center.stop() } label: { Label("End meeting", systemImage: "stop.fill").fixedSize() }
                .buttonStyle(PrimaryButtonStyle()).help("Stop recording and write the notes")
        }.padding(.horizontal, 14).frame(height: 48)
            .background(Palette.wash, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct LevelLabel: View {
    let title: String
    let level: Float
    let color: Color
    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 12)).foregroundStyle(Palette.muted).fixedSize()
            LiveWaveform(level: level, bars: 6, color: color, maxHeight: 16)
        }
    }
}

struct NotesEditor: View {
    @Binding var text: String
    let placeholder: String
    var body: some View {
        TextEditor(text: $text)
            .font(.system(size: 15)).lineSpacing(6).scrollContentBackground(.hidden).padding(.horizontal, -5)
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder).font(.system(size: 15)).foregroundStyle(Palette.faint).allowsHitTesting(false)
                }
            }
    }
}

/// The live transcript beside your notes, scrolled to the newest words.
struct TranscriptPanel: View {
    let meeting: Meeting
    let me: String
    let live: Bool
    let pending: Int
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Transcript").font(.system(size: 12, weight: .semibold))
                Spacer()
                if pending > 0 { ProgressView().controlSize(.mini) }
                Text("\(meeting.wordCount) words").font(.system(size: 11)).foregroundStyle(Palette.muted).monospacedDigit()
            }.padding(.horizontal, 16).frame(height: 52)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if meeting.segments.isEmpty {
                            Text("Words appear here a moment after they’re spoken.").font(.system(size: 12.5)).foregroundStyle(Palette.faint).padding(.top, 6)
                        }
                        ForEach(meeting.segments) { segment in Bubble(segment: segment, me: me, them: MeetingsUI.them(meeting)).id(segment.id) }
                        Color.clear.frame(height: 1).id("end")
                    }.padding(.horizontal, 14).padding(.bottom, 16)
                }.onChange(of: meeting.segments.count) { _, _ in withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("end", anchor: .bottom) } }
            }
        }.background(Palette.sidebar)
    }
}

enum MeetingsUI {
    /// The other side's name when the calendar says it's a one-on-one.
    static func them(_ meeting: Meeting) -> String {
        let label = MeetingWriter.othersLabel(meeting)
        return label == "Other person" ? "Them" : label
    }
}

struct Bubble: View {
    let segment: MeetingSegment
    let me: String
    var them = "Them"
    var body: some View {
        let mine = segment.speaker == .me
        VStack(alignment: mine ? .trailing : .leading, spacing: 3) {
            Text("\(mine ? me : them) · \(MeetingTranscript.clock(segment.start))").font(.system(size: 10.5, weight: .medium)).foregroundStyle(Palette.faint)
            Text(segment.text).font(.system(size: 13)).lineSpacing(2).textSelection(.enabled)
                .padding(.horizontal, 11).padding(.vertical, 8)
                .background(mine ? Palette.accent.opacity(0.13) : Palette.canvas, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(mine ? .clear : Palette.line, lineWidth: 1))
                .fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
            .padding(mine ? .leading : .trailing, 28)
    }
}

struct TranscriptList: View {
    let meeting: Meeting
    let me: String
    var body: some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            if meeting.segments.isEmpty { Text("Nothing was transcribed.").foregroundStyle(Palette.muted) }
            ForEach(meeting.segments) { segment in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(MeetingTranscript.clock(segment.start)).font(.system(size: 11)).monospacedDigit().foregroundStyle(Palette.faint).frame(width: 44, alignment: .trailing)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(segment.speaker == .me ? me : MeetingsUI.them(meeting)).font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(segment.speaker == .me ? Palette.accent : Palette.green)
                        Text(segment.text).font(.system(size: 14)).lineSpacing(4).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}

/// The finished notes: summary, topic sections, decisions and action items.
struct NotesView: View {
    let notes: MeetingNotes
    let onToggle: (UUID) -> Void
    /// Still being written: no footer, and new lines fade in.
    var writing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if !notes.summary.isEmpty {
                Text(notes.summary).font(.system(size: 15.5)).lineSpacing(5).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(notes.sections) { section in
                block(section.heading, symbol: nil) { bullets(section.bullets) }
            }
            if !notes.actionItems.isEmpty {
                block("Action items", symbol: "checklist") {
                    ForEach(notes.actionItems) { item in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Button { onToggle(item.id) } label: {
                                Image(systemName: item.done ? "checkmark.circle.fill" : "circle").font(.system(size: 15))
                                    .foregroundStyle(item.done ? Palette.green : Palette.faint)
                            }.buttonStyle(.plain)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.task).font(.system(size: 14)).strikethrough(item.done, color: Palette.faint)
                                    .foregroundStyle(item.done ? Palette.muted : Palette.ink).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                if item.owner != nil || item.due != nil {
                                    HStack(spacing: 6) {
                                        if let owner = item.owner { Chip(symbol: "person", text: owner) }
                                        if let due = item.due { Chip(symbol: "calendar", text: due) }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            if !notes.decisions.isEmpty {
                block("Decisions", symbol: "checkmark.seal") { bullets(notes.decisions) }
            }
            if !writing { HStack(spacing: 6) {
                Image(systemName: "lock.fill").font(.system(size: 9))
                Text(notes.writer == "Murmur" ? "Basic notes made on this Mac. Install Ollama (free) for full AI notes." : "Written by \(notes.writer) on this Mac")
            }.font(.system(size: 11)).foregroundStyle(Palette.faint).padding(.top, 4) }
        }.animation(writing ? .easeOut(duration: 0.25) : nil, value: notes.sections.count + notes.actionItems.count + notes.decisions.count)
    }

    private func block<Content: View>(_ title: String, symbol: String?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                if let symbol { Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(Palette.muted) }
                Text(title).font(.system(size: 17, weight: .semibold)).tracking(-0.2)
            }
            content()
        }
    }

    private func bullets(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Circle().fill(Palette.muted).frame(width: 4.5, height: 4.5).offset(y: -2)
                    Text(item).font(.system(size: 14.5)).lineSpacing(4).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// "Writing…" above notes that are appearing.
struct WritingStatus: View {
    let step: String
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(step).font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.muted)
        }
    }
}

struct WritingPlaceholder: View {
    let step: String
    @State private var phase = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(step).font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.muted)
            }
            ForEach(0..<6, id: \.self) { index in
                RoundedRectangle(cornerRadius: 4).fill(Palette.wash)
                    .frame(width: [520, 440, 480, 300, 460, 380][index], height: 12)
                    .opacity(phase ? 0.45 : 1)
                    .animation(.easeInOut(duration: 0.9).repeatForever().delay(Double(index) * 0.08), value: phase)
            }
        }.onAppear { phase = true }
    }
}

// MARK: Floating panels

/// "Zoom call detected · Take notes?" in the corner of the screen.
struct MeetingPromptView: View {
    @ObservedObject var center: MeetingCenter
    var body: some View {
        if let call = center.detected {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(Color.red.opacity(0.18)).frame(width: 36, height: 36)
                    Image(systemName: "person.2.wave.2.fill").font(.system(size: 14, weight: .semibold)).foregroundStyle(Color(hex: 0xFF8A80))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(call.event?.title ?? "\(call.app) call").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                    Text(call.bundleID.hasPrefix("event:") ? "Starting now · \(call.app)" : "Take notes with Murmur?").font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.6))
                }
                Spacer(minLength: 6)
                Button {
                    if call.bundleID.hasPrefix("event:"), let event = call.event { center.join(event) }
                    else { center.start(app: call.app, event: call.event, fromCall: call.bundleID) }
                } label: {
                    Text(call.bundleID.hasPrefix("event:") ? "Join & take notes" : "Take notes").font(.system(size: 12, weight: .semibold)).foregroundStyle(.black)
                        .padding(.horizontal, 12).frame(height: 28).background(.white, in: Capsule())
                }.buttonStyle(.plain)
                Button { center.dismissDetected() } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white.opacity(0.55))
                        .frame(width: 24, height: 24).background(.white.opacity(0.08), in: Circle())
                }.buttonStyle(.plain).help("Not this time")
            }.padding(.leading, 12).padding(.trailing, 10).frame(width: 380, height: 62)
                .background(PaletteGlass())
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.14), lineWidth: 1))
                .shadow(color: .black.opacity(0.3), radius: 18, y: 8)
                .padding(16)
                .environment(\.colorScheme, .dark)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

/// A small pill on screen while a meeting records, so you always know.
struct MeetingPillView: View {
    @ObservedObject var center: MeetingCenter
    var open: () -> Void
    var body: some View {
        if let live = center.live {
            HStack(spacing: 9) {
                LivePulse()
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(MeetingTranscript.clock(context.date.timeIntervalSince(live.createdAt))).font(.system(size: 12, weight: .semibold)).monospacedDigit().foregroundStyle(.white)
                }
                LiveWaveform(level: max(center.micLevel, center.systemLevel), bars: 5, color: Palette.pillMeter, maxHeight: 14)
                Button(action: open) { Image(systemName: "note.text").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.8)) }
                    .buttonStyle(.plain).help("Open meeting notes")
                Button { center.stop() } label: {
                    Image(systemName: "stop.fill").font(.system(size: 8)).foregroundStyle(.white)
                        .frame(width: 20, height: 20).background(Color.red.opacity(0.8), in: Circle())
                }.buttonStyle(.plain).help("End meeting and write notes")
            }.padding(.horizontal, 12).frame(height: 36)
                .background(Palette.pill.opacity(0.94), in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.13), lineWidth: 1))
                .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
                .padding(10)
                .environment(\.colorScheme, .dark)
        }
    }
}
