@preconcurrency import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum MediaError: Error, LocalizedError {
    case missing(URL)
    case unreadable(URL, String)
    case noUsableTracks(URL)

    public var errorDescription: String? {
        switch self {
        case .missing(let url): "“\(url.lastPathComponent)” could not be found. It may have been moved or deleted."
        case .unreadable(let url, let reason): "“\(url.lastPathComponent)” could not be opened: \(reason)"
        case .noUsableTracks(let url): "“\(url.lastPathComponent)” contains no video or audio Framelo can use."
        }
    }
}

/// Facts about a media file, read once and stored in the project.
public struct MediaFacts: Sendable, Equatable {
    public var duration: Double
    public var hasVideo: Bool
    public var hasAudio: Bool
    /// Display size (preferred transform applied).
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var frameRate: Double
    public var videoCodec: String?
}

public enum MediaInspector {
    /// Validates that a file exists, is readable and has usable tracks, and returns its facts.
    public static func inspect(_ url: URL) async throws -> MediaFacts {
        guard FileManager.default.fileExists(atPath: url.path) else { throw MediaError.missing(url) }
        let asset = AVURLAsset(url: url)
        do {
            let (duration, isReadable) = try await asset.load(.duration, .isReadable)
            guard isReadable else { throw MediaError.unreadable(url, "the format is not supported") }
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            guard !videoTracks.isEmpty || !audioTracks.isEmpty, duration.isNumeric, duration.seconds > 0 else {
                throw MediaError.noUsableTracks(url)
            }
            var facts = MediaFacts(duration: duration.seconds, hasVideo: !videoTracks.isEmpty, hasAudio: !audioTracks.isEmpty,
                                   pixelWidth: 0, pixelHeight: 0, frameRate: 0, videoCodec: nil)
            if let track = videoTracks.first {
                let (size, transform, rate, formats) = try await track.load(.naturalSize, .preferredTransform,
                                                                            .nominalFrameRate, .formatDescriptions)
                let display = size.applying(transform)
                facts.pixelWidth = Int(abs(display.width).rounded())
                facts.pixelHeight = Int(abs(display.height).rounded())
                facts.frameRate = Double(rate)
                if let format = formats.first {
                    facts.videoCodec = fourCC(CMFormatDescriptionGetMediaSubType(format))
                }
            }
            return facts
        } catch let error as MediaError {
            throw error
        } catch {
            throw MediaError.unreadable(url, error.localizedDescription)
        }
    }

    static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [UInt8((code >> 24) & 0xFF), UInt8((code >> 16) & 0xFF), UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF)]
        return String(bytes: bytes, encoding: .ascii) ?? "\(code)"
    }
}

public enum ThumbnailGenerator {
    /// One frame of a video as a `CGImage`, scaled so its longer side is at most `maxSide`.
    public static func image(for url: URL, at seconds: Double, maxSide: CGFloat = 640) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxSide, height: maxSide)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        return try? await generator.image(at: CMTime(seconds: max(0, seconds), preferredTimescale: 600)).image
    }

    /// Evenly spaced frames for a timeline strip.
    public static func strip(for url: URL, times: [Double], maxSide: CGFloat = 160) async -> [(time: Double, image: CGImage)] {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxSide, height: maxSide)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
        var result: [(Double, CGImage)] = []
        for time in times {
            if Task.isCancelled { break }
            if let image = try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image {
                result.append((time, image))
            }
        }
        return result
    }

    @discardableResult
    public static func writeJPEG(_ image: CGImage, to url: URL, quality: Double = 0.8) -> Bool {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            return false
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(destination)
    }

    /// Writes the project's poster image used on the dashboard.
    public static func writePoster(for project: Project, package: URL) async {
        guard let source = project.sources.first(where: { $0.screen != nil }), let file = source.screen else { return }
        let url = ProjectPackage.resolve(file.relativePath, in: package)
        guard let image = await image(for: url, at: min(1, file.duration / 2)) else { return }
        writeJPEG(image, to: package.appendingPathComponent(ProjectPackage.posterFile))
    }
}
