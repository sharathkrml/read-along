import AppKit
import SwiftUI

// MARK: - Window shell

struct ContentView: View {
    @EnvironmentObject private var model: ReaderModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dropTargeted = false
    @State private var dropError: String?
    @State private var sidebarVisible = true

    var body: some View {
        VStack(spacing: 0) {
            StudioHeader(sidebarVisible: $sidebarVisible)
            Rectangle().fill(ReaderTheme.hairline).frame(height: 1)
            HStack(spacing: 0) {
                if sidebarVisible {
                    SidebarView()
                        .frame(width: 266)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                    Rectangle().fill(ReaderTheme.hairline).frame(width: 1)
                }
                DetailView()
            }
        }
        .frame(minWidth: 1000, minHeight: 620)
        .ignoresSafeArea(.all, edges: .top)
        .background(ReaderTheme.canvas)
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
        .animation(.easeInOut(duration: 0.18), value: sidebarVisible)
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
                RoundedRectangle(cornerRadius: ReaderTheme.cardRadius, style: .continuous)
                    .strokeBorder(ReaderTheme.accent, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                    .padding(10)
                    .background(ReaderTheme.accent.opacity(0.06))
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
        .overlay {
            if model.presentVisible {
                PresentView().transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: model.presentVisible)
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

// MARK: - Title bar

private struct StudioHeader: View {
    @EnvironmentObject private var model: ReaderModel
    @Binding var sidebarVisible: Bool
    @State private var showAppearance = false
    @State private var showDetails = false

    private var hasDocument: Bool {
        model.activeDoc != nil || model.hasSource || model.documentLoadingMessage != nil
    }
    private var hasWords: Bool { !model.pageModel.words.isEmpty }
    private var title: String { model.activeDoc?.title ?? "Read Along" }

    private var subtitle: String {
        if model.documentLoadingMessage != nil { return "Opening document…" }
        guard hasDocument else { return "Your library, on this Mac" }
        let pages = max(model.sourcePageCount, model.activeDoc?.pageCount ?? 0)
        var parts: [String] = []
        if pages > 0 { parts.append("\(pages) \(pages == 1 ? "page" : "pages")") }
        if model.isProcessing { parts.append("Recovering text") }
        else if model.isComplete { parts.append("Finished") }
        else if hasWords { parts.append("\(Int(model.progressPercent))% read") }
        return parts.joined(separator: "  ·  ")
    }

    private var mode: Binding<ViewPane> {
        Binding(
            get: { model.expandedPane ?? .split },
            set: { model.expandedPane = $0 == .split ? nil : $0 }
        )
    }

    var body: some View {
        HStack(spacing: 14) {
            Button {
                sidebarVisible.toggle()
            } label: {
                Image(systemName: "sidebar.left")
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(StudioIconButtonStyle())
            .help(sidebarVisible ? "Hide library" : "Show library")
            .accessibilityLabel(sidebarVisible ? "Hide library" : "Show library")

            HStack(spacing: 8) {
                Image(systemName: "text.book.closed.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(ReaderTheme.accent)
                    .accessibilityHidden(true)
                Text("Read Along")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ReaderTheme.primaryText)
            }
            .fixedSize()

            if hasDocument {
                Rectangle()
                    .fill(ReaderTheme.hairlineStrong)
                    .frame(width: 1, height: 18)
                    .padding(.horizontal, 2)

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(ReaderTheme.primaryText)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(ReaderTheme.secondaryText)
                        .lineLimit(1)
                        .monospacedDigit()
                }
                .frame(maxWidth: 320, alignment: .leading)
                .help(title)
            }

            Spacer(minLength: 8)

            if hasDocument {
                ViewModeControl(mode: mode, textEnabled: hasWords, splitEnabled: hasWords)
                Rectangle()
                    .fill(ReaderTheme.hairlineStrong)
                    .frame(width: 1, height: 18)

                HeaderIconButton(symbol: "magnifyingglass", help: "Find in document (⌘F)") {
                    model.findInDocument()
                }
                .disabled(!hasWords || model.presentVisible)

                Button {
                    showAppearance.toggle()
                } label: {
                    Text("Aa")
                        .font(.system(size: 12.5, weight: .medium, design: .serif))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(StudioIconButtonStyle())
                .accessibilityLabel("Reading appearance")
                .help("Reading appearance")
                .popover(isPresented: $showAppearance, arrowEdge: .bottom) {
                    ReadingAppearancePopover().environmentObject(model)
                }

                HeaderIconButton(symbol: "arrow.up.left.and.arrow.down.right",
                                 help: "Focus (⇧⌘F)") {
                    model.enterPresent()
                }
                .disabled(!hasWords || model.presentVisible)
            }

            moreMenu
        }
        .padding(.leading, 84)
        .padding(.trailing, 14)
        .frame(height: 54)
        .background {
            ZStack {
                ReaderTheme.canvas
                WindowDragArea()
            }
        }
    }

    private var moreMenu: some View {
        Menu {
            Button { model.importDocument() } label: {
                Label("Import document…", systemImage: "plus")
            }
            .disabled(!model.ready)
            if hasDocument {
                Divider()
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
                .disabled(model.pageModel.pages.isEmpty)
                Divider()
                Button { model.pendingRename = model.activeDoc } label: {
                    Label("Rename…", systemImage: "character.cursor.ibeam")
                }
                .disabled(model.activeDoc == nil)
                Button { showDetails = true } label: {
                    Label("Document details…", systemImage: "info.circle")
                }
            }
            Divider()
            SettingsLink { Label("Settings…", systemImage: "gearshape") }
        } label: {
            Image(systemName: "ellipsis")
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 26)
        .help("More actions")
        .accessibilityLabel("More actions")
        .sheet(isPresented: $showDetails) {
            DocumentDetailsView().environmentObject(model)
        }
    }
}

/// A compact three-way view switch instead of scattered expand arrows.
private struct ViewModeControl: View {
    @Binding var mode: ViewPane
    var textEnabled: Bool
    var splitEnabled: Bool

    var body: some View {
        HStack(spacing: 1) {
            segment(.text, symbol: "text.alignleft", help: "Text only (⌘1)", enabled: textEnabled)
            segment(.original, symbol: "doc.richtext", help: "Original only (⌘2)", enabled: true)
            segment(.split, symbol: "rectangle.split.2x1", help: "Split view (⌘3)", enabled: splitEnabled)
        }
        .padding(2)
        .background(ReaderTheme.raised,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(ReaderTheme.hairline, lineWidth: 1)
        }
    }

    private func segment(_ pane: ViewPane, symbol: String, help: String, enabled: Bool) -> some View {
        let selected = _mode.wrappedValue == pane
        return Button {
            _mode.wrappedValue = pane
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(selected ? ReaderTheme.primaryText : ReaderTheme.secondaryText)
                .frame(width: 28, height: 22)
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(selected ? ReaderTheme.selection : Color.clear)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .help(help)
        .accessibilityLabel(help)
    }
}

private struct HeaderIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 26, height: 26)
        }
        .buttonStyle(StudioIconButtonStyle())
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Empty areas of the custom title bar move the window; buttons above it still win.
private struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ view: DragView, context: Context) {}

    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                window?.zoom(nil)
            } else {
                window?.performDrag(with: event)
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { self }
    }
}

// MARK: - Reader

struct DetailView: View {
    @EnvironmentObject private var model: ReaderModel
    @ObservedObject private var backend = BackendService.shared
    @State private var confirmRecovery = false
    @StateObject private var splitController = PDFSourceController()

