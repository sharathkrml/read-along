import SwiftUI
import AppKit
import PDFKit

/// Common contract for the PDF and image source viewers so the same toolbar
/// (zoom, fit, page navigation) can drive either one.
@MainActor
protocol SourceControlling: ObservableObject {
    var currentPage: Int { get }
    var totalPages: Int { get }
    var zoomPercent: Int { get }
    func goPrev()
    func goNext()
    func goToPage(_ oneBased: Int)
    func zoomOut()
    func zoomIn()
    func fitPage()
    func fitWidth()
    func actualSize()
}

struct SourceViewerTransform: Equatable {
    var scale: CGFloat = 1
    var origin: CGPoint = .zero

    func pageToScreen(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x * scale + origin.x, y: p.y * scale + origin.y)
    }
    func screenToPage(_ s: CGPoint) -> CGPoint {
        CGPoint(x: (s.x - origin.x) / scale, y: (s.y - origin.y) / scale)
    }
    func screenStrokeWidth(base: CGFloat) -> CGFloat { base }
    func roundTrip(_ p: CGPoint) -> CGPoint { screenToPage(pageToScreen(p)) }
}

@MainActor
final class PDFSourceController: ObservableObject, SourceControlling {
    weak var viewer: PDFSourceViewer?
    var onUserNavigate: ((Int) -> Void)?
    var onWordClick: ((Int, CGPoint) -> Void)?
    @Published var currentPage: Int = 1
    @Published var totalPages: Int = 1
    @Published var zoomPercent: Int = 100
    /// Set when `followToPage` moved the PDF because the live reading
    /// position advanced. The split view compares the next page change
    /// against it to tell a programmatic follow apart from the user
    /// turning the page themselves.
    var lastProgrammaticPage: Int?

    func attach(_ v: PDFSourceViewer) {
        guard viewer !== v else { return }
        viewer = v
        v.pdfView.controller = self
    }

    func sync() {
        guard let v = viewer, let doc = v.pdfView.document else { return }
        // Publish only real changes. These properties are observed by SwiftUI;
        // re-sending an identical value from inside a view update invalidates
        // the platform view again and can spin the update graph forever.
        let pages = max(1, doc.pageCount)
        if totalPages != pages { totalPages = pages }
        // Prefer the dominant visible page over pdfView.currentPage:
        // in singlePageContinuous, scrolling the stacked pages does not
        // reliably advance currentPage, so the text mirror would stay
        // on page 1 while the user looks at page 2 or 3.
        let visible = visiblePageIndex(v: v, doc: doc)
        var page = currentPage
        if let visible {
            page = visible + 1
        } else if let p = v.pdfView.currentPage {
            page = doc.index(for: p) + 1
        }
        if currentPage != page { currentPage = page }
        if let p = doc.page(at: max(0, currentPage - 1)) {
            // Report the zoom the user actually sees; PDFView.scaleFactor is not
            // always the on-screen point ratio while autoScales is active.
            let pageRect = p.bounds(for: .cropBox)
            let onScreen = v.pdfView.convert(pageRect, from: p)
            if pageRect.width > 0, onScreen.width > 0 {
                let zoom = max(1, Int((onScreen.width / pageRect.width * 100).rounded()))
                if zoomPercent != zoom { zoomPercent = zoom }
            }
        }
    }

