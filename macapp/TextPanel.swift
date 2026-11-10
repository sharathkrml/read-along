import SwiftUI

/// The right-hand text panel. The PDF on the left is the source of truth:
/// this panel only ever mirrors the text on the page the PDF is showing
/// (`model.displayPage`). While reading it is a highlighted, click-to-jump
/// view; with Edit it becomes an inline editor for that page, so an OCR
/// mistake can be fixed in place without opening a sheet.
struct TextPanel: View {
    @EnvironmentObject private var model: ReaderModel
    @State private var editing = false
    @State private var editPage = 0
    @State private var draft = ""
    @State private var original = ""
    @State private var saving = false
    @State private var showDiscard = false

    private var page: Int { model.displayPage }
    private var total: Int { max(1, model.pageModel.pages.count) }
    private var pageLines: [Line] { model.pageModel.lines.filter { $0.page == page } }
    private var dirty: Bool { draft != original }
    private var isBrowsing: Bool { model.viewer.browsedPage != nil }

    private var syncCaption: String {
        if editing { return "Source page stays unchanged" }
        if isBrowsing { return "Browsing the original" }
        if model.state.status == "listening" { return "Following your voice" }
        return "In sync with the original"
    }

    var body: some View {
        // No card of its own: the split workspace provides the one shared
        // surface, so text and original read as columns in a single box.
        VStack(spacing: 0) {
            header
            Rectangle().fill(ReaderTheme.hairline).frame(height: 1)
            bodyContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: model.library.active) { _, _ in
            editing = false
            saving = false
        }
        .alert("Discard changes to page \(editPage + 1)?", isPresented: $showDiscard) {
            Button("Discard", role: .destructive) { editing = false }
            Button("Keep editing", role: .cancel) { }
        } message: {
            Text(editing && dirty ? "Your fix to this page's text will not be saved." : "Unsaved changes will be lost.")
        }
    }

    @ViewBuilder private var header: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(editing ? ReaderTheme.warning : (model.viewer.textFollows ? ReaderTheme.success : ReaderTheme.warning))
                            .frame(width: 6, height: 6)
                            .accessibilityHidden(true)
                        Text(editing ? "EDITING" : "TEXT")
                            .font(ReaderTheme.micro(9.5))
                            .tracking(1.3)
                            .foregroundStyle(editing ? ReaderTheme.accent : ReaderTheme.secondaryText)
                        Text(editing ? "PAGE \(editPage + 1) OF \(total)" : "PAGE \(page + 1) OF \(total)")
                            .font(ReaderTheme.numeral(9.5))
                            .foregroundStyle(ReaderTheme.tertiaryText)
                    }
                    Text(syncCaption)
                        .font(.system(size: 10.5))
                        .foregroundStyle(ReaderTheme.secondaryText)
                }
                Spacer(minLength: 6)
                if !editing, isBrowsing || !model.viewer.textFollows {
                    Button { model.returnToReading() } label: {
                        Image(systemName: "arrow.uturn.backward")
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(StudioIconButtonStyle())
                    .help("Return both panes to the live reading position")
                    .accessibilityLabel("Return to reading")
                }
                if editing {
                    if saving { ProgressView().controlSize(.small).frame(width: 28, height: 28) }
                } else {
                    Button {
                        startEditing()
                    } label: {
                        Image(systemName: "pencil")
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(StudioIconButtonStyle())
                    .help("Edit this page’s text to fix OCR errors")
                    .accessibilityLabel(pageLines.isEmpty ? "Add text for page \(page + 1)" : "Edit text for page \(page + 1)")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(minHeight: 52)
            if editing {
                Rectangle().fill(ReaderTheme.hairline).frame(height: 3)
            } else {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(ReaderTheme.hairline).frame(height: 3)
                        Capsule().fill(ReaderTheme.accent)
                            .frame(width: max(14, geo.size.width * min(1, max(0, model.progressPercent / 100))), height: 3)
                    }
                }
                .frame(height: 3)
                .accessibilityHidden(true)
            }
        }
    }

    @ViewBuilder private var bodyContent: some View {
        if editing {
            editBody
        } else if pageLines.isEmpty {
            emptyPageBody
        } else {
            ReaderTextView(stage: false, page: page)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder private var editBody: some View {
        VStack(spacing: 0) {
            TextEditor(text: $draft)
                .font(.system(size: 12.5, design: .monospaced))
                .disableAutocorrection(true)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Rectangle().fill(ReaderTheme.hairline).frame(height: 1)
            HStack(spacing: 10) {
                Text(dirty ? "Unsaved changes" : "No changes")
                    .font(.system(size: 10.5))
                    .foregroundStyle(dirty ? ReaderTheme.warning : ReaderTheme.tertiaryText)
                Spacer(minLength: 4)
                Button("Cancel") { requestCancel() }
                    .buttonStyle(StudioSecondaryButtonStyle())
                    .controlSize(.small)
                    .disabled(saving)
                Button("Save") { save() }
                    .buttonStyle(StudioPrimaryButtonStyle())
                    .controlSize(.small)
                    .disabled(!dirty || saving)
                    .help("Save this page’s text and rebuild its reading positions")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(ReaderTheme.raised.opacity(0.55))
        }
    }

    @ViewBuilder private var emptyPageBody: some View {
        VStack(spacing: 12) {
            Image(systemName: "text.page")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(ReaderTheme.secondaryText)
                .frame(width: 44, height: 44)
                .background(ReaderTheme.raised, in: Circle())
            Text("No text on page \(page + 1)")
                .font(.system(size: 14, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            Text("No text was recovered for this page. Type it here and save — the original on the left stays the source of truth.")
                .font(.system(size: 11.5))
                .foregroundStyle(ReaderTheme.secondaryText)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 22)
            Button {
                startEditing()
            } label: {
                Label("Add text", systemImage: "pencil")
            }
            .buttonStyle(StudioSecondaryButtonStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }

    private func startEditing() {
        editPage = page
        let text = model.pageModel.lines.filter { $0.page == page }.map(\.text).joined(separator: "\n")
        draft = text
        original = text
        editing = true
        // Saving rebuilds the page's word model; mirroring EditSheet, stop
        // the live follower so it cannot fight the save.
        model.stopFollow()
    }

    private func requestCancel() {
        if dirty { showDiscard = true } else { editing = false }
    }

    private func save() {
        guard dirty, !saving else { return }
        saving = true
        let target = editPage
        let text = draft
        model.saveScript(page: target, text: text) { error in
            Task { @MainActor in
                saving = false
                if error == nil {
                    editing = false
                } else {
                    model.showToast(error?.localizedDescription ?? "Could not save this page", isError: true)
                }
            }
        }
    }
}
