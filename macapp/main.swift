import AVFoundation
import Cocoa
import UniformTypeIdentifiers
import WebKit

/// A small native shell: own the window and the lifecycle, run the Python
/// backend (OCR + speech + local web UI) from inside the bundle, and point a
/// WKWebView at it.
final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKUIDelegate {
    private var window: NSWindow!
    private var webView: WKWebView!
    private var backend: Process?
    private var port = 0
    private var dataURL: URL!
    private var logURL: URL!
    private var quitting = false
    private var activity: NSObjectProtocol?

    // MARK: lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // OCR and the speech model are long GPU jobs; App Nap must not
        // throttle them when the window is behind another app.
        activity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Reading a document and listening for speech"
        )
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        dataURL = support.appendingPathComponent("ReadAlong", isDirectory: true)
        try? FileManager.default.createDirectory(at: dataURL, withIntermediateDirectories: true)

        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        logURL = library.appendingPathComponent("Logs/ReadAlong/backend.log")
        try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        buildMenu()
        buildWindow()
        primeMicrophone()
        startBackend()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        quitting = true
        stopBackend()
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
    }

    // MARK: window + menu

    private func buildWindow() {
        let rect = NSRect(x: 0, y: 0, width: 1360, height: 900)
        window = NSWindow(
            contentRect: rect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "ReadAlong"
        window.minSize = NSSize(width: 900, height: 600)
        window.setFrameAutosaveName("ReadAlongMain")
        window.center()

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        webView = WKWebView(frame: rect, configuration: config)
        webView.autoresizingMask = [.width, .height]
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.underPageBackgroundColor = NSColor(red: 0.059, green: 0.067, blue: 0.082, alpha: 1)
        webView.loadHTMLString(Self.placeholder, baseURL: nil)

        window.contentView = webView
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About ReadAlong", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Open Data Folder", action: #selector(openDataFolder), keyEquivalent: "").target = self
        appMenu.addItem(withTitle: "Show Log", action: #selector(showLog), keyEquivalent: "").target = self
        appMenu.addItem(withTitle: "Microphone Access…", action: #selector(openMicrophoneSettings), keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide ReadAlong", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit ReadAlong", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(withTitle: "Reload", action: #selector(reload), keyEquivalent: "r").target = self
        viewMenu.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
            .keyEquivalentModifierMask = [.command, .control]
        viewItem.submenu = viewMenu
        main.addItem(viewItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu
    }

    @objc private func openDataFolder() { NSWorkspace.shared.open(dataURL) }
    @objc private func showLog() { NSWorkspace.shared.open(logURL) }
    @objc private func reload() { webView.reload() }

    @objc private func openMicrophoneSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
        NSWorkspace.shared.open(url)
    }

    /// Ask once at launch so TCC records ReadAlong as the owner of the mic,
    /// not the bundled python child process.
    private func primeMicrophone() {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        }
    }

    // MARK: backend

    private func startBackend() {
        guard let resource = Bundle.main.resourceURL else {
            return showError("The app bundle is incomplete.")
        }
        let backendDir = resource.appendingPathComponent("backend", isDirectory: true)
        let python = backendDir.appendingPathComponent("python/bin/python3.12")
        let script = backendDir.appendingPathComponent("readalong.py")
        let site = backendDir.appendingPathComponent("site-packages", isDirectory: true)

        guard FileManager.default.isExecutableFile(atPath: python.path) else {
            return showError("The bundled Python runtime is missing.\n\(python.path)")
        }
        guard let freePort = Self.freePort() else {
            return showError("Could not reserve a local port.")
        }
        port = freePort

        let process = Process()
        process.executableURL = python
        process.arguments = ["-u", script.path, "--no-browser", "--port", "\(port)"]
        var env = ProcessInfo.processInfo.environment
        env["PYTHONPATH"] = site.path
        env["PYTHONUNBUFFERED"] = "1"
        env["READALONG_DATA"] = dataURL.path
        env["READALONG_FERMION"] = backendDir.appendingPathComponent("fermion_main.py").path
        process.environment = env
        process.currentDirectoryURL = backendDir

        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        if let log = try? FileHandle(forWritingTo: logURL) {
            log.seekToEndOfFile()
            process.standardOutput = log
            process.standardError = log
        }

        process.terminationHandler = { [weak self] proc in
            guard let self, !self.quitting, proc.terminationStatus != 0 else { return }
            DispatchQueue.main.async {
                self.showError("The ReadAlong engine stopped unexpectedly.\n\n\(Self.tail(self.logURL))")
            }
        }

        do {
            try process.run()
            backend = process
            waitForServer(attempt: 0)
        } catch {
            showError("Could not start the ReadAlong engine.\n\n\(error.localizedDescription)")
        }
    }

    private func stopBackend() {
        guard let process = backend, process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning && Date() < deadline {
            usleep(100_000)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        backend = nil
    }

    private func waitForServer(attempt: Int) {
        guard let url = URL(string: "http://127.0.0.1:\(port)/state") else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1
        URLSession.shared.dataTask(with: request) { [weak self] _, response, _ in
            guard let self else { return }
            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                DispatchQueue.main.async {
                    self.webView.load(URLRequest(url: URL(string: "http://127.0.0.1:\(self.port)/")!))
                }
            } else if attempt < 300 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    self.waitForServer(attempt: attempt + 1)
                }
            } else {
                DispatchQueue.main.async {
                    self.showError("The ReadAlong engine did not start.\n\n\(Self.tail(self.logURL))")
                }
            }
        }.resume()
    }

    private func showError(_ message: String) {
        let escaped = message
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let html = """
        <!doctype html><html><head><meta charset="utf-8"><style>
        body{margin:0;min-height:100vh;display:grid;place-items:center;background:#0f1115;color:#e8e6e3;
        font:14px/1.6 -apple-system,BlinkMacSystemFont,sans-serif}
        main{max-width:760px;padding:32px}pre{white-space:pre-wrap;color:#8b93a1;font-size:12px;
        background:#171a21;border:1px solid #252a34;border-radius:10px;padding:16px;max-height:50vh;overflow:auto}
        h1{font-size:18px;margin:0 0 12px}</style></head><body><main><h1>ReadAlong</h1>
        <p>\(escaped.replacingOccurrences(of: "\n", with: "<br>"))</p></main></body></html>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }

    private static func tail(_ url: URL, lines: Int = 24) -> String {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return text.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines).joined(separator: "\n")
    }

    private static func freePort() -> Int? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        let length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, length)
            }
        }
        guard bound == 0 else { return nil }
        var result = sockaddr_in()
        var resultLength = length
        let named = withUnsafeMutablePointer(to: &result) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &resultLength)
            }
        }
        guard named == 0 else { return nil }
        return Int(UInt16(bigEndian: result.sin_port))
    }

    // MARK: web view

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image, .pdf]
        panel.begin { response in
            completionHandler(response == .OK ? panel.urls : nil)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled {
            showError(error.localizedDescription)
        }
    }

    private static let placeholder = """
    <!doctype html><html><head><meta charset="utf-8"><style>
    body{margin:0;height:100vh;display:grid;place-items:center;background:#0f1115;color:#8b93a1;
    font:14px -apple-system,BlinkMacSystemFont,sans-serif}</style></head>
    <body>Starting ReadAlong…</body></html>
    """
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