    /// Index of the page with the greatest vertical overlap with the
    /// PDF view's viewport, or nil when nothing is laid out yet.
    private func visiblePageIndex(v: PDFSourceViewer, doc: PDFDocument) -> Int? {
        let viewport = v.pdfView.bounds
        guard viewport.width > 1, viewport.height > 1, doc.pageCount > 0 else { return nil }
        var best: Int?
        var bestOverlap: CGFloat = 0
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let rect = v.pdfView.convert(page.bounds(for: .cropBox), from: page)
            let overlap = rect.intersection(viewport).height
            if overlap > bestOverlap {
                bestOverlap = overlap
                best = i
            }
        }
        return best
    }

    func goPrev() {
        viewer?.pdfView.goToPreviousPage(nil)
        sync()
        onUserNavigate?(currentPage)
    }
    func goNext() {
        viewer?.pdfView.goToNextPage(nil)
        sync()
        onUserNavigate?(currentPage)
    }
    /// Browse to a page because the user asked; this detaches the pane from following.
    func goToPage(_ oneBased: Int) {
        currentPage = max(1, min(oneBased, totalPages))
        followToPage(oneBased)
        onUserNavigate?(currentPage)
    }
    /// Move with the live reading position without detaching following.
    func followToPage(_ oneBased: Int) {
        guard let v = viewer, let doc = v.pdfView.document else { return }
        let idx = max(0, min(oneBased - 1, doc.pageCount - 1))
        lastProgrammaticPage = idx + 1
        if let page = doc.page(at: idx) { v.pdfView.go(to: page) }
        sync()
        // If the PDF view would not have changed, the split view never
        // gets a page-change to consume the flag with; clear it shortly.
        let target = idx + 1
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 750_000_000)
            if self?.lastProgrammaticPage == target { self?.lastProgrammaticPage = nil }
        }
    }
    func zoomOut() {
        guard let v = viewer else { return }
        v.fitsWidth = false
        v.pdfView.scaleFactor = max(0.25, v.pdfView.scaleFactor / 1.2)
        v.needsLayout = true
        sync()
    }
    func zoomIn() {
        guard let v = viewer else { return }
        v.fitsWidth = false
        v.pdfView.scaleFactor = min(4.0, v.pdfView.scaleFactor * 1.2)
        v.needsLayout = true
        sync()
    }
    func fitPage() {
        guard let v = viewer else { return }
        v.fitsWidth = false
        v.pdfView.displayMode = .singlePageContinuous
        if let page = v.pdfView.currentPage ?? v.pdfView.document?.page(at: 0) {
            let pageRect = page.bounds(for: .cropBox)
            guard pageRect.width > 0, pageRect.height > 0, v.bounds.width > 16, v.bounds.height > 16 else { sync(); return }
            let fit = min((v.bounds.width - 16) / pageRect.width, (v.bounds.height - 16) / pageRect.height)
            v.pdfView.scaleFactor = max(0.25, min(4, fit))
        }
        v.needsLayout = true
        sync()
    }
    func fitWidth() {
        guard let v = viewer else { return }
        v.fitsWidth = true
        v.pdfView.frame = v.bounds
        v.needsLayout = true
        v.applyFitWidth() // Snap to the width now, not after a resize settles.
        sync()
    }
    func actualSize() {
        guard let v = viewer else { return }
        v.fitsWidth = false
        v.pdfView.frame = v.bounds
        v.pdfView.scaleFactor = 1.0
        v.needsLayout = true
        sync()
    }
}

/// Tracks which source viewer the user last clicked so arrow keys stay scoped
/// to the viewer without hijacking typing or text selection elsewhere.
@MainActor
enum SourceFocus {
    static weak var active: PDFSourceViewer?
}

final class SourcePDFView: PDFView {
    weak var controller: PDFSourceController?
    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: controller?.goPrev()   // Left
        case 124: controller?.goNext()   // Right
        default: super.keyDown(with: event)
        }
    }
}

final class PDFSourceViewer: NSView {
    let pdfView = SourcePDFView()
    weak var controller: PDFSourceController?
    private var annotations: [PDFAnnotation] = []
    private var highlightCurrent: [[Double]] = []
    private var highlightNext: [[Double]] = []
    private var highlightPage = -1

    /// Whether the pane scale is owned by the fit-width rule. Zoom, fit-page
    /// and actual size turn this off so a resize cannot yank the scale back.
    var fitsWidth = true
    private var pendingFit: DispatchWorkItem?

