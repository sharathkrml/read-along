import SwiftUI
import AppKit
import PDFKit

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
final class PDFSourceController: ObservableObject {
    weak var viewer: PDFSourceViewer?
    var onUserNavigate: ((Int) -> Void)?
    @Published var currentPage: Int = 1
    @Published var totalPages: Int = 1
    @Published var zoomPercent: Int = 100

    func attach(_ v: PDFSourceViewer) {
        guard viewer !== v else { return }
        viewer = v
        v.pdfView.controller = self
        sync()
    }

    func sync() {
        guard let v = viewer, let doc = v.pdfView.document else { return }
        totalPages = max(1, doc.pageCount)
        if let p = v.pdfView.currentPage {
            let idx = doc.index(for: p)
            currentPage = idx + 1
            // Report the zoom the user actually sees; PDFView.scaleFactor is not
            // always the on-screen point ratio while autoScales is active.
            let pageRect = p.bounds(for: .cropBox)
            let onScreen = v.pdfView.convert(pageRect, from: p)
            if pageRect.width > 0, onScreen.width > 0 {
                zoomPercent = max(1, Int((onScreen.width / pageRect.width * 100).rounded()))
            }
        }
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
        followToPage(oneBased)
        onUserNavigate?(currentPage)
    }
    /// Move with the live reading position without detaching following.
    func followToPage(_ oneBased: Int) {
        guard let v = viewer, let doc = v.pdfView.document else { return }
        let idx = max(0, min(oneBased - 1, doc.pageCount - 1))
        if let page = doc.page(at: idx) { v.pdfView.go(to: page) }
        sync()
    }
    func zoomOut() {
        guard let v = viewer else { return }
        v.pdfView.autoScales = false
        v.pdfView.scaleFactor = max(0.25, v.pdfView.scaleFactor / 1.2)
        v.needsLayout = true
        sync()
    }
    func zoomIn() {
        guard let v = viewer else { return }
        v.pdfView.autoScales = false
        v.pdfView.scaleFactor = min(4.0, v.pdfView.scaleFactor * 1.2)
        v.needsLayout = true
        sync()
    }
    func fitPage() {
        guard let v = viewer else { return }
        v.pdfView.autoScales = true
        v.pdfView.displayMode = .singlePageContinuous
        v.needsLayout = true
        sync()
    }
    func fitWidth() {
        guard let v = viewer else { return }
        v.pdfView.autoScales = false
        v.pdfView.frame = v.bounds
        if let page = v.pdfView.currentPage {
            let pageRect = page.bounds(for: .cropBox)
            let viewWidth = v.bounds.width - 2
            if pageRect.width > 0 { v.pdfView.scaleFactor = max(0.25, min(4, viewWidth / pageRect.width)) }
        }
        sync()
    }
    func actualSize() {
        guard let v = viewer else { return }
        v.pdfView.autoScales = false
        v.pdfView.frame = v.bounds
        v.pdfView.scaleFactor = 1.0
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

    private var clickMonitor: Any?

    override init(frame: NSRect) {
        super.init(frame: frame)
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displaysPageBreaks = false
        pdfView.autoresizingMask = [.width, .height]
        pdfView.backgroundColor = .clear
        addSubview(pdfView)
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, let window = self.window, event.window === window else { return event }
            let point = self.convert(event.locationInWindow, from: nil)
            if self.bounds.contains(point) {
                window.makeFirstResponder(self.pdfView)
                MainActor.assumeIsolated { SourceFocus.active = self }
            }
            return event
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
    }

    override func layout() {
        super.layout()
        pdfView.frame = bounds
        guard pdfView.autoScales,
              let page = pdfView.currentPage ?? pdfView.document?.page(at: 0) else { return }
        let pageRect = page.bounds(for: .cropBox)
        guard pageRect.width > 0, pageRect.height > 0, bounds.width > 1, bounds.height > 1 else { return }
        let fit = min((bounds.width - 2) / pageRect.width, (bounds.height - 2) / pageRect.height)
        guard fit > 0 else { return }
        if abs(pdfView.scaleFactor - fit) > 0.001 { pdfView.scaleFactor = fit }
        controller?.sync()
    }

    func load(url: URL) { pdfView.document = PDFDocument(url: url); fitPage() }
    func load(data: Data) { pdfView.document = PDFDocument(data: data); fitPage() }

    private func fitPage() {
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        needsLayout = true
        layoutSubtreeIfNeeded()
        controller?.sync()
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
            (current, NSColor(srgbRed: 0.96, green: 0.73, blue: 0.26, alpha: 1)),
            (next, NSColor.controlAccentColor),
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

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let image, image.size.width > 0, image.size.height > 0 else { return }
        let size = bounds.size
        for (boxes, color) in [
            (currentBoxes, NSColor(srgbRed: 0.96, green: 0.73, blue: 0.26, alpha: 1)),
            (nextBoxes, NSColor.controlAccentColor),
        ] {
            for b in boxes {
                let rect = CGRect(
                    x: b[0] * size.width,
                    // Normalized boxes are top-left origin; AppKit draws bottom-left.
                    y: (1 - b[1] - b[3]) * size.height,
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
    let scrollView = NSScrollView()
    let imageView = OverlayImageView()
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
        scrollView.documentView = imageView
        addSubview(scrollView)
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
        let fit = min((available.width - 2) / image.size.width,
                      (available.height - 2) / image.size.height)
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

struct PDFSourceRepresentable: NSViewRepresentable {
    let data: Data
    @ObservedObject var controller: PDFSourceController
    var page: Int
    var follows: Bool
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
        if follows, controller.currentPage != page + 1 {
            controller.followToPage(page + 1)
        }
        nsView.applyHighlights(current: currentBoxes, next: nextBoxes, pageIndex: page)
    }
}

struct ImageSourceRepresentable: NSViewRepresentable {
    let image: NSImage
    var currentBoxes: [[Double]] = []
    var nextBoxes: [[Double]] = []
    func makeNSView(context: Context) -> ImageSourceViewer {
        let v = ImageSourceViewer(frame: .zero)
        v.setImage(image)
        v.setHighlights(current: currentBoxes, next: nextBoxes)
        return v
    }
    func updateNSView(_ nsView: ImageSourceViewer, context: Context) {
        if nsView.imageView.image !== image { nsView.setImage(image) }
        nsView.setHighlights(current: currentBoxes, next: nextBoxes)
    }
}

struct SourceViewerToolbar: View {
    @ObservedObject var controller: PDFSourceController
    @State private var pageInput: String = ""
    var body: some View {
        HStack(spacing: 8) {
            Menu("Pages") {
                ForEach(1...max(1, controller.totalPages), id: \.self) { page in
                    Button("Page \(page)") { controller.goToPage(page) }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Button { controller.goPrev() } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.bordered)
                .disabled(controller.currentPage <= 1)
                .accessibilityLabel("Previous")
            TextField("", text: $pageInput)
                .frame(width: 44)
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
            Text("/ \(controller.totalPages)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Button { controller.goNext() } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.bordered)
                .disabled(controller.currentPage >= controller.totalPages)
                .accessibilityLabel("Next")
            Button { controller.zoomOut() } label: { Image(systemName: "minus.magnifyingglass") }
                .buttonStyle(.bordered)
                .accessibilityLabel("Zoom out")
            Text("\(controller.zoomPercent)%")
                .font(.caption.monospacedDigit())
            Button { controller.zoomIn() } label: { Image(systemName: "plus.magnifyingglass") }
                .buttonStyle(.bordered)
                .accessibilityLabel("Zoom in")
            Menu("Fit") {
                Button("Fit page") { controller.fitPage() }
                Button("Fit width") { controller.fitWidth() }
                Button("Actual size") { controller.actualSize() }
            }
            .buttonStyle(.bordered)
        }
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
    }
}
