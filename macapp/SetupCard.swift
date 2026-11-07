import SwiftUI

/// A contextual dependency, never a prerequisite for opening the library.
struct SetupCard: View {
    @EnvironmentObject private var model: ReaderModel
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        if let key = model.modelSetupKey, key == "speech" || key == "ocr" {
            VStack(alignment: .leading, spacing: 16) {
                Label(key == "speech" ? "Set up voice following" : "Read handwriting on this Mac",
                      systemImage: key == "speech" ? "waveform" : "pencil.and.outline")
                    .font(.title3.weight(.semibold))

                Text(key == "speech"
                     ? "Follow me uses a small, English-only model to match your voice to the text. Read to me uses a macOS voice and needs no speech-following download."
                     : "Handwriting recognition needs an optional local model. Text PDFs and many printed scans work without it; your original document stays available.")
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
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    if isInstalled(key) {
                        if key == "speech", !model.pageModel.isEmpty {
                            Button("Start listening") {
                                model.modelSetupKey = nil
                                model.setMode(.follow)
                                model.togglePlay()
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.state.status == "listening" || model.state.status == "loading")
                        } else {
                            Button("Done") { model.modelSetupKey = nil }
                                .buttonStyle(.borderedProminent)
                        }
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
