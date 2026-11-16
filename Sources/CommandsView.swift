import SwiftUI

/// The Commands page in the main window.
struct CommandsPage: View {
    @ObservedObject var center: CommandCenter
    var openPalette: () -> Void
    @State private var newPhrase = ""
    @State private var newSteps = ""
    @State private var siteName = ""
    @State private var siteAddress = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                hero
                examples
                if !center.timers.isEmpty { timers }
                custom
                yourSites
                settings
                if !center.history.isEmpty { recent }
            }.frame(maxWidth: 720, alignment: .leading)
                .padding(.horizontal, 52).padding(.top, 54).padding(.bottom, 40)
                .frame(maxWidth: .infinity)
        }
    }

    private var hero: some View {
        HStack(alignment: .center, spacing: 22) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Commands").font(.system(size: 30, weight: .bold)).tracking(-0.6)
                Text("Open apps, sites, files and folders. Play any song or video. Search, set timers, control your Mac. Type it, or just say it.")
                    .font(.system(size: 13.5)).foregroundStyle(Palette.muted).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 14) {
                    Button(action: openPalette) { Label("Open Commands", systemImage: "command") }.buttonStyle(PrimaryButtonStyle())
                    HStack(spacing: 6) {
                        Text("Press").foregroundStyle(Palette.muted)
                        ShortcutKeys(keys: ["Space", "↓"])
                        Text("to type · hold to talk").foregroundStyle(Palette.muted)
                    }.font(.system(size: 12))
                }.padding(.top, 4)
            }
            Spacer(minLength: 0)
            PaletteMiniature()
        }
    }

    private var examples: some View {
        VStack(alignment: .leading, spacing: 10) {
            heading("Things you can say")
            let groups: [(String, String, [String])] = [
                ("square.grid.2x2", "Apps & places", ["Open Slack", "Open murmur in Cursor", "Open Downloads", "Quit Spotify"]),
                ("play.circle", "Music & video", ["Play Not Like Us", "Play lofi on YouTube", "Next song", "Volume 30"]),
                ("magnifyingglass", "Search & ask", ["Search Amazon for desk lamps", "Ask ChatGPT for a pitch", "Translate thank you to Burmese", "Directions to JFK"]),
                ("bolt", "Do things", ["Timer 25 minutes", "Take meeting notes", "New doc", "Run Focus Mode", "Lock screen"]),
            ]
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(groups, id: \.1) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        Label(group.1, systemImage: group.0).font(.system(size: 12.5, weight: .semibold))
                        ForEach(group.2, id: \.self) { example in
                            Button { center.query = example; openPalette() } label: {
                                Text("“\(example)”").font(.system(size: 12.5)).foregroundStyle(Palette.ink.opacity(0.85))
                            }.buttonStyle(.plain)
                        }
                    }.padding(14).frame(maxWidth: .infinity, alignment: .topLeading)
                        .background(Palette.wash, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
            Text("Say “this” to use what’s selected or a copied link: select a song name and say “play this”.")
                .font(.system(size: 12)).foregroundStyle(Palette.muted)
        }
    }

    private var timers: some View {
        VStack(alignment: .leading, spacing: 8) {
            heading("Timers")
            ForEach(center.timers) { timer in
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let left = max(0, Int(timer.ends.timeIntervalSince(context.date)))
                    HStack {
                        Image(systemName: "timer").foregroundStyle(.orange)
                        Text(timer.label)
                        Spacer()
                        Text(String(format: "%d:%02d", left / 60, left % 60)).monospacedDigit().font(.system(size: 13, weight: .semibold))
                        IconButton(symbol: "xmark", help: "Cancel timer") { center.cancelTimer(timer.id) }
                    }.font(.system(size: 13)).padding(.horizontal, 12).frame(height: 40)
                        .background(Palette.wash, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
        }
    }

    private var custom: some View {
        VStack(alignment: .leading, spacing: 10) {
            heading("Your commands")
            Text("Give a phrase several steps. Say “work mode” to open everything you need at once.")
                .font(.system(size: 12)).foregroundStyle(Palette.muted)
            ForEach(center.customCommands) { command in
                HStack(spacing: 10) {
                    Image(systemName: "sparkles").foregroundStyle(Color(hex: 0x8B5CF6))
                    Text("“\(command.phrase)”").font(.system(size: 13, weight: .semibold))
                    Image(systemName: "arrow.right").font(.system(size: 10)).foregroundStyle(Palette.faint)
                    Text(command.steps.joined(separator: " · ")).font(.system(size: 12.5)).foregroundStyle(Palette.muted).lineLimit(1)
                    Spacer()
                    IconButton(symbol: "trash", help: "Remove") { center.customCommands.removeAll { $0.id == command.id } }
                }.padding(.horizontal, 12).frame(height: 40)
                    .background(Palette.wash, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            HStack(spacing: 8) {
                TextField("Phrase, e.g. work mode", text: $newPhrase).textFieldStyle(.roundedBorder).frame(width: 190)
                TextField("Steps, separated by commas: open cursor, open slack, play lofi", text: $newSteps).textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Button("Add", action: add).buttonStyle(QuietButtonStyle(tint: Palette.accent))
                    .disabled(newPhrase.trimmingCharacters(in: .whitespaces).isEmpty || newSteps.trimmingCharacters(in: .whitespaces).isEmpty)
            }.font(.system(size: 12.5))
        }
    }

    private func add() {
        let phrase = newPhrase.trimmingCharacters(in: .whitespaces)
        let steps = newSteps.components(separatedBy: CharacterSet(charactersIn: ",;\n")).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !phrase.isEmpty, !steps.isEmpty else { return }
        center.customCommands.removeAll { $0.phrase.lowercased() == phrase.lowercased() }
        center.customCommands.append(CustomCommand(phrase: phrase, steps: steps))
        newPhrase = ""; newSteps = ""
    }

    private var yourSites: some View {
        VStack(alignment: .leading, spacing: 10) {
            heading("Your sites")
            Text("Say “open acme” and Murmur opens your site, not someone else’s. When it isn’t sure, it asks once and remembers here.")
                .font(.system(size: 12)).foregroundStyle(Palette.muted)
            ForEach(center.sites.sorted { $0.key < $1.key }, id: \.key) { name, url in
                HStack(spacing: 10) {
                    Image(systemName: "globe").foregroundStyle(Palette.accent)
                    Text("“\(name)”").font(.system(size: 13, weight: .semibold))
                    Image(systemName: "arrow.right").font(.system(size: 10)).foregroundStyle(Palette.faint)
                    Text(url.host ?? url.absoluteString).font(.system(size: 12.5)).foregroundStyle(Palette.muted).lineLimit(1)
                    Spacer()
                    IconButton(symbol: "trash", help: "Forget") { center.sites[name] = nil }
                }.padding(.horizontal, 12).frame(height: 40)
                    .background(Palette.wash, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            HStack(spacing: 8) {
                TextField("Name, e.g. acme", text: $siteName).textFieldStyle(.roundedBorder).frame(width: 190)
                TextField("Address, e.g. acme.com", text: $siteAddress).textFieldStyle(.roundedBorder).onSubmit(addSite)
                Button("Add", action: addSite).buttonStyle(QuietButtonStyle(tint: Palette.accent))
                    .disabled(SiteBook.key(siteName).isEmpty || siteAddress.trimmingCharacters(in: .whitespaces).isEmpty)
            }.font(.system(size: 12.5))
        }
    }

    private func addSite() {
        let key = SiteBook.key(siteName)
        var address = siteAddress.trimmingCharacters(in: .whitespaces).lowercased()
        guard !key.isEmpty, !address.isEmpty else { return }
        if !address.hasPrefix("http") { address = "https://" + address }
        guard let url = URL(string: address), url.host != nil else { return }
        center.sites[key] = url
        siteName = ""; siteAddress = ""
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 10) {
            heading("Settings")
            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "music.note").foregroundStyle(Palette.muted).frame(width: 18)
                    Text("Play music with")
                    Spacer()
                    Picker("", selection: $center.music) { ForEach(MusicService.allCases) { Text($0.rawValue).tag($0) } }.labelsHidden().frame(width: 170)
                }.padding(.horizontal, 14).frame(height: 42)
                Hairline()
                HStack {
                    Image(systemName: "sparkles").foregroundStyle(Palette.muted).frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Understand anything with local AI")
                        Text("When a spoken command doesn’t match, a model on this Mac works out what you meant.").font(.system(size: 11)).foregroundStyle(Palette.muted)
                    }
                    Spacer()
                    Toggle("", isOn: $center.useLocalAI).labelsHidden().toggleStyle(.switch).controlSize(.small)
                }.padding(.horizontal, 14).frame(height: 52)
                Hairline()
                HStack {
                    Image(systemName: "clock.arrow.circlepath").foregroundStyle(Palette.muted).frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Learn your sites from browser history")
                        Text("Only site names and visit counts, read on this Mac. Safari’s history needs Full Disk Access.").font(.system(size: 11)).foregroundStyle(Palette.muted)
                    }
                    Spacer()
                    Toggle("", isOn: $center.learnFromHistory).labelsHidden().toggleStyle(.switch).controlSize(.small)
                }.padding(.horizontal, 14).frame(height: 52)
            }.font(.system(size: 13)).background(Palette.wash.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private var recent: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                heading("Recent")
                Spacer()
                Button("Clear") { center.clearHistory() }.buttonStyle(QuietButtonStyle())
            }
            ForEach(center.history.prefix(10)) { record in
                HStack(spacing: 10) {
                    Image(systemName: record.ok ? "checkmark.circle" : "exclamationmark.circle").foregroundStyle(record.ok ? Palette.green : Palette.star)
                    Text(record.text).lineLimit(1)
                    Spacer()
                    Text(record.title).foregroundStyle(Palette.muted).lineLimit(1)
                    Text(record.date.formatted(.relative(presentation: .named))).foregroundStyle(Palette.faint).frame(width: 86, alignment: .trailing)
                }.font(.system(size: 12.5)).frame(height: 28)
            }
        }
    }

    private func heading(_ text: String) -> some View {
        Text(text).font(.system(size: 15, weight: .semibold)).tracking(-0.2)
    }
}

/// A small picture of the palette for the Commands page.
struct PaletteMiniature: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "waveform").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color(hex: 0xFF8A80))
                Text("open spotify and play drake").font(.system(size: 12)).foregroundStyle(.white)
            }.padding(.horizontal, 12).frame(height: 36)
            Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
            ForEach([("play.fill", Color(hex: 0x1DB954), "Open Spotify, then Play “drake”"), ("magnifyingglass", Color(hex: 0x3B82F6), "Search Google")], id: \.2) { row in
                HStack(spacing: 8) {
                    Image(systemName: row.0).font(.system(size: 8, weight: .bold)).foregroundStyle(.white).frame(width: 18, height: 18)
                        .background(row.1, in: RoundedRectangle(cornerRadius: 5))
                    Text(row.2).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
                }.padding(.horizontal, 10).frame(height: 30)
            }
        }.frame(width: 230).padding(.bottom, 4)
            .background(Color(white: 0.11), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 1))
            .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
    }
}
