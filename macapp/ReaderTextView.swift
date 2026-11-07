import AppKit
import SwiftUI

struct Span: Equatable {
    var range: NSRange
    var word: Int
}

/// Native selection, Find, and UTF-16 word mapping share one scroll owner.
struct ReaderTextView: NSViewRepresentable {
    @EnvironmentObject var model: ReaderModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    var stage = false

    func makeCoordinator() -> Coordinator {
        Coordinator(stage: stage, model: model)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = ReaderScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.findBarPosition = .aboveContent
        scrollView.onManualScroll = { [weak coordinator = context.coordinator] in
            coordinator?.detachFollowing()
        }

        let text = JumpTextView(frame: NSRect(origin: .zero, size: scrollView.contentSize))
        text.drawsBackground = false
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = true
        text.importsGraphics = false
        text.allowsUndo = false
        text.usesFontPanel = false
        text.usesFindBar = true
        text.isIncrementalSearchingEnabled = true
        text.usesInspectorBar = false
        text.minSize = .zero
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.lineFragmentPadding = 0
        text.coordinatorOwner = context.coordinator
        text.setAccessibilityLabel(stage ? "Focus reading text" : "Reading text")
        context.coordinator.textView = text
        scrollView.documentView = text
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.model = model
        coordinator.stage = stage
        let appearance = stage || colorScheme == .dark ? NSAppearance.Name.darkAqua : .aqua
        scrollView.appearance = NSAppearance(named: appearance)
        coordinator.sync(appearance: "\(appearance.rawValue)|\(contrast)")
    }

    @MainActor
    final class Coordinator {
        weak var textView: JumpTextView?
        var model: ReaderModel?
        var stage: Bool
        private var contentSignature = ""
        private var highlighted: HighlightState?
        private var followed = false
        private var isProgrammaticScroll = false
        private var textFollowEnabled = true
        private var sourceFollowEnabled = true
        private var documentID: String?
        private static var handledFindRequest = 0
        private(set) var spans: [Span] = []

        private struct HighlightState: Equatable {
            var spec: HighlightSpec
            var spokenWord: Int?
        }

        init(stage: Bool, model: ReaderModel?) {
            self.stage = stage
            self.model = model
        }

        func sync(appearance: String) {
            guard let model, let view = textView else { return }
            let content = ReaderContent(model: model, stage: stage, appearance: appearance)
            view.readingMeasure = content.bodySize * (stage ? 29 : 34)
            view.stage = stage
            view.layoutReadingColumn()
            let rebuilt = content.renderKey != contentSignature
            if rebuilt { rebuild(with: content, in: view) }

            var spec = model.highlight
            if model.isComplete {
                spec.currentStart = -1
                spec.nextStart = -1
            }
            // cursor is advanced by real AVSpeech range callbacks, never an animation clock.
            let spokenWord = model.prefs.mode == .read && model.transportState == .playing && !model.isComplete
                ? model.cursor : nil
            let next = HighlightState(spec: spec, spokenWord: spokenWord)
            let changed = next != highlighted
            if rebuilt || changed {
                applyHighlight(next, in: view)
                highlighted = next
            }
            textFollowEnabled = model.viewer.textFollows
            if textFollowEnabled && (rebuilt || changed || !followed) { scrollToCurrent(in: view) }
            followed = textFollowEnabled

            if Self.handledFindRequest != model.findRequest, stage == model.presentVisible {
                Self.handledFindRequest = model.findRequest
                if model.findRequest > 0 {
                    DispatchQueue.main.async { [weak self, weak view] in
                        guard let self, let view, view.window != nil else { return }
                        self.detachFollowing()
                        view.window?.makeFirstResponder(view)
                        let item = NSMenuItem()
                        item.tag = NSTextFinder.Action.showFindInterface.rawValue
                        view.performTextFinderAction(item)
                    }
                }
            }
        }

        private func rebuild(with content: ReaderContent, in view: JumpTextView) {
            let sameDocument = documentID == content.model.activeDoc?.id
            let selections = view.selectedRanges
            let origin = view.visibleRect.origin
            let (attributed, spans) = content.build()
            self.spans = spans
            view.textStorage?.setAttributedString(attributed)
            if sameDocument {
                view.selectedRanges = selections.compactMap { value in
                    let range = value.rangeValue
                    guard range.location != NSNotFound, range.location <= attributed.length else { return nil }
                    return NSValue(range: NSRange(location: range.location, length: min(range.length, attributed.length - range.location)))
                }
                view.enclosingScrollView?.contentView.scroll(to: origin)
            } else {
                view.setSelectedRange(NSRange(location: 0, length: 0))
            }
            documentID = content.model.activeDoc?.id
            contentSignature = content.renderKey
            highlighted = nil // Replacing text storage also replaces its temporary reading attributes.
        }

