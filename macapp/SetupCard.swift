import SwiftUI

/// First-run setup and contextual model downloads. "welcome" offers both
/// models; a model key opens just that download.
struct SetupCard: View {
    @EnvironmentObject private var model: ReaderModel
    @Environment(\.colorSchemeContrast) private var contrast

    private var key: String { model.modelSetupKey ?? "welcome" }
    private var isWelcome: Bool { key == "welcome" }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(ReaderTheme.accent)
                    .frame(width: 38, height: 38)
                    .background(ReaderTheme.accentSoft, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(eyebrow)
                        .font(ReaderTheme.micro(9))
                        .tracking(1.4)
                        .foregroundStyle(ReaderTheme.secondaryText)
                    Text(title)
                        .font(.system(size: 17, weight: .semibold))
                }
            }

            Text(copy)
                .font(.system(size: 12.5))
                .foregroundStyle(ReaderTheme.secondaryText)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 14) {
                ForEach(isWelcome ? ["speech", "ocr"] : [key], id: \.self) { cardKey in
                    ModelCard(key: cardKey)
                        .padding(14)
                        .background(ReaderTheme.canvas,
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(ReaderTheme.hairline, lineWidth: 1)
                        }
                }
            }

            HStack(spacing: 7) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 10.5))
                Text("Documents and voice stay on this Mac. Internet is needed only for the one-time download.")
                    .font(.system(size: 11))
            }
            .foregroundStyle(ReaderTheme.tertiaryText)
            .fixedSize(horizontal: false, vertical: true)

            Rectangle().fill(ReaderTheme.hairline).frame(height: 1)

            HStack {
                Button(isWelcome ? "Skip for now" : "Not now") { dismiss() }
                    .buttonStyle(StudioSecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if isReady {
                    Button(isWelcome ? "Start reading" : "Done") { dismiss() }
                        .buttonStyle(StudioPrimaryButtonStyle())
                }
            }
        }
        .padding(26)
        .foregroundStyle(ReaderTheme.primaryText)
        .frame(maxWidth: 580, alignment: .leading)
        .glassPanel(radius: 16)
        .interactiveDismissDisabled()
    }

    private var symbol: String {
        switch key {
        case "speech": return "waveform"
        case "ocr": return "pencil.and.outline"
        default: return "text.book.closed.fill"
        }
    }

    private var eyebrow: String {
        switch key {
        case "speech": return "VOICE FOLLOWING"
        case "ocr": return "OPTIONAL MODEL"
        default: return "WELCOME TO READ ALONG"
        }
    }

    private var title: String {
        switch key {
        case "speech": return "Set up speech to text"
        case "ocr": return "Set up handwriting recognition"
        default: return "Set up your local models"
        }
    }

    private var copy: String {
        switch key {
        case "speech":
            return "Follow me listens as you read aloud and moves the guide with your voice. The speech model runs entirely on this Mac."
        case "ocr":
            return "Printed PDFs and photos work with Apple’s built-in text reader. The optional model reads handwriting and difficult scans, entirely on this Mac."
        default:
            return "Follow me needs a small speech model. Handwriting recognition is optional and only helps with scans and difficult pages. Neither downloads on its own."
        }
    }

    /// First run can close as soon as speech works; handwriting stays optional.
    private var isReady: Bool {
        let status = isWelcome
            ? model.setup.speech
            : (key == "speech" ? model.setup.speech : model.setup.ocr)
        return status?.state == "ready"
    }

    private func dismiss() {
        model.modelSetupKey = nil
        if isWelcome {
            Task { await model.completeSetup() }
        }
    }
}