    private var clickMonitor: Any?
    private var clickDown: NSPoint?
    private var clickDragged = false
    private var scrollObservers: [Any] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        // Never let PDFView's autoScales race our fit-width scale: two owners
        // produced the fullscreen zoom in/out flicker. We own scaleFactor.
        pdfView.autoScales = false
        pdfView.displayMode = .singlePageContinuous
        pdfView.displaysPageBreaks = true
        pdfView.autoresizingMask = [.width, .height]
        // Match the shared pane surface so the PDF column blends into the
        // single-box workspace instead of reading as a separate dark slab.
        pdfView.backgroundColor = ReaderTheme.nsSurface
        addSubview(pdfView)
        clickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            guard let self, let window = self.window, event.window === window else { return event }
            let point = self.convert(event.locationInWindow, from: nil)
            let inside = self.bounds.contains(point)
            switch event.type {
            case .leftMouseDown:
                if inside {
                    window.makeFirstResponder(self.pdfView)
                    MainActor.assumeIsolated { SourceFocus.active = self }
                    self.clickDown = point
                    self.clickDragged = false
                } else {
                    self.clickDown = nil
                }
            case .leftMouseDragged:
                if let down = self.clickDown,
                   hypot(point.x - down.x, point.y - down.y) >= 3 {
                    self.clickDragged = true
                }
            case .leftMouseUp:
                guard self.clickDown != nil else { return event }
                self.clickDown = nil
                guard inside, !self.clickDragged, event.clickCount == 1,
                      event.modifierFlags.intersection([.shift, .command, .option, .control]).isEmpty,
                      self.hitIsViewer(event) else { return event }
                MainActor.assumeIsolated { self.pageClicked(at: point) }
            default:
                break
            }
            return event
        }
        // PDFView scrolls through an internal NSScrollView, so layout()
        // is not called while paging through stacked pages. Listen for
        // scroll/bounds changes inside this viewer and refresh the
        // controller's visible page, which the text panel mirrors.
        for name in [Notification.Name("NSScrollViewDidScrollNotification"),
                     NSView.boundsDidChangeNotification] {
            scrollObservers.append(NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main) { [weak self] note in
                guard let self,
                      let view = note.object as? NSView,
                      view.isDescendant(of: self) else { return }
                MainActor.assumeIsolated { self.controller?.sync() }
            })
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        pendingFit?.cancel()
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        for observer in scrollObservers { NotificationCenter.default.removeObserver(observer) }
    }

    override func layout() {
        super.layout()
        pdfView.frame = bounds
        // During a fullscreen toggle or window drag, bounds changes every
        // frame. Debounce the scale instead of chasing each intermediate
        // width — one final fit after the size settles, no swimming.
        scheduleFitWidth()
    }

    /// Snap the scale to fit width immediately (explicit Fit-width tap).
    func applyFitWidth() {
        pendingFit?.cancel()
        pendingFit = nil
        guard fitsWidth,
              let page = pdfView.currentPage ?? pdfView.document?.page(at: 0) else { return }
        let pageRect = page.bounds(for: .cropBox)
        guard pageRect.width > 0, bounds.width > 16 else { return }
        let fit = (bounds.width - 16) / pageRect.width
        guard fit > 0 else { return }
        if abs(pdfView.scaleFactor - fit) > 0.001 { pdfView.scaleFactor = fit }
    }

    private func scheduleFitWidth() {
        pendingFit?.cancel()
        guard fitsWidth,
              let page = pdfView.currentPage ?? pdfView.document?.page(at: 0) else { return }
        let pageRect = page.bounds(for: .cropBox)
        guard pageRect.width > 0, bounds.width > 16 else { return }
        let width = bounds.width
        let job = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.fitsWidth, self.bounds.width == width,
                  let page = self.pdfView.currentPage ?? self.pdfView.document?.page(at: 0) else { return }
            let pageRect = page.bounds(for: .cropBox)
            guard pageRect.width > 0 else { return }
            let fit = (width - 16) / pageRect.width
            if abs(self.pdfView.scaleFactor - fit) > 0.001 {
                self.pdfView.scaleFactor = fit
            }
            // Scroll observers already track the visible page; syncing here
            // as well would republish mid-animation and restart layouts.
        }
        pendingFit = job
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: job)
    }

    func load(url: URL) { pdfView.document = PDFDocument(url: url); fitPage() }
    func load(data: Data) { pdfView.document = PDFDocument(data: data); fitPage() }

    private func fitPage() {
        fitsWidth = true
        pdfView.displayMode = .singlePageContinuous
        needsLayout = true
        layoutSubtreeIfNeeded()
        scheduleFitWidth()
    }

    /// A floating toolbar sits above the page; its clicks are not page clicks.
    private func hitIsViewer(_ event: NSEvent) -> Bool {
        guard let content = window?.contentView else { return true }
        let point = content.convert(event.locationInWindow, from: nil)
        guard let hit = content.hitTest(point) else { return true }
        if hit is NSScroller { return false }
        return hit === self || hit.isDescendant(of: self)
    }

    private func pageClicked(at point: NSPoint) {
        let viewPoint = pdfView.convert(point, from: self)
        guard let page = pdfView.page(for: viewPoint, nearest: true),
              let index = pdfView.document?.index(for: page) else { return }
        let bounds = page.bounds(for: .cropBox)
        guard bounds.width > 0, bounds.height > 0 else { return }
        // Normalized boxes are top-left origin; PDF page space is bottom-left.
        let p = pdfView.convert(viewPoint, to: page)
        controller?.onWordClick?(index, CGPoint(
            x: (p.x - bounds.minX) / bounds.width,
            y: (bounds.maxY - p.y) / bounds.height
        ))
    }

    /// Draw the reading marker as PDF annotations so it scrolls and zooms with the page.
    func applyHighlights(current: [[Double]], next: [[Double]], pageIndex: Int) {
        guard current != highlightCurrent || next != highlightNext || pageIndex != highlightPage else { return }
        highlightCurrent = current
        highlightNext = next
        highlightPage = pageIndex
        for annotation in annotations {
            if let page = annotation.page { page.removeAnnotation(annotation) }
        }
        annotations = []
        guard let doc = pdfView.document, let page = doc.page(at: pageIndex) else { return }
        let bounds = page.bounds(for: .cropBox)
        guard bounds.width > 0, bounds.height > 0 else { return }
        let pad = max(2, bounds.width * 0.004)
        for (boxes, color) in [
            (current, ReaderTheme.nsPageCurrent),
            (next, ReaderTheme.nsPageNext),
        ] {
            for box in boxes {
                let rect = CGRect(
                    x: bounds.minX + box[0] * bounds.width - pad,
                    // Normalized boxes are top-left origin; PDF page space is bottom-left.
                    y: bounds.maxY - (box[1] + box[3]) * bounds.height - pad,
                    width: max(1, box[2] * bounds.width + pad * 2),
                    height: max(1, box[3] * bounds.height + pad * 2)
                )
                let annotation = PDFAnnotation(bounds: rect, forType: .square, withProperties: nil)
                annotation.color = color
                annotation.interiorColor = color.withAlphaComponent(0.16)
                let border = PDFBorder()
                border.lineWidth = 1.5
                annotation.border = border
                annotation.shouldDisplay = true
                annotation.shouldPrint = false
                page.addAnnotation(annotation)
                annotations.append(annotation)
            }
        }
    }
}