    var body: some View {
        VStack(spacing: 0) {
            notices
            GeometryReader { geometry in
                workspace(width: geometry.size.width)
                    .frame(maxHeight: geometry.size.height - bottomInsetHeight)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ReaderTheme.canvas)
        .foregroundStyle(ReaderTheme.primaryText)
        .overlay(alignment: .bottom) {
            if model.canRead, model.documentLoadingMessage == nil {
                PlayerBar()
                    .frame(maxWidth: .infinity)
            }
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
    private var bottomInsetHeight: CGFloat {
        model.canRead && model.documentLoadingMessage == nil ? PlayerBar.measuredHeight : 0
    }

    @ViewBuilder private var notices: some View {
        VStack(spacing: 8) {
            if hasDocument, let error = backend.startupError {
                ReaderStatusStrip(symbol: "bolt.slash", title: "Reading engine disconnected", detail: error) {
                    Button("Reconnect") { backend.restart() }
                        .buttonStyle(StudioSecondaryButtonStyle())
                }
            } else if hasDocument, !model.ready {
                ReaderStatusStrip(symbol: "clock", title: "Preparing the reading engine…",
                                  detail: "Your saved document stays here while the engine reconnects.", busy: true) {
                    EmptyView()
                }
            }
            if let error = model.operationError {
                ReaderStatusStrip(symbol: "exclamationmark.circle", title: "Couldn’t complete that action", detail: error) {
                    Button("Dismiss") { model.dismissOperationError() }
                        .buttonStyle(StudioSecondaryButtonStyle())
                }
            } else {
                ToastView()
            }
            if model.isProcessing, model.documentLoadingMessage == nil {
                ReaderStatusStrip(symbol: "clock", title: "Recovering document text", detail: model.processingCopy, busy: true) {
                    EmptyView()
                }
            } else if hasWords, recoveryError != nil {
                ReaderStatusStrip(symbol: "exclamationmark.triangle", title: "Some text couldn’t be recovered",
                                  detail: recoveryError ?? "Available pages are still readable.") {
                    Button("Retry recovery…") { confirmRecovery = true }
                        .buttonStyle(StudioSecondaryButtonStyle())
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
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
            // One seamless box: a single surface hosts both panes, divided
            // only by the split divider. The PDF on the right owns the page;
            // the text panel mirrors it.
            HSplitView {
                if model.expandedPane != .original {
                    textPane
                        .frame(minWidth: 380,
                               idealWidth: 420,
                               maxWidth: model.expandedPane == .text ? .infinity : 560,
                               maxHeight: .infinity)
                        .background(ReaderSplitAutosave(documentID: model.library.active ?? "current"))
                }
                if model.expandedPane != .text {
                    VStack(spacing: 0) {
                        PageView(sharedController: splitController)
                    }
                    .frame(minWidth: 330, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(ReaderTheme.surface,
                        in: RoundedRectangle(cornerRadius: ReaderTheme.cardRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: ReaderTheme.cardRadius, style: .continuous)
                    .strokeBorder(ReaderTheme.hairline, lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .clipShape(RoundedRectangle(cornerRadius: ReaderTheme.cardRadius, style: .continuous))
            .padding(12)
            .onChange(of: splitController.currentPage) { _, newPage in
                if isPDFSource { syncPDFPage(newPage) }
            }
        }
    }

    private func syncPDFPage(_ oneBased: Int) {
        if splitController.lastProgrammaticPage == oneBased {
            splitController.lastProgrammaticPage = nil
            return
        }
        let zeroBased = max(0, oneBased - 1)
        if model.viewer.browsedPage != zeroBased {
            model.viewer.browsedPage = zeroBased
            model.viewer.sourceFollows = false
        }
    }

    @ViewBuilder private var textPane: some View {
        if hasWords {
            TextPanel()
        } else {
            TextUnavailableView(error: recoveryError) { confirmRecovery = true }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Welcome & states

struct PlaceholderView: View {
    @EnvironmentObject private var model: ReaderModel
    @FocusState private var importFocused: Bool

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 0) {
                    Spacer(minLength: 28)
                    HStack(alignment: .center, spacing: 32) {
                        VStack(alignment: .leading, spacing: 0) {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(ReaderTheme.accent)
                                    .frame(width: 5, height: 5)
                                Text("READ ALONG")
                                    .font(ReaderTheme.micro(10))
                                    .tracking(1.8)
                                    .foregroundStyle(ReaderTheme.secondaryText)
                            }
                            .padding(.bottom, 18)

                            Text("Your words.\nYour pace.")
                                .font(.system(size: 46, weight: .semibold))
                                .tracking(-1.2)
                                .lineSpacing(2)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityAddTraits(.isHeader)
                                .padding(.bottom, 18)

                            Text("Open a PDF or a photo. Listen with a moving reading guide, or read aloud and let the guide follow your voice.")
                                .font(.system(size: 14))
                                .foregroundStyle(ReaderTheme.secondaryText)
                                .lineSpacing(5)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.bottom, 26)

                            HStack(spacing: 10) {
                                Button { model.importDocument() } label: {
                                    Label("Import a document", systemImage: "plus")
                                }
                                .buttonStyle(StudioPrimaryButtonStyle())
                                .focused($importFocused)
                                .help("Choose a PDF, JPEG, or PNG (⌘O)")

                                Button("Try a sample") { Task { await model.importSample() } }
                                    .buttonStyle(StudioSecondaryButtonStyle())
                            }
                            .padding(.bottom, 14)

                            Text("PDF, JPEG, or PNG  ·  Up to 25 MB")
                                .font(.system(size: 11))
                                .foregroundStyle(ReaderTheme.tertiaryText)
                                .padding(.bottom, 30)

                            Rectangle()
                                .fill(ReaderTheme.hairline)
                                .frame(height: 1)
                                .padding(.bottom, 16)

                            HStack(spacing: 8) {
                                Image(systemName: "lock.shield")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(ReaderTheme.tertiaryText)
                                    .accessibilityHidden(true)
                                Text("Processed on this Mac. No account required.")
                                    .font(.system(size: 11))
                                    .foregroundStyle(ReaderTheme.tertiaryText)
                            }
                        }
                        .frame(maxWidth: 370, alignment: .leading)

                        ReadingPreviewCard()
                            .accessibilityHidden(true)
                    }
                    .padding(.horizontal, 32)
                    .padding(.vertical, 40)
                    .frame(maxWidth: 860)
                    Spacer(minLength: 28)
                }
                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
        }
        .onAppear { importFocused = true }
    }
}

/// A small paper study that gives the empty state something to look at.
private struct ReadingPreviewCard: View {
    private let lines: [(width: CGFloat, highlight: Bool)] = [
        (150, false), (128, false), (160, false), (108, false),
        (142, true), (132, false), (90, false),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("CHAPTER ONE")
                    .font(.system(size: 8, weight: .semibold))
                    .tracking(1.4)
                    .foregroundStyle(Color.black.opacity(0.38))
                Text("The quiet hour")
                    .font(.system(size: 23, weight: .semibold, design: .serif))
                    .foregroundStyle(Color.black.opacity(0.82))
            }
            .padding(.bottom, 8)

            VStack(alignment: .leading, spacing: 11) {
                ForEach(Array(lines.enumerated()), id: \.offset) { entry in
                    let line = entry.element
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(line.highlight ? ReaderTheme.pageCurrent.opacity(0.30) : Color.black.opacity(0.10))
                            .frame(width: line.width + 10, height: 9)
                        Capsule()
                            .fill(line.highlight ? ReaderTheme.pageCurrent : Color.black.opacity(0.20))
                            .frame(width: line.width, height: 2.5)
                            .offset(y: 3)
                    }
                }
            }

            Spacer(minLength: 24)

            HStack {
                Text("03")
                    .font(ReaderTheme.numeral(9, weight: .medium))
                Spacer()
                Image(systemName: "bookmark")
                    .font(.system(size: 9))
            }
            .foregroundStyle(Color.black.opacity(0.30))
        }
        .padding(24)
        .frame(width: 220, height: 306, alignment: .topLeading)
        .background(Color(red: 0.975, green: 0.968, blue: 0.945),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.black.opacity(0.08), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.28), radius: 28, x: 0, y: 18)
        .rotationEffect(.degrees(-2))
    }
}

private struct EngineStatusView: View {
    @EnvironmentObject private var model: ReaderModel
    var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 8) {
                Circle()
                    .fill(error == nil ? ReaderTheme.accent : ReaderTheme.warning)
                    .frame(width: 5, height: 5)
                Text("READ ALONG")
                    .font(ReaderTheme.micro(10))
                    .tracking(1.8)
                    .foregroundStyle(ReaderTheme.secondaryText)
            }
            if error == nil {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "bolt.slash")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(ReaderTheme.secondaryText)
            }
            Text(error == nil ? "Opening your library…" : "Let’s reconnect your library.")
                .font(.system(size: 28, weight: .semibold))
                .tracking(-0.4)
                .accessibilityAddTraits(.isHeader)
            Text(error == nil
                 ? "Preparing the reading engine on this Mac. Your documents will appear here when it’s ready."
                 : "The local reading engine couldn’t connect. Your saved documents haven’t been removed.")
                .font(.system(size: 13))
                .foregroundStyle(ReaderTheme.secondaryText)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
            if let error {
                Button("Retry connection") { model.retryConnection() }
                    .buttonStyle(StudioPrimaryButtonStyle())
                DisclosureGroup("Details") {
                    Text(error).font(.system(size: 11)).textSelection(.enabled).padding(.top, 8)
                }
                .font(.system(size: 12))
            } else {
                Text("First launch can take a little longer. No models are downloaded automatically.")
                    .font(.system(size: 11))
                    .foregroundStyle(ReaderTheme.tertiaryText)
            }
        }
        .padding(40)
        .frame(maxWidth: 470, alignment: .leading)
        .glassPanel(radius: ReaderTheme.cardRadius)
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct DocumentLoadingView: View {
    let message: String

    var body: some View {
        VStack(spacing: 22) {
            VStack(alignment: .leading, spacing: 13) {
                Text("PAGE 01")
                    .font(ReaderTheme.micro(8))
                    .tracking(1.4)
                    .foregroundStyle(Color.black.opacity(0.35))
                ForEach([1.0, 0.84, 0.93, 0.68], id: \.self) { fraction in
                    Capsule().fill(Color.black.opacity(0.10))
                        .frame(width: 216 * fraction, height: 6)
                }
            }
            .padding(30)
            .frame(width: 290, height: 230, alignment: .topLeading)
            .background(Color(red: 0.97, green: 0.965, blue: 0.945),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .shadow(color: .black.opacity(0.22), radius: 22, y: 12)
            .accessibilityHidden(true)
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(message).font(.system(size: 12)).foregroundStyle(ReaderTheme.secondaryText)
            }
            Text("Your original file stays unchanged.")
                .font(.system(size: 11))
                .foregroundStyle(ReaderTheme.tertiaryText)
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
        VStack(spacing: 14) {
            if model.isProcessing { ProgressView().controlSize(.small) }
            else {
                Image(systemName: error == nil ? "text.page" : "exclamationmark.triangle")
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(ReaderTheme.secondaryText)
            }
            Text(model.isProcessing ? "Making room for your words…" : "No readable text yet")
                .font(.system(size: 17, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            Text(error ?? (model.isProcessing
                 ? model.processingCopy
                 : "This page may contain a photo or an illustration. You can browse the original, or try recovering the document’s text again."))
                .font(.system(size: 12.5))
                .foregroundStyle(ReaderTheme.secondaryText)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            if let sourceError = model.sourceError {
                Text(sourceError).font(.system(size: 11)).foregroundStyle(ReaderTheme.secondaryText)
                Button("Retry original") { model.retrySource() }
                    .buttonStyle(StudioSecondaryButtonStyle())
            } else if model.sourceLoading {
                Text("Preparing the original preview…")
                    .font(.system(size: 11))
                    .foregroundStyle(ReaderTheme.tertiaryText)
            }
            if !model.isProcessing {
                Button("Recover document text…", action: onRecover)
                    .buttonStyle(StudioSecondaryButtonStyle())
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
        HStack(alignment: .center, spacing: 11) {
            Group {
                if busy {
                    ProgressView().controlSize(.mini).accessibilityLabel(title)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(ReaderTheme.warning)
                        .accessibilityHidden(true)
                }
            }
            .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .medium))
                if !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(ReaderTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .lineLimit(3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            actions().fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(ReaderTheme.surface,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(ReaderTheme.hairline, lineWidth: 1)
                .allowsHitTesting(false)
        }
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
                    .buttonStyle(StudioIconButtonStyle(size: 24))
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
            Text("Reading appearance")
                .font(.system(size: 13, weight: .semibold))
            VStack(alignment: .leading, spacing: 8) {
                Text("Typeface")
                    .font(.system(size: 11))
                    .foregroundStyle(ReaderTheme.secondaryText)
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
                    Text("Text size").font(.system(size: 12))
                    Spacer()
                    Text("\(Int(model.prefs.size)) pt")
                        .font(ReaderTheme.numeral(11))
                        .foregroundStyle(ReaderTheme.secondaryText)
                }
                Slider(value: $model.prefs.size, in: 16...32, step: 1)
                    .tint(ReaderTheme.accent)
                    .accessibilityLabel("Text size")
                    .accessibilityValue("\(Int(model.prefs.size)) points")
            }
            Toggle("Reading guide", isOn: $model.prefs.guide)
                .font(.system(size: 12))
                .help("Emphasize the current phrase while keeping surrounding text readable")
            Rectangle().fill(ReaderTheme.hairline).frame(height: 1)
            VStack(alignment: .leading, spacing: 8) {
                Text("Appearance")
                    .font(.system(size: 11))
                    .foregroundStyle(ReaderTheme.secondaryText)
                Picker("Appearance", selection: $model.prefs.appearance) {
                    Text("System").tag(Appearance.system)
                    Text("Light").tag(Appearance.light)
                    Text("Dark").tag(Appearance.dark)
                }
                .pickerStyle(.segmented).labelsHidden()
            }
        }
        .padding(20)
        .frame(width: 300)
        .foregroundStyle(ReaderTheme.primaryText)
        .glassPanel(radius: 14)
    }
}

private struct DocumentDetailsView: View {
    @EnvironmentObject private var model: ReaderModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 9) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(ReaderTheme.accent)
                Text("DOCUMENT DETAILS")
                    .font(ReaderTheme.micro(9.5))
                    .tracking(1.4)
                    .foregroundStyle(ReaderTheme.secondaryText)
            }
            Text(model.activeDoc?.title ?? "Document")
                .font(.system(size: 24, weight: .semibold))
                .tracking(-0.3)
                .textSelection(.enabled)
            Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 12) {
                detail("Original file", value: model.activeDoc?.file_name ?? "—")
                detail("Pages", value: String(max(model.sourcePageCount, model.activeDoc?.pageCount ?? 0)))
                detail("Available words", value: model.wordsTotal.formatted())
                detail("Text recovery", value: model.isProcessing ? "In progress" : (model.canRead ? "Readable" : "No text available"))
            }
            .font(.system(size: 12))
            Rectangle().fill(ReaderTheme.hairline).frame(height: 1)
            Text("Read Along keeps a managed copy on this Mac. Your original file is unchanged.")
                .font(.system(size: 11))
                .foregroundStyle(ReaderTheme.tertiaryText)
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(StudioPrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 440)
        .foregroundStyle(ReaderTheme.primaryText)
        .glassPanel(radius: 16)
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
                    let key = "ReadAlong.readerSplit.v4.\(name)"
                    split.autosaveName = NSSplitView.AutosaveName(key)
                    split.dividerStyle = .thin
                    return
                }
                ancestor = view.superview
            }
        }
    }
}
