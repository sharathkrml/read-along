import AppKit
import SwiftUI

struct PageView: View {
    @EnvironmentObject private var model: ReaderModel
    @StateObject private var sourceController = PDFSourceController()
    @StateObject private var imageSourceController = ImageSourceController()
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
        // No card of its own (see TextPanel): one shared surface hosts both
        // panes. The PDF toolbar floats on top as glass, rather than taking
        // a dedicated footer strip.
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                panelHeader
                Rectangle().fill(ReaderTheme.hairline).frame(height: 1)
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if hasSource, showsToolbar {
                if isPDF {
                    SourceViewerToolbar(controller: controller)
                        .padding(.bottom, 14)
                } else {
                    SourceViewerToolbar(controller: imageSourceController)
                        .padding(.bottom, 14)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            if isPDF {
                controller.onUserNavigate = { page in
                    model.viewer.browsedPage = max(0, page - 1)
                    model.viewer.sourceFollows = false
                }
            } else {
                imageSourceController.onUserNavigate = { _ in }
            }
        }
        .onChange(of: model.displayPage) { _, page in
            if isPDF, model.viewer.sourceFollows { controller.followToPage(page + 1) }
        }
        .onChange(of: model.viewer.sourceFollows) { _, follows in
            if isPDF, follows { controller.followToPage(model.displayPage + 1) }
        }
    }

    private var hasSource: Bool {
        model.sourceData != nil && !(model.sourceData?.isEmpty ?? true)
    }

    private var panelHeader: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Text("ORIGINAL")
                    .font(ReaderTheme.micro(9.5))
                    .tracking(1.3)
                    .foregroundStyle(ReaderTheme.secondaryText)
                Text("·")
                    .font(ReaderTheme.micro(9.5))
                    .foregroundStyle(ReaderTheme.tertiaryText)
                Text(isPDF ? "PDF" : "IMAGE")
                    .font(ReaderTheme.micro(9.5))
                    .tracking(0.8)
                    .foregroundStyle(ReaderTheme.tertiaryText)
            }
            Spacer(minLength: 8)
            if !model.viewer.sourceFollows, model.sourceData != nil {
                Button { model.returnToReading() } label: {
                    Label("Return to reading", systemImage: "arrow.uturn.backward")
                        .font(.system(size: 10.5, weight: .medium))
                        .padding(.horizontal, 9)
                        .frame(height: 24)
                        .background(ReaderTheme.raised, in: Capsule(style: .continuous))
                        .overlay {
                            Capsule(style: .continuous)
                                .strokeBorder(ReaderTheme.hairline, lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
                .help("Jump the original page back to the live reading position")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minHeight: 52)
    }

    @ViewBuilder private var content: some View {
        if model.sourceLoading {
            loadingView
        } else if let error = model.sourceError {
            ScrollView([.vertical, .horizontal]) { SpacedPageView() }
                .overlay(alignment: .top) {
                    HStack(spacing: 10) {
                        Text(error).font(.system(size: 11)).lineLimit(2)
                        Button("Retry") { model.loadSource(force: true) }
                            .buttonStyle(StudioSecondaryButtonStyle())
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(ReaderTheme.raised, in: Capsule(style: .continuous))
                    .overlay {
                        Capsule(style: .continuous)
                            .strokeBorder(ReaderTheme.hairline, lineWidth: 1)
                    }
                    .padding(14)
                }
        } else if let data = model.sourceData, !data.isEmpty {
            if isPDF {
                PDFSourceRepresentable(
                    data: data,
                    controller: controller,
                    page: model.displayPage,
                    currentBoxes: currentBoxes,
                    nextBoxes: nextBoxes
                )
                .id(model.library.active)
            } else {
                // The import path validates and re-encodes every image, so it
                // is safe to hand the bytes straight to the viewer instead of
                // decoding a throwaway NSImage on every body evaluation.
                ImageSourceRepresentable(data: data, controller: imageSourceController, currentBoxes: currentBoxes, nextBoxes: nextBoxes)
                    .id(model.library.active)
            }
        } else {
            rasterFallback
        }
    }

    private var loadingView: some View {
        VStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 12) {
                Text("PAGE")
                    .font(ReaderTheme.micro(8))
                    .tracking(1.4)
                    .foregroundStyle(Color.black.opacity(0.35))
                ForEach([1.0, 0.86, 0.94, 0.7], id: \.self) { fraction in
                    Capsule().fill(Color.black.opacity(0.09))
                        .frame(width: 180 * fraction, height: 5)
                }
            }
            .padding(24)
            .frame(width: 240, height: 186, alignment: .topLeading)
            .background(Color(red: 0.97, green: 0.965, blue: 0.945),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .shadow(color: .black.opacity(0.20), radius: 18, y: 10)
            .accessibilityHidden(true)
            HStack(spacing: 9) {
                ProgressView().controlSize(.small)
                Text("Loading the original…")
                    .font(.system(size: 11))
                    .foregroundStyle(ReaderTheme.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var rasterFallback: some View {
        ScrollViewReader { proxy in
            ScrollView([.vertical, .horizontal]) {
                SpacedPageView()
            }
            .onChange(of: model.highlightIdentity) {
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

/// The page itself: white paper on a matte panel, with amber/blue
/// rounded stroke rectangles aligned to the words on that page.
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
                        .strokeBorder(Color.black.opacity(0.08))
                )
                .shadow(color: .black.opacity(0.24), radius: 20, y: 8)
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
            ProgressView().controlSize(.small)
            Text(model.isProcessing ? "Loading the original…" : "Page")
                .font(.system(size: 11))
                .foregroundStyle(ReaderTheme.tertiaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 160)
        .accessibilityLabel(model.isProcessing ? "Loading the original" : "Page")
    }

    @ViewBuilder private var overlayCanvas: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                let lineWidth = max(2, size.width * 0.0022)
                for (boxes, stroke, fill) in [
                    (currentBoxes, ReaderTheme.pageCurrent, ReaderTheme.pageCurrent.opacity(0.18)),
                    (nextBoxes, ReaderTheme.pageNext, ReaderTheme.pageNext.opacity(0.10)),
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
