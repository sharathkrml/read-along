import AVFoundation
import Cocoa

/// Owns only the bundled Python process; an override URL is never terminated.
@MainActor
final class BackendService: ObservableObject {
    static let shared = BackendService()

    @Published var baseURL: URL?
    @Published var startupError: String?
    @Published var ready = false


    private var process: Process?
    private let dataURL: URL
    private let logURL: URL
    private var logHandle: FileHandle?
    private var readinessTask: Task<Void, Never>?
    private var stoppingTask: Task<Void, Never>?
    private var restartTask: Task<Void, Never>?
    private var connectionGeneration = 0
    private var quitting = false
    private var storageError: String?

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        dataURL = ProcessInfo.processInfo.environment["READALONG_DATA"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? support.appendingPathComponent("ReadAlong", isDirectory: true)
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        logURL = library.appendingPathComponent("Logs/ReadAlong/backend.log")
        do {
            try FileManager.default.createDirectory(at: dataURL, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            storageError = "Read Along could not prepare its local storage. Check available space and folder permissions, then retry."
        }
    }

    /// Dev escape hatch: point the UI at an already-running backend and skip
    /// launching the bundled interpreter. `READALONG_URL=http://127.0.0.1:8765 make ui`
    private var overrideURL: URL? {
        if let raw = ProcessInfo.processInfo.environment["READALONG_URL"], !raw.isEmpty {
            return URL(string: raw)
        }
        return nil
    }

    func start() {
        guard baseURL == nil, process == nil, stoppingTask == nil, restartTask == nil else { return }
        quitting = false
        startupError = nil
        ready = false
        if let storageError {
            startupError = storageError
            return
        }
        if let override = overrideURL {
            baseURL = override
            waitUntilReady()
            return
        }
        guard let resource = Bundle.main.resourceURL else {
            startupError = "The app bundle is incomplete."
            return
        }
        let backendDir = resource.appendingPathComponent("backend", isDirectory: true)
        let python = backendDir.appendingPathComponent("python/bin/python3.12")
        let script = backendDir.appendingPathComponent("readalong.py")
        let site = backendDir.appendingPathComponent("site-packages", isDirectory: true)

        guard FileManager.default.isExecutableFile(atPath: python.path) else {
            startupError = "The bundled reading engine is missing. Reinstall Read Along; your saved library is not removed."
            return
        }
        guard FileManager.default.fileExists(atPath: script.path) else {
            startupError = "The app bundle is incomplete. Reinstall Read Along; your saved library is not removed."
            return
        }
        guard let freePort = Self.freePort() else {
            startupError = "Could not reserve a local port."
            return
        }

        let process = Process()
        process.executableURL = python
        process.arguments = ["-u", script.path, "--port", "\(freePort)"]
        var env = ProcessInfo.processInfo.environment
        env["PYTHONPATH"] = site.path
        env["PYTHONUNBUFFERED"] = "1"
        env["READALONG_DATA"] = dataURL.path
        env["READALONG_FERMION"] = backendDir.appendingPathComponent("fermion_main.py").path
        process.environment = env
        process.currentDirectoryURL = backendDir

        do {
            if !FileManager.default.fileExists(atPath: logURL.path) {
                guard FileManager.default.createFile(atPath: logURL.path, contents: nil) else {
                    startupError = "Read Along could not create its diagnostics log. Check available space and folder permissions, then retry."
                    return
                }
            }
            let log = try FileHandle(forWritingTo: logURL)
            try log.seekToEnd()
            logHandle = log
            process.standardOutput = log
            process.standardError = log
        } catch {
            startupError = "Read Along could not open its diagnostics log. Check available space and folder permissions, then retry."
            return
        }

        process.terminationHandler = { [weak self] proc in
            Task { @MainActor in
                guard let self, self.process === proc, !self.quitting else { return }
                self.process = nil
                self.resetConnection()
                self.closeLog()
                self.startupError = "The reading engine disconnected. Retry to reconnect; your saved documents have not been removed."
            }
        }

        do {
            try process.run()
            self.process = process
            baseURL = URL(string: "http://127.0.0.1:\(freePort)")
            waitUntilReady()
        } catch {
            closeLog()
            startupError = "Could not start the reading engine. Retry, or open diagnostics for more information."
        }
    }

    /// Reset readiness before waiting for the old owned process to exit.
    func restart() {
        guard restartTask == nil else { return }
        quitting = false
        resetConnection()
        startupError = nil
        let stopped = terminateOwnedProcess()
        restartTask = Task { [weak self] in
            await stopped?.value
            guard let self else { return }
            self.restartTask = nil
            guard !Task.isCancelled, !self.quitting else { return }
            self.start()
        }
    }

    func stop() {
        quitting = true
        restartTask?.cancel()
        resetConnection()
        _ = terminateOwnedProcess()
    }

    func stopAndWait() async {
        stop()
        await stoppingTask?.value
    }

    private func resetConnection() {
        connectionGeneration += 1
        readinessTask?.cancel()
        readinessTask = nil
        ready = false
        baseURL = nil
    }

    private func terminateOwnedProcess() -> Task<Void, Never>? {
        guard let owned = process else { return stoppingTask }
        process = nil
        owned.terminationHandler = nil
        closeLog()
        guard owned.isRunning else { return stoppingTask }
        owned.terminate()
        stoppingTask = Task { [weak self] in
            let deadline = Date().addingTimeInterval(5)
            while owned.isRunning && Date() < deadline {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            if owned.isRunning { kill(owned.processIdentifier, SIGKILL) }
            self?.stoppingTask = nil
        }
        return stoppingTask
    }

    private func closeLog() {
        try? logHandle?.close()
        logHandle = nil
    }

    private func waitUntilReady() {
        guard let base = baseURL else { return }
        let generation = connectionGeneration
        readinessTask?.cancel()
        readinessTask = Task { [weak self] in
            for _ in 0..<600 {
                guard let self, !Task.isCancelled, !self.quitting,
                      generation == self.connectionGeneration, self.baseURL == base else { return }
                var request = URLRequest(url: base.appendingPathComponent("state"))
                request.timeoutInterval = 1
                if let (data, response) = try? await URLSession.shared.data(for: request),
                   let http = response as? HTTPURLResponse, http.statusCode == 200, !data.isEmpty,
                   !Task.isCancelled, generation == self.connectionGeneration, !self.quitting {
                    self.startupError = nil
                    self.ready = true
                    self.readinessTask = nil
                    return
                }
                do { try await Task.sleep(nanoseconds: 150_000_000) }
                catch { return }
            }
            guard let self, generation == self.connectionGeneration, !self.quitting else { return }
            self.readinessTask = nil
            self.startupError = "The reading engine is taking too long to start. Retry, or open diagnostics for more information."
        }
    }

    @objc func openDataFolder() { NSWorkspace.shared.open(dataURL) }
    @objc func showLog() {
        let alert = NSAlert()
        alert.messageText = "Open private diagnostics?"
        alert.informativeText = "The local engine log may contain document text, recognized speech, and private file paths. Review it before sharing."
        alert.addButton(withTitle: "Open Log")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(logURL) }
    }
    @objc func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
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
}

/// Call only for an explicit, still-current Follow me intent so TCC attributes
/// microphone access to Read Along rather than its Python child.
func requestMicrophonePermission() async -> Bool {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized: return true
    case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
    case .denied, .restricted: return false
    @unknown default: return false
    }
}