final class OverlayImageView: NSImageView {
    var currentBoxes: [[Double]] = []
    var nextBoxes: [[Double]] = []
    var onClick: ((CGPoint) -> Void)?

    // Flipped so the scroll view's origin is the top-left: a photo reads
    // top-down and scroll-to-zero lands at the top instead of the bottom.
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let image, image.size.width > 0, image.size.height > 0 else { return }
        let size = bounds.size
        for (boxes, color) in [
            (currentBoxes, ReaderTheme.nsPageCurrent),
            (nextBoxes, ReaderTheme.nsPageNext),
        ] {
            for b in boxes {
                let rect = CGRect(
                    x: b[0] * size.width,
                    // Normalized boxes are top-left origin; the view is flipped.
                    y: b[1] * size.height,
                    width: max(1, b[2] * size.width),
                    height: max(1, b[3] * size.height)
                ).insetBy(dx: -2, dy: -2)
                let path = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
                color.withAlphaComponent(0.16).setFill()
                path.fill()
                color.setStroke()
                path.lineWidth = 1.5
                path.stroke()
            }
        }
    }
}

final class ImageSourceViewer: NSView {
    var transform = SourceViewerTransform()
    var controller: ImageSourceController?
    var loadedDataHash: Int?
    let scrollView = NSScrollView()
    let imageView = OverlayImageView()
    private var clickMonitor: Any?
    private var clickDown: NSPoint?
    private var clickDragged = false
    override init(frame: NSRect) {
        super.init(frame: frame)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.allowsMagnification = true
        // A 300 dpi photo needs to fit below 25% on a normal window.
        scrollView.minMagnification = 0.05
        scrollView.maxMagnification = 4.0
        imageView.imageScaling = .scaleNone
        imageView.onClick = { [weak self] point in
            MainActor.assumeIsolated { self?.controller?.onWordClick?(point) }
        }
        scrollView.documentView = imageView
        addSubview(scrollView)
        clickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            guard let self, let window = self.window, event.window === window else { return event }
            let viewPoint = self.convert(event.locationInWindow, from: nil)
            let imagePoint = self.imageView.convert(event.locationInWindow, from: nil)
            let inside = self.bounds.contains(viewPoint) && self.imageView.bounds.contains(imagePoint)
            switch event.type {
            case .leftMouseDown:
                self.clickDown = inside ? imagePoint : nil
                self.clickDragged = false
            case .leftMouseDragged:
                if let down = self.clickDown,
                   hypot(imagePoint.x - down.x, imagePoint.y - down.y) >= 3 {
                    self.clickDragged = true
                }
            case .leftMouseUp:
                guard self.clickDown != nil else { return event }
                self.clickDown = nil
                guard inside, !self.clickDragged, event.clickCount == 1,
                      event.modifierFlags.intersection([.shift, .command, .option, .control]).isEmpty,
                      self.hitIsImage(event) else { return event }
                let up = self.imageView.convert(event.locationInWindow, from: nil)
                let bounds = self.imageView.bounds
                guard bounds.width > 0, bounds.height > 0 else { return event }
                MainActor.assumeIsolated {
                    self.imageView.onClick?(CGPoint(x: up.x / bounds.width, y: up.y / bounds.height))
                }
            default:
                break
            }
            return event
        }
        // Keep the toolbar's zoom percentage in sync after a pinch/scroll-wheel zoom.
        for name in [NSScrollView.didEndLiveMagnifyNotification] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(imageMagnificationChanged),
                name: name, object: scrollView
            )
        }
    }

    deinit {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
    }

    /// A floating toolbar sits above the image; its clicks are not page clicks.
    private func hitIsImage(_ event: NSEvent) -> Bool {
        guard let content = window?.contentView else { return true }
        let point = content.convert(event.locationInWindow, from: nil)
        guard let hit = content.hitTest(point) else { return true }
        return hit === imageView || hit.isDescendant(of: imageView)
    }

    @objc private func imageMagnificationChanged() {
        controller?.sync()
    }
    required init?(coder: NSCoder) { fatalError() }

    private var didFit = false

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        fitIfNeeded()
        if !didFit {
            // SwiftUI can size the representable after its first layout pass.
            DispatchQueue.main.async { [weak self] in self?.fitIfNeeded() }
        }
    }

    private func fitIfNeeded() {
        guard !didFit, let image = imageView.image,
              image.size.width > 0, image.size.height > 0 else { return }
        let available = scrollView.bounds.size
        guard available.width > 1, available.height > 1 else { return }
        // Default to full width so a tall photo reads like the PDF column
        // instead of being shrunk to fit the whole pane.
        let fit = (available.width - 2) / image.size.width
        scrollView.magnification = max(0.05, min(4, fit))
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        didFit = true
    }

    func setImage(_ image: NSImage) {
        imageView.image = image
        imageView.frame = NSRect(origin: .zero, size: image.size)
        didFit = false
        needsLayout = true
        DispatchQueue.main.async { [weak self] in
            self?.needsLayout = true
            self?.layoutSubtreeIfNeeded()
            self?.fitIfNeeded()
        }
    }
    func setHighlights(current: [[Double]], next: [[Double]]) {
        guard current != imageView.currentBoxes || next != imageView.nextBoxes else { return }
        imageView.currentBoxes = current
        imageView.nextBoxes = next
        imageView.needsDisplay = true
    }
}

