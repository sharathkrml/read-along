import SwiftUI

/// A contextual dependency, never a prerequisite for opening the library.
struct SetupCard: View {
    @EnvironmentObject private var model: ReaderModel
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        if let key = model.modelSetupKey, key == "ocr" {
            VStack(alignment: .leading, spacing: 16) {
                Label("Set up voice following",
                      systemImage: "waveform")
                    .font(.title3.weight(.semibold))

                Text("Follow me uses a small, English-only model to match your voice to the text.")
                    .font(.callout)
                    .foregroundStyle(ReaderTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                ModelCard(key: key)

                Label("Documents and voice stay on this Mac. Internet is needed for the one-time download.",
                      systemImage: "lock.shield")
                    .font(.caption)
                    .foregroundStyle(ReaderTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Button("Not now") { model.modelSetupKey = nil }
                        .controlSize(.small)
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    if isInstalled(key) {
                        Button("Done") { model.modelSetupKey = nil }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    }
                }
            }
            .padding(24)
            .foregroundStyle(ReaderTheme.primaryText)
            .frame(maxWidth: 560, alignment: .leading)
            .background(ReaderTheme.surface, in: RoundedRectangle(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(contrast == .increased ? ReaderTheme.secondaryText : ReaderTheme.separator)
            }
        }
    }

    private func isInstalled(_ key: String) -> Bool {
        (key == "speech" ? model.setup.speech : model.setup.ocr)?.state == "ready"
    }
}
