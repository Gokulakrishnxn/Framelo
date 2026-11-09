@preconcurrency import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
@preconcurrency import ScreenCaptureKit

/// Captures the screen (and system audio) with ScreenCaptureKit and writes them to disk.
///
/// Concurrency: all mutable state is confined to `queue`, which is also the queue ScreenCaptureKit delivers
/// samples on. That confinement is the invariant behind `@unchecked Sendable`.
final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    struct Prepared: Sendable {
        var capture: CaptureInfo
        var pixelWidth: Int
        var pixelHeight: Int
    }

    private let queue = DispatchQueue(label: "app.framelo.recorder.screen", qos: .userInitiated)
    private let clock: RecordingClock
    private let onFirstSample: @Sendable (RecordingJournal.TrackKind, Double) -> Void
    private let onInterruption: @Sendable (String) -> Void

    private var stream: SCStream?
    private var video: TrackWriter?
    private var audio: TrackWriter?
    private var audioURL: URL?
    private var lastPixelBuffer: CVPixelBuffer?
    private var firstFrameWaiter: CheckedContinuation<Void, Error>?
    private var stopping = false

    init(clock: RecordingClock,
         onFirstSample: @escaping @Sendable (RecordingJournal.TrackKind, Double) -> Void,
         onInterruption: @escaping @Sendable (String) -> Void) {
        self.clock = clock
        self.onFirstSample = onFirstSample
        self.onInterruption = onInterruption
    }

    /// Builds the content filter and stream, and creates the writers. Capture has not started yet.
    func prepare(config: RecordingConfig, videoURL: URL, audioURL: URL?) async throws -> Prepared {
        let content = try await CaptureCatalog.shareableContent()
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let ownApps = content.applications.filter { $0.processID == ownPID }

        let filter: SCContentFilter
        let streamConfig = SCStreamConfiguration()
        var captureRect: CGRect
        var scale: CGFloat

        switch config.target {
        case .display(let id):
            guard let display = content.displays.first(where: { $0.displayID == id }) else {
                throw RecordingError.sourceUnavailable("The selected display")
            }
            filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
            captureRect = CGDisplayBounds(id)
            scale = CGFloat(filter.pointPixelScale)
        case .region(let displayID, let x, let y, let width, let height):
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                throw RecordingError.sourceUnavailable("The selected display")
            }
            filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
            let bounds = CGDisplayBounds(displayID)
            let local = CGRect(x: x, y: y, width: width, height: height)
                .intersection(CGRect(origin: .zero, size: bounds.size))
            guard local.width >= 32, local.height >= 32 else { throw RecordingError.sourceUnavailable("The selected region") }
            streamConfig.sourceRect = local
            captureRect = local.offsetBy(dx: bounds.minX, dy: bounds.minY)
            scale = CGFloat(filter.pointPixelScale)
        case .window(let id):
            guard let window = content.windows.first(where: { $0.windowID == id }) else {
                throw RecordingError.sourceUnavailable("The selected window")
            }
            filter = SCContentFilter(desktopIndependentWindow: window)
            captureRect = window.frame
            scale = CGFloat(filter.pointPixelScale)
        }
        if scale <= 0 { scale = 2 }

        var pixelWidth = captureRect.width * scale
        var pixelHeight = captureRect.height * scale
        if let maxHeight = config.resolution.maxHeight, pixelHeight > CGFloat(maxHeight) {
            let factor = CGFloat(maxHeight) / pixelHeight
            pixelWidth *= factor
            pixelHeight *= factor
        }
        let width = max(2, Int(pixelWidth / 2) * 2)
        let height = max(2, Int(pixelHeight / 2) * 2)

        streamConfig.width = width
        streamConfig.height = height
        streamConfig.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(config.frameRate))
        streamConfig.pixelFormat = kCVPixelFormatType_32BGRA
        streamConfig.colorSpaceName = CGColorSpace.sRGB
        // The cursor is recorded separately and drawn (smoothed, resized) by the renderer.
        streamConfig.showsCursor = false
        streamConfig.queueDepth = 6
        streamConfig.capturesAudio = config.captureSystemAudio
        streamConfig.excludesCurrentProcessAudio = true
        streamConfig.sampleRate = 48_000
        streamConfig.channelCount = 2

        let videoWriter = try TrackWriter.video(url: videoURL, width: width, height: height, frameRate: config.frameRate)
        let stream = SCStream(filter: filter, configuration: streamConfig, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if config.captureSystemAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        }

        let firstSample = onFirstSample
        queue.sync {
            self.stream = stream
            self.video = videoWriter
            self.audioURL = config.captureSystemAudio ? audioURL : nil
            videoWriter.onFirstSample = { firstSample(.screen, $0.seconds) }
        }
        return Prepared(capture: CaptureInfo(x: captureRect.minX, y: captureRect.minY,
                                             width: captureRect.width, height: captureRect.height, scale: Double(scale)),
                        pixelWidth: width, pixelHeight: height)
    }

    /// Starts the stream. Returns once ScreenCaptureKit reports the stream as started.
    func startCapture() async throws {
        guard let stream = queue.sync(execute: { self.stream }) else { throw RecordingError.notRecording }
        try await stream.startCapture()
    }

    /// Suspends until the first frame has actually been written to disk, or fails after `timeout`.
    func waitForFirstFrame(timeout: Double = 6) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                if (self.video?.sampleCount ?? 0) > 0 {
                    continuation.resume()
                    return
                }
                self.firstFrameWaiter = continuation
                self.queue.asyncAfter(deadline: .now() + timeout) {
                    if let waiter = self.firstFrameWaiter {
                        self.firstFrameWaiter = nil
                        waiter.resume(throwing: RecordingError.noFramesReceived)
                    }
                }
            }
        }
    }

    /// Stops capture and closes the files.
    func stop(endTime: CMTime) async -> (video: TrackResult?, audio: TrackResult?, failure: String?) {
        let stream = queue.sync { () -> SCStream? in
            self.stopping = true
            return self.stream
        }
        try? await stream?.stopCapture()
        // Samples already queued are drained before the writers are closed.
        let (video, audio) = queue.sync { () -> (TrackWriter?, TrackWriter?) in
            // Hold the last picture until the end so the video is as long as the session, even on a static screen.
            if let buffer = self.lastPixelBuffer, let last = self.video?.lastTime, endTime > last {
                self.video?.append(pixelBuffer: buffer, at: endTime)
            }
            let writers = (self.video, self.audio)
            self.video = nil
            self.audio = nil
            self.stream = nil
            self.lastPixelBuffer = nil
            return writers
        }
        let videoResult = await video?.finish()
        let audioResult = await audio?.finish()
        return (videoResult, audioResult, video?.failure ?? audio?.failure)
    }

    // MARK: SCStreamOutput (called on `queue`)

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard !stopping, sampleBuffer.isValid else { return }
        switch type {
        case .screen: handleVideo(sampleBuffer)
        case .audio: handleAudio(sampleBuffer)
        default: break
        }
    }

    private func handleVideo(_ sampleBuffer: CMSampleBuffer) {
        guard let video else { return }
        let status = frameStatus(of: sampleBuffer)
        guard let time = clock.sessionTime(forHost: sampleBuffer.presentationTimeStamp) else { return }

        if status == .complete, let pixelBuffer = sampleBuffer.imageBuffer {
            lastPixelBuffer = pixelBuffer
            if video.append(pixelBuffer: pixelBuffer, at: time), let waiter = firstFrameWaiter {
                firstFrameWaiter = nil
                waiter.resume()
            }
        } else if status == .idle, let buffer = lastPixelBuffer, let last = video.lastTime, (time - last).seconds >= 0.5 {
            // Nothing changed on screen: repeat the last picture twice a second so the file keeps growing
            // and a crash during a quiet stretch loses nothing.
            video.append(pixelBuffer: buffer, at: time)
        }
        if let failure = video.failure { fail(failure) }
    }

    private func handleAudio(_ sampleBuffer: CMSampleBuffer) {
        guard sampleBuffer.numSamples > 0,
              let time = clock.sessionTime(forHost: sampleBuffer.presentationTimeStamp) else { return }
        if audio == nil, let audioURL, let format = sampleBuffer.formatDescription,
           let description = format.audioStreamBasicDescription {
            do {
                let writer = try TrackWriter.audio(url: audioURL, sampleRate: description.mSampleRate,
                                                   channels: Int(description.mChannelsPerFrame), formatHint: format)
                let firstSample = onFirstSample
                writer.onFirstSample = { firstSample(.systemAudio, $0.seconds) }
                audio = writer
            } catch {
                // System audio is optional: carry on without it.
                self.audioURL = nil
            }
        }
        audio?.append(audio: sampleBuffer, at: time)
    }

    private func frameStatus(of sampleBuffer: CMSampleBuffer) -> SCFrameStatus {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw) else { return .complete }
        return status
    }

    private func fail(_ reason: String) {
        guard !stopping else { return }
        stopping = true
        if let waiter = firstFrameWaiter {
            firstFrameWaiter = nil
            waiter.resume(throwing: RecordingError.writerFailed(reason))
        }
        onInterruption(reason)
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        // Display disconnected, window closed, permission revoked, or the user stopped sharing from the menu bar.
        queue.async { self.fail(error.localizedDescription) }
    }
}