        func detachFollowing() {
            guard let model, model.viewer.textFollows else { return }
            if isProgrammaticScroll { return }
            model.viewer.textFollows = false
        }

        func jump(word: Int) {
            model?.viewer.textFollows = true
            textFollowEnabled = true
            model?.jump(word: word, quiet: false)
        }

        private func lowerBound(_ word: Int) -> Int {
            var low = 0
            var high = spans.count
            while low < high {
                let middle = (low + high) / 2
                if spans[middle].word < word { low = middle + 1 } else { high = middle }
            }
            return low
        }

        private func characterRange(_ words: Range<Int>) -> NSRange? {
            guard !words.isEmpty else { return nil }
            let first = lowerBound(words.lowerBound)
            let end = lowerBound(words.upperBound)
            guard first < end else { return nil }
            return NSRange(location: spans[first].range.location,
                           length: NSMaxRange(spans[end - 1].range) - spans[first].range.location)
        }

        private func scrollToCurrent(in view: JumpTextView) {
            guard view.selectedRange().length == 0, let model,
                  let range = characterRange(model.cursor..<(model.cursor + 1)),
                  let manager = view.layoutManager, let container = view.textContainer,
                  let scroll = view.enclosingScrollView else { return }
            manager.ensureLayout(forCharacterRange: range)
            let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let line = manager.boundingRect(forGlyphRange: glyphs, in: container)
                .offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y)
            let visible = view.visibleRect
            guard visible.height > 0 else { return }
            let band = visible.minY + visible.height * 0.30 ... visible.minY + visible.height * 0.60
            guard line.minY < band.lowerBound || line.maxY > band.upperBound else { return }
            let y = min(max(0, line.midY - visible.height * 0.43), max(0, view.bounds.height - visible.height))
            // Only input events detach following; this programmatic scroll cannot detach itself.
            isProgrammaticScroll = true
            scroll.contentView.scroll(to: NSPoint(x: visible.minX, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
            isProgrammaticScroll = false
        }

        private func applyHighlight(_ next: HighlightState, in view: JumpTextView) {
            guard let manager = view.layoutManager, let storage = view.textStorage, storage.length > 0 else { return }
            var dirty: [NSRange] = []
            if let old = highlighted, old.spec.guide == next.spec.guide {
                for state in [old, next] {
                    for (start, end) in [(state.spec.currentStart, state.spec.currentEnd), (state.spec.nextStart, state.spec.nextEnd)] where start >= 0 && end > start {
                        if let range = characterRange(start..<end) { dirty.append(range) }
                    }
                    if let word = state.spokenWord, let range = characterRange(word..<(word + 1)) { dirty.append(range) }
                }
                let start = min(old.spec.cursor, next.spec.cursor)
                let end = max(old.spec.cursor, next.spec.cursor)
                if start < end, let range = characterRange(start..<end) { dirty.append(range) }
            } else {
                dirty = [NSRange(location: 0, length: storage.length)]
            }

            for range in dirty {
                for key: NSAttributedString.Key in [.foregroundColor, .backgroundColor, .underlineStyle, .underlineColor] {
                    manager.removeTemporaryAttribute(key, forCharacterRange: range)
                }
                if next.spec.guide {
                    manager.addTemporaryAttribute(.foregroundColor, value: ReaderTheme.nsSecondaryText, forCharacterRange: range)
                } else if let past = characterRange(0..<max(0, next.spec.cursor)) {
                    let intersection = NSIntersectionRange(past, range)
                    if intersection.length > 0 {
                        manager.addTemporaryAttribute(.foregroundColor, value: ReaderTheme.nsSecondaryText, forCharacterRange: intersection)
                    }
                }
                if next.spec.currentStart >= 0, next.spec.currentEnd > next.spec.currentStart,
                   let current = characterRange(next.spec.currentStart..<next.spec.currentEnd) {
                    let intersection = NSIntersectionRange(current, range)
                    if intersection.length > 0 {
                        manager.addTemporaryAttributes([.backgroundColor: ReaderTheme.nsReadingFill,
                                                        .foregroundColor: ReaderTheme.nsReadingInk], forCharacterRange: intersection)
                    }
                }
                if let word = next.spokenWord, let spoken = characterRange(word..<(word + 1)) {
                    let intersection = NSIntersectionRange(spoken, range)
                    if intersection.length > 0 {
                        manager.addTemporaryAttributes([.underlineStyle: NSUnderlineStyle.thick.rawValue,
                                                        .underlineColor: ReaderTheme.nsReadingStroke], forCharacterRange: intersection)
                    }
                }
            }
        }

        func word(atCharacter index: Int) -> Int? {
            var low = 0
            var high = spans.count
            while low < high {
                let middle = (low + high) / 2
                if NSMaxRange(spans[middle].range) <= index { low = middle + 1 } else { high = middle }
            }
            guard low < spans.count, NSLocationInRange(index, spans[low].range) else { return nil }
            return spans[low].word
        }
    }
}

extension ReaderTextView {
    @MainActor
    struct ReaderContent {
        var model: ReaderModel
        var stage: Bool
        var appearance: String

