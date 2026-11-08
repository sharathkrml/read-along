import SwiftUI

/// A contextual dependency, never a prerequisite for opening the library.
struct SetupCard: View {
    @EnvironmentObject private var model: ReaderModel
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        if let key = model.modelSetupKey, key == "ocr" {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    Image(systemName: "pencil.and.outline")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(ReaderTheme.accent)
                        .frame(width: 38, height: 38)
                        .background(ReaderTheme.accentSoft, in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text("OPTIONAL MODEL")
                            .font(ReaderTheme.micro(9))
                            .tracking(1.4)
                            .foregroundStyle(ReaderTheme.secondaryText)
                        Text("Set up handwriting recognition")
                            .font(.system(size: 17, weight: .semibold))
                    }
                }

                Text("Printed PDFs and photos work with Apple’s built-in text reader. The optional model reads handwriting and difficult scans, entirely on this Mac.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(ReaderTheme.secondaryText)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)

                ModelCard(key: key)
                    .padding(14)
                    .background(ReaderTheme.canvas,
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(ReaderTheme.hairline, lineWidth: 1)
                    }

                HStack(spacing: 7) {
                    Image(systemName: "lock.shield")
                        .font(.system(size: 10.5))
                    Text("Documents stay on this Mac. Internet is needed only for the one-time download.")
                        .font(.system(size: 11))
                }
                .foregroundStyle(ReaderTheme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)

                Rectangle().fill(ReaderTheme.hairline).frame(height: 1)

                HStack {
                    Button("Not now") { model.modelSetupKey = nil }
                        .buttonStyle(StudioSecondaryButtonStyle())
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    if isInstalled(key) {
                        Button("Done") { model.modelSetupKey = nil }
                            .buttonStyle(StudioPrimaryButtonStyle())
                    }
                }
            }
            .padding(26)
            .foregroundStyle(ReaderTheme.primaryText)
            .frame(maxWidth: 560, alignment: .leading)
            .glassPanel(radius: 16)
        }
    }

    private func isInstalled(_ key: String) -> Bool {
        (key == "speech" ? model.setup.speech : model.setup.ocr)?.state == "ready"
    }
}
