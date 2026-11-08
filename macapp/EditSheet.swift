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
            VStack(spacing: 8) {
                HStack {
                    Button {
                        requestPageChange(max(0, page - 1))
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .disabled(page <= 0)
                    Text("Page \(page + 1) of \(max(1, model.pageModel.pages.count))")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Button {
                        requestPageChange(min(model.pageModel.pages.count - 1, page + 1))
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .disabled(page >= model.pageModel.pages.count - 1)
                    Spacer()
                    Button("Reprocess document") {
                        working = true
                        model.reOCR()
                        dismiss()
                    }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                    Button("Export JPEG…") {
                        export()
                    }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 8)

            Divider()

            TextEditor(text: Binding(get: { text }, set: { newValue in
                text = newValue
                if text != originalText { dirty = true }
            }))
                .font(.system(.body, design: .monospaced))
                .disableAutocorrection(true)
                .padding(.horizontal)
                .padding(.top, 8)

            Divider()
            HStack {
                Button("Cancel") {
                    model.showEdit = false
                    dismiss()
                }
                .controlSize(.small)
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save Text") { save() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .keyboardShortcut("s", modifiers: .command)
                    .keyboardShortcut(.defaultAction)
                    .disabled(working || model.pageModel.pages.isEmpty)
            }
            .padding(14)
        }
        .frame(minWidth: 620, minHeight: 460)
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
