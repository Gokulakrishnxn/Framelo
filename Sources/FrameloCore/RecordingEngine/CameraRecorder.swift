@preconcurrency import AVFoundation
import CoreMedia
import Foundation

/// Records the webcam to its own file.
/// Concurrency: state is confined to `queue`, which is also the capture delegate queue (`@unchecked Sendable` invariant).
final class CameraRecorder: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.framelo.recorder.camera", qos: .userInitiated)
    private let clock: RecordingClock
    private let onFirstSample: @Sendable (Double) -> Void
    private let session = AVCaptureSession()
    private var writer: TrackWriter?
    private var url: URL?
    private var frameRate = 30
    private var running = false

    init(clock: RecordingClock, onFirstSample: @escaping @Sendable (Double) -> Void) {
        self.clock = clock
        self.onFirstSample = onFirstSample
    }

    func start(url: URL, deviceID: String?) throws {
        let device: AVCaptureDevice?
        if let deviceID, let chosen = AVCaptureDevice(uniqueID: deviceID) {
            device = chosen
        } else {
            device = AVCaptureDevice.default(for: .video)
        }
        guard let device else { throw RecordingError.sourceUnavailable("The camera") }
        let input = try AVCaptureDeviceInput(device: device)

        session.beginConfiguration()
        if session.canSetSessionPreset(.hd1280x720) { session.sessionPreset = .hd1280x720 }
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw RecordingError.sourceUnavailable("The camera")
        }
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            throw RecordingError.sourceUnavailable("The camera")
        }
        session.addOutput(output)
        session.commitConfiguration()

        let duration = device.activeVideoMinFrameDuration
        let fps = duration.isNumeric && duration.seconds > 0 ? Int((1 / duration.seconds).rounded()) : 30
        queue.sync {
            self.url = url
            self.frameRate = min(max(fps, 15), 60)
            self.running = true
        }
        session.startRunning()
        guard session.isRunning else {
            queue.sync { self.running = false }
            throw RecordingError.sourceUnavailable("The camera")
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard running, let pixelBuffer = sampleBuffer.imageBuffer else { return }
        var host = sampleBuffer.presentationTimeStamp
        if let source = session.synchronizationClock {
            host = CMSyncConvertTime(host, from: source, to: CMClockGetHostTimeClock())
        }
        guard let time = clock.sessionTime(forHost: host) else { return }
        if writer == nil, let url {
            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            let created = try? TrackWriter.video(url: url, width: width, height: height, frameRate: frameRate,
                                                 bitRate: max(3_000_000, width * height * 6))
            let firstSample = onFirstSample
            created?.onFirstSample = { firstSample($0.seconds) }
            writer = created
        }
        writer?.append(pixelBuffer: pixelBuffer, at: time)
    }

    func stop() async -> TrackResult? {
        session.stopRunning()
        let writer = queue.sync { () -> TrackWriter? in
            self.running = false
            let writer = self.writer
            self.writer = nil
            return writer
        }
        return await writer?.finish()
    }
}
