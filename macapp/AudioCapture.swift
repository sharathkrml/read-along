import AVFoundation
import CoreMedia
import Foundation

/// Captures microphone audio with AVCaptureSession and streams PCM (float32,
/// mono, 16 kHz) to the Python backend over a WebSocket.
///
/// The Swift app owns the microphone permission (``NSMicrophoneUsageDescription``
/// plus the ``com.apple.security.device.audio-input`` entitlement) and already
/// requests access via ``AVCaptureDevice.requestAccess(for:)``. By capturing
/// here — instead of in the bundled Python child process — TCC attributes
/// microphone access to Read Along and the system permission prompt appears.
///
/// Uses ``AVCaptureAudioDataOutput`` with delegate callbacks instead of
/// ``AVAudioEngine.installTap``: on macOS ``installTap`` can throw an uncaught
/// Objective-C ``NSException`` (not an NSError) when there is no usable input,
/// which would crash the app. The delegate-based API never crashes.
final class AudioCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private var session = AVCaptureSession()
    private var output = AVCaptureAudioDataOutput()
    private let outputQueue = DispatchQueue(label: "readalong.audio.capture")
    private var socketTask: URLSessionWebSocketTask?
    private var runtimeObserver: NSObjectProtocol?
    private var failureReported = false
    private(set) var isRunning = false
    /// AVFoundation uniqueID of the input in this session, nil when stopped.
    private(set) var deviceID: String?

    /// True only while the session is live and still owns a running input.
    var isCapturing: Bool { isRunning && session.isRunning }

    /// Called on the main queue when capture or the PCM socket dies mid-session.
    var onFailure: ((String) -> Void)?

    /// Start capturing and streaming to `url` (the backend's echo of
    /// ``state.audio_port``, e.g. ``ws://127.0.0.1:54321/audio``).
    /// Returns the uniqueID of the device actually used. Throws a clear error
    /// (never crashes) if the microphone can't be used.
    @discardableResult
    func start(to url: URL, deviceID: String? = nil) async throws -> String {
        guard !isRunning else { return self.deviceID ?? "" }

        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        guard status == .authorized else {
            throw MicrophoneError.notAuthorized
        }

        // An explicit selection that just disappeared falls back to system
        // default rather than failing the whole reading session.
        guard let device = Self.inputDevice(id: deviceID) else {
            throw MicrophoneError.noInputDevice
        }

        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            throw MicrophoneError.tapInstallFailed(error.localizedDescription)
        }

        // A fresh session per run: stop() leaves the old one configured, and
        // re-adding its input/output (or starting an interrupted session again)
        // made the second Follow me fail with "Try again".
        let session = AVCaptureSession()
        let output = AVCaptureAudioDataOutput()

        guard session.canAddInput(input) else {
            throw MicrophoneError.noInputFormat
        }
        session.addInput(input)

        // Request float32 mono 16 kHz PCM — the format the local fermion
        // speech server expects.
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: 16000,
        ]
        guard session.canAddOutput(output) else {
            throw MicrophoneError.noInputFormat
        }
        session.addOutput(output)

        output.setSampleBufferDelegate(self, queue: outputQueue)

        self.session = session
        self.output = output
        session.startRunning()

        let task = URLSession.shared.webSocketTask(with: url)
        task.resume()
        self.socketTask = task
        self.deviceID = device.uniqueID
        self.failureReported = false
        self.isRunning = true
        self.runtimeObserver = NotificationCenter.default.addObserver(
            forName: .AVCaptureSessionRuntimeError,
            object: session,
            queue: .main
        ) { [weak self] note in
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? Error
            self?.reportFailure(
                error?.localizedDescription ?? "The microphone input stopped."
            )
        }
        return device.uniqueID
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        if let runtimeObserver {
            NotificationCenter.default.removeObserver(runtimeObserver)
            self.runtimeObserver = nil
        }
        session.stopRunning()
        socketTask?.cancel(with: .goingAway, reason: nil)
        socketTask = nil
        deviceID = nil
    }

    private static func inputDevice(id: String?) -> AVCaptureDevice? {
        if let id, let device = AVCaptureDevice(uniqueID: id) {
            return device
        }
        if let device = AVCaptureDevice.default(for: .audio) {
            return device
        }
        // CoreAudio can briefly report no default while switching inputs; any
        // attached microphone is better than failing the whole session.
        return AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone],
            mediaType: .audio,
            position: .unspecified
        ).devices.first
    }

    private func reportFailure(_ message: String) {
        guard isRunning, !failureReported else { return }
        failureReported = true
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isRunning else { return }
            self.onFailure?(message)
        }
    }

    // MARK: - AVCaptureAudioDataOutputSampleBufferDelegate

    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard isRunning,
              let dataBuffer = sampleBuffer.dataBuffer
        else { return }

        var length: Int = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(
            dataBuffer,
            atOffset: 0,
            lengthAtOffsetOut: &length,
            totalLengthOut: nil,
            dataPointerOut: &dataPointer
        )
        guard status == noErr, let dataPointer else { return }

        let pcmData = Data(bytes: dataPointer, count: length)
        socketTask?.send(.data(pcmData)) { [weak self] error in
            guard let error else { return }
            print("AudioCapture send error: \(error.localizedDescription)")
            self?.reportFailure("The microphone audio stream stopped. Start Follow me again.")
        }
    }
}

enum MicrophoneError: LocalizedError {
    case notAuthorized
    case noInputDevice
    case noInputFormat
    case tapInstallFailed(String)
    case audioRelayUnavailable

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "Microphone access is not authorized. Allow Read Along in System Settings → Privacy & Security → Microphone."
        case .noInputDevice:
            return "No microphone input device was found."
        case .noInputFormat:
            return "The microphone input has no usable audio format."
        case .tapInstallFailed(let msg):
            return "Could not start microphone capture: \(msg)"
        case .audioRelayUnavailable:
            return "The local audio relay is not ready. Try again in a moment."
        }
    }
}
