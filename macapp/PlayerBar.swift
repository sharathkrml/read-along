import SwiftUI

/// Inset reading dock. The parent reserves its measured height with safeAreaInset.
struct PlayerBar: View {
    /// Reserved height so the scrollable text/document panes never extend
    /// underneath the player bar (NSViewRepresentable children don't always
    /// participate in SwiftUI safe-area layout).
    static let measuredHeight: CGFloat = 92

    @EnvironmentObject private var model: ReaderModel
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var isScrubbing = false
    @State private var scrubValue = 0.0

    var body: some View {
        VStack(spacing: 8) {
            transport

            HStack(spacing: 10) {
                Slider(value: $scrubValue, in: 0...1, onEditingChanged: scrubEditingChanged)
                    .controlSize(.mini)
                    .disabled(!model.canRead || model.transportState == .stopping)
                    .accessibilityLabel("Reading position")
                    .accessibilityValue("\(Int((scrubValue * 100).rounded())) percent")
                    .help("Move the reading position. Release to continue; Escape to cancel.")
                Text("\(Int((scrubValue * 100).rounded()))%")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(ReaderTheme.secondaryText)
                    .frame(width: 34, alignment: .trailing)
                    .accessibilityHidden(true)
            }
            .frame(height: 20)

            HStack(spacing: 12) {
                status
                Spacer(minLength: 4)
                Text(positionContext)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(ReaderTheme.secondaryText)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .foregroundStyle(ReaderTheme.primaryText)
        .background {
            let shape = RoundedRectangle(cornerRadius: ReaderTheme.dockRadius, style: .continuous)
            if reduceTransparency {
                shape.fill(ReaderTheme.raised)
            } else {
                shape.fill(.regularMaterial)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: ReaderTheme.dockRadius, style: .continuous)
                .strokeBorder(contrast == .increased ? ReaderTheme.primaryText : ReaderTheme.glassBorder,
                              lineWidth: contrast == .increased ? 1.5 : 1)
                .allowsHitTesting(false)
                .blendMode(.plusLighter)
            RoundedRectangle(cornerRadius: ReaderTheme.dockRadius, style: .continuous)
                .strokeBorder(ReaderTheme.glassEdge, lineWidth: 1)
                .padding(-0.5)
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

        .onDisappear { cancelScrub() }
        .onExitCommand {
            if isScrubbing { cancelScrub() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Reading controls")
    }

    private var transport: some View {
        HStack(spacing: 5) {
            Button { model.movePhrase(-1) } label: {
                Image(systemName: "backward.end.fill")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
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
                .frame(width: 132, height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .disabled(model.transportState == .stopping || (!model.canRead && !canStop))
            .accessibilityLabel(primaryTitle)
            .help(primaryTitle)

            Button { model.movePhrase(1) } label: {
                Image(systemName: "forward.end.fill")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .disabled(!model.canRead || model.isComplete || model.transportState == .stopping)
            .accessibilityLabel("Next phrase")
            .help("Next phrase (⌘])")
        }
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

    private var primaryTitle: String { model.isComplete ? "Listen again" : model.transportTitle }
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
        case .preparing: return "Preparing speech engine…"
        case .waitingForText: return "Waiting for the next page…"
        case .stopping: return "Stopping…"
        case .failed: return "Could not start. Try again or choose another input."
        case .paused: return "Paused · Your place is saved."
        case .playing: return "Listening"
        case .listening: return "Listening"
        case .idle: return model.isProcessing ? "Available text · More pages are being prepared" : "Your place is saved."
        }
    }

    private var statusSymbol: String {
        if model.operationError != nil || model.transportState == .failed { return "exclamationmark.triangle" }
        if microphoneIsOn { return "mic.fill" }
        if model.isComplete { return "checkmark.circle" }
        if isBusy || model.documentLoadingMessage != nil { return "hourglass" }
        return "mic.slash"
    }

    private var positionContext: String {
        var parts: [String] = []
        if model.sourcePageCount > 0, !model.pageModel.words.isEmpty {
            let index = isScrubbing
                ? Int((scrubValue * Double(model.wordsTotal)).rounded(.down)) : model.cursor
            let word = model.pageModel.words[min(max(0, index), model.pageModel.words.count - 1)]
            parts.append("Page \(min(model.sourcePageCount, max(1, word.page + 1))) of \(model.sourcePageCount)")
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

}
