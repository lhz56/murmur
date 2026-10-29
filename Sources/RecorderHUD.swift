import SwiftUI

/// The floating pill shown while recording, transcribing and delivering text.
struct RecorderHUD: View {
    @ObservedObject var model: AppModel
    @ObservedObject var speech: DictationEngine

    private var listening: Bool { speech.phase == .recording }
    private var finished: Bool { model.hudMessage != nil }
    private var hasWords: Bool { listening && !speech.liveText.isEmpty }
    private var expanded: Bool { hasWords && model.hudVisible }
    private var width: CGFloat {
        guard model.hudVisible else { return 58 }
        if hasWords { return 420 }
        return listening ? 340 : 300
    }
    private var radius: CGFloat { expanded ? 24 : 29 }
    private static let spring = Animation.spring(response: 0.24, dampingFraction: 0.82)

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 10) {
                topRow
                if expanded {
                    Text(String(speech.liveText.suffix(160)))
                        .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.72))
                        .lineLimit(2).lineSpacing(3).truncationMode(.head)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }.padding(.horizontal, 16).padding(.vertical, 13)
                .frame(width: width, height: expanded ? 102 : 58, alignment: .topLeading)
                .background(Palette.pill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(.white.opacity(0.13), lineWidth: 1))
                .shadow(color: .black.opacity(0.28), radius: 16, y: 6)
                .opacity(model.hudVisible ? 1 : 0).scaleEffect(model.hudVisible ? 1 : 0.92, anchor: .bottom)
                .animation(Self.spring, value: model.hudVisible)
                .animation(Self.spring, value: speech.phase)
                .animation(Self.spring, value: hasWords)
                .animation(Self.spring, value: model.hudMessage)
                .padding(.bottom, 18)
        }.frame(width: 480, height: 170).environment(\.colorScheme, .dark)
    }

    private var symbol: String {
        if finished { return "checkmark" }
        switch speech.phase {
        case .finishing: return "text.bubble"
        case .downloading: return "arrow.down"
        default: return "mic.fill"
        }
    }

    private var title: String {
        model.hudMessage ?? model.hudWorking ?? (listening ? "Listening" : speech.phase == .idle ? "Getting ready…" : speech.phase.label)
    }

    private var subtitle: String {
        if finished { return model.hudDetail ?? "Saved to your library" }
        switch speech.phase {
        case .recording:
            if speech.signal.hasFrames && speech.signal.audibleSeconds < 0.5 && speech.elapsed > 3 { return "Quiet input · check your microphone" }
            if model.fnHoldInProgress { return "\(speech.clockLabel) · release \(model.preferences.dictationKey.name) to finish" }
            return "\(speech.clockLabel) · \(speech.inputName)"
        case .finishing: return "Transcribing on this Mac"
        case .downloading: return "\(Int(speech.downloadProgress * 100))% · one-time download"
        default: return "On-device transcription"
        }
    }

    private var topRow: some View {
        HStack(spacing: 11) {
            ZStack {
                Circle().fill(finished ? Palette.pillSuccess.opacity(0.16) : listening ? Color.red.opacity(0.18) : .white.opacity(0.07))
                    .frame(width: 30, height: 30)
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(finished ? Palette.pillSuccess : listening ? Color(hex: 0xFF8A80) : .white.opacity(0.85))
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.pulse, isActive: speech.phase == .finishing && !finished)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(.white)
                Text(subtitle).font(.system(size: 10)).foregroundStyle(.white.opacity(0.52)).monospacedDigit().lineLimit(1)
            }
            Spacer(minLength: 2)
            if listening {
                LiveWaveform(level: speech.level, bars: 9, color: Palette.pillMeter, maxHeight: 24)
                Button(action: model.toggleRecording) {
                    Image(systemName: "stop.fill").font(.system(size: 8)).foregroundStyle(.white.opacity(0.85))
                        .frame(width: 24, height: 24).background(.white.opacity(0.1), in: Circle())
                }.buttonStyle(.plain).help("Finish recording").accessibilityLabel("Finish recording")
            } else if !finished {
                ProgressView().controlSize(.small).tint(.white.opacity(0.6)).frame(width: 20)
            }
        }.opacity(model.hudVisible ? 1 : 0)
    }
}