@MainActor
final class ImageSourceController: ObservableObject, SourceControlling {
    weak var viewer: ImageSourceViewer?
    @Published var currentPage: Int = 1
    @Published var totalPages: Int = 1
    @Published var zoomPercent: Int = 100
    var onUserNavigate: ((Int) -> Void)?
    var onWordClick: ((CGPoint) -> Void)?

    func attach(_ v: ImageSourceViewer) {
        guard viewer !== v else { return }
        viewer = v
        v.controller = self
        sync()
    }

    func sync() {
        guard let v = viewer, let image = v.imageView.image, image.size.width > 0 else { return }
        let mag = v.scrollView.magnification
        zoomPercent = max(1, Int((mag * 100).rounded()))
    }

    func goPrev() {}
    func goNext() {}
    func goToPage(_ oneBased: Int) {}
    func followToPage(_ oneBased: Int) {}

    func zoomOut() {
        guard let v = viewer else { return }
        v.scrollView.magnification = max(v.scrollView.minMagnification, v.scrollView.magnification / 1.2)
        sync()
    }
    func zoomIn() {
        guard let v = viewer else { return }
        v.scrollView.magnification = min(v.scrollView.maxMagnification, v.scrollView.magnification * 1.2)
        v.needsLayout = true
        v.layoutSubtreeIfNeeded()
        sync()
    }
    func fitPage() {
        guard let v = viewer, let image = v.imageView.image, image.size.width > 0 else { return }
        let available = v.scrollView.bounds.size
        guard available.width > 1, available.height > 1 else { return }
        let fit = min((available.width - 2) / image.size.width,
                      (available.height - 2) / image.size.height)
        v.scrollView.magnification = max(v.scrollView.minMagnification, min(v.scrollView.maxMagnification, fit))
        v.scrollView.contentView.scroll(to: .zero)
        v.scrollView.reflectScrolledClipView(v.scrollView.contentView)
        sync()
    }
    func fitWidth() {
        guard let v = viewer, let image = v.imageView.image, image.size.width > 0 else { return }
        let available = v.scrollView.bounds.size
        guard available.width > 1 else { return }
        let fit = (available.width - 2) / image.size.width
        v.scrollView.magnification = max(v.scrollView.minMagnification, min(v.scrollView.maxMagnification, fit))
        sync()
    }
    func actualSize() {
        guard let v = viewer else { return }
        v.scrollView.magnification = 1.0
        sync()
    }
}

