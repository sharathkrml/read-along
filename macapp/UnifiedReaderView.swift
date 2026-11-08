import AppKit
import SwiftUI

/// Holds a weak reference to the NSScrollView so SwiftUI content can request
/// programmatic scrolling (e.g. when speech advances to a new word).
@MainActor
final class ScrollCoordinator: ObservableObject {
    weak var scrollView: NSScrollView?
    private var scrollObserver: Any?

    func scrollTo(_ y: CGFloat) {
        guard let scrollView else { return }
        var origin = scrollView.contentView.bounds.origin
        origin.y = y
        scrollView.contentView.scroll(to: origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// Detach "follow me" tracking when the user manually scrolls, so speech
    /// no longer fights the user's scroll position.
    func startObservingScroll(model: ReaderModel) {
        guard let scrollView, scrollObserver == nil else { return }
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSScrollView.willStartLiveScrollNotification,
            object: scrollView,
            queue: .main
        ) { [weak model] _ in
            MainActor.assumeIsolated {
                model?.viewer.textFollows = false
            }
        }
    }
}

/// Unified reader: one scroll bar, text on the left, document on the right.
/// Both scroll together as a single unit. Speech highlights text and scrolls both smoothly.
///
/// Replaces the HSplitView with two independent NSScrollViews (each with its own
/// scroll bar). A single NSScrollView owns all scrolling; the text pane shows only
/// the text that lies under the currently visible document page.
struct UnifiedReaderView: NSViewRepresentable {
    @EnvironmentObject private var model: ReaderModel
    @StateObject private var scrollCoordinator = ScrollCoordinator()

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.contentView.scroll(to: .zero)

        let content = UnifiedReaderContent(
            model: model,
            scrollCoordinator: scrollCoordinator
        )
        let hosting = NSHostingView(rootView: content)
        // Let the hosting view size to fit its SwiftUI content so the scroll view
        // can show scroll bars when the document (all pages in a VStack) is taller
        // than the visible area. Width tracks the scroll view; height is content-driven.
        hosting.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = hosting

        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
        ])

        scrollCoordinator.scrollView = scrollView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        if let hosting = scrollView.documentView as? NSHostingView<UnifiedReaderContent> {
            hosting.rootView = UnifiedReaderContent(
                model: model,
                scrollCoordinator: scrollCoordinator
            )
        }
    }
}

/// SwiftUI content inside the shared NSScrollView: text column (left) + document (right).
struct UnifiedReaderContent: View {
    @ObservedObject private var model: ReaderModel
    let scrollCoordinator: ScrollCoordinator

    init(model: ReaderModel, scrollCoordinator: ScrollCoordinator) {
        self.model = model
        self.scrollCoordinator = scrollCoordinator
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // LEFT: Text for every page, so it scrolls in lockstep with the
            // document pages on the right. Filtering to a single page (via
            // model.displayPage) left the left pane blank once the user scrolled
            // past the reading cursor's page.
            ReaderTextView(
                page: nil,
                useOuterScroll: true,
                onScrollTo: { y in
                    scrollCoordinator.scrollTo(y)
                }
            )
            .frame(minWidth: 300, idealWidth: 400, maxWidth: 600, maxHeight: .infinity)

            Divider()

            // RIGHT: The document (PDF page or image) with highlight overlays.
            UnifiedDocumentView(model: model)
                .frame(minWidth: 350, maxHeight: .infinity)
        }
        .frame(maxHeight: .infinity)
        .onAppear {
            scrollCoordinator.startObservingScroll(model: model)
        }
    }
}

/// Document view inside the unified scroll: renders every page image vertically so
/// scrolling moves through the whole document. Reading highlight boxes are drawn on
/// the current page only. No internal scroll view — the outer NSScrollView owns all scrolling.
struct UnifiedDocumentView: View {
    @ObservedObject private var model: ReaderModel

    init(model: ReaderModel) {
        self.model = model
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(model.pageModel.pages.indices), id: \.self) { pageIndex in
                pageView(for: pageIndex)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    @ViewBuilder private func pageView(for pageIndex: Int) -> some View {
        let image = model.pageImages[pageIndex]
        let info = model.pageModel.pages.indices.contains(pageIndex)
            ? model.pageModel.pages[pageIndex] : nil

        if let image, let info {
            ZStack {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(CGFloat(info.width) / max(1, CGFloat(info.height)), contentMode: .fit)
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .strokeBorder(ReaderTheme.glassBorder)
                    )
                    .shadow(color: .black.opacity(0.16), radius: 10, y: 4)
                if pageIndex == model.displayPage {
                    overlayCanvas(for: pageIndex)
                    boxAnchor(for: pageIndex)
                }
            }
            .frame(maxWidth: 980)
            .frame(maxWidth: .infinity)
        } else if model.pageModel.pages.indices.contains(pageIndex) {
            placeholder(for: pageIndex)
        } else {
            EmptyView()
        }
    }

    @ViewBuilder private func boxAnchor(for pageIndex: Int) -> some View {
        GeometryReader { geo in
            if let first = boxesForPage(pageIndex).first {
                Color.clear
                    .frame(width: 1, height: 1)
                    .position(x: geo.size.width / 2, y: (first[1] + first[3] / 2) * geo.size.height)
                    .id("anchor-page-\(pageIndex)")
            }
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder private func overlayCanvas(for pageIndex: Int) -> some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                let lineWidth = max(2, size.width * 0.0022)
                for (boxes, stroke, fill) in [
                    (boxesForPage(pageIndex), Color(red: 0.96, green: 0.73, blue: 0.26), Color(red: 0.96, green: 0.73, blue: 0.26).opacity(0.18)),
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

    private func boxesForPage(_ pageIndex: Int) -> [[Double]] {
        model.groupBoxes(range: model.currentRange, page: pageIndex)
    }

    private func placeholder(for pageIndex: Int) -> some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("Page \(pageIndex + 1)")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, minHeight: 300)
        .padding(.vertical, 100)
    }
}
