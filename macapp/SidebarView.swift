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
            header
            searchField
                .padding(.horizontal, 12)
                .padding(.bottom, 10)

            if model.library.documents.isEmpty {
                emptyLibrary
            } else if matches.isEmpty {
                noMatches
            } else {
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(Array(matches.enumerated()), id: \.element.id) { entry in
                            SidebarRow(doc: entry.element, index: entry.offset + 1)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
                .scrollIndicators(.never)
            }

            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ReaderTheme.sidebar)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("LIBRARY")
                .font(ReaderTheme.micro(9.5))
                .tracking(1.5)
                .foregroundStyle(ReaderTheme.secondaryText)
            Spacer()
            Text("\(model.library.documents.count)")
                .font(ReaderTheme.numeral(10))
                .foregroundStyle(ReaderTheme.tertiaryText)
        }
        .padding(.horizontal, 14)
        .padding(.top, 16)
        .padding(.bottom, 10)
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(ReaderTheme.tertiaryText)
                .accessibilityHidden(true)
            TextField("Search documents", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .accessibilityLabel("Search document titles and file names")
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(ReaderTheme.tertiaryText)
                .help("Clear search")
                .accessibilityLabel("Clear document search")
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 29)
        .background(ReaderTheme.raised,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(ReaderTheme.hairline, lineWidth: 1)
        }
    }

    private var footer: some View {
        VStack(spacing: 8) {
            Rectangle().fill(ReaderTheme.hairline).frame(height: 1)
            if downloadCount > 0 {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.mini)
                    Text("Downloading \(downloadCount) model\(downloadCount == 1 ? "" : "s")")
                        .font(.system(size: 10.5))
                    Spacer(minLength: 0)
                    SettingsLink {
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .help("View model downloads in Settings")
                    .accessibilityLabel("View downloads in Settings")
                }
                .foregroundStyle(ReaderTheme.secondaryText)
                .padding(.horizontal, 4)
            }
            Button { model.importDocument() } label: {
                HStack(spacing: 9) {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(ReaderTheme.accent)
                        .frame(width: 21, height: 21)
                        .background(ReaderTheme.accentSoft, in: Circle())
                    Text("Import document")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(ReaderTheme.primaryText)
                    Spacer(minLength: 6)
                    Text("⌘O")
                        .font(ReaderTheme.numeral(9.5))
                        .foregroundStyle(ReaderTheme.tertiaryText)
                }
                .padding(.horizontal, 9)
                .frame(height: 38)
                .background(ReaderTheme.raised,
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(ReaderTheme.hairline, lineWidth: 1)
                }
                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("Import one PDF, JPEG, or PNG, up to 25 MB (⌘O)")
        }
        .padding(10)
    }

    private var downloadCount: Int {
        [model.setup.speech, model.setup.ocr].compactMap { $0?.state }.filter {
            ["preparing", "downloading", "verifying", "installing"].contains($0)
        }.count
    }

    private var emptyLibrary: some View {
        VStack(spacing: 12) {
            Image(systemName: "books.vertical")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(ReaderTheme.tertiaryText)
                .frame(width: 46, height: 46)
                .background(ReaderTheme.raised, in: Circle())
            Text("Your library starts here")
                .font(.system(size: 13, weight: .medium))
            Text("Import a document to keep its text and reading place on this Mac.")
                .font(.system(size: 11))
                .foregroundStyle(ReaderTheme.secondaryText)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
        }
        .foregroundStyle(ReaderTheme.primaryText)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noMatches: some View {
        VStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(ReaderTheme.tertiaryText)
            Text("No matching documents")
                .font(.system(size: 12.5, weight: .medium))
            Text("Search a title or file name.")
                .font(.system(size: 11))
                .foregroundStyle(ReaderTheme.secondaryText)
            Button("Clear search") { query = "" }
                .buttonStyle(StudioSecondaryButtonStyle())
                .padding(.top, 4)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct SidebarRow: View {
    @EnvironmentObject private var model: ReaderModel
    let doc: Document
    let index: Int
    @State private var hovered = false

    private var selected: Bool { model.library.active == doc.id }
    private var opening: Bool { model.openingDocumentID == doc.id }
    /// Live progress is only valid once the page model and backend state
    /// both belong to this document. Before then, reuse the row's stored
    /// position so a switch cannot flash the previous document's Done state.
    private var live: Bool {
        selected && model.pageModel.doc_id == doc.id && model.state.doc_id == doc.id
            && model.state.model_ready != false
    }
    private var storedComplete: Bool {
        doc.statusName == "ready" && doc.wordTotal > 0 && doc.wordPosition >= doc.wordTotal
    }
    private var processing: Bool {
        doc.statusName == "processing" || (live && model.isProcessing)
    }
    private var failed: Bool { doc.statusName == "error" }
    private var complete: Bool { live ? model.isComplete : storedComplete }
    private var percent: Int {
        guard doc.wordTotal > 0 else { return 0 }
        if complete { return 100 }
        return Int((live ? model.progressPercent : ReadingMath.progress(position: doc.wordPosition, total: doc.wordTotal) * 100).rounded())
    }

    var body: some View {
        HStack(spacing: 0) {
            Button { model.openDocument(doc.id) } label: {
                HStack(spacing: 10) {
                    Text(String(format: "%02d", index))
                        .font(ReaderTheme.numeral(9.5, weight: .medium))
                        .foregroundStyle(selected ? ReaderTheme.accent : ReaderTheme.tertiaryText)
                        .frame(width: 18, alignment: .leading)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(doc.title)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(ReaderTheme.primaryText)
                            .lineLimit(1)
                            .help(doc.title)
                        Text(metaText)
                            .font(.system(size: 10.5))
                            .foregroundStyle(ReaderTheme.secondaryText)
                            .lineLimit(1)
                            .minimumScaleFactor(0.9)
                            .help(metaText)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    trailing
                }
                .padding(.leading, 8)
                .padding(.trailing, 4)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Menu { rowActions } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 22, height: 26)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 22)
            .opacity(hovered || selected ? 1 : 0)
            .allowsHitTesting(hovered || selected)
            .help("Actions for \(doc.title)")
            .accessibilityLabel("Actions for \(doc.title)")
            .padding(.trailing, 4)
        }
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(selected ? ReaderTheme.selection : (hovered ? ReaderTheme.raised.opacity(0.7) : Color.clear))
        }
        .overlay(alignment: .leading) {
            if selected {
                Capsule()
                    .fill(ReaderTheme.accent)
                    .frame(width: 2, height: 18)
                    .padding(.leading, 2)
            }
        }
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(ReaderTheme.hairline, lineWidth: 1)
            }
        }
        .onHover { hovered = $0 }
        .contextMenu { rowActions }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var trailing: some View {
        if opening {
            ProgressView().controlSize(.mini)
                .accessibilityLabel("Opening document")
        } else if processing {
            ProgressView().controlSize(.mini)
                .accessibilityLabel("Recovering text")
        } else if failed {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 10.5))
                .foregroundStyle(ReaderTheme.warning)
                .accessibilityLabel("Text recovery needs attention")
        } else if doc.wordTotal > 0 {
            Text(complete ? "Done" : "\(percent)%")
                .font(ReaderTheme.numeral(9.5, weight: .medium))
                .foregroundStyle(complete ? ReaderTheme.success : ReaderTheme.secondaryText)
                .frame(minWidth: 28, alignment: .trailing)
        } else {
            Text("—")
                .font(ReaderTheme.numeral(9.5))
                .foregroundStyle(ReaderTheme.tertiaryText)
        }
    }

    private var metaText: String {
        if processing {
            let total = (live ? model.state.ocr_total : nil) ?? doc.ocr_total ?? 0
            let done = (live ? model.state.ocr_done : nil) ?? doc.ocr_done ?? 0
            return total > 0 ? "Recovering · \(min(total, max(0, done)))/\(total)" : "Preparing text…"
        }
        if failed { return "Text recovery needs attention" }
        let pages = doc.pageCount > 0 ? "\(doc.pageCount) \(doc.pageCount == 1 ? "page" : "pages")" : nil
        let date = openedText
        if let pages, !date.isEmpty { return "\(pages)  ·  \(date)" }
        if let pages { return pages }
        if doc.statusName == "ready" { return "No readable text" }
        return date.isEmpty ? (doc.file_name ?? "Not processed yet") : date
    }

    private var openedText: String {
        guard let stamp = doc.last_opened, stamp > 0 else { return "" }
        let date = Date(timeIntervalSince1970: stamp)
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        let days = calendar.dateComponents([.day], from: date, to: Date()).day ?? 99
        let formatter = DateFormatter()
        formatter.locale = .current
        if days < 7 { formatter.dateFormat = "EEEE" } else { formatter.dateFormat = "MMM d" }
        return formatter.string(from: date)
    }

    @ViewBuilder private var rowActions: some View {
        Button("Open") { model.openDocument(doc.id) }
        Button("Rename…") { model.pendingRename = doc }
        Divider()
        Button("Delete…", role: .destructive) { model.pendingDelete = doc }
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
        VStack(alignment: .leading, spacing: 16) {
            Text("RENAME DOCUMENT")
                .font(ReaderTheme.micro(9.5))
                .tracking(1.4)
                .foregroundStyle(ReaderTheme.secondaryText)
            Text(doc.title)
                .font(.system(size: 19, weight: .semibold))
                .tracking(-0.2)
                .lineLimit(1)
            TextField("Name", text: $name)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(.horizontal, 11)
                .frame(height: 34)
                .background(ReaderTheme.canvas,
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(nameFocused ? ReaderTheme.accent.opacity(0.6) : ReaderTheme.hairline,
                                      lineWidth: 1)
                }
                .focused($nameFocused)
                .disabled(saving)
            HStack(alignment: .top) {
                Text(error ?? validation ?? "The original file name will not change.")
                    .foregroundStyle(error != nil ? ReaderTheme.warning : ReaderTheme.secondaryText)
                Spacer()
                Text("\(cleanName.count)/100")
                    .font(ReaderTheme.numeral(10))
                    .foregroundStyle(ReaderTheme.tertiaryText)
            }
            .font(.system(size: 10.5))
            Rectangle().fill(ReaderTheme.hairline).frame(height: 1)
            HStack {
                Button("Cancel") { model.pendingRename = nil; dismiss() }
                    .buttonStyle(StudioSecondaryButtonStyle())
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
                .buttonStyle(StudioPrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(saving || validation != nil || cleanName == doc.title)
            }
        }
        .padding(26)
        .frame(width: 420)
        .foregroundStyle(ReaderTheme.primaryText)
        .glassPanel(radius: 16)
        .interactiveDismissDisabled(saving)
        .onAppear {
            guard !initialized else { return }
            initialized = true
            name = doc.title
            nameFocused = true
        }
        .onChange(of: model.pendingRename) {
            if model.pendingRename == nil { dismiss() }
        }
        .onChange(of: model.operationError) {
            guard saving, let message = model.operationError else { return }
            error = message
            saving = false
        }
    }
}
