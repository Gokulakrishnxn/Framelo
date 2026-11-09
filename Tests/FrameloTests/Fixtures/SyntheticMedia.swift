@preconcurrency import AVFoundation
import CoreVideo
import Foundation
@testable import FrameloCore

/// Deterministic media generated in-test. Every video frame encodes its own index as a strip of
/// black/white blocks, so a test can read back exactly which source frame ended up at an output time.
enum SyntheticMedia {
    static let indexBits = 16

    static func temporaryDirectory(_ name: String = "framelo-fixture") -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A BGRA frame: a flat colour that changes with the index, a moving white square, and the index strip on top.
    static func frame(index: Int, width: Int, height: Int) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                                           kCVPixelBufferMetalCompatibilityKey: true]
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer)
        let pixelBuffer = buffer!
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        let base = CVPixelBufferGetBaseAddress(pixelBuffer)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let stripHeight = max(8, height / 8)
        let blockWidth = width / indexBits
        let b = UInt8(40 + (index * 3) % 120)
        let g = UInt8(60 + (index * 5) % 100)
        let r = UInt8(80 + (index * 7) % 90)
        let squareX = (index * 4) % max(1, width - 24)
        for y in 0..<height {
            let row = base + y * stride
            for x in 0..<width {
                var pixel: (UInt8, UInt8, UInt8) = (b, g, r)
                if y < stripHeight {
                    let bit = min(indexBits - 1, x / max(1, blockWidth))
                    let on = (index >> bit) & 1 == 1
                    pixel = on ? (255, 255, 255) : (0, 0, 0)
                } else if y > height / 2, y < height / 2 + 24, x >= squareX, x < squareX + 24 {
                    pixel = (255, 255, 255)
                }
                row[x * 4] = pixel.0
                row[x * 4 + 1] = pixel.1
                row[x * 4 + 2] = pixel.2
                row[x * 4 + 3] = 255
            }
        }
        return pixelBuffer
    }

    /// Reads the frame index back from a decoded BGRA frame whose top strip spans the full width.
    static func decodeIndex(_ pixelBuffer: CVPixelBuffer) -> Int {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let base = CVPixelBufferGetBaseAddress(pixelBuffer)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let y = max(2, height / 16)
        let blockWidth = Double(width) / Double(indexBits)
        var index = 0
        for bit in 0..<indexBits {
            let x = Int((Double(bit) + 0.5) * blockWidth)
            let pixel = base + y * stride + x * 4
            let luma = (Int(pixel[0]) + Int(pixel[1]) + Int(pixel[2])) / 3
            if luma > 127 { index |= 1 << bit }
        }
        return index
    }

    /// Writes a video whose frame `i` is shown at `times[i]` (seconds). Irregular `times` give a variable frame rate.
    @discardableResult
    static func writeVideo(to url: URL, width: Int = 320, height: Int = 240, times: [Double]) async throws -> URL {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 1_500_000, AVVideoAllowFrameReorderingKey: false] as [String: Any],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for (index, time) in times.enumerated() {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            adaptor.append(frame(index: index, width: width, height: height),
                           withPresentationTime: MediaTime(seconds: time).cmTime)
        }
        input.markAsFinished()
        if let last = times.last, times.count > 1 {
            writer.endSession(atSourceTime: MediaTime(seconds: last + (last - times[times.count - 2])).cmTime)
        }
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        return url
    }

    static func constantTimes(duration: Double, fps: Int) -> [Double] {
        (0..<Int(duration * Double(fps))).map { Double($0) / Double(fps) }
    }

    /// Frame times with a fixed-seed jitter and occasional long holds, like a real screen capture.
    static func variableTimes(duration: Double, seed: UInt64 = 42) -> [Double] {
        var generator = SeededGenerator(seed: seed)
        var times: [Double] = []
        var time = 0.0
        while time < duration {
            times.append(time)
            let roll = Double.random(in: 0...1, using: &generator)
            time += roll < 0.1 ? Double.random(in: 0.2...0.6, using: &generator) : Double.random(in: 0.012...0.04, using: &generator)
        }
        return times
    }

    /// PCM audio: a quiet tone with a full-scale click at each of `clickTimes`.
    static func pcm(duration: Double, sampleRate: Double = 48_000, clickTimes: [Double] = []) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let frames = AVAudioFrameCount(duration * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<2 {
            let data = buffer.floatChannelData![channel]
            for i in 0..<Int(frames) {
                data[i] = 0.05 * sinf(Float(i) * 2 * .pi * 440 / Float(sampleRate))
            }
            for click in clickTimes {
                let start = Int(click * sampleRate)
                for i in start..<min(Int(frames), start + 48) { data[i] = 1 }
            }
        }
        return buffer
    }

    @discardableResult
    static func writeAudio(to url: URL, duration: Double, clickTimes: [Double] = []) throws -> URL {
        try? FileManager.default.removeItem(at: url)
        let buffer = pcm(duration: duration, clickTimes: clickTimes)
        let file = try AVAudioFile(forWriting: url, settings: buffer.format.settings)
        try file.write(from: buffer)
        return url
    }

    /// A cursor that moves in straight lines between click points, sampled at 120 Hz.
    static func cursorTrack(duration: Double, clicks: [(t: Double, x: Double, y: Double)]) -> CursorTrack {
        var track = CursorTrack()
        let points = [(t: 0.0, x: 0.5, y: 0.5)] + clicks + [(t: duration, x: clicks.last?.x ?? 0.5, y: clicks.last?.y ?? 0.5)]
        var time = 0.0
        while time <= duration {
            let next = points.firstIndex { $0.t >= time } ?? points.count - 1
            let a = points[max(0, next - 1)]
            let b = points[next]
            let f = b.t > a.t ? (time - a.t) / (b.t - a.t) : 1
            track.samples.append(CursorSample(t: time, x: lerp(a.x, b.x, f), y: lerp(a.y, b.y, f)))
            time += 1.0 / 120
        }
        track.clicks = clicks.map { ClickEvent(t: $0.t, x: $0.x, y: $0.y, releaseTime: $0.t + 0.08) }
        return track
    }

    /// Reads every frame of a video: presentation time and decoded index.
    static func readFrames(_ url: URL) async throws -> [(time: Double, index: Int)] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return [] }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        reader.add(output)
        reader.startReading()
        var frames: [(Double, Int)] = []
        while let sample = output.copyNextSampleBuffer() {
            if let image = sample.imageBuffer {
                frames.append((sample.presentationTimeStamp.seconds, decodeIndex(image)))
            }
        }
        return frames
    }
}

struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
