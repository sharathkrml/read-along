import SwiftUI

/// The left-hand text panel. The PDF on the right is the source of truth:
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
        if editing { return "Editing page \(editPage + 1) · PDF is unchanged" }
        if isBrowsing { return "Synced to PDF · browsing" }
        if model.state.status == "listening" { return "Live · following your voice" }
        return "Synced to PDF"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(ReaderTheme.separator).frame(height: 1)
            bodyContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ReaderTheme.surface, in: RoundedRectangle(cornerRadius: ReaderTheme.cardRadius))
        .overlay {
            RoundedRectangle(cornerRadius: ReaderTheme.cardRadius)
                .strokeBorder(ReaderTheme.separator, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: ReaderTheme.cardRadius))
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
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(editing ? "Page \(editPage + 1) text" : "Page \(page + 1) of \(total) text")
                    .font(.caption.weight(.semibold))
                Text(syncCaption)
                    .font(.caption2)
                    .foregroundStyle(ReaderTheme.secondaryText)
            }
            Spacer(minLength: 4)
            if !editing, isBrowsing || !model.viewer.textFollows {
                Button { model.returnToReading() } label: {
                    Label("Return to reading", systemImage: "arrow.uturn.backward")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Return both panes to the live reading position")
                .accessibilityLabel("Return to reading")
            }
            if editing {
                if saving { ProgressView().controlSize(.small) }
            } else {
                Button {
                    startEditing()
                } label: {
                    Label(pageLines.isEmpty ? "Add text" : "Edit", systemImage: "pencil")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Edit this page's text to fix OCR errors")
                .accessibilityLabel(pageLines.isEmpty ? "Add text for page \(page + 1)" : "Edit text for page \(page + 1)")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
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
                .font(.system(.body, design: .monospaced))
                .disableAutocorrection(true)
                .padding(8)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Rectangle().fill(ReaderTheme.separator).frame(height: 1)
            HStack(spacing: 8) {
                Text(dirty ? "Unsaved changes" : "No changes")
                    .font(.caption2)
                    .foregroundStyle(ReaderTheme.secondaryText)
                Spacer(minLength: 4)
                Button("Cancel") { requestCancel() }
                    .controlSize(.small)
                    .disabled(saving)
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(!dirty || saving)
                    .help("Save this page's text and rebuild its reading positions")
            }
            .padding(8)
        }
    }

    @ViewBuilder private var emptyPageBody: some View {
        VStack(spacing: 10) {
            Image(systemName: "text.page")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(ReaderTheme.secondaryText)
            Text("No text on page \(page + 1)")
                .font(.callout.weight(.medium))
                .accessibilityAddTraits(.isHeader)
            Text("No text was recovered for this page. Type it here and save — the PDF on the right stays the source of truth.")
                .font(.caption)
                .foregroundStyle(ReaderTheme.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
            Button {
                startEditing()
            } label: {
                Label("Add text…", systemImage: "pencil")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
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
