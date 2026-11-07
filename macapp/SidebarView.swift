import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var model: ReaderModel
    @State private var query = ""

    private var matches: [Document] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !search.isEmpty else { return model.library.documents }
        return model.library.documents.filter {
            $0.title.localizedStandardContains(search) || ($0.file_name?.localizedStandardContains(search) ?? false)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
                .padding(12)

            if model.library.documents.isEmpty {
                emptyLibrary
            } else {
                List(selection: Binding(
                    get: { model.library.active },
                    // Filtering a selected row out must not close the document.
                    set: { id in if let id { model.openDocument(id) } }
                )) {
                    SwiftUI.Section(query.isEmpty ? "Recent Documents" : "Search Results") {
                        ForEach(matches) { doc in
                            SidebarRow(doc: doc)
                                .tag(doc.id)
                        }
                    }
                }
                .listStyle(.sidebar)
                .overlay {
                    if matches.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "magnifyingglass")
                                .font(.title2)
                            Text("No matching documents")
                                .font(.callout.weight(.medium))
                            Text("Search a title or file name.")
                                .font(.caption)
                            Button("Clear Search") { query = "" }
                                .padding(.top, 4)
                        }
                        .foregroundStyle(ReaderTheme.secondaryText)
                        .padding(16)
                    }
                }
                .onDeleteCommand {
                    guard let doc = matches.first(where: { $0.id == model.library.active }) else { return }
                    model.pendingDelete = doc
                }
            }

            footer
        }
        .background(ReaderTheme.canvas)
        .navigationTitle("Read Along")
        .navigationSplitViewColumnWidth(min: 208, ideal: 256, max: 320)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(ReaderTheme.secondaryText)
                .accessibilityHidden(true)
            TextField("Search documents", text: $query)
                .textFieldStyle(.plain)
                .accessibilityLabel("Search document titles and file names")
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(ReaderTheme.secondaryText)
                .help("Clear search")
                .accessibilityLabel("Clear document search")
            }
        }
        .font(.callout)
        .padding(8)
        .background(ReaderTheme.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(ReaderTheme.separator))
    }

    private var footer: some View {
        VStack(spacing: 10) {
            if downloadCount > 0 {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.mini)
                    Text("Downloads · \(downloadCount) active")
                        .font(.caption)
                    Spacer(minLength: 0)
                    SettingsLink {
                        Image(systemName: "arrow.up.right")
                    }
                    .help("View model downloads in Settings")
                    .accessibilityLabel("View downloads in Settings")
                }
                .foregroundStyle(ReaderTheme.secondaryText)
            }
            Button { model.importDocument() } label: {
                Label("Import Document…", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 3)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .help("Import one PDF, JPEG, or PNG, up to 25 MB (⌘O)")
        }
        .padding(12)
        .background(ReaderTheme.canvas)
    }

    private var downloadCount: Int {
        [model.setup.speech, model.setup.ocr].compactMap { $0?.state }.filter {
            ["preparing", "downloading", "verifying", "installing"].contains($0)
        }.count
    }

    private var emptyLibrary: some View {
        VStack(spacing: 12) {
            Image(systemName: "books.vertical")
                .font(.system(size: 28, weight: .light))
            Text("Your library starts here")
                .font(.callout.weight(.medium))
            Text("Import a document to keep its text and reading place on this Mac.")
                .font(.caption)
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(ReaderTheme.secondaryText)
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct SidebarRow: View {
    @EnvironmentObject private var model: ReaderModel
    let doc: Document
    @State private var hovered = false

    private var selected: Bool { model.library.active == doc.id }
    private var processing: Bool {
        doc.statusName == "processing" || (selected && model.isProcessing)
    }
    private var complete: Bool {
        selected ? model.isComplete : doc.statusName == "ready" && doc.wordTotal > 0 && doc.wordPosition >= doc.wordTotal
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: sourceIcon)
                .font(.system(size: 21, weight: .regular))
                .foregroundStyle(selected ? Color.primary : ReaderTheme.secondaryText)
                .frame(width: 30, height: 38)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(doc.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .help(doc.title)
                Text(detailText)
                    .font(.system(size: 12))
                    .foregroundStyle(selected ? Color.secondary : ReaderTheme.secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .help(detailText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if processing {
                ProgressView().controlSize(.mini)
                    .accessibilityLabel("Recovering text")
            } else if doc.statusName == "error" {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Text recovery needs attention")
            }
            Menu { rowActions } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 20, height: 24)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .opacity(hovered || selected ? 1 : 0)
            .help("Actions for \(doc.title)")
            .accessibilityLabel("Actions for \(doc.title)")
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .contextMenu { rowActions }
    }

    @ViewBuilder private var rowActions: some View {
        Button("Open") { model.openDocument(doc.id) }
        Button("Rename…") { model.pendingRename = doc }
        Divider()
        Button("Delete…", role: .destructive) { model.pendingDelete = doc }
    }

    private var sourceIcon: String {
        let ext = ((doc.file_name ?? doc.source ?? "") as NSString).pathExtension.lowercased()
        if ext == "pdf" { return "doc.richtext" }
        if ["jpg", "jpeg", "png"].contains(ext) { return "photo" }
        return "doc.text"
    }

    private var detailText: String {
        if processing {
            let total = (selected ? model.state.ocr_total : nil) ?? doc.ocr_total ?? 0
            let done = (selected ? model.state.ocr_done : nil) ?? doc.ocr_done ?? 0
            // OCR counters count recovery jobs, not physical pages in a mixed PDF.
            return total > 0 ? "Recovering text · \(min(total, max(0, done)))/\(total) steps" : "Preparing text recovery…"
        }
        if doc.statusName == "error" {
            return doc.errorMessage.isEmpty ? "Text recovery needs attention" : doc.errorMessage
        }
        let pages = doc.pageCount > 0 ? "\(doc.pageCount) \(doc.pageCount == 1 ? "page" : "pages")" : nil
        if complete { return [pages, "Completed"].compactMap { $0 }.joined(separator: " · ") }
        if doc.wordTotal > 0 {
            let percent = selected ? model.progressPercent : ReadingMath.progress(position: doc.wordPosition, total: doc.wordTotal) * 100
            // Keep the metadata short enough for the sidebar beside the row menu.
            return ["\(Int(percent))% read", pages].compactMap { $0 }.joined(separator: " · ")
        }
        if doc.statusName == "ready" {
            return [pages, "No readable text"].compactMap { $0 }.joined(separator: " · ")
        }
        return pages ?? doc.file_name ?? "Not processed yet"
    }
}

struct RenameSheet: View {
    @EnvironmentObject private var model: ReaderModel
    @Environment(\.dismiss) private var dismiss
    let doc: Document
    @State private var name = ""
    @State private var initialized = false
    @State private var saving = false
    @State private var error: String?
    @FocusState private var nameFocused: Bool

    private var cleanName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var validation: String? {
        if cleanName.isEmpty { return "Enter a document name." }
        if cleanName.count > 100 { return "Use 100 characters or fewer." }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename Document")
                .font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($nameFocused)
                .disabled(saving)
            HStack(alignment: .top) {
                Text(error ?? validation ?? "The original file name will not change.")
                    .foregroundStyle(error != nil ? Color.red : ReaderTheme.secondaryText)
                Spacer()
                Text("\(cleanName.count)/100")
                    .monospacedDigit()
                    .foregroundStyle(ReaderTheme.secondaryText)
            }
            .font(.caption)
            HStack {
                Button("Cancel") { model.pendingRename = nil; dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(saving)
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                Button(saving ? "Renaming…" : "Rename") {
                    guard validation == nil else { return }
                    error = nil
                    model.operationError = nil
                    saving = true
                    model.renameDocument(doc, title: cleanName)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(saving || validation != nil || cleanName == doc.title)
            }
        }
        .padding(24)
        .frame(width: 420)
        .background(ReaderTheme.surface)
        .interactiveDismissDisabled(saving)
        .onAppear {
            guard !initialized else { return }
            initialized = true
            name = doc.title
            nameFocused = true
        }
        .onChange(of: model.pendingRename) { pending in
            if pending == nil { dismiss() }
        }
        .onChange(of: model.operationError) { message in
            guard saving, let message else { return }
            error = message
            saving = false
        }
    }
}
