import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: ReaderModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var dropTargeted = false
    @State private var dropError: String?

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 208, ideal: 256, max: 320)
        } detail: {
            DetailView()
        }
        .navigationSplitViewStyle(.balanced)
        .background(ReaderTheme.canvas)
        .frame(minWidth: 900, minHeight: 600)
        .preferredColorScheme(scheme)
        .task { await model.start() }
        .onChange(of: scenePhase) { _, phase in
            model.activeWindow = phase == .active
        }
        .onAppear {
            #if DEBUG
            ReaderTheme.validateContrast()
            #endif
        }
        .sheet(isPresented: $model.showEdit) {
            EditSheet()
                .environmentObject(model)
                .interactiveDismissDisabled(model.editorHasUnsavedChanges)
        }
        .sheet(item: renameBinding) { doc in
            RenameSheet(doc: doc).environmentObject(model)
        }
        .sheet(isPresented: setupBinding) {
            SetupCard().environmentObject(model)
        }
        .background(deleteAlert)
        .alert("Couldn’t import those files", isPresented: Binding(
            get: { dropError != nil }, set: { if !$0 { dropError = nil } }
        )) {
            Button("Choose a file…") { model.importDocument() }
            Button("Cancel", role: .cancel) { dropError = nil }
        } message: {
            Text(dropError ?? "Choose one PDF, JPEG, or PNG at a time.")
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: ReaderTheme.cardRadius)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8, 5]))
                    .padding(8)
                    .background(Color.accentColor.opacity(0.06))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard urls.count == 1, let url = urls.first else {
                dropError = "Choose one file at a time. Read Along imports a single PDF, JPEG, or PNG, up to 25 MB."
                return false
            }
            Task { await model.importFile(at: url) }
            return true
        } isTargeted: { dropTargeted = $0 }
    }

    private var scheme: ColorScheme? {
        switch model.prefs.appearance {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    private var renameBinding: Binding<Document?> {
        Binding(get: { model.pendingRename }, set: { model.pendingRename = $0 })
    }

    private var setupBinding: Binding<Bool> {
        Binding(get: { model.modelSetupKey != nil },
                set: { if !$0 { model.modelSetupKey = nil } })
    }

    @ViewBuilder private var deleteAlert: some View {
        if let doc = model.pendingDelete {
            Color.clear.frame(width: 0, height: 0)
                .alert("Delete “\(doc.title)” ?", isPresented: Binding(
                    get: { model.pendingDelete != nil },
                    set: { if !$0 { model.pendingDelete = nil } }
                )) {
                    Button("Cancel", role: .cancel) { model.pendingDelete = nil }
                    Button("Delete", role: .destructive) { model.deleteDocument(doc) }
                } message: {
                    Text("This removes Read Along’s managed copy and cached reading data. Your original file elsewhere on this Mac is not changed.")
                }
        }
    }
}

struct DetailView: View {
    @EnvironmentObject private var model: ReaderModel
    @ObservedObject private var backend = BackendService.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showAppearance = false
    @State private var showDetails = false
    @State private var confirmRecovery = false
    /// Which pane is expanded to fill the workspace; `nil` = split view.
    @State private var expandedPane: ViewPane? = nil
    // Owns the PDF toolbar docked above the split view so it and the PDF pane
    // track the same document.
    @StateObject private var splitController = PDFSourceController()

    var body: some View {
        VStack(spacing: 0) {
            notices
            GeometryReader { geometry in
                workspace(width: geometry.size.width)
                    // NSViewRepresentable (NSScrollView) children don't always
                    // participate in SwiftUI safe-area layout, so clamp the
                    // workspace height explicitly to keep scrollable panes clear
                    // of the bottom player bar.
                    .frame(maxHeight: geometry.size.height - bottomInsetHeight)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ReaderTheme.canvas)
        .foregroundStyle(ReaderTheme.primaryText)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.canRead, model.documentLoadingMessage == nil {
                PlayerBar()
                    .frame(maxWidth: 1000)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 16)
                    .frame(maxWidth: .infinity)
                    .background(ReaderTheme.canvas)
            }
        }
        .overlay {
            if model.presentVisible {
                PresentView().transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: model.presentVisible)
        .navigationTitle(title)
        .navigationSubtitle(subtitle)
        .toolbarBackground(ReaderTheme.canvas, for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        .toolbar(content: toolbar)
        .sheet(isPresented: $showDetails) {
            DocumentDetailsView().environmentObject(model)
        }
        .confirmationDialog("Recover this document’s text again?", isPresented: $confirmRecovery,
                            titleVisibility: .visible) {
            Button("Recover document text", role: .destructive) { model.reOCR() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This applies to the whole document and may replace text corrections. Your original file stays unchanged.")
        }
    }

    private var hasWords: Bool { !model.pageModel.words.isEmpty }
    private var isPDFSource: Bool {
        guard let data = model.sourceData, !data.isEmpty else { return false }
        return data.prefix(4) == Data("%PDF".utf8)
    }
    private var hasDocument: Bool {
        model.activeDoc != nil || model.hasSource || model.documentLoadingMessage != nil
    }
    /// Height to subtract from the workspace so scrollable panes never extend
    /// underneath the bottom player bar.
    private var bottomInsetHeight: CGFloat {
        model.canRead && model.documentLoadingMessage == nil ? PlayerBar.measuredHeight : 0
    }
    private var title: String { model.activeDoc?.title ?? "Read Along" }

    private var subtitle: String {
        if model.documentLoadingMessage != nil { return "Opening document…" }
        guard hasDocument else { return "A little space to read." }
        let pages = max(model.sourcePageCount, model.activeDoc?.pageCount ?? 0)
        var parts: [String] = []
        if pages > 0 { parts.append("\(pages) \(pages == 1 ? "page" : "pages")") }
        if model.isProcessing { parts.append("Recovering text") }
        else if model.isComplete { parts.append("Completed") }
        else if hasWords { parts.append("\(Int(model.progressPercent))% read") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var notices: some View {
        if hasDocument, let error = backend.startupError {
            ReaderStatusStrip(symbol: "bolt.slash", title: "Reading engine disconnected", detail: error) {
                Button("Reconnect") { backend.restart() }
            }
        } else if hasDocument, !model.ready {
            ReaderStatusStrip(symbol: "", title: "Preparing the reading engine…",
                              detail: "Your saved document stays here while the engine reconnects.", busy: true) {
                EmptyView()
            }
        }
        if let error = model.operationError {
            ReaderStatusStrip(symbol: "exclamationmark.circle", title: "Couldn’t complete that action", detail: error) {
                Button("Dismiss") { model.dismissOperationError() }
            }
        } else {
            ToastView()
        }
        if model.isProcessing, model.documentLoadingMessage == nil {
            ReaderStatusStrip(symbol: "", title: "Recovering document text", detail: model.processingCopy, busy: true) {
                EmptyView()
            }
        } else if hasWords, recoveryError != nil {
            ReaderStatusStrip(symbol: "exclamationmark.triangle", title: "Some text couldn’t be recovered",
                              detail: recoveryError ?? "Available pages are still readable.") {
                Button("Retry recovery…") { confirmRecovery = true }
            }
        }
    }

    private var recoveryError: String? {
        if model.state.ocr_status == "error" { return model.state.ocr_error ?? "Text recovery stopped." }
        if model.activeDoc?.statusName == "error" { return model.activeDoc?.errorMessage }
        return nil
    }

    @ViewBuilder private func workspace(width: CGFloat) -> some View {
        if !model.ready, !hasDocument {
            EngineStatusView(error: backend.startupError)
        } else if let message = model.documentLoadingMessage {
            DocumentLoadingView(message: message)
        } else if !hasDocument {
            PlaceholderView()
        } else {
            VStack(spacing: 0) {
                if isPDFSource { SourceViewerToolbar(controller: splitController) }
                HSplitView {
                    if expandedPane != .original {
                        textPane
                            .frame(minWidth: 280, idealWidth: width * 0.45, maxWidth: .infinity,
                                   maxHeight: .infinity)
                            .background(ReaderSplitAutosave(documentID: model.library.active ?? "current"))
                            .simultaneousGesture(
                                TapGesture().onEnded { if expandedPane == .text { expandedPane = nil } }
                            )
                            .overlay(alignment: .topTrailing) {
                                expandButton(for: .text)
                            }
                    }
                    if expandedPane != .text {
                        PageView(sharedController: splitController, showsToolbar: false)
                            .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
                            .simultaneousGesture(
                                TapGesture().onEnded { if expandedPane == .original { expandedPane = nil } }
                            )
                            .overlay(alignment: .topLeading) {
                                expandButton(for: .original)
                            }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var textPane: some View {
        cardPane
    }

    private var cardPane: some View {
        VStack(spacing: 0) {
            if hasWords {
                if !model.viewer.textFollows {
                    HStack {
                        Button {
                            model.returnToReading()
                        } label: {
                            Label("Return to reading", systemImage: "arrow.uturn.backward")
                        }
                        .controlSize(.small)
                        .buttonStyle(.borderless)
                        .help("Return to the live reading position without stopping playback")
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    Rectangle()
                        .fill(ReaderTheme.separator)
                        .frame(height: 1)
                }
                ReaderTextView(stage: false)
            } else {
                TextUnavailableView(error: recoveryError) { confirmRecovery = true }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ReaderTheme.surface, in: RoundedRectangle(cornerRadius: ReaderTheme.cardRadius))
        .overlay {
            RoundedRectangle(cornerRadius: ReaderTheme.cardRadius)
                .strokeBorder(ReaderTheme.separator, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: ReaderTheme.cardRadius))
    }

    /// Expand one pane to fill the workspace; tapping again returns to split view.
    @ViewBuilder private func expandButton(for pane: ViewPane) -> some View {
        let isExpanded = expandedPane == pane
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                expandedPane = isExpanded ? nil : pane
            }
        } label: {
            Image(systemName: isExpanded ? "arrow.backward" : "arrow.left.and.right")
                .imageScale(.small)
        }
        .controlSize(.small)
        .buttonStyle(.plain)
        .padding(7)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6))
        .padding(6)
        .help(isExpanded ? "Return to split view" : "Expand \(pane == .text ? "text" : "original")")
    }

    @ToolbarContentBuilder private func toolbar() -> some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { model.findInDocument() } label: {
                Label("Find", systemImage: "magnifyingglass")
            }
            .labelStyle(.iconOnly)
            .controlSize(.small)
            .buttonStyle(.borderless)
            .disabled(!hasWords || model.presentVisible)
            .help("Find in document (⌘F)")

            Button { showAppearance.toggle() } label: {
                Text("Aa").font(.system(size: 15, weight: .medium, design: .serif))
            }
            .controlSize(.small)
            .buttonStyle(.bordered)
            .accessibilityLabel("Reading appearance")
            .help("Reading appearance")
            .popover(isPresented: $showAppearance, arrowEdge: .bottom) {
                ReadingAppearancePopover().environmentObject(model)
            }

            Button { model.enterPresent() } label: {
                Label("Focus", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            .controlSize(.small)
            .buttonStyle(.bordered)
            .disabled(!hasWords || model.presentVisible)
            .help("Focus (⇧⌘F)")

            Menu {
                Button { model.showEdit = true } label: {
                    Label("Edit text…", systemImage: "pencil")
                }
                .disabled(!hasWords)
                Button { model.exportPage(mode: "proof") } label: {
                    Label("Export word-box proof…", systemImage: "square.and.arrow.up")
                }
                Button { model.exportPage(mode: "read") } label: {
                    Label("Export current highlight…", systemImage: "highlighter")
                }
                .disabled(!hasDocument || model.pageModel.pages.isEmpty)
                Divider()
                Button {
                    model.pendingRename = model.activeDoc
                } label: {
                    Label("Rename…", systemImage: "character.cursor.ibeam")
                }
                .disabled(model.activeDoc == nil)
                Button { showDetails = true } label: {
                    Label("Document details…", systemImage: "info.circle")
                }
                .disabled(!hasDocument)
                Divider()
                Button { model.importDocument() } label: {
                    Label("Import document…", systemImage: "plus")
                }
                .disabled(!model.ready)
                SettingsLink { Label("Settings…", systemImage: "gearshape") }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .labelStyle(.iconOnly)
            .controlSize(.small)
            .buttonStyle(.borderless)
            .help("More document actions")
            .accessibilityLabel("More document actions")
        }
    }
}

/// Welcome is useful without installing either optional recognition model.
struct PlaceholderView: View {
    @EnvironmentObject private var model: ReaderModel
    @FocusState private var importFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 10) {
                    Image(systemName: "book.closed")
                        .font(.system(size: 19, weight: .medium))
                    Text("READ ALONG")
                        .font(.caption.weight(.semibold))
                        .tracking(1.8)
                }
                .foregroundStyle(ReaderTheme.secondaryText)
                VStack(alignment: .leading, spacing: 12) {
                    Text("Your words.\nYour pace.")
                        .font(.system(size: 34, weight: .semibold))
                        .tracking(-0.8)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text("Open a PDF or photo. Listen with a moving reading guide, or read aloud and let the guide follow you.")
                        .font(.system(size: 15))
                        .foregroundStyle(ReaderTheme.secondaryText)
                        .lineSpacing(5)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Button { model.importDocument() } label: {
                            Label("Import a document…", systemImage: "plus")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                        .focused($importFocused)
                        .help("Choose a PDF, JPEG, or PNG (⌘O)")
                        Button("Try a sample") { Task { await model.importSample() } }
                            .buttonStyle(.bordered)
                            .controlSize(.regular)
                    }
                    Text("PDF, JPEG, or PNG · Up to 25 MB")
                        .font(.caption)
                        .foregroundStyle(ReaderTheme.secondaryText)
                }
                Divider().overlay(ReaderTheme.separator)
                HStack(alignment: .top, spacing: 24) {
                    welcomeMode("Follow me", symbol: "mic",
                                detail: "Read aloud at your own pace. The reading guide follows your voice.")
                }
                Label("Processed on this Mac. No account required.", systemImage: "lock.shield")
                    .font(.caption)
                    .foregroundStyle(ReaderTheme.secondaryText)
            }
            .padding(32)
            .frame(maxWidth: 640, alignment: .leading)
            .background(ReaderTheme.surface, in: RoundedRectangle(cornerRadius: ReaderTheme.cardRadius))
            .overlay {
                RoundedRectangle(cornerRadius: ReaderTheme.cardRadius)
                    .strokeBorder(ReaderTheme.separator, lineWidth: 1)
            }
            .padding(24)
            .frame(maxWidth: .infinity, minHeight: 500)
        }
        .onAppear { importFocused = true }
    }

    private func welcomeMode(_ title: String, symbol: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol).font(.headline)
            Text(detail)
                .font(.callout)
                .foregroundStyle(ReaderTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct EngineStatusView: View {
    @EnvironmentObject private var model: ReaderModel
    var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("Read Along", systemImage: "book.closed")
                .font(.headline)
                .foregroundStyle(ReaderTheme.secondaryText)
            if error == nil { ProgressView().controlSize(.small) }
            else { Image(systemName: "bolt.slash").font(.title2).foregroundStyle(ReaderTheme.secondaryText) }
            VStack(alignment: .leading, spacing: 8) {
                Text(error == nil ? "Opening your library…" : "Let’s reconnect your library.")
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(error == nil
                     ? "Preparing the reading engine on this Mac. Your documents will appear here when it’s ready."
                     : "The local reading engine couldn’t connect. Your saved documents haven’t been removed.")
                    .font(.callout)
                    .foregroundStyle(ReaderTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error {
                Button("Retry connection") { model.retryConnection() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                DisclosureGroup("Details") {
                    Text(error).font(.callout).textSelection(.enabled).padding(.top, 8)
                }
                .font(.callout)
            } else {
                Text("First launch can take a little longer. No models are downloaded automatically.")
                    .font(.caption)
                    .foregroundStyle(ReaderTheme.secondaryText)
            }
        }
        .padding(32)
        .frame(maxWidth: 490, alignment: .leading)
        .background(ReaderTheme.surface, in: RoundedRectangle(cornerRadius: ReaderTheme.cardRadius))
        .overlay {
            RoundedRectangle(cornerRadius: ReaderTheme.cardRadius).strokeBorder(ReaderTheme.separator)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct DocumentLoadingView: View {
    let message: String

    var body: some View {
        VStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 14) {
                Image(systemName: "doc.text").font(.title).foregroundStyle(ReaderTheme.secondaryText)
                ForEach([1.0, 0.84, 0.93, 0.68], id: \.self) { fraction in
                    Capsule().fill(ReaderTheme.separator.opacity(0.55))
                        .frame(width: 216 * fraction, height: 7)
                }
            }
            .padding(32)
            .frame(width: 290, height: 230, alignment: .topLeading)
            .background(ReaderTheme.surface, in: RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(ReaderTheme.separator) }
            .accessibilityHidden(true)
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(message).font(.callout).foregroundStyle(ReaderTheme.secondaryText)
            }
            Text("Your original file stays unchanged.")
                .font(.caption)
                .foregroundStyle(ReaderTheme.secondaryText)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

private struct TextUnavailableView: View {
    @EnvironmentObject private var model: ReaderModel
    let error: String?
    let onRecover: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            if model.isProcessing { ProgressView().controlSize(.small) }
            else {
                Image(systemName: error == nil ? "text.page" : "exclamationmark.triangle")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(ReaderTheme.secondaryText)
            }
            Text(model.isProcessing ? "Making room for your words…" : "No readable text yet")
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text(error ?? (model.isProcessing
                 ? "The original is available while text recovery continues. Ready pages will appear here as they finish."
                 : "This page may contain a photo or an illustration. You can browse the original, or try recovering the document’s text again."))
                .font(.callout)
                .foregroundStyle(ReaderTheme.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let sourceError = model.sourceError {
                Text(sourceError).font(.caption).foregroundStyle(ReaderTheme.secondaryText)
                Button("Retry original") { model.retrySource() }
            } else if model.sourceLoading {
                Text("Preparing the original preview…").font(.caption).foregroundStyle(ReaderTheme.secondaryText)
            }
            if !model.isProcessing {
                Button("Recover document text…", action: onRecover)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: 380)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ReaderStatusStrip<Actions: View>: View {
    let symbol: String
    let title: String
    let detail: String
    var busy = false
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if busy { ProgressView().controlSize(.small).accessibilityLabel(title) }
            else { Image(systemName: symbol).foregroundStyle(ReaderTheme.secondaryText).accessibilityHidden(true) }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(ReaderTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            actions().controlSize(.small).fixedSize()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(ReaderTheme.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(ReaderTheme.separator).frame(height: 1) }
        .accessibilityElement(children: .contain)
    }
}

struct ToastView: View {
    @EnvironmentObject private var model: ReaderModel

    var body: some View {
        if let toast = model.toast {
            ReaderStatusStrip(symbol: toast.isError ? "exclamationmark.circle" : "checkmark.circle",
                              title: toast.isError ? "Action needed" : toast.text,
                              detail: toast.isError ? toast.text : "") {
                Button { model.toast = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Dismiss notification")
                    .help("Dismiss notification")
            }
        }
    }
}

private struct ReadingAppearancePopover: View {
    @EnvironmentObject private var model: ReaderModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Reading appearance").font(.headline)
            VStack(alignment: .leading, spacing: 8) {
                Text("Typeface").font(.callout)
                Picker("Reading typeface", selection: Binding(
                    get: { model.prefs.readingFont ?? "sans" }, set: { model.prefs.readingFont = $0 }
                )) {
                    Text("SF Pro").tag("sans")
                    Text("New York").tag("serif")
                    Text("Mono").tag("mono")
                }
                .pickerStyle(.segmented).labelsHidden()
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Text size")
                    Spacer()
                    Text("\(Int(model.prefs.size)) pt").monospacedDigit().foregroundStyle(ReaderTheme.secondaryText)
                }
                Slider(value: $model.prefs.size, in: 16...32, step: 1) { Text("Text size") }
                    .accessibilityValue("\(Int(model.prefs.size)) points")
            }
            .font(.callout)
            Toggle("Reading guide", isOn: $model.prefs.guide)
                .help("Emphasize the current phrase while keeping surrounding text readable")
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("Appearance").font(.callout)
                Picker("Appearance", selection: $model.prefs.appearance) {
                    Text("System").tag(Appearance.system)
                    Text("Light").tag(Appearance.light)
                    Text("Dark").tag(Appearance.dark)
                }
                .pickerStyle(.segmented).labelsHidden()
            }
        }
        .padding(20)
        .frame(width: 310)
        .foregroundStyle(ReaderTheme.primaryText)
        .background(ReaderTheme.raised)
    }
}

private struct DocumentDetailsView: View {
    @EnvironmentObject private var model: ReaderModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("Document details", systemImage: "doc.text.magnifyingglass").font(.headline)
            Text(model.activeDoc?.title ?? "Document")
                .font(.title2.weight(.semibold)).textSelection(.enabled)
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 12) {
                detail("Original file", value: model.activeDoc?.file_name ?? "—")
                detail("Pages", value: String(max(model.sourcePageCount, model.activeDoc?.pageCount ?? 0)))
                detail("Available words", value: model.wordsTotal.formatted())
                detail("Text recovery", value: model.isProcessing ? "In progress" : (model.canRead ? "Readable" : "No text available"))
            }
            .font(.callout)
            Text("Read Along keeps a managed copy on this Mac. Your original file is unchanged.")
                .font(.caption).foregroundStyle(ReaderTheme.secondaryText)
            HStack { Spacer(); Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .keyboardShortcut(.defaultAction) }
        }
        .padding(28)
        .frame(width: 440)
        .foregroundStyle(ReaderTheme.primaryText)
        .background(ReaderTheme.surface)
    }

    private func detail(_ label: String, value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(ReaderTheme.secondaryText)
            Text(value).textSelection(.enabled)
        }
    }
}

/// Let the native splitter save its divider; do not turn browsing into model state.
private struct ReaderSplitAutosave: NSViewRepresentable {
    let documentID: String

    func makeNSView(context: Context) -> Probe { Probe(name: documentID) }
    func updateNSView(_ view: Probe, context: Context) { view.name = documentID; view.needsLayout = true }

    final class Probe: NSView {
        var name: String
        private var configuredName: String?

        init(name: String) { self.name = name; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func layout() {
            super.layout()
            var ancestor = superview
            while let view = ancestor {
                if let split = view as? NSSplitView, split.isVertical, split.subviews.count == 2,
                   split.bounds.width > 0 {
                    guard configuredName != name else { return }
                    configuredName = name
                    let key = "ReadAlong.readerSplit.v1.\(name)"
                    let saved = UserDefaults.standard.object(forKey: "NSSplitView Subview Frames \(key)") != nil
                    split.autosaveName = NSSplitView.AutosaveName(key)
                    if !saved { split.setPosition(split.bounds.width * 0.45, ofDividerAt: 0) }
                    return
                }
                ancestor = view.superview
            }
        }
    }
}