struct PDFSourceRepresentable: NSViewRepresentable {
    let data: Data
    @ObservedObject var controller: PDFSourceController
    var page: Int
    var currentBoxes: [[Double]]
    var nextBoxes: [[Double]]

    func makeNSView(context: Context) -> PDFSourceViewer {
        let v = PDFSourceViewer(frame: .zero)
        v.controller = controller
        v.load(data: data)
        controller.attach(v)
        controller.followToPage(page + 1)
        return v
    }
    func updateNSView(_ nsView: PDFSourceViewer, context: Context) {
        if nsView.pdfView.document == nil { nsView.load(data: data) }
        nsView.controller = controller
        controller.attach(nsView)
        // Page following is driven by PageView's onChange handlers, never here:
        // this method runs inside a SwiftUI update, and calling followToPage
        // publishes controller state that schedules another update, which
        // re-enters this method and hangs the app.
        nsView.applyHighlights(current: currentBoxes, next: nextBoxes, pageIndex: page)
    }
}

struct ImageSourceRepresentable: NSViewRepresentable {
    let data: Data
    @ObservedObject var controller: ImageSourceController
    var currentBoxes: [[Double]] = []
    var nextBoxes: [[Double]] = []

    func makeNSView(context: Context) -> ImageSourceViewer {
        let v = ImageSourceViewer(frame: .zero)
        if let image = NSImage(data: data) {
            v.setImage(image)
            v.loadedDataHash = data.hashValue
        }
        v.setHighlights(current: currentBoxes, next: nextBoxes)
        controller.attach(v)
        return v
    }

