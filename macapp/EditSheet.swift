import SwiftUI

struct EditSheet: View {
    @EnvironmentObject private var model: ReaderModel
    @Environment(\.dismiss) private var dismiss
    @State private var page = 0
    @State private var text = ""
    @State private var originalText = ""
    @State private var working = false
    @State private var dirty = false
    @State private var pendingPage: Int? = nil
    @State private var showDirtyAlert = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(ReaderTheme.hairline).frame(height: 1)
            TextEditor(text: Binding(get: { text }, set: { newValue in
                text = newValue
                if text != originalText { dirty = true }
            }))
                .font(.system(size: 12.5, design: .monospaced))
                .disableAutocorrection(true)
                .scrollContentBackground(.hidden)
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(ReaderTheme.canvas,
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(ReaderTheme.hairline, lineWidth: 1)
                }
                .padding(16)
            Rectangle().fill(ReaderTheme.hairline).frame(height: 1)
            footer
        }
        .frame(minWidth: 660, minHeight: 500)
        .foregroundStyle(ReaderTheme.primaryText)
        .glassPanel(radius: 16)
        .onAppear {
            page = min(max(0, model.displayPage), max(0, model.pageModel.pages.count - 1))
            load()
            model.stopFollow()
        }
        .onChange(of: model.pageModel) { _, _ in
            if !dirty { load() }
        }
        .alert("Unsaved changes", isPresented: $showDirtyAlert) {
            Button("Save") { saveThenMove() }
            Button("Discard", role: .destructive) { discardThenMove() }
            Button("Cancel", role: .cancel) { pendingPage = nil }
        } message: {
            Text("Save your correction before leaving this page?")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("EDIT TEXT")
                    .font(ReaderTheme.micro(9.5))
                    .tracking(1.4)
                    .foregroundStyle(ReaderTheme.secondaryText)
                Text(model.activeDoc?.title ?? "Document")
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            HStack(spacing: 2) {
                Button { requestPageChange(max(0, page - 1)) } label: {
                    Image(systemName: "chevron.left").frame(width: 24, height: 24)
                }
                .buttonStyle(StudioIconButtonStyle(size: 24))
                .disabled(page <= 0)
                .accessibilityLabel("Previous page")
                Text("Page \(page + 1) / \(max(1, model.pageModel.pages.count))")
                    .font(ReaderTheme.numeral(10.5))
                    .foregroundStyle(ReaderTheme.secondaryText)
                    .padding(.horizontal, 6)
                Button { requestPageChange(min(model.pageModel.pages.count - 1, page + 1)) } label: {
                    Image(systemName: "chevron.right").frame(width: 24, height: 24)
                }
                .buttonStyle(StudioIconButtonStyle(size: 24))
                .disabled(page >= model.pageModel.pages.count - 1)
                .accessibilityLabel("Next page")
            }
            .padding(3)
            .background(ReaderTheme.raised, in: Capsule(style: .continuous))
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(ReaderTheme.hairline, lineWidth: 1)
            }

            Button("Reprocess") {
                working = true
                model.reOCR()
                dismiss()
            }
            .buttonStyle(StudioSecondaryButtonStyle())
            .help("Recover the whole document again")
            Button("Export JPEG…") { export() }
                .buttonStyle(StudioSecondaryButtonStyle())
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(dirty ? ReaderTheme.warning : ReaderTheme.tertiaryText)
                .frame(width: 5, height: 5)
            Text(dirty ? "Unsaved changes" : "No changes")
                .font(.system(size: 11))
                .foregroundStyle(ReaderTheme.secondaryText)
            Spacer()
            Button("Cancel") {
                model.showEdit = false
                dismiss()
            }
            .buttonStyle(StudioSecondaryButtonStyle())
            .keyboardShortcut(.cancelAction)
            Button("Save text") { save() }
                .buttonStyle(StudioPrimaryButtonStyle())
                .keyboardShortcut("s", modifiers: .command)
                .keyboardShortcut(.defaultAction)
                .disabled(working || model.pageModel.pages.isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 13)
    }

    private func load() {
        let lines = model.pageModel.lines.filter { $0.page == page }
        text = lines.map(\.text).joined(separator: "\n")
        originalText = text
        dirty = false
    }

    private func requestPageChange(_ newPage: Int) {
        guard newPage != page else { return }
        if dirty {
            pendingPage = newPage
            showDirtyAlert = true
        } else {
            page = newPage
            load()
        }
    }
    private func saveThenMove() {
        save { _ in
            if let p = pendingPage { page = p; load() }
            pendingPage = nil
        }
    }
    private func discardThenMove() {
        if let p = pendingPage { page = p; load() }
        pendingPage = nil
    }

    private func save(completion: ((Error?) -> Void)? = nil) {
        working = true
        model.saveScript(page: page, text: text) { error in
            Task { @MainActor in
                working = false
                if let error {
                    model.showToast(error.localizedDescription, isError: true)
                    completion?(error)
                    return
                }
                originalText = text
                dirty = false
                completion?(nil)
                dismiss()
            }
        }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.jpeg]
        panel.nameFieldStringValue = "page-\(page + 1)-proof.jpg"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let target = page
            Task { @MainActor in
                if let data = try? await model.exportJPEG(page: target) {
                    do {
                        try data.write(to: url, options: .atomic)
                        model.showToast("Exported “\(url.lastPathComponent)”")
                        model.feedback(.success)
                    } catch {
                        model.showToast("Couldn’t export: \(error.localizedDescription)", isError: true)
                    }
                } else {
                    model.showToast("Couldn’t export that page", isError: true)
                }
            }
        }
    }
}