        var bodySize: CGFloat { stage ? min(44, max(32, model.prefs.size * 1.7)) : model.prefs.size }

        var renderKey: String {
            "\(model.activeDoc?.id ?? "none")|\(model.contentRevision)|\(model.prefs.readingFont ?? "serif")|\(model.prefs.size)|\(model.prefs.appearance.rawValue)|\(appearance)|\(stage)|\(NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast)"
        }

        func build() -> (NSAttributedString, [Span]) {
            let attributed = NSMutableAttributedString()
            var spans: [Span] = []
            let bodyWeight: NSFont.Weight = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? .medium : .regular

            func readingFont(_ size: CGFloat, weight: NSFont.Weight) -> NSFont {
                switch model.prefs.readingFont {
                case "mono": return .monospacedSystemFont(ofSize: size, weight: weight)
                case "serif", nil:
                    if let descriptor = NSFont.systemFont(ofSize: size, weight: weight).fontDescriptor.withDesign(.serif),
                       let font = NSFont(descriptor: descriptor, size: size) { return font }
                    return .systemFont(ofSize: size, weight: weight)
                default: return .systemFont(ofSize: size, weight: weight)
                }
            }

            func attributes(_ kind: String) -> [NSAttributedString.Key: Any] {
                let size: CGFloat
                switch kind {
                case "title": size = min(stage ? 54 : 36, bodySize * 1.4)
                case "label": size = bodySize * 0.80
                case "row": size = bodySize * 0.94
                case "page": size = max(11, bodySize * 0.65)
                default: size = bodySize
                }
                let paragraph = NSMutableParagraphStyle()
                paragraph.minimumLineHeight = size * (kind == "title" ? 1.25 : 1.5)
                paragraph.paragraphSpacing = bodySize * (kind == "label" ? 0.25 : 0.55)
                paragraph.paragraphSpacingBefore = kind == "title" ? bodySize * 0.35 : 0
                if kind == "bullet" { paragraph.headIndent = bodySize * 0.9 }
                if kind == "page" { paragraph.paragraphSpacing = bodySize * 0.45 }
                let font = kind == "label" || kind == "page"
                    ? NSFont.systemFont(ofSize: size, weight: .medium)
                    : readingFont(size, weight: kind == "title" ? .semibold : bodyWeight)
                return [.font: font, .paragraphStyle: paragraph,
                        .foregroundColor: kind == "label" || kind == "page" ? ReaderTheme.nsSecondaryText : ReaderTheme.nsPrimaryText]
            }

            var lastBlock: Int?
            var lastKind: String?
            var lastPage = -1
            for line in model.pageModel.lines {
                let kind = line.kind ?? "body"
                let style = attributes(kind)
                let changedPage = line.page != lastPage
                if changedPage {
                    if attributed.length > 0 { attributed.append(NSAttributedString(string: "\n", attributes: style)) }
                    if model.pageModel.pages.count > 1 {
                        attributed.append(NSAttributedString(string: "Page \(line.page + 1)\n", attributes: attributes("page")))
                    }
                    lastPage = line.page
                    lastBlock = nil
                } else if attributed.length > 0 {
                    let separator = lastBlock != (line.block ?? 0) || lastKind != kind ? "\n" : (line.sep ?? " ")
                    attributed.append(NSAttributedString(string: separator, attributes: style))
                }
                lastBlock = line.block ?? 0
                lastKind = kind
                for (index, token) in line.tokens.enumerated() {
                    if index > 0 { attributed.append(NSAttributedString(string: " ", attributes: style)) }
                    let start = attributed.length
                    attributed.append(NSAttributedString(string: token.text, attributes: style))
                    if let word = token.w, model.pageModel.words.indices.contains(word), attributed.length > start {
                        spans.append(Span(range: NSRange(location: start, length: attributed.length - start), word: word))
                    }
                }
            }
            assert(zip(spans, spans.dropFirst()).allSatisfy { $0.word <= $1.word }, "Reading spans must retain backend word order")
            assert(spans.allSatisfy { NSMaxRange($0.range) <= attributed.length }, "Word mapping must use UTF-16 offsets")
            return (attributed, spans)
        }
    }
}

private final class ReaderScrollView: NSScrollView {
    var onManualScroll: (() -> Void)?

