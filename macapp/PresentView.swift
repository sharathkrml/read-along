import AppKit
import SwiftUI

/// Focus continues the existing session; ReaderTextView owns all scrolling.
struct PresentView: View {
    @EnvironmentObject private var model: ReaderModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var chrome = true
    @State private var hideTask: Task<Void, Never>?
    @State private var pointerOverControls = false
    @State private var menuOpen = false
    @FocusState private var focusedControl: Control?

    private enum Control: Hashable { case exit, previous, transport, next, stop, returnToReading }

    var body: some View {
        ReaderTextView(stage: true)
            .background(ReaderTheme.canvas)
            .safeAreaInset(edge: .top, spacing: 0) { header }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 12) {
                    if !model.viewer.textFollows {
                        Button(action: model.returnToReading) {
                            Label("Return to reading", systemImage: "arrow.uturn.backward")
                        }
                        .focused($focusedControl, equals: .returnToReading)
                        .buttonStyle(.bordered)
                    }
                    presentBar
                        .opacity(chrome ? 1 : 0)
                        .allowsHitTesting(chrome)
                        .accessibilityHidden(!chrome)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
            }
            .background(FocusActivityMonitor(onActivity: revealControls))
            .preferredColorScheme(.dark)
            .onAppear(perform: revealControls)
            .onDisappear { hideTask?.cancel() }
            .onChange(of: model.transportState) { _, _ in revealControls() }
            .onChange(of: model.state.error) { _, _ in revealControls() }
            .onChange(of: focusedControl) { _, _ in revealControls() }
            .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in
                menuOpen = true
                revealControls()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)) { _ in
                menuOpen = false
                revealControls()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in revealControls() }
            .onExitCommand { model.exitPresent() }
    }

    private var microphoneActive: Bool {
        model.transportState == .listening || model.state.status == "listening"
    }

    private var header: some View {
        HStack(spacing: 16) {
            Text(model.activeDoc?.title ?? "Focus")
                .font(.headline)
                .foregroundStyle(ReaderTheme.secondaryText)
                .lineLimit(1)
                .opacity(chrome ? 1 : 0)
                .accessibilityHidden(!chrome)
            Spacer(minLength: 12)
            if microphoneActive {
                Label("Microphone on", systemImage: "mic.fill")
                    .font(.callout)
                    .foregroundStyle(ReaderTheme.primaryText)
                    .accessibilityLabel("Microphone active")
            }
            Button(action: model.exitPresent) {
                Label("Exit Focus", systemImage: "xmark")
            }
            .focused($focusedControl, equals: .exit)
            .buttonStyle(.bordered)
            .help("Exit Focus (Escape)")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(ReaderTheme.canvas)
        .onHover { hovering in pointerOverControls = hovering; revealControls() }
    }

    private var presentBar: some View {
        HStack(spacing: 16) {
            Button { model.movePhrase(-1) } label: {
                Label("Previous phrase", systemImage: "backward.end.fill")
            }
            .focused($focusedControl, equals: .previous)
            .help("Previous phrase (⌘[)")

            Button(action: model.togglePlay) {
                Label(model.transportTitle, systemImage: model.transportSymbol)
                    .frame(minWidth: 22, minHeight: 22)
            }
            .focused($focusedControl, equals: .transport)
            .buttonStyle(.borderedProminent)
            .help(model.transportTitle)
            .disabled(model.transportState == .stopping || model.wordsTotal == 0)

            Button { model.movePhrase(1) } label: {
                Label("Next phrase", systemImage: "forward.end.fill")
            }
            .focused($focusedControl, equals: .next)
            .help("Next phrase (⌘])")

            VStack(alignment: .leading, spacing: 3) {
                Text(model.transportTitle).font(.callout.weight(.medium))
                Text(model.transportSubtitle)
                    .font(.caption)
                    .foregroundStyle(ReaderTheme.secondaryText)
                    .lineLimit(2)
            }
            .frame(minWidth: 120, maxWidth: 250, alignment: .leading)
            .accessibilityElement(children: .combine)

            Text("\(Int(model.progressPercent))%")
                .font(.callout.monospacedDigit())
                .foregroundStyle(ReaderTheme.secondaryText)
                .accessibilityLabel("Reading progress, \(Int(model.progressPercent)) percent")

            Button(action: model.stopPlayback) {
                Label("Stop reading", systemImage: "stop.fill")
            }
            .focused($focusedControl, equals: .stop)
            .disabled(model.transportState == .idle)
            .help("Stop reading")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .foregroundStyle(ReaderTheme.primaryText)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(ReaderTheme.raised, in: RoundedRectangle(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(ReaderTheme.separator) }
        .fixedSize(horizontal: false, vertical: true)
        .onHover { hovering in pointerOverControls = hovering; revealControls() }
    }

    private var mayHideControls: Bool {
        model.transportState == .playing && focusedControl == nil && !pointerOverControls && !menuOpen
            && (model.state.error ?? "").isEmpty && model.toast?.isError != true
    }

    private func revealControls() {
        hideTask?.cancel()
        chrome = true
        guard mayHideControls else { return }
        hideTask = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(2500)) } catch { return }
            guard !Task.isCancelled, mayHideControls else { return }
            // Native Find fields, sheets, and popovers must keep their controls visible.
            if NSApp.windows.contains(where: { $0.isVisible && ($0 is NSPanel || $0.attachedSheet != nil) }) { return }
            if let text = NSApp.keyWindow?.firstResponder as? NSTextView,
               text.isFieldEditor || text.selectedRange().length > 0 { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) { chrome = false }
        }
    }
}

/// Observe activity without stealing a text click, drag, Find key, or scroll event.
private struct FocusActivityMonitor: NSViewRepresentable {
    var onActivity: () -> Void

    func makeNSView(context: Context) -> ActivityView {
        let view = ActivityView()
        view.onActivity = onActivity
        return view
    }

    func updateNSView(_ view: ActivityView, context: Context) { view.onActivity = onActivity }

    static func dismantleNSView(_ view: ActivityView, coordinator: ()) { view.stopMonitoring() }

    final class ActivityView: NSView {
        var onActivity: (() -> Void)?
        private var monitor: Any?
        private weak var monitoredWindow: NSWindow?
        private var acceptedMouseMoved = false

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard let window else { return }
            monitoredWindow = window
            acceptedMouseMoved = window.acceptsMouseMovedEvents
            window.acceptsMouseMovedEvents = true
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .rightMouseDown, .keyDown, .scrollWheel]) { [weak self] event in
                if event.window === self?.monitoredWindow { self?.onActivity?() }
                return event
            }
        }

        func stopMonitoring() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            monitoredWindow?.acceptsMouseMovedEvents = acceptedMouseMoved
            monitoredWindow = nil
        }
    }
}
