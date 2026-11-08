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
    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let outputQueue = DispatchQueue(label: "readalong.audio.capture")
    private var socketTask: URLSessionWebSocketTask?
    private(set) var isRunning = false

    /// Start capturing and streaming to `url` (e.g. ``ws://127.0.0.1:8011/audio``).
    /// Throws a clear error (never crashes) if the microphone can't be used.
    func start(to url: URL) async throws {
        guard !isRunning else { return }

        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        guard status == .authorized else {
            throw MicrophoneError.notAuthorized
        }

        guard let device = AVCaptureDevice.default(for: .audio) else {
            throw MicrophoneError.noInputDevice
        }

        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            throw MicrophoneError.tapInstallFailed(error.localizedDescription)
        }
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

        session.startRunning()

        let task = URLSession.shared.webSocketTask(with: url)
        task.resume()
        self.socketTask = task
        self.isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        session.stopRunning()
        socketTask?.cancel(with: .goingAway, reason: nil)
        socketTask = nil
        isRunning = false
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
        socketTask?.send(.data(pcmData)) { error in
            if let error {
                print("AudioCapture send error: \(error.localizedDescription)")
            }
        }
    }
}

enum MicrophoneError: LocalizedError {
    case notAuthorized
    case noInputDevice
    case noInputFormat
    case tapInstallFailed(String)

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
        }
    }
}