    override func scrollWheel(with event: NSEvent) {
        if event.scrollingDeltaY != 0 || event.scrollingDeltaX != 0 { onManualScroll?() }
        super.scrollWheel(with: event)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSScrollView.willStartLiveScrollNotification, object: self)
        if window != nil {
            NotificationCenter.default.addObserver(self, selector: #selector(manualScroll), name: NSScrollView.willStartLiveScrollNotification, object: self)
        }
    }

    @objc private func manualScroll() { onManualScroll?() }
}

final class JumpTextView: NSTextView {
    weak var coordinatorOwner: ReaderTextView.Coordinator?
    var readingMeasure: CGFloat = 680
    var stage = false
    private var contextWord: Int?

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutReadingColumn()
    }

    func layoutReadingColumn() {
        let gutter: CGFloat = stage ? 32 : 24
        let inset = NSSize(width: max(gutter, (bounds.width - readingMeasure) / 2), height: stage ? 24 : 28)
        if textContainerInset != inset { textContainerInset = inset }
    }

    private func word(at point: NSPoint) -> Int? {
        guard let manager = layoutManager, let container = textContainer, manager.numberOfGlyphs > 0 else { return nil }
        let local = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let glyph = manager.glyphIndex(for: local, in: container)
        guard glyph < manager.numberOfGlyphs,
              manager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).insetBy(dx: -1, dy: -1).contains(local) else { return nil }
        let index = manager.characterIndexForGlyph(at: glyph)
        let text = string as NSString
        guard index < text.length,
              !text.substring(with: text.rangeOfComposedCharacterSequence(at: index)).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return coordinatorOwner?.word(atCharacter: index)
    }

    override func mouseDown(with event: NSEvent) {
        let start = convert(event.locationInWindow, from: nil)
        var dragged = false
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDragged) { event in
            dragged = true
            return event
        }
        defer { if let monitor { NSEvent.removeMonitor(monitor) } }
        super.mouseDown(with: event)
        let end = convert(window?.mouseLocationOutsideOfEventStream ?? event.locationInWindow, from: nil)
        guard event.clickCount == 1, event.modifierFlags.intersection([.shift, .command, .option, .control]).isEmpty,
              !dragged, hypot(end.x - start.x, end.y - start.y) < 3, selectedRange().length == 0,
              let word = word(at: start) else { return }
        coordinatorOwner?.jump(word: word)
    }

    override func keyDown(with event: NSEvent) {
        let origin = visibleRect.origin
        super.keyDown(with: event)
        if visibleRect.origin != origin { coordinatorOwner?.detachFollowing() }
    }

    override func performTextFinderAction(_ sender: Any?) {
        if (sender as? NSMenuItem)?.tag != NSTextFinder.Action.hideFindInterface.rawValue {
            coordinatorOwner?.detachFollowing()
        }
        super.performTextFinderAction(sender)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        contextWord = selectedRange().length > 0
            ? coordinatorOwner?.word(atCharacter: selectedRange().location)
            : word(at: convert(event.locationInWindow, from: nil))
        if contextWord != nil {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            let item = NSMenuItem(title: "Read from here", action: #selector(readFromHere), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        return menu
    }

    @objc private func readFromHere() {
        if let contextWord { coordinatorOwner?.jump(word: contextWord) }
    }
}
