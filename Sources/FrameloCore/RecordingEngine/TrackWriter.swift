@preconcurrency import AVFoundation
import CoreMedia
import Foundation

public enum RecordingError: Error, LocalizedError {
    case permissionDenied(PermissionKind)
    case sourceUnavailable(String)
    case noFramesReceived
    case writerFailed(String)
    case alreadyRunning
    case notRecording
    case captureInterrupted(String)

    public var errorDescription: String? {
        switch self {
        case .permissionDenied(let kind):
            "\(kind.displayName) access is turned off for Framelo. Allow it in System Settings › Privacy & Security, then try again."
        case .sourceUnavailable(let what): "\(what) is no longer available. Choose another source and try again."
        case .noFramesReceived: "The screen did not deliver any frames. Check Screen Recording permission and try again."
        case .writerFailed(let reason): "The recording could not be written to disk: \(reason)"
        case .alreadyRunning: "A recording is already in progress."
        case .notRecording: "No recording is in progress."
        case .captureInterrupted(let reason): "Recording stopped early: \(reason) Everything captured up to that point was saved."
        }
    }
}

/// Result of closing one track file.
public struct TrackResult: Sendable {
    public var url: URL
    /// Session time of the first sample (the file's own timeline starts at zero there).
    public var startOffset: Double
    /// Session time of the last sample.
    public var lastSampleTime: Double
    public var sampleCount: Int
    public var droppedCount: Int
}

/// Writes one media file in crash-tolerant fragmented QuickTime format.
/// Not thread-safe: each instance is owned by exactly one recorder and used only on that recorder's queue.
final class TrackWriter {
    let url: URL
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private(set) var firstTime: CMTime?
    private(set) var lastTime: CMTime?
    private(set) var sampleCount = 0
    private(set) var droppedCount = 0
    private(set) var failure: String?
    /// Called once, on the owner's queue, when the first sample has been written.
    var onFirstSample: ((CMTime) -> Void)?

