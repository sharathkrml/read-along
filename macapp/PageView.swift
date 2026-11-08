import AppKit
import SwiftUI

struct PageView: View {
    @EnvironmentObject private var model: ReaderModel
    @StateObject private var sourceController = PDFSourceController()
    /// In Split the toolbar is docked above both panes, so the PDF pane shares
    /// the controller owned by ContentView instead of the toolbar row below.
    var sharedController: PDFSourceController?
    var showsToolbar = true

    private var controller: PDFSourceController { sharedController ?? sourceController }
    private var isPDF: Bool {
        guard let data = model.sourceData, !data.isEmpty else { return false }
        return data.prefix(4) == Data("%PDF".utf8)
    }

    var body: some View {
        VStack(spacing: 0) {
            if isPDF, showsToolbar {
                SourceViewerToolbar(controller: controller)
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .topTrailing) {
                    if !model.viewer.sourceFollows, model.sourceData != nil {
                        Button("Return to reading") { model.returnToReading() }
                            .controlSize(.small)
                            .padding(12)
                            .help("Jump the original page back to the live reading position")
                    }
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ReaderTheme.canvas)
        .onAppear {
            controller.onUserNavigate = { page in
                model.viewer.browsedPage = max(0, page - 1)
                model.viewer.sourceFollows = false
            }
        }
        .onChange(of: model.displayPage) { _, page in
            if model.viewer.sourceFollows { controller.followToPage(page + 1) }
        }
        .onChange(of: model.viewer.sourceFollows) { _, follows in
            if follows { controller.followToPage(model.displayPage + 1) }
        }
    }

    @ViewBuilder private var content: some View {
        if model.sourceLoading {
            VStack(spacing: 10) {
                ProgressView()
                Text("Loading original…").font(.caption).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = model.sourceError {
            ScrollView([.vertical, .horizontal]) { SpacedPageView() }
                .overlay(alignment: .top) {
                    HStack(spacing: 10) {
                        Text(error).font(.caption).lineLimit(2)
                        Button("Retry") { model.loadSource(force: true) }
                            .controlSize(.small)
                    }
                    .padding(8)
                    .glassCard(radius: 8)
                    .padding(8)
                }
        } else if let data = model.sourceData, !data.isEmpty {
            if isPDF {
                PDFSourceRepresentable(
                    data: data,
                    controller: controller,
                    page: model.displayPage,
                    follows: model.viewer.sourceFollows,
                    currentBoxes: currentBoxes,
                    nextBoxes: nextBoxes
                )
                .id(model.library.active)
            } else if let image = NSImage(data: data) {
                ImageSourceRepresentable(image: image, currentBoxes: currentBoxes, nextBoxes: nextBoxes)
                    .id(model.library.active)
            } else {
                rasterFallback
            }
        } else {
            rasterFallback
        }
    }

    private var rasterFallback: some View {
        ScrollViewReader { proxy in
            ScrollView([.vertical, .horizontal]) {
                SpacedPageView()
            }
            .onChange(of: model.highlightIdentity) { _ in
                Task { @MainActor in
                    withAnimation(.smooth(duration: 0.2)) {
                        proxy.scrollTo("anchor-current", anchor: .center)
                    }
                }
            }

        }
    }

    private var currentBoxes: [[Double]] {
        model.groupBoxes(range: model.currentRange, page: model.displayPage)
    }

    private var nextBoxes: [[Double]] {
        model.groupBoxes(range: model.nextRange, page: model.displayPage)
    }
}

/// The page itself: white paper on a macOS gray canvas, with amber/blue rounded
/// stroke rectangles aligned to the words on that page.
struct SpacedPageView: View {
    @EnvironmentObject private var model: ReaderModel

    var body: some View {
        VStack {
            if let image = model.pageImage, let info = model.pageInfo {
                page(image: image, aspect: info.width / max(1, info.height))
            } else {
                // Never leave this pane empty: while OCR is still publishing
                // pages, show a busy placeholder instead of a blank wall.
                placeholder
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .top)
    }

    @ViewBuilder private func page(image: NSImage, aspect: CGFloat) -> some View {
        ZStack {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(aspect, contentMode: .fit)
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(ReaderTheme.glassBorder)
                )
                .shadow(color: .black.opacity(0.16), radius: 10, y: 4)
            overlayCanvas
            boxAnchors
        }
        .frame(maxWidth: 980)
        .frame(maxWidth: .infinity)
    }

    /// Invisible anchor inside the page image so ScrollViewReader can scroll to
    /// the current phrase without knowing the pixel geometry of the canvas.
    private var boxAnchors: some View {
        GeometryReader { geo in
            if let first = currentBoxes.first {
                Color.clear
                    .frame(width: 1, height: 1)
                    .position(x: geo.size.width / 2, y: (first[1] + first[3] / 2) * geo.size.height)
                    .id("anchor-current")
            }
        }
        .allowsHitTesting(false)
    }

    var placeholder: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text(model.isProcessing ? "Loading the original…" : "Page")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 200)
        .accessibilityLabel(model.isProcessing ? "Loading the original" : "Page")
    }

    @ViewBuilder private var overlayCanvas: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                let lineWidth = max(2, size.width * 0.0022)
                for (boxes, stroke, fill) in [
                    (currentBoxes, Color(red: 0.96, green: 0.73, blue: 0.26), Color(red: 0.96, green: 0.73, blue: 0.26).opacity(0.18)),
                    (nextBoxes, Color.accentColor, Color.accentColor.opacity(0.10)),
                ] {
                    for b in boxes {
                        let rect = CGRect(
                            x: b[0] * size.width - 2,
                            y: b[1] * size.height - 2,
                            width: max(2, b[2] * size.width + 4),
                            height: max(2, b[3] * size.height + 4)
                        )
                        let path = Path(roundedRect: rect, cornerRadius: lineWidth * 2.4)
                        ctx.fill(path, with: .color(fill))
                        ctx.stroke(path, with: .color(stroke), lineWidth: lineWidth)
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    private var currentBoxes: [[Double]] {
        model.groupBoxes(range: model.currentRange, page: model.displayPage)
    }

    private var nextBoxes: [[Double]] {
        model.groupBoxes(range: model.nextRange, page: model.displayPage)
    }
}



