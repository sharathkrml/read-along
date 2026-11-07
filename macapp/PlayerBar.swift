import SwiftUI

/// Inset reading dock. The parent reserves its measured height with safeAreaInset.
struct PlayerBar: View {
    @EnvironmentObject private var model: ReaderModel
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var showsOptions = false
    @State private var isScrubbing = false
    @State private var scrubValue = 0.0

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                modeMenu
                Spacer(minLength: 4)
                transport
                Spacer(minLength: 4)
                optionsButton
            }
            .frame(height: 36)

            HStack(spacing: 10) {
                Slider(value: $scrubValue, in: 0...1, onEditingChanged: scrubEditingChanged)
                    .controlSize(.mini)
                    .disabled(!model.canRead || model.transportState == .stopping)
                    .accessibilityLabel("Reading position")
                    .accessibilityValue("\(Int((scrubValue * 100).rounded())) percent")
                    .help("Move the reading position. Release to continue; Escape to cancel.")
                Text("\(Int((scrubValue * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(ReaderTheme.secondaryText)
                    .frame(width: 34, alignment: .trailing)
                    .accessibilityHidden(true)
            }
            .frame(height: 16)

            HStack(spacing: 12) {
                status
                Spacer(minLength: 4)
                Text(positionContext)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(ReaderTheme.secondaryText)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .foregroundStyle(ReaderTheme.primaryText)
        .background {
            let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
            if reduceTransparency {
                shape.fill(ReaderTheme.raised)
            } else {
                shape.fill(.regularMaterial)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(contrast == .increased ? ReaderTheme.primaryText : ReaderTheme.separator,
                              lineWidth: contrast == .increased ? 1.5 : 0.5)
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(contrast == .increased ? 0 : 0.07), radius: 12, y: 4)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .onAppear { scrubValue = progressFraction }
        .onChange(of: model.progressPercent) { _, _ in
            if !isScrubbing { scrubValue = progressFraction }
        }
        .onChange(of: model.library.active) { _, _ in cancelScrub() }
        .onChange(of: model.prefs.mode) { _, _ in cancelScrub() }
        .onDisappear { cancelScrub() }
        .onExitCommand {
            if isScrubbing { cancelScrub() }
            else { showsOptions = false }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Reading controls")
    }

    private var modeMenu: some View {
        Menu {
            Picker("Reading mode", selection: Binding(
                get: { model.prefs.mode }, set: { model.setMode($0) }
            )) {
                Label("Read to me", systemImage: "speaker.wave.2").tag(PlaybackMode.read)
                Label("Follow me", systemImage: "mic").tag(PlaybackMode.follow)
            }
        } label: {
            Label(modeTitle, systemImage: model.prefs.mode == .read ? "speaker.wave.2" : "mic")
                .font(.callout)
        }
        .menuStyle(.borderlessButton)
        .frame(width: 126, alignment: .leading)
        .accessibilityLabel("Reading mode")
        .accessibilityValue(modeTitle)
        .help("Read to me uses a macOS voice. Follow me listens as you read aloud.")
    }

    private var transport: some View {
        HStack(spacing: 4) {
            Button { model.movePhrase(-1) } label: {
                Image(systemName: "backward.end.fill").frame(width: 28, height: 28)
            }
            .buttonStyle(.borderless)
            .disabled(!model.canRead || model.cursor <= 0 || model.transportState == .stopping)
            .accessibilityLabel("Previous phrase")
            .help("Previous phrase (⌘[)")

            Button(action: primaryAction) {
                HStack(spacing: 6) {
                    if isBusy {
                        if reduceMotion {
                            Image(systemName: "hourglass").accessibilityHidden(true)
                        } else {
                            ProgressView().controlSize(.mini).accessibilityHidden(true)
                        }
                    }
                    Image(systemName: model.isComplete ? "arrow.counterclockwise" : model.transportSymbol)
                        .accessibilityHidden(true)
                    Text(primaryTitle).lineLimit(1)
                }
                .font(.callout.weight(.semibold))
                .frame(width: 128, height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .disabled(model.transportState == .stopping || (!model.canRead && !canStop))
            .accessibilityLabel(primaryTitle)
            .help(primaryTitle)

            Button { model.movePhrase(1) } label: {
                Image(systemName: "forward.end.fill").frame(width: 28, height: 28)
            }
            .buttonStyle(.borderless)
            .disabled(!model.canRead || model.isComplete || model.transportState == .stopping)
            .accessibilityLabel("Next phrase")
            .help("Next phrase (⌘])")
        }
    }

    private var optionsButton: some View {
        Button { showsOptions.toggle() } label: {
            HStack(spacing: 6) {
                if model.prefs.mode == .read {
                    Text(model.prefs.speed.formatted(.number.precision(.fractionLength(0...2))) + "×")
                        .monospacedDigit()
                }
                Image(systemName: "slider.horizontal.3")
            }
            .font(.callout)
            .frame(minWidth: 44, minHeight: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Reading options")
        .help(model.prefs.mode == .read ? "Voice and reading speed" : "Microphone and voice-following details")
        .popover(isPresented: $showsOptions, arrowEdge: .bottom) {
            options
        }
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Reading options").font(.headline)
                Text(modeTitle).font(.subheadline).foregroundStyle(ReaderTheme.secondaryText)
            }
            Divider()
            if model.prefs.mode == .read {
                Picker("Installed voice", selection: Binding(
                    get: { model.prefs.voice }, set: { model.setVoice($0) }
                )) {
                    Text("System voice").tag("")
                    if !model.prefs.voice.isEmpty && !model.voiceList.contains(where: { $0.id == model.prefs.voice }) {
                        Text("Selected voice unavailable").tag(model.prefs.voice).disabled(true)
                    }
                    ForEach(model.voiceList) { voice in
                        Text("\(voice.name) · \(voice.language)").tag(voice.id)
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Reading speed").font(.subheadline)
                    Picker("Reading speed", selection: Binding(
                        get: { model.prefs.speed }, set: { model.setSpeed($0) }
                    )) {
                        ForEach([0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { speed in
                            Text(speed.formatted(.number.precision(.fractionLength(0...2))) + "×").tag(speed)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                Text("Uses voices installed on this Mac. No voice-following model is required.")
                    .font(.caption).foregroundStyle(ReaderTheme.secondaryText)
            } else {
                Picker("Microphone", selection: micBinding) {
                    Text("System default").tag(Int?.none)
                    ForEach(model.microphones.devices) { mic in
                        Text(mic.name).tag(Int?.some(mic.id))
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Label(microphoneIsOn ? "Microphone on" : "Microphone off",
                          systemImage: microphoneIsOn ? "mic.fill" : "mic.slash")
                        .font(.subheadline)
                    ProgressView(value: microphoneLevel)
                        .accessibilityLabel("Microphone input level")
                        .accessibilityValue("\(Int(microphoneLevel * 100)) percent")
                    Text(model.followStatusText)
                        .font(.caption).foregroundStyle(ReaderTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Recognized speech").font(.subheadline)
                    Text(model.state.partial.flatMap { $0.isEmpty ? nil : $0 } ?? "No speech recognized yet.")
                        .font(.callout).foregroundStyle(ReaderTheme.secondaryText)
                        .textSelection(.enabled)
                        .lineLimit(5)
                    if let confidence = model.state.confidence, confidence.isFinite {
                        Text("Alignment confidence: \(Int(min(1, max(0, confidence)) * 100))%")
                            .font(.caption.monospacedDigit()).foregroundStyle(ReaderTheme.secondaryText)
                    }
                }
                Text("Voice following currently supports English.")
                    .font(.caption).foregroundStyle(ReaderTheme.secondaryText)
            }
            Divider()
            Text(model.isComplete ? "Finished reading · Your place is saved." :
                    "Word \(min(model.cursor + 1, model.wordsTotal)) of \(model.wordsTotal)\(model.isProcessing ? " available" : "")")
                .font(.caption.monospacedDigit()).foregroundStyle(ReaderTheme.secondaryText)
            if let error = model.operationError, !error.isEmpty {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .frame(width: 340, alignment: .leading)
        .foregroundStyle(ReaderTheme.primaryText)
        .background(ReaderTheme.raised)
    }

    private var status: some View {
        HStack(spacing: 5) {
            Image(systemName: statusSymbol).accessibilityHidden(true)
            Text(statusText).lineLimit(1).truncationMode(.tail)
            if microphoneIsOn {
                ProgressView(value: microphoneLevel)
                    .frame(width: 40)
                    .accessibilityLabel("Microphone input level")
            }
        }
        .font(.caption)
        .foregroundStyle(model.transportState == .failed ? Color.red : ReaderTheme.secondaryText)
        .help(statusText)
        .accessibilityElement(children: .combine)
    }

    private var modeTitle: String { model.prefs.mode == .read ? "Read to me" : "Follow me" }
    private var primaryTitle: String { model.isComplete ? "Read again" : model.transportTitle }
    private var isBusy: Bool {
        [.preparing, .stopping, .waitingForText].contains(model.transportState)
    }
    private var canStop: Bool {
        [.preparing, .playing, .paused, .listening, .waitingForText].contains(model.transportState)
    }
    private var progressFraction: Double {
        model.progressPercent.isFinite ? min(1, max(0, model.progressPercent / 100)) : 0
    }
    private var microphoneIsOn: Bool { model.state.status == "listening" }
    private var microphoneLevel: Double {
        guard microphoneIsOn else { return 0 }
        return model.micLevel
    }

    private var statusText: String {
        if isScrubbing { return "Release to move · Escape to cancel" }
        if let error = model.operationError, !error.isEmpty { return error }
        if model.isComplete { return "Finished reading · Your place is saved." }
        if let loading = model.documentLoadingMessage, !loading.isEmpty { return loading }
        if microphoneIsOn {
            return model.transportSubtitle.isEmpty ? "Microphone on · Listening" : "Microphone on · \(model.transportSubtitle)"
        }
        if !model.transportSubtitle.isEmpty { return model.transportSubtitle }
        switch model.transportState {
        case .preparing: return model.prefs.mode == .read ? "Preparing voice…" : "Preparing speech engine…"
        case .waitingForText: return "Waiting for the next page…"
        case .stopping: return "Stopping…"
        case .failed: return "Could not start. Try again or choose another input."
        case .paused: return "Paused · Your place is saved."
        case .playing: return "Reading aloud"
        case .listening: return "Listening"
        case .idle: return model.isProcessing ? "Available text · More pages are being prepared" : "Your place is saved."
        }
    }

    private var statusSymbol: String {
        if model.operationError != nil || model.transportState == .failed { return "exclamationmark.triangle" }
        if microphoneIsOn { return "mic.fill" }
        if model.isComplete { return "checkmark.circle" }
        if isBusy || model.documentLoadingMessage != nil { return "hourglass" }
        return model.prefs.mode == .read ? "bookmark" : "mic.slash"
    }

    private var positionContext: String {
        var parts: [String] = []
        if model.sourcePageCount > 0, !model.pageModel.words.isEmpty {
            let index = isScrubbing
                ? Int((scrubValue * Double(model.wordsTotal)).rounded(.down)) : model.cursor
            let word = model.pageModel.words[min(max(0, index), model.pageModel.words.count - 1)]
            parts.append("Page \(min(model.sourcePageCount, max(1, word.page + 1))) of \(model.sourcePageCount)")
        }
        if !isScrubbing && !model.isComplete && !model.isProcessing, let left = model.wordsLeft {
            parts.append(left.hasPrefix("About") ? left : "About \(left)")
        }
        return parts.joined(separator: " · ")
    }

    private func primaryAction() {
        if model.transportState == .preparing || model.transportState == .waitingForText {
            model.stopPlayback()
        } else {
            model.togglePlay()
        }
    }

    private func scrubEditingChanged(_ editing: Bool) {
        if editing {
            guard !isScrubbing else { return }
            isScrubbing = true
            model.beginScrubbing()
        } else {
            guard isScrubbing else { return }
            isScrubbing = false
            model.commitScrub(scrubValue)
            scrubValue = progressFraction
        }
    }

    private func cancelScrub() {
        if isScrubbing {
            isScrubbing = false
            model.cancelScrubbing()
        }
        scrubValue = progressFraction
    }

    private var micBinding: Binding<Int?> {
        Binding(
            get: { model.selectedMicID },
            set: { id in
                let device = id.flatMap { id in model.microphones.devices.first { $0.id == id } }
                model.selectMic(device)
            }
        )
    }
}
