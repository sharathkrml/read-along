import SwiftUI

/// One compact control surface for reading: transport, state, position,
/// and a live strip showing the phrase being heard or the next phrase to read.
struct PlayerBar: View {
    /// Reserved height so scrollable panes never run under the dock.
    static let measuredHeight: CGFloat = 106

    @EnvironmentObject private var model: ReaderModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isScrubbing = false
    @State private var scrubValue = 0.0

    var body: some View {
        VStack(spacing: 0) {
            topRow
            Rectangle().fill(ReaderTheme.hairline).frame(height: 1)
            liveRow
        }
        .foregroundStyle(ReaderTheme.primaryText)
        .background {
            RoundedRectangle(cornerRadius: ReaderTheme.dockRadius, style: .continuous)
                .fill(ReaderTheme.raised)
        }
        .overlay {
            RoundedRectangle(cornerRadius: ReaderTheme.dockRadius, style: .continuous)
                .strokeBorder(ReaderTheme.hairline, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: ReaderTheme.dockRadius, style: .continuous))
        .shadow(color: .black.opacity(0.20), radius: 20, x: 0, y: 10)
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .frame(maxWidth: 980)
        .onAppear { scrubValue = progressFraction }
        .onChange(of: model.progressPercent) { _, _ in
            if !isScrubbing { scrubValue = progressFraction }
        }
        .onChange(of: model.library.active) { _, _ in cancelScrub() }
        .onDisappear { cancelScrub() }
        .onExitCommand {
            if isScrubbing { cancelScrub() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Reading controls")
    }

    // MARK: - Transport

    private var topRow: some View {
        HStack(spacing: 13) {
            transport
            Rectangle().fill(ReaderTheme.hairlineStrong).frame(width: 1, height: 20)
            status
            Rectangle().fill(ReaderTheme.hairlineStrong).frame(width: 1, height: 20)
            modelReadiness
            Spacer(minLength: 10)
            progress
            if !positionContext.isEmpty {
                Rectangle().fill(ReaderTheme.hairlineStrong).frame(width: 1, height: 20)
                Text(positionContext)
                    .font(ReaderTheme.numeral(10))
                    .foregroundStyle(ReaderTheme.tertiaryText)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
    }

    private var transport: some View {
        HStack(spacing: 3) {
            Button { model.movePhrase(-1) } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(StudioIconButtonStyle(size: 26))
            .disabled(!model.canRead || model.cursor <= 0 || model.transportState == .stopping)
            .accessibilityLabel("Previous phrase")
            .help("Previous phrase (⌘[)")

            Button(action: primaryAction) {
                HStack(spacing: 7) {
                    if isBusy {
                        if reduceMotion {
                            Image(systemName: "hourglass")
                                .accessibilityHidden(true)
                        } else {
                            ProgressView().controlSize(.mini).tint(ReaderTheme.accentInk).accessibilityHidden(true)
                        }
                    }
                    Image(systemName: model.isComplete ? "arrow.counterclockwise" : model.transportSymbol)
                        .font(.system(size: 10, weight: .semibold))
                        .accessibilityHidden(true)
                    Text(primaryTitle).lineLimit(1)
                }
            }
            .buttonStyle(StudioPrimaryButtonStyle())
            .disabled(model.transportState == .stopping || (!model.canRead && !canStop))
            .accessibilityLabel(primaryTitle)
            .help(model.transportTitle + " (Space)")

            Button { model.movePhrase(1) } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(StudioIconButtonStyle(size: 26))
            .disabled(!model.canRead || model.isComplete || model.transportState == .stopping)
            .accessibilityLabel("Next phrase")
            .help("Next phrase (⌘])")
        }
    }

    private var status: some View {
        HStack(spacing: 7) {
            if microphoneIsOn {
                MicMeter(level: microphoneLevel)
            } else if let symbol = statusSymbol {
                Image(systemName: symbol)
                    .font(.system(size: 10))
                    .foregroundStyle(statusColor)
                    .accessibilityHidden(true)
            }
            Text(statusText)
                .font(.system(size: 11))
                .foregroundStyle(statusColor)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(statusText)
            micPermissionChip
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// Mic-permission chip shown when Follow me is idle and the mic hasn't been
    /// authorized yet, so the user knows why the mic won't light up.
    @ViewBuilder
    private var micPermissionChip: some View {
        if microphoneIsOn {
            EmptyView()
        } else if case .notDetermined = model.micPermissionState {
            permissionChip("Mic access not requested", symbol: "mic.slash", color: ReaderTheme.warning)
        } else if case .denied = model.micPermissionState {
            permissionChip("Mic access denied", symbol: "mic.slash", color: ReaderTheme.warning)
        } else if case .restricted = model.micPermissionState {
            permissionChip("Mic access restricted", symbol: "mic.slash", color: ReaderTheme.warning)
        } else {
            EmptyView()
        }
    }

    private func permissionChip(_ label: String, symbol: String, color: Color) -> some View {
        Button {
            if model.micPermissionState == .denied {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(color)
                Text(label)
                    .font(.system(size: 10))
                    .foregroundStyle(color)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .frame(minHeight: 22)
        .background(ReaderTheme.canvas.opacity(0.55), in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(color.opacity(0.5), lineWidth: 1)
        }
        .contentShape(Capsule(style: .continuous))
        .help(label)
        .accessibilityLabel(label)
        .accessibilityHint(model.micPermissionState == .denied ? "Open System Settings microphone privacy" : "Request microphone access")
    }

    /// Speech-model readiness chip shown in the player bar so the user can tell
    /// at a glance whether Follow me can start, is downloading, or is blocked.
    private var modelReadiness: some View {
        Group {
            if model.speechModelDownloading {
                readinessChip("Downloading model", symbol: "arrow.down.circle", color: ReaderTheme.accent)
            } else if model.speechModelReady {
                readinessChip("Speech model ready", symbol: "checkmark.circle.fill", color: ReaderTheme.success)
            } else if model.speechModelMissing {
                readinessChip("Speech model needed", symbol: "exclamationmark.circle", color: ReaderTheme.warning)
                    .onTapGesture { model.modelSetupKey = "speech" }
            } else {
                readinessChip("Checking model…", symbol: "clock", color: ReaderTheme.secondaryText)
            }
        }
    }

    private func readinessChip(_ label: String, symbol: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(color)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(color)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .frame(minHeight: 22)
        .background(ReaderTheme.canvas.opacity(0.55), in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(color.opacity(0.5), lineWidth: 1)
        }
        .contentShape(Capsule(style: .continuous))
        .help(label)
        .accessibilityLabel(label)
    }

    private var progress: some View {
        HStack(spacing: 8) {
            Slider(value: $scrubValue, in: 0...1, onEditingChanged: scrubEditingChanged)
                .controlSize(.mini)
                .tint(ReaderTheme.accent)
                .frame(width: 152)
                .disabled(!model.canRead || model.transportState == .stopping)
                .accessibilityLabel("Reading position")
                .accessibilityValue("\(displayPercent) percent")
                .help("Move the reading position. Release to continue; Escape to cancel.")
            Text("\(displayPercent)%")
                .font(ReaderTheme.numeral(10))
                .foregroundStyle(isScrubbing ? ReaderTheme.primaryText : ReaderTheme.secondaryText)
                .frame(width: 32, alignment: .trailing)
                .accessibilityHidden(true)
        }
    }

    // MARK: - Live strip

    private var liveRow: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                if microphoneIsOn {
                    Circle()
                        .fill(ReaderTheme.accent)
                        .frame(width: 5, height: 5)
                        .shadow(color: ReaderTheme.accent.opacity(0.7), radius: 3)
                }
                Text(liveLabel)
                    .font(ReaderTheme.micro(9))
                    .tracking(1.2)
                    .foregroundStyle(microphoneIsOn ? ReaderTheme.accent : ReaderTheme.tertiaryText)
                    .lineLimit(1)
            }
            .frame(width: 64, alignment: .leading)

            Text(liveText)
                .font(.system(size: 11.5))
                .foregroundStyle(liveTextIsLive ? ReaderTheme.primaryText : ReaderTheme.secondaryText)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentTransition(.opacity)
                .animation(.easeOut(duration: 0.14), value: liveText)
                .help(liveText)
                .accessibilityLabel("\(liveLabel): \(liveText)")

            Rectangle().fill(ReaderTheme.hairlineStrong).frame(width: 1, height: 14)

            microphoneMenu
        }
        .padding(.horizontal, 16)
        .frame(height: 33)
    }

    private var microphoneMenu: some View {
        Menu {
            Toggle("System default", isOn: Binding(
                get: { model.selectedMicID == nil },
                set: { on in if on { model.selectMic(nil) } }
            ))
            if !model.microphones.isEmpty {
                Divider()
                ForEach(model.microphones) { mic in
                    Toggle(mic.name, isOn: Binding(
                        get: { model.selectedMicID == mic.id },
                        set: { on in if on { model.selectMic(mic) } }
                    ))
                }
            }
            if model.savedMicUnavailable, let name = model.prefs.micName, !name.isEmpty {
                Divider()
                Button("Saved microphone unavailable · \(name)") { }
                    .disabled(true)
            }
            Divider()
            Button("Refresh devices") {
                model.refreshMicrophonesAndSync()
            }
            SettingsLink { Label("Microphone settings…", systemImage: "gearshape") }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: microphoneIsOn ? "mic.fill" : "mic")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(microphoneIsOn ? ReaderTheme.accent : ReaderTheme.tertiaryText)
                Text(microphoneLabel)
                    .font(.system(size: 10.5))
                    .foregroundStyle(ReaderTheme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(ReaderTheme.tertiaryText)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: 176, minHeight: 22)
            .background(ReaderTheme.canvas.opacity(0.55),
                        in: Capsule(style: .continuous))
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(ReaderTheme.hairline, lineWidth: 1)
            }
            .contentShape(Capsule(style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Switch microphone")
        .accessibilityLabel("Microphone, \(microphoneLabel)")
    }

    /// Menu items render a leading checkmark without changing the title.
    private var microphoneLabel: String {
        model.selectedMicLabel
    }

    private var liveLabel: String {
        if model.isComplete { return "DONE" }
        return microphoneIsOn ? "LIVE" : "READING"
    }

    private var liveTextIsLive: Bool {
        microphoneIsOn && !(model.state.partial ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var liveText: String {
        if model.isComplete { return "You reached the end. Your place is saved." }
        if microphoneIsOn {
            let partial = (model.state.partial ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !partial.isEmpty { return partial }
        }
        if let phrase = currentPhrase { return phrase }
        if let error = model.operationError, !error.isEmpty { return error }
        return model.transportSubtitle
    }

    private var currentPhrase: String? {
        guard let range = model.currentRange, !range.isEmpty else { return nil }
        let words = model.pageModel.words
        let lower = max(0, min(range.lowerBound, words.count))
        let upper = max(lower, min(range.upperBound, words.count))
        guard lower < upper else { return nil }
        return words[lower..<upper].map(\.text).joined(separator: " ")
    }

    // MARK: - Derived state

    private var displayPercent: Int {
        Int(((isScrubbing ? scrubValue : progressFraction) * 100).rounded())
    }

    private var primaryTitle: String {
        if model.isComplete { return "Read again" }
        switch model.transportState {
        case .playing, .listening, .preparing, .stopping, .waitingForText, .paused:
            return "Stop"
        case .failed:
            return "Try again"
        case .idle:
            return "Follow me"
        }
    }

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
        if model.isComplete { return "Finished · your place is saved" }
        if let loading = model.documentLoadingMessage, !loading.isEmpty { return loading }
        if microphoneIsOn {
            return model.transportSubtitle.isEmpty ? "Microphone on · listening" : model.transportSubtitle
        }
        if !model.transportSubtitle.isEmpty { return model.transportSubtitle }
        switch model.transportState {
        case .preparing:
            if model.speechModelMissing {
                return "Speech model not installed — get it in Settings to read aloud"
            }
            return "Warming up the speech engine…"
        case .waitingForText: return "Waiting for the next page…"
        case .stopping: return "Stopping…"
        case .failed:
            if model.speechModelMissing {
                return "Follow me couldn't start — the speech model needs to be installed"
            }
            return "Couldn't start. Try again or choose another input."
        case .paused: return "Paused · your place is saved"
        case .playing, .listening: return "Listening"
        case .idle: return model.isProcessing ? "Available text · more pages are being prepared" : "Your words. Your pace."
        }
    }

    private var statusSymbol: String? {
        if model.operationError != nil || model.transportState == .failed { return "exclamationmark.triangle" }
        if model.isComplete { return "checkmark.circle" }
        if isBusy || model.documentLoadingMessage != nil { return "clock" }
        return nil
    }

    private var statusColor: Color {
        if model.operationError != nil || model.transportState == .failed { return ReaderTheme.warning }
        return ReaderTheme.secondaryText
    }

    private var positionContext: String {
        guard model.sourcePageCount > 0, !model.pageModel.words.isEmpty else { return "" }
        let index = isScrubbing
            ? Int((scrubValue * Double(model.wordsTotal)).rounded(.down)) : model.cursor
        let word = model.pageModel.words[min(max(0, index), model.pageModel.words.count - 1)]
        let page = min(model.sourcePageCount, max(1, word.page + 1))
        return "Page \(page) / \(model.sourcePageCount)"
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
}

/// Five small capsules that read the microphone without a full-width meter.
private struct MicMeter: View {
    let level: Double
    private let bars = 5

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<bars, id: \.self) { index in
                Capsule()
                    .fill(Double(index) < level * Double(bars) ? ReaderTheme.accent : ReaderTheme.hairlineStrong)
                    .frame(width: 2, height: 5 + CGFloat(index) * 1.8)
            }
        }
        .frame(width: 18, height: 14)
        .accessibilityLabel("Microphone input level")
    }
}