    static let fragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)

    private init(url: URL, mediaType: AVMediaType, settings: [String: Any], formatHint: CMFormatDescription?, pixelBuffers: Bool) throws {
        self.url = url
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        // Fragments make the file readable up to the last flushed fragment if the app dies mid-recording.
        writer.movieFragmentInterval = Self.fragmentInterval
        input = AVAssetWriterInput(mediaType: mediaType, outputSettings: settings, sourceFormatHint: formatHint)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw RecordingError.writerFailed("unsupported \(mediaType.rawValue) settings") }
        writer.add(input)
        adaptor = pixelBuffers ? AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil) : nil
    }

    static func video(url: URL, width: Int, height: Int, frameRate: Int, bitRate: Int? = nil) throws -> TrackWriter {
        let rate = bitRate ?? min(60_000_000, max(4_000_000, Int(Double(width * height * frameRate) * 0.14)))
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: rate,
                AVVideoExpectedSourceFrameRateKey: frameRate,
                // One key frame per second keeps scrubbing in the editor responsive.
                AVVideoMaxKeyFrameIntervalKey: frameRate,
                AVVideoAllowFrameReorderingKey: false,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ] as [String: Any],
        ]
        return try TrackWriter(url: url, mediaType: .video, settings: settings, formatHint: nil, pixelBuffers: true)
    }

    static func audio(url: URL, sampleRate: Double, channels: Int, formatHint: CMFormatDescription? = nil) throws -> TrackWriter {
        let outChannels = min(max(channels, 1), 2)
        let rate = [44_100.0, 48_000.0].contains(sampleRate) ? sampleRate : 48_000
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: outChannels,
            AVEncoderBitRateKey: outChannels == 1 ? 128_000 : 192_000,
        ]
        return try TrackWriter(url: url, mediaType: .audio, settings: settings, formatHint: formatHint, pixelBuffers: false)
    }

    /// Whether the encoder can take another sample right now.
    var isReady: Bool { firstTime == nil || input.isReadyForMoreMediaData }

    private func begin(at time: CMTime) -> Bool {
        guard firstTime == nil else { return true }
        guard writer.startWriting() else {
            failure = writer.error?.localizedDescription ?? "could not start writing"
            return false
        }
        writer.startSession(atSourceTime: time)
        firstTime = time
        onFirstSample?(time)
        return true
    }

    /// Appends a video frame at a session time. Frames are dropped (and counted) if the encoder is behind.
    @discardableResult
    func append(pixelBuffer: CVPixelBuffer, at time: CMTime) -> Bool {
        guard failure == nil, let adaptor else { return false }
        if let lastTime, time <= lastTime { return false }
        guard begin(at: time) else { return false }
        guard input.isReadyForMoreMediaData else { droppedCount += 1; return false }
        guard adaptor.append(pixelBuffer, withPresentationTime: time) else {
            failure = writer.error?.localizedDescription ?? "append failed"
            return false
        }
        lastTime = time
        sampleCount += 1
        return true
    }

    /// Appends an audio buffer, re-stamped so its first sample is at session time `time`.
    @discardableResult
    func append(audio sampleBuffer: CMSampleBuffer, at time: CMTime) -> Bool {
        guard failure == nil else { return false }
        guard begin(at: time) else { return false }
        guard input.isReadyForMoreMediaData else { droppedCount += 1; return false }
        let shift = sampleBuffer.presentationTimeStamp - time
        let buffer: CMSampleBuffer
        if shift == .zero {
            buffer = sampleBuffer
        } else {
            guard let timings = try? sampleBuffer.sampleTimingInfos() else { return false }
            let shifted = timings.map { info in
                CMSampleTimingInfo(duration: info.duration,
                                   presentationTimeStamp: info.presentationTimeStamp - shift,
                                   decodeTimeStamp: info.decodeTimeStamp.isValid ? info.decodeTimeStamp - shift : .invalid)
            }
            guard let copy = try? CMSampleBuffer(copying: sampleBuffer, withNewTiming: shifted) else { return false }
            buffer = copy
        }
        guard input.append(buffer) else {
            failure = writer.error?.localizedDescription ?? "append failed"
            return false
        }
        lastTime = time + sampleBuffer.duration
        sampleCount += sampleBuffer.numSamples
        return true
    }

    /// Closes the file. Returns `nil` (and removes the empty file) when nothing was ever written.
    func finish(endTime: CMTime? = nil) async -> TrackResult? {
        guard let firstTime, writer.status == .writing else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        input.markAsFinished()
        if let endTime, let lastTime, endTime > lastTime { writer.endSession(atSourceTime: endTime) }
        await writer.finishWriting()
        if writer.status != .completed {
            failure = writer.error?.localizedDescription ?? "could not finish writing"
        }
        return TrackResult(url: url, startOffset: firstTime.seconds, lastSampleTime: (lastTime ?? firstTime).seconds,
                           sampleCount: sampleCount, droppedCount: droppedCount)
    }

    /// Stops writing and leaves whatever fragments were flushed on disk (used on abort after a failure).
    func abandon() {
        if writer.status == .writing { writer.cancelWriting() }
    }
}

extension CMSampleBuffer {
    /// Wraps PCM audio in a sample buffer stamped at `time`.
    static func make(from pcm: AVAudioPCMBuffer, at time: CMTime) -> CMSampleBuffer? {
        guard pcm.frameLength > 0 else { return nil }
        let format = pcm.format.formatDescription
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(pcm.format.sampleRate)),
                                        presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
                                          makeDataReadyCallback: nil, refcon: nil, formatDescription: format,
                                          sampleCount: CMItemCount(pcm.frameLength), sampleTimingEntryCount: 1,
                                          sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil,
                                          sampleBufferOut: &sampleBuffer)
        guard status == noErr, let sampleBuffer else { return nil }
        let filled = CMSampleBufferSetDataBufferFromAudioBufferList(
            sampleBuffer, blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0, bufferList: pcm.audioBufferList)
        return filled == noErr ? sampleBuffer : nil
    }
}
