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
        HStack(spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "text.book.closed.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(ReaderTheme.accent)
                Text(model.activeDoc?.title ?? "Focus")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(ReaderTheme.secondaryText)
                    .lineLimit(1)
            }
            .opacity(chrome ? 1 : 0)
            .accessibilityHidden(!chrome)
            Spacer(minLength: 12)
            if microphoneActive {
                HStack(spacing: 6) {
                    Circle().fill(ReaderTheme.accent).frame(width: 5, height: 5)
                    Text("Microphone on")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(ReaderTheme.primaryText)
                }
                .accessibilityLabel("Microphone active")
            }
            Button(action: model.exitPresent) {
                Label("Exit Focus", systemImage: "xmark")
                    .font(.system(size: 11.5, weight: .medium))
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background(ReaderTheme.raised, in: Capsule(style: .continuous))
                    .overlay {
                        Capsule(style: .continuous)
                            .strokeBorder(ReaderTheme.hairline, lineWidth: 1)
                    }
            }
            .buttonStyle(.plain)
            .focused($focusedControl, equals: .exit)
            .help("Exit Focus (Escape)")
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
        .background(ReaderTheme.canvas)
        .overlay(alignment: .bottom) {
            Rectangle().fill(ReaderTheme.hairline).frame(height: 1)
        }
        .onHover { hovering in pointerOverControls = hovering; revealControls() }
    }

    private var presentBar: some View {
        HStack(spacing: 14) {
            Button { model.movePhrase(-1) } label: {
                Image(systemName: "backward.end.fill")
                    .font(.system(size: 10))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(StudioIconButtonStyle(size: 30))
            .focused($focusedControl, equals: .previous)
            .help("Previous phrase (⌘[)")

            Button(action: model.togglePlay) {
                HStack(spacing: 7) {
                    Image(systemName: model.transportSymbol)
                        .font(.system(size: 10, weight: .semibold))
                    Text(model.isComplete ? "Read again" : model.transportState.isActive ? "Stop" : "Listen")
                }
            }
            .focused($focusedControl, equals: .transport)
            .buttonStyle(StudioPrimaryButtonStyle())
            .help(model.transportTitle)
            .disabled(model.transportState == .stopping || model.wordsTotal == 0)

            Button { model.movePhrase(1) } label: {
                Image(systemName: "forward.end.fill")
                    .font(.system(size: 10))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(StudioIconButtonStyle(size: 30))
            .focused($focusedControl, equals: .next)
            .help("Next phrase (⌘])")

            VStack(alignment: .leading, spacing: 2) {
                Text(model.transportTitle)
                    .font(.system(size: 12, weight: .medium))
                Text(model.transportSubtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(ReaderTheme.secondaryText)
                    .lineLimit(2)
            }
            .frame(minWidth: 140, maxWidth: 280, alignment: .leading)
            .accessibilityElement(children: .combine)

            Spacer(minLength: 6)

            Text("\(Int(model.progressPercent))%")
                .font(ReaderTheme.numeral(11, weight: .medium))
                .foregroundStyle(ReaderTheme.secondaryText)
                .accessibilityLabel("Reading progress, \(Int(model.progressPercent)) percent")

            Button(action: model.stopPlayback) {
                Image(systemName: "stop.fill")
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(StudioIconButtonStyle(size: 30))
            .focused($focusedControl, equals: .stop)
            .disabled(model.transportState == .idle)
            .help("Stop reading")
        }
        .foregroundStyle(ReaderTheme.primaryText)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassPanel(radius: 16)
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
