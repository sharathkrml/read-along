import AppKit
import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// Which words to light up in the reading text.
struct HighlightSpec: Equatable {
    var cursor = 0
    var currentStart = -1
    var currentEnd = -1
    var nextStart = -1
    var nextEnd = -1
    var guide = true
}

struct Toast: Equatable {
    var text: String
    var isError: Bool
}

enum FeedbackKind {
    case light, navigation, success, error
}

func playSound(_ name: String) {
    NSSound(named: NSSound.Name(name))?.play()
}

private func haptic(_ pattern: NSHapticFeedbackManager.FeedbackPattern) {
    NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .default)
}

@MainActor
final class ReaderModel: ObservableObject {
    static let shared = ReaderModel()

    // MARK: published state

    @Published var library = LibraryPayload(active: nil, documents: [])
    @Published var pageModel = PageModel()
    @Published var state = ReaderState()
    @Published var setup = SetupStatus()
    @Published var ready = false
    @Published var cursor = 0
    @Published var pageImage: NSImage?
    /// Cache of page images for all pages, used by the unified document view
    /// so scrolling can move through every page.
    @Published var pageImages: [Int: NSImage] = [:]
    @Published var presentVisible = false
    var presentEnteredFullscreen = false
    @Published var showEdit = false
    @Published var pendingRename: Document?
    @Published var pendingDelete: Document?
    @Published var pendingRemove: String?
    @Published var toast: Toast?
    @Published var microphones = Microphones()
    @Published var selectedMicID: Int?
    @Published var micPermissionState: AVAuthorizationStatus = .notDetermined
    @Published var micLevel: Double = 0
    @Published var transportState: TransportState = .idle
    @Published var viewer = ViewerState() {
        didSet { scheduleViewerSave() }
    }
    /// nil = split, .text = text only, .original = source only.
    @Published var expandedPane: ViewPane?
    @Published var documentLoadingMessage: String?
    @Published var operationError: String?
    @Published var sourceURL: URL?
    @Published var sourceData: Data?
    @Published var sourceLoading = false
    @Published var sourceError: String?
    @Published var sourcePageCount = 0
    @Published var contentRevision = 0
    @Published var findRequest = 0
    @Published var modelSetupKey: String?
    @Published var editorHasUnsavedChanges = false
    @Published var prefs: Prefs {
        didSet { Self.savePrefs(prefs) }
    }

    // MARK: internals

    var activeWindow = true
    var activeDocument: Document? {
        library.documents.first(where: { $0.id == library.active })
    }
    private var client: BackendClient?
    private var pollTask: Task<Void, Never>?
    private var modelRevision = 0
    private var toastTask: Task<Void, Never>?
    private let imageCache = NSCache<NSString, NSImage>()
    private let sourceCache = NSCache<NSString, NSData>()
    private var pageImageTask: Task<Void, Never>?
    private var pageImageKey = ""
    private var pageImagesDocID = ""
    private var pageImageGeneration = 0
    private var documentGeneration = 0
    private var pendingOpenID: String?
    private var openTask: Task<Void, Never>?
    private var sourceTask: Task<Void, Never>?
    private var sourceKey = ""
    private var viewerSaveTask: Task<Void, Never>?
    private var pendingImportURL: URL?
    private var followGeneration = 0
    private var wantsFollow = false
    private var positionTask: Task<Void, Never>?
    private var pendingPosition: (String, Int)?
    private var seekVersion = 0
    private var acknowledgedSeekVersion = 0
    private var scrubOrigin: Int?
    private var scrubDocumentID: String?
    private var waitingForText = false
    private var pendingRecoveryDocumentID: String?
    private var presentedDependencyDocumentID: String?
    private weak var presentWindow: NSWindow?
    private var focusOwnsFullscreen = false