    func updateNSView(_ nsView: ImageSourceViewer, context: Context) {
        // Rebuilding NSImage every render reset scroll; only do it for new bytes.
        if nsView.loadedDataHash != data.hashValue, let image = NSImage(data: data) {
            nsView.setImage(image)
            nsView.loadedDataHash = data.hashValue
        }
        nsView.setHighlights(current: currentBoxes, next: nextBoxes)
        controller.attach(nsView)
    }
}

struct SourceViewerToolbar<C: SourceControlling>: View {
    @ObservedObject var controller: C
    @State private var pageInput: String = ""

    var body: some View {
        HStack(spacing: 2) {
            Button { controller.goPrev() } label: {
                Image(systemName: "chevron.left")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(StudioIconButtonStyle(size: 28))
            .disabled(controller.currentPage <= 1)
            .accessibilityLabel("Previous page")
            .help("Previous page")

            TextField("", text: $pageInput)
                .textFieldStyle(.plain)
                .font(ReaderTheme.numeral(11, weight: .medium))
                .multilineTextAlignment(.center)
                .frame(width: 38, height: 24)
                .background(ReaderTheme.canvas,
                            in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(ReaderTheme.hairline, lineWidth: 1)
                }
                .onAppear { pageInput = "\(controller.currentPage)" }
                .onChange(of: controller.currentPage) { _, v in pageInput = "\(v)" }
                .onSubmit {
                    if let n = Int(pageInput), (1...max(1, controller.totalPages)).contains(n) {
                        controller.goToPage(n)
                    } else {
                        pageInput = "\(controller.currentPage)"
                    }
                }
                .onExitCommand { pageInput = "\(controller.currentPage)" }
                .accessibilityLabel("Page number")

            Text("/ \(controller.totalPages)")
                .font(ReaderTheme.numeral(11))
                .foregroundStyle(ReaderTheme.tertiaryText)
                .padding(.trailing, 4)

            Button { controller.goNext() } label: {
                Image(systemName: "chevron.right")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(StudioIconButtonStyle(size: 28))
            .disabled(controller.currentPage >= controller.totalPages)
            .accessibilityLabel("Next page")
            .help("Next page")

            Rectangle().fill(ReaderTheme.hairlineStrong)
                .frame(width: 1, height: 16)
                .padding(.horizontal, 6)

            Button { controller.zoomOut() } label: {
                Image(systemName: "minus")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(StudioIconButtonStyle(size: 28))
            .accessibilityLabel("Zoom out")
            .help("Zoom out")

            Text("\(controller.zoomPercent)%")
                .font(ReaderTheme.numeral(11))
                .foregroundStyle(ReaderTheme.secondaryText)
                .frame(width: 44)
                .accessibilityLabel("Zoom \(controller.zoomPercent) percent")

            Button { controller.zoomIn() } label: {
                Image(systemName: "plus")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(StudioIconButtonStyle(size: 28))
            .accessibilityLabel("Zoom in")
            .help("Zoom in")

            Menu {
                Button("Fit page") { controller.fitPage() }
                Button("Fit width") { controller.fitWidth() }
                Button("Actual size") { controller.actualSize() }
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 28)
            .help("Fit")
            .accessibilityLabel("Fit options")
        }
        .padding(6)
        // Opaque, theme-aware surface instead of a material: a material adapts
        // to whatever is behind it (here a white PDF page), which washes out
        // the toolbar and its buttons in dark mode. A solid raised surface keeps
        // contrast stable regardless of the page color.
        .background(ReaderTheme.raised, in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(ReaderTheme.hairlineStrong, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.28), radius: 16, y: 8)
    }
}
