import AVFoundation
import Cocoa
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var keyMonitor: Any?
    private var clickMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Bare-binary builds show up as accessory apps without this.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        BackendService.shared.start()
        // Let the custom title bar use the full window height so the traffic
        // lights share the same row as the app mark. The window is created
        // after applicationDidFinishLaunching, so wait for it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.configureWindowChrome()
        }
        NotificationCenter.default.addObserver(self, selector: #selector(windowDidBecomeKey(_:)),
                                               name: NSWindow.didBecomeKeyNotification, object: nil)
        // Reader-context keys only. A menu key equivalent would also steal
        // spaces and brackets while the user is typing in search or the editor.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { Self.handleReaderKey(event) }
        }
        // Arrow keys stay with the source pane until the user clicks elsewhere.
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            MainActor.assumeIsolated {
                guard let active = SourceFocus.active else { return }
                let inside = event.window === active.window
                    && active.bounds.contains(active.convert(event.locationInWindow, from: nil))
                if !inside { SourceFocus.active = nil }
            }
            return event
        }
    }

    private func configureWindowChrome() {
        for window in NSApp.windows where window.title == "Read Along" {
            window.styleMask.insert(.fullSizeContentView)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.titlebarSeparatorStyle = .none
        }
    }

    @objc private func windowDidBecomeKey(_ note: Notification) {
        guard let window = note.object as? NSWindow, window.title == "Read Along" else { return }
        configureWindowChrome()
    }

    @MainActor
    private static func handleReaderKey(_ event: NSEvent) -> NSEvent? {
        guard !event.isARepeat,
              event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
              let window = event.window, window == NSApp.mainWindow,
              window.attachedSheet == nil,
              let responder = window.firstResponder,
              !(responder is NSControl),
              !((responder as? NSTextView)?.isEditable ?? false) else { return event }
        if event.keyCode == 123 || event.keyCode == 124,
           let source = SourceFocus.active, source.window === window {
            if event.keyCode == 123 { source.controller?.goPrev() } else { source.controller?.goNext() }
            return nil
        }
        let model = ReaderModel.shared
        guard model.canRead else { return event }
        switch event.charactersIgnoringModifiers {
        case " ": model.togglePlay(); return nil
        case "[": model.movePhrase(-1); return nil
        case "]": model.movePhrase(1); return nil
        default: return event
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        ReaderModel.shared.flushForTermination()
        BackendService.shared.stop()
    }
}

extension ReaderModel {
    /// Export the currently shown page as a JPEG via a native save panel.
    /// `mode` is "proof" (all word boxes) or "read" (current reading highlight).
    func exportPage(mode: String = "proof") {
        let capturedDoc = activeDoc?.id ?? state.doc_id
        let capturedPage = displayPage
        let capturedMode = mode
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.jpeg]
        panel.nameFieldStringValue = "read-along-page-\(capturedPage + 1)-\(capturedMode).jpg"
        panel.begin { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            Task { [weak self] in
                guard let self else { return }
                do {
                    guard let data = try await self.exportJPEG(page: capturedPage, mode: capturedMode, docID: capturedDoc) else {
                        await MainActor.run { self.showToast("Couldn’t export that page", isError: true) }
                        return
                    }
                    try data.write(to: url, options: .atomic)
                    await MainActor.run {
                        self.showToast("Exported “\(url.lastPathComponent)”")
                        self.feedback(.success)
                    }
                } catch {
                    await MainActor.run { self.showToast("Couldn’t export: \(error.localizedDescription)", isError: true) }
                }
            }
        }
    }
}

@main
struct ReadAlongApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = ReaderModel.shared

    var body: some Scene {
        Window("Read Along", id: "main") {
            ContentView()
                .environmentObject(model)
        }
        .defaultSize(width: 1320, height: 880)
        .windowResizability(.contentMinSize)
        .windowStyle(.hiddenTitleBar)
        .commands { readerCommands }

        Settings {
            SettingsView()
                .environmentObject(model)
        }
    }

    @CommandsBuilder
    private var readerCommands: some Commands {
        CommandGroup(after: .newItem) {
            Button("Import Document…") { ReaderModel.shared.importDocument() }
                .keyboardShortcut("o")
            Button("Export Page as JPEG…") {
                ReaderModel.shared.exportPage()
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
        }

        CommandGroup(replacing: .help) {
            Button("Read Along Help") {
                let alert = NSAlert()
                alert.messageText = "Read Along shortcuts"
                alert.informativeText = """
                Space: play/pause or listen in reader/source canvas (not while typing)
                [ / ] in the reading canvas, or Cmd+[ / Cmd+]: previous/next phrase
                Left/Right: browse source pages when source owns input
                Cmd+O: import document
                Cmd+E: edit text
                Shift+Cmd+E: export page as JPEG
                Cmd+1/2/3: Text / Original / Split
                Shift+Cmd+F: Focus
                Cmd+F: Find (in text)
                Cmd+Plus/Minus/Equals: zoom focused pane
                """
                alert.alertStyle = .informational
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        }

        CommandMenu("Reader") {
            Button(ReaderModel.shared.playLabel) {
                ReaderModel.shared.togglePlay()
            }
            .disabled(ReaderModel.shared.pageModel.words.isEmpty)
            Divider()
            Button("Text View") { ReaderModel.shared.expandedPane = .text }
                .keyboardShortcut("1", modifiers: .command)
                .disabled(ReaderModel.shared.pageModel.words.isEmpty)
            Button("Original View") { ReaderModel.shared.expandedPane = .original }
                .keyboardShortcut("2", modifiers: .command)
            Button("Split View") { ReaderModel.shared.expandedPane = nil }
                .keyboardShortcut("3", modifiers: .command)
                .disabled(ReaderModel.shared.pageModel.words.isEmpty)
            Divider()
            Button("Previous Phrase") { ReaderModel.shared.movePhrase(-1) }
                .keyboardShortcut("[", modifiers: .command)
            Button("Next Phrase") { ReaderModel.shared.movePhrase(1) }
                .keyboardShortcut("]", modifiers: .command)
            Divider()
            Button("Focus") { ReaderModel.shared.enterPresent() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(ReaderModel.shared.pageModel.words.isEmpty)
            Button("Edit Text") { ReaderModel.shared.showEdit = true }
                .keyboardShortcut("e")
                .disabled(ReaderModel.shared.pageModel.words.isEmpty)
        }

    }
}

extension ReaderModel {
    /// Label for the Reader ▸ Play / Pause menu item.
    var playLabel: String {
        return isPlaying ? "Stop Listening" : "Listen"
    }
}