    private static let prefsKey = "readalong.prefs.v2"

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.prefsKey) {
            prefs = (try? JSONDecoder().decode(Prefs.self, from: data)) ?? Prefs()
        } else {
            prefs = Prefs()
        }
        imageCache.totalCostLimit = 48 * 1024 * 1024
        imageCache.countLimit = 5
    }

    private static func savePrefs(_ preferences: Prefs) {
        if let data = try? JSONEncoder().encode(preferences) {
            UserDefaults.standard.set(data, forKey: prefsKey)
        }
    }

    // MARK: derived values

    var activeDoc: Document? {
        library.documents.first { $0.id == library.active }
    }

    var isPlaying: Bool {
        transportState.isActive
    }

    var hasSource: Bool { activeDoc != nil || sourceURL != nil }
    var canRead: Bool { !pageModel.words.isEmpty && documentLoadingMessage == nil }
    var isProcessing: Bool {
        ["running", "waiting_for_model", "waiting_model"].contains(state.ocr_status ?? "")
            || ["processing", "waiting_for_model", "waiting_model"].contains(activeDoc?.statusName ?? "")
    }
    var isComplete: Bool {
        wordsTotal > 0 && cursor >= wordsTotal && !isProcessing
            && (state.ocr_status == "done" || activeDoc?.statusName == "ready")
    }
    var transportTitle: String {
        switch transportState {
        case .preparing: return "Preparing voice following…"
        case .playing: return "Stop Follow me"
        case .paused: return "Resume Follow me"
        case .listening: return "Stop Follow me"
        case .stopping: return "Stopping…"
        case .waitingForText: return "Waiting for the next page…"
        case .failed: return "Try again"
        case .idle: return isComplete ? "Read again" : "Start Follow me"
        }
    }
    var transportSubtitle: String {
        if let operationError, transportState == .failed { return operationError }
        switch transportState {
        case .preparing: return "Preparing the local speech engine. The microphone starts only for this session."
        case .waitingForText: return "Text recovery is continuing. Stop to cancel automatic continuation."
        case .listening: return followStatusText
        case .paused: return "Your place is kept. Resume whenever you're ready."
        case .stopping: return "Closing the active audio session."
        default: return isComplete ? "Finished reading. Your place is saved." : "Your words. Your pace."
        }
    }
    var transportSymbol: String {
        switch transportState {
        case .playing: return "stop.fill"
        case .listening, .preparing, .stopping, .waitingForText: return "stop.fill"
        default: return isComplete ? "arrow.counterclockwise" : "mic.fill"
        }
    }

    var transportPresentation: TransportPresentation {
        TransportPresentation(
            label: transportTitle,
            icon: transportSymbol,
            enabled: !transportState.isBusy && canRead,
            busy: transportState.isBusy
        )
    }

    var followStatusText: String {
        if let error = state.error, !error.isEmpty { return error }
        switch state.status {
        case "listening":
            return (state.confidence ?? 0) >= 0.5 ? "Following your voice" : "Listening — read the highlighted words"
        case "loading":
            return "Preparing voice following…"
        case "error":
            return "Follow me is off."
        default:
            return "Follow me is ready."
        }
    }

    var currentGroupIndex: Int {
        guard !pageModel.groups.isEmpty else { return -1 }
        // `cursor` points one past the last word confirmed as read, so the
        // phrase being read is the group containing cursor - 1. Highlighting
        // the group at `cursor` would light up the next phrase before it's read.
        let position = max(0, cursor - 1)
        if let i = pageModel.groups.firstIndex(where: { position < $0.end }) {
            return i
        }
        return pageModel.groups.count - 1
    }

    var currentRange: Range<Int>? {
        guard !isComplete else { return nil }
        guard (0..<pageModel.groups.count).contains(currentGroupIndex) else { return nil }
        let g = pageModel.groups[currentGroupIndex]
        return g.start..<g.end
    }

    var nextRange: Range<Int>? {
        guard !isComplete else { return nil }
        let i = currentGroupIndex + 1
        guard i < pageModel.groups.count else { return nil }
        let g = pageModel.groups[i]
        return g.start..<g.end
    }

    /// Page of the live reading position. Browsing does not change this.
    var readingPage: Int {
        let i = currentGroupIndex
        if i >= 0 && i < pageModel.groups.count {
            return pageModel.groups[i].page
        }
        return state.page ?? 0
    }

    /// Page currently shown in the source pane; nil browsing means follow reading.
    var displayPage: Int {
        viewer.browsedPage ?? readingPage
    }

    var highlight: HighlightSpec {
        var spec = HighlightSpec()
        spec.cursor = cursor
        spec.guide = prefs.guide
        if let range = currentRange {
            spec.currentStart = range.lowerBound
            spec.currentEnd = range.upperBound
        }
        if let next = nextRange {
            spec.nextStart = next.lowerBound
            spec.nextEnd = next.upperBound
        }
        return spec
    }

    var highlightIdentity: Int {
        var hasher = Hasher()
        hasher.combine(cursor)
        hasher.combine(library.active)
        hasher.combine(contentRevision)
        hasher.combine(viewer.textFollows)
        hasher.combine(viewer.sourceFollows)
        if let range = currentRange {
            hasher.combine(range.lowerBound)
            hasher.combine(range.upperBound)
        }
        if let next = nextRange {
            hasher.combine(next.lowerBound)
            hasher.combine(next.upperBound)
        }
        hasher.combine(prefs.guide)
        return hasher.finalize()
    }

    var wordsTotal: Int { pageModel.words.count }

    var pageInfo: PageInfo? {
        pageModel.pages.indices.contains(displayPage) ? pageModel.pages[displayPage] : nil
    }

    var progressPercent: Double {
        let percent = ReadingMath.progress(position: cursor, total: wordsTotal) * 100
        return isProcessing ? min(99, percent) : percent
    }

    var processingCopy: String {
        if state.ocr_status == "running" {
            switch state.ocr_phase {
            case "vision": return "Preparing Apple's text reader. The first use can take longer."
            case "rendering": return "Preparing document pages…"
            case "loading_model", "loading": return "Loading handwriting model…"
            case "mapping": return "Preparing reading positions…"
            case "saving": return "Saving recovered text…"
            default: break
            }
            if let page = state.ocr_page { return "Recovering page \(page + 1) of \(max(sourcePageCount, pageModel.pages.count, page + 1))…" }
            if let total = state.ocr_total, total > 0 {
                let done = min((state.ocr_done ?? 0) + 1, total)
                return "Recovering scanned page \(done) of \(total)…"
            }
            return "Reading the page…"
        }
        if state.ocr_status == "error" {
            return state.ocr_error ?? "The reader could not process this document."
        }
        if ["waiting_for_model", "waiting_model"].contains(state.ocr_status ?? "") {
            return "This page needs the optional handwriting model. Your original is ready to view."
        }
        return "This document is in your library but hasn't been processed yet."
    }

    // MARK: lifecycle

    func start() async {
        guard client == nil else { return }
        let service = BackendService.shared
        for _ in 0..<1200 {
            if service.startupError != nil { break }
            if service.ready { break }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        guard let base = service.baseURL, service.startupError == nil else { return }
        ready = true
        client = BackendClient(base: base)
        await refreshLibrary()
        await loadModel()
        await pollStateOnce()
        await refreshSetup()
        await refreshPageImage()
        await refreshMicrophones()
        pollTask = Task { [weak self] in await self?.pollLoop() }
    }

    /// Quit path: flush the exact position before the owned backend is terminated.
    /// Blocking is bounded (2 s) and runs the request off the main actor.
    func flushForTermination() {
        guard let c = client, !pageModel.words.isEmpty else { return }
        let target = cursor
        let listening = state.status == "listening"
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            _ = try? await c.jump(word: target)
            if listening { _ = try? await c.stopFollow() }
            done.signal()
        }
        _ = done.wait(timeout: .now() + 2)
    }

    private func pollLoop() async {
        var libraryClock = Date()
        while !Task.isCancelled {
            let busy = isPlaying || state.status == "listening"
            let interval: UInt64 = !activeWindow ? 1_200_000_000 : (busy ? 120_000_000 : 400_000_000)
            try? await Task.sleep(nanoseconds: interval)
            guard let client, ready, !Task.isCancelled else { continue }
            if let s = try? await client.state() {
                await applyState(s)
                if Date().timeIntervalSince(libraryClock) > 1.0 {
                    libraryClock = Date()
                    await refreshLibrary(quiet: true)
                }
            }
        }
    }

    private func applyState(_ newState: ReaderState) async {
        let previousDoc = state.doc_id
        let previousModelWords = state.model_words
        let previousModelPages = state.model_pages
        let previousRevision = state.model_revision
        if let docID = newState.doc_id, library.active != docID {
            library.active = docID
        }
        if let pos = newState.pos {
            cursor = clamp(pos)
        }
        if previousDoc != newState.doc_id || previousModelWords != newState.model_words
            || previousModelPages != newState.model_pages
            || previousRevision != newState.model_revision {
            await loadModel()
        }
        let listening = newState.status == "listening"
        if listening, let rms = newState.rms {
            let mapped = min(1.0, max(0.08, rms * 4.0))
            micLevel = mapped
        } else {
            micLevel = 0
        }
        state = newState
        switch newState.status {
        case "listening":
            transportState = .listening
            // Never leave the microphone open after the last word is reached.
            if let pos = newState.pos, let total = newState.total, total > 0, pos >= total {
                stopFollow()
            }
        case "loading": transportState = .preparing
        case "error": if transportState == .listening || transportState == .preparing { transportState = .failed }
        default:
            // Idle means not listening. Clear a stale Preparing latch so a
            // background engine warm-up can never strand the UI in "Preparing…"
            // until the user stops and restarts.
            if transportState == .listening || transportState == .preparing { transportState = .idle }
        }
        // Polling must not cancel/restart an in-flight page image every tick.
        loadPageImage()
    }

    private func pollStateOnce() async {
        guard let client else { return }
        if let s = try? await client.state() {
            await applyState(s)
        }
    }

    private func clamp(_ pos: Int) -> Int {
        let upper = pageModel.words.count
        guard upper > 0 else { return 0 }
        return max(0, min(pos, upper))
    }

    // MARK: library

    func refreshLibrary(quiet: Bool = false) async {
        guard let client else { return }
        guard let payload = try? await client.library() else { return }
        let ids = payload.documents.map(\.id)
        let current = library.documents.map(\.id)
        if !quiet || ids != current || library.active != payload.active {
            library = payload
            return
        }
        // Quiet refresh: keep row order stable, but update metadata in place.
        for (index, doc) in payload.documents.enumerated() {
            guard index < library.documents.count else { break }
            library.documents[index] = doc
        }
    }

    func openDocument(_ id: String?) {
        guard let id, id != library.active else { return }
        if state.status == "listening" || transportState == .listening || transportState == .preparing {
            stopFollow()
        }
        Task {
            do {
                try await client?.openDocument(id: id)
                library.active = id
                viewer.browsedPage = nil
                loadSource()
                await refreshLibrary()
                await loadModel()
                await pollStateOnce()
                if let doc = activeDoc {
                    showToast("Opened “\(doc.title)”")
                }
                feedback(.navigation)
            } catch {
                showToast(error.localizedDescription, isError: true)
            }
        }
    }

    func importDocument() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.pdf, .image]
        panel.begin { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            Task { @MainActor in await self.importFile(at: url) }
        }
    }

    func importFile(at url: URL) async {
        guard let client else { return }
        let name = url.lastPathComponent
        guard let data = try? Data(contentsOf: url) else {
            showToast("Could not read “\(name)”.", isError: true)
            feedback(.error)
            return
        }
        if data.count > 25 * 1024 * 1024 {
            showToast("That file is larger than 25 MB.", isError: true)
            return
        }
        let dataURL = data.base64EncodedString()
        do {
            let doc = try await client.importDocument(name: name, dataURL: dataURL, mode: prefs.ocrMode)
            await refreshLibrary()
            if let id = doc?.id { library.active = id }
            viewer.browsedPage = nil
            loadSource()
            await loadModel()
            await pollStateOnce()
            if doc?.statusName == "ready" {
                showToast("Document ready")
            } else {
                showToast("Import started")
            }
            feedback(.success)
        } catch {
            showToast(error.localizedDescription, isError: true)
            feedback(.error)
        }
    }

    func importSample() async {
        guard let client else { return }
        do {
            let data = try await client.imageData("sample")
            let doc = try await client.importDocument(
                name: "Sample document.pdf",
                dataURL: data.base64EncodedString(),
                mode: prefs.ocrMode
            )
            await refreshLibrary()
            if let id = doc?.id { library.active = id }
            viewer.browsedPage = nil
            loadSource()
            await loadModel()
            await pollStateOnce()
            showToast("Sample imported")
        } catch {
            showToast("Could not import the bundled sample: \(error.localizedDescription)", isError: true)
        }
    }

    func renameDocument(_ doc: Document, title: String) {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            showToast("Give the document a name", isError: true)
            return
        }
        pendingRename = nil
        Task {
            do {
                try await client?.renameDocument(id: doc.id, title: clean)
                await refreshLibrary()
                showToast("Document renamed")
                feedback(.success)
            } catch {
                // The rename sheet observes this and stays open so the draft survives.
                operationError = error.localizedDescription
                showToast(error.localizedDescription, isError: true)
            }
        }
    }

    func deleteDocument(_ doc: Document) {
        pendingDelete = nil
        Task {
            do {
                try await client?.deleteDocument(id: doc.id)
                await refreshLibrary()
                await loadModel()
                await pollStateOnce()
                showToast("Document deleted")
                feedback(.success)
            } catch {
                showToast(error.localizedDescription, isError: true)
            }
        }
    }

    func scheduleViewerSave() {
        // Viewer persistence is completed in R08; keep a no-op seam here so
        // the model compiles and the didSet does not crash.
    }

    func cancelModel(_ key: String) {
        Task { _ = try? await client?.cancelModel(key) }
    }
    func dismissOperationError() { operationError = nil }
    func findInDocument(_ query: String = "") {
        // Native find is hosted by ReaderTextView; this bumps the request counter.
        findRequest &+= 1
    }
    func retryConnection() {
        pollTask?.cancel()
        pollTask = nil
        client = nil
        ready = false
        BackendService.shared.restart()
        Task { await start() }
    }

    // MARK: the reading model

    private func loadModel() async {
        guard let client else { return }
        guard let payload = try? await client.pageModel() else {
            loadSource()
            return
        }
        pageModel = payload
        modelRevision += 1
        contentRevision += 1
        // Only a document switch invalidates the page-image cache; OCR updates
        // to the same document must not blank pages that are already loaded.
        let docID = payload.doc_id ?? library.active ?? ""
        if docID != pageImagesDocID {
            pageImagesDocID = docID
            pageImages.removeAll()
            pageImageGeneration += 1
        }
        cursor = clamp(state.pos ?? cursor)
        loadPageImage(force: true)
        loadSource()
    }

    private func refreshSetup() async {
        guard let client else { return }
        setup = (try? await client.setupStatus()) ?? SetupStatus()
    }

    func refreshSetupPoll() async {
        await refreshSetup()
    }

    func refreshSetupAction() {
        Task { await refreshSetup() }
    }

    // MARK: jump / navigation

    /// Persist the newest intended reading position in order.
    private func persistPosition(_ word: Int) {
        seekVersion += 1
        let v = seekVersion
        let client = self.client
        Task { [weak self] in
            _ = try? await client?.jump(word: word)
            await MainActor.run { if self?.seekVersion == v { self?.acknowledgedSeekVersion = v } }
        }
    }

    /// One explicit seek for word clicks, phrase commands, scrubbing, and menus.
    func seek(word: Int, quiet: Bool = false) {
        guard !pageModel.words.isEmpty else { return }
        let target = clamp(word)
        cursor = target
        viewer.browsedPage = nil
        persistPosition(target)
        if !quiet { feedback(.navigation) }
    }

    func jump(word: Int, quiet: Bool = false) { seek(word: word, quiet: quiet) }

    func returnToReading() {
        viewer.textFollows = true
        viewer.sourceFollows = true
        viewer.browsedPage = nil
    }

    func setPage(_ page: Int) {
        guard pageModel.pages.count > 0 else { return }
        let bound = max(0, min(page, pageModel.pages.count - 1))
        viewer.browsedPage = bound
        loadPageImage(force: true)
        feedback(.navigation)
    }

    func movePhrase(_ delta: Int) {
        guard !pageModel.groups.isEmpty else { return }
        let start = max(0, currentGroupIndex)
        let target = max(0, min(start + delta, pageModel.groups.count - 1))
        jump(word: pageModel.groups[target].start)
    }

    // MARK: follow mode

    func requestMicrophoneAccessIfNeeded() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        micPermissionState = status
        switch status {
        case .authorized:
            return true
        case .notDetermined:
            showToast("Follow me needs microphone access.", isError: false)
            let granted = await requestMicrophonePermission()
            micPermissionState = granted ? .authorized : .denied
            return granted
        case .denied:
            showToast("Microphone access denied. Open System Settings to allow.", isError: true)
            return false
        case .restricted:
            showToast("Microphone access restricted.", isError: true)
            return false
        @unknown default:
            return false
        }
    }

    func toggleFollow() {
        guard !pageModel.words.isEmpty else {
            showToast("There is no readable text yet.", isError: true)
            return
        }
        if state.status == "listening" || transportState == .preparing {
            // Toggle also cancels a start still waiting on the engine, so
            // Space / Present / menu behave like the PlayerBar Stop button.
            stopFollow()
            return
        }
        if state.status == "loading" { return }
        if state.speech_ready == false {
            showToast("Follow me needs the local speech model.", isError: true)
            return
        }
        // English-only disclosure
        showToast("Follow me is English-only.", isError: false)
        Task {
            let ok = await self.requestMicrophoneAccessIfNeeded()
            guard ok else { return }
            transportState = .preparing
            do {
                try await client?.startFollow()
                feedback(.light)
            } catch {
                transportState = .failed
                showToast(error.localizedDescription, isError: true)
            }
        }
    }

    func stopFollow() {
        let c = client
        transportState = .idle
        Task {
            do { try await c?.stopFollow(); feedback(.navigation) } catch {}
        }
    }

    func togglePlay() {
        toggleFollow()
    }

    func beginScrubbing() {
        scrubOrigin = cursor
        scrubDocumentID = library.active
    }

    func commitScrub(_ value: Double) {
        guard scrubDocumentID == library.active else { cancelScrubbing(); return }
        let total = max(1, pageModel.words.count)
        let target = max(0, min(total - 1, Int((value * Double(total)).rounded(.down))))
        cursor = target
        viewer.browsedPage = nil
        persistPosition(target)
        scrubOrigin = nil
        scrubDocumentID = nil
    }

    func cancelScrubbing() {
        if let origin = scrubOrigin { cursor = origin }
        scrubOrigin = nil
        scrubDocumentID = nil
    }

    func stopPlayback() {
        if state.status == "listening" || transportState == .preparing {
            stopFollow()
        }
        transportState = .idle
    }

    // MARK: page image

    private func loadPageImage(force: Bool = false) {
        guard !pageModel.pages.isEmpty, pageModel.pages.indices.contains(displayPage) else {
            if pageImage != nil { pageImage = nil }
            pageImageKey = ""
            return
        }
        let info = pageModel.pages[displayPage]
        guard info.width > 0 else {
            if pageImage != nil { pageImage = nil }
            pageImageKey = ""
            return
        }
        let docID = library.active ?? state.doc_id ?? "none"
        let key = "\(docID)/\(displayPage)/\(modelRevision)"
        if !force && key == pageImageKey { return }
        pageImageKey = key
        if let cached = imageCache.object(forKey: key as NSString) {
            pageImage = cached
            return
        }
        pageImageTask?.cancel()
        let client = self.client
        let identifier = key
        pageImageTask = Task { [weak self] in
            let currentDisplayPage = self?.displayPage ?? 0
            guard let data = try? await client?.imageData("page/\(currentDisplayPage)") else { return }
            guard let image = NSImage(data: data) else { return }
            self?.imageCache.setObject(image, forKey: identifier as NSString)
            await MainActor.run {
                guard self?.pageImageKey == identifier else { return }
                self?.pageImage = image
            }
        }
    }

    func refreshPageImage() async {
        loadPageImage(force: true)
    }

    /// Load an arbitrary page image into the pageImages cache (used by the unified
    /// document view so all pages can be scrolled through).
    func loadPageImage(_ page: Int) {
        guard pageModel.pages.indices.contains(page) else { return }
        guard pageImages[page] == nil else { return }
        let docID = library.active ?? state.doc_id ?? "none"
        let key = "\(docID)/\(page)/\(modelRevision)"
        if let cached = imageCache.object(forKey: key as NSString) {
            pageImages[page] = cached
            contentRevision += 1 // Notify views that a page image is now available
            return
        }
        let client = self.client
        let generation = pageImageGeneration
        Task { [weak self] in
            // The page raster can be missing for a moment while a document is
            // being rendered, so retry a few times before leaving the spinner.
            for attempt in 0..<3 {
                if let data = try? await client?.imageData("page/\(page)"),
                   let image = NSImage(data: data) {
                    self?.imageCache.setObject(image, forKey: key as NSString)
                    await MainActor.run {
                        guard self?.pageImageGeneration == generation else { return }
                        self?.pageImages[page] = image
                        self?.contentRevision += 1 // Notify views that a page image is now available
                    }
                    return
                }
                if attempt < 2 { try? await Task.sleep(nanoseconds: 1_500_000_000) }
            }
        }
    }

    // MARK: source

    func loadSource(force: Bool = false) {
        let docID = library.active ?? state.doc_id
        guard let docID, !docID.isEmpty else {
            sourceData = nil
            sourceKey = ""
            sourceLoading = false
            sourceError = nil
            return
        }
        let key = docID
        if !force && key == sourceKey { return }
        if key != sourceKey {
            // Never show the previous document's page under a new title.
            sourceData = nil
            sourceError = nil
        }
        sourceKey = key
        if let cached = sourceCache.object(forKey: key as NSString) {
            sourceData = cached as Data
            sourceLoading = false
            sourceError = nil
            return
        }
        sourceTask?.cancel()
        sourceLoading = true
        sourceError = nil
        let client = self.client
        let identifier = key
        sourceTask = Task { [weak self] in
            do {
                let data = try await client?.sourceData(docID: docID) ?? Data()
                self?.sourceCache.setObject(data as NSData, forKey: identifier as NSString)
                await MainActor.run {
                    guard self?.sourceKey == identifier else { return }
                    self?.sourceData = data
                    self?.sourceLoading = false
                    self?.sourceError = nil
                }
            } catch {
                await MainActor.run {
                    guard self?.sourceKey == identifier else { return }
                    self?.sourceLoading = false
                    self?.sourceError = error.localizedDescription
                }
            }
        }
    }

    func retrySource() {
        loadSource(force: true)
    }

    // MARK: edit text

    func saveScript(page: Int, text: String, completion: @escaping (Error?) -> Void) {
        Task { [weak self] in
            guard let self, let client = self.client else { return }
            do {
                let model = try await client.saveScript(page: page, text: text)
                self.pageModel = model
                self.modelRevision += 1
                self.contentRevision += 1
                self.cursor = self.clamp(self.cursor)
                self.loadPageImage(force: true)
                await self.refreshLibrary()
                self.showEdit = false
                self.showToast("Text saved")
                self.feedback(.success)
                completion(nil)
            } catch {
                completion(error)
            }
        }
    }

    func reOCR() {
        Task { [weak self] in
            guard let self, let client = self.client else { return }
            do {
                try await client.reOCR(fast: self.prefs.ocrMode == "fast", auto: self.prefs.ocrMode == "auto")
                self.showToast("Re-reading document")
            } catch {
                self.showToast(error.localizedDescription, isError: true)
            }
        }
    }

    func exportJPEG(page: Int, mode: String = "proof", docID: String? = nil) async throws -> Data? {
        guard let client else { return nil }
        return try await client.exportJPEG(page: page, mode: mode, docID: docID ?? activeDoc?.id ?? state.doc_id)
    }

    // MARK: present

    func enterPresent() {
        guard !pageModel.words.isEmpty else {
            showToast("There is no readable text yet.", isError: true)
            return
        }
        presentVisible = true
        SourceFocus.active = nil
        if let window = NSApp.keyWindow, !window.styleMask.contains(.fullScreen) {
            presentEnteredFullscreen = true
            window.toggleFullScreen(nil)
        } else {
            presentEnteredFullscreen = false
        }
    }

    func exitPresent() {
        presentVisible = false
        if presentEnteredFullscreen, let window = NSApp.keyWindow, window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        }
        presentEnteredFullscreen = false
    }

    // MARK: setup

    func downloadModel(_ key: String) {
        Task {
            do {
                try await client?.downloadModel(key)
                await refreshSetup()
            } catch {
                showToast(error.localizedDescription, isError: true)
            }
        }
    }

    func removeModel(_ key: String) {
        Task {
            do {
                try await client?.removeModel(key)
                await refreshSetup()
            } catch {
                showToast(error.localizedDescription, isError: true)
            }
        }
    }

    func completeSetup() async {
        _ = try? await client?.finishSetup()
        await refreshSetup()
    }

    func refreshOnAppear() {
        Task { await refreshSetup() }
        Task { await refreshLibrary() }
        Task { await refreshMicrophones() }
    }

    // MARK: microphone (Follow me)

    var selectedMicrophone: Microphone? {
        microphones.devices.first { $0.id == selectedMicID }
    }

    var selectedMicLabel: String {
        selectedMicrophone?.name ?? "System default"
    }

    func refreshMicrophones() async {
        guard let client else { return }
        guard let payload = try? await client.mics() else { return }
        microphones = payload
        // Reconcile the remembered name with the device list: USB/AirPods ids
        // shift between launches, names usually survive.
        if let name = prefs.micName, !name.isEmpty,
           let device = payload.devices.first(where: { $0.name == name }),
           selectedMicID != device.id {
            selectedMicID = device.id
            _ = try? await client.setMic(device.id)
        } else if prefs.micName == nil, selectedMicID == nil {
            selectedMicID = nil
        }
    }

    func selectMic(_ device: Microphone?) {
        selectedMicID = device?.id
        prefs.micName = device?.name
        let client = client
        let id = device?.id
        Task {
            do {
                try await client?.setMic(id)
                if let device {
                    showToast("Microphone: \(device.name)")
                } else {
                    showToast("Microphone: system default")
                }
                feedback(.navigation)
            } catch {
                await self.refreshMicrophones()
                showToast(error.localizedDescription, isError: true)
            }
        }
    }

    // MARK: feedback + toasts

    func feedback(_ kind: FeedbackKind) {
        if prefs.sound {
            let name: String
            switch kind {
            case .light: name = "Tink"
            case .navigation: name = "Pop"
            case .success: name = "Glass"
            case .error: name = "Basso"
            }
            playSound(name)
        }
        if prefs.haptic {
            let pattern: NSHapticFeedbackManager.FeedbackPattern
            switch kind {
            case .light: pattern = .generic
            case .navigation: pattern = .alignment
            case .success: pattern = .levelChange
            case .error: pattern = .generic
            }
            haptic(pattern)
        }
    }

    func showToast(_ text: String, isError: Bool = false) {
        toast = Toast(text: text, isError: isError)
        if isError { feedback(.error) }
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_600_000_000)
            self?.toast = nil
        }
    }
}

extension ReaderModel {
    /// Bounding boxes on a page for a word range, grouped per text line, exactly
    /// group_boxes.
    func groupBoxes(range: Range<Int>?, page: Int) -> [[Double]] {
        guard let range else { return [] }
        var byLine: [Int: [[Double]]] = [:]
        for i in range {
            guard pageModel.words.indices.contains(i) else { continue }
            let word = pageModel.words[i]
            if let box = word.box, word.page == page {
                byLine[word.line, default: []].append(box)
            }
        }
        let pairs: [(Double, Double, Double, Double)] = byLine.values.map { boxes in
            let minX = boxes.map { $0[0] }.min() ?? 0
            let minY = boxes.map { $0[1] }.min() ?? 0
            let maxX = boxes.map { $0[0] + $0[2] }.max() ?? 0
            let maxY = boxes.map { $0[1] + $0[3] }.max() ?? 0
            return (minX, minY, maxX - minX, maxY - minY)
        }
        return pairs.map { [$0.0, $0.1, $0.2, $0.3] }
    }
}
