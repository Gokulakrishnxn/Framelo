@preconcurrency import AVFoundation
import CoreGraphics
import Foundation

public enum ExportError: Error, LocalizedError {
    case cancelled
    case invalidProject(String)
    case missingSource(String)
    case unsupportedSettings(String)
    case insufficientDiskSpace(needed: Int64, available: Int64)
    case readFailed(String)
    case writeFailed(String)
    case validationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .cancelled:
            "The export was cancelled."
        case .invalidProject(let reason):
            "This project can't be exported yet: \(reason)"
        case .missingSource(let name):
            "“\(name)” is missing. Put the file back where it was (or re-import it) and export again."
        case .unsupportedSettings(let what):
            "This Mac can't encode \(what). Try H.264, or a lower resolution."
        case .insufficientDiskSpace(let needed, let available):
            "Not enough free space: about \(ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)) is needed, " +
            "\(ByteCountFormatter.string(fromByteCount: available, countStyle: .file)) is available. Free up space or choose another location."
        case .readFailed(let reason):
            "A source video could not be read during export: \(reason)"
        case .writeFailed(let reason):
            "The video could not be written: \(reason) Check that the destination is writable and has free space."
        case .validationFailed(let reason):
            "The exported file did not pass verification (\(reason)), so it was not saved. Please export again."
        }
    }
}

public struct ExportResult: Sendable, Equatable {
    public var url: URL
    public var duration: Double
    public var width: Int
    public var height: Int
    public var frameRate: Double
    public var codec: String
    public var hasAudio: Bool
    public var fileSize: Int64
}

/// Renders a project to a video file: composition → Metal compositor → encoder.
/// The file is written to a temporary location and only moved to the destination after it has been verified.
public enum ExportService {
    /// - Parameters:
    ///   - progress: called with 0…1 as frames are written.
    /// Cancel the surrounding task to cancel the export; all temporary files are removed.
    public static func export(project: Project, package: URL, cursorTracks: [UUID: CursorTrack],
                              settings: ExportSettings, destination: URL, tempDirectory: URL,
                              progress: @escaping @Sendable (Double) -> Void) async throws -> ExportResult {
        // Preflight ---------------------------------------------------------------------------------
        do {
            try TimelineValidator.validate(project)
        } catch {
            throw ExportError.invalidProject(error.localizedDescription)
        }
        let size = settings.canvasSize(aspect: project.canvasAspect)
        let built: BuiltComposition
        do {
            built = try await CompositionBuilder.build(project: project, package: package)
        } catch CompositionError.missingMedia(let name) {
            throw ExportError.missingSource(name)
        } catch {
            throw ExportError.invalidProject(error.localizedDescription)
        }

        let videoSettings = Self.videoSettings(settings, width: size.width, height: size.height)
        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: ExportSettings.audioBitRate,
        ]
        let fileType: AVFileType = settings.container == .mp4 ? .mp4 : .mov

        let fm = FileManager.default
        // Each export works in its own folder: the encoder creates sidecar files next to its output,
        // and removing the folder is the only way to be sure none of them is left behind.
        let workDirectory = tempDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? fm.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        let tempURL = workDirectory.appendingPathComponent("export.\(settings.container.fileExtension)")

        let estimate = settings.estimatedFileSize(width: size.width, height: size.height,
                                                  duration: built.duration.seconds, hasAudio: built.hasAudio)
        for directory in [tempDirectory, destination.deletingLastPathComponent()] {
            if let available = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                .volumeAvailableCapacityForImportantUsage, available < estimate + estimate / 4 + 50_000_000 {
                try? fm.removeItem(at: workDirectory)
                throw ExportError.insufficientDiskSpace(needed: estimate, available: available)
            }
        }

        // Reader ------------------------------------------------------------------------------------
        let plan = RenderPlan(project: project, cursorTracks: cursorTracks)
        let context = built.makeContext(plan: plan)
        let videoComposition = built.videoComposition(context: context,
                                                      renderSize: CGSize(width: size.width, height: size.height),
                                                      frameRate: settings.frameRate)
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: built.composition)
        } catch {
            throw ExportError.readFailed(error.localizedDescription)
        }
        let videoTracks = try await built.composition.loadTracks(withMediaType: .video)
        let videoOutput = AVAssetReaderVideoCompositionOutput(videoTracks: videoTracks, videoSettings: MetalRenderer.pixelBufferAttributes)
        videoOutput.videoComposition = videoComposition
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else { throw ExportError.readFailed("the timeline's video could not be prepared") }
        reader.add(videoOutput)

        var audioOutput: AVAssetReaderAudioMixOutput?
        let audioTracks = try await built.composition.loadTracks(withMediaType: .audio)
        if !audioTracks.isEmpty {
            let output = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
            ])
            output.audioMix = built.audioMix
            output.audioTimePitchAlgorithm = .spectral
            output.alwaysCopiesSampleData = false
            if reader.canAdd(output) {
                reader.add(output)
                audioOutput = output
            }
        }

        // Writer ------------------------------------------------------------------------------------
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: tempURL, fileType: fileType)
        } catch {
            throw ExportError.writeFailed(error.localizedDescription)
        }
        guard writer.canApply(outputSettings: videoSettings, forMediaType: .video) else {
            throw ExportError.unsupportedSettings("\(settings.codec.displayName) at \(size.width)×\(size.height)")
        }
        writer.shouldOptimizeForNetworkUse = true
        writer.metadata = metadataItems(author: settings.author)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        writer.add(videoInput)
        var audioInput: AVAssetWriterInput?
        if audioOutput != nil {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            audioInput = input
        }

        /// Stops reading and writing and removes the work folder. `cancelWriting` finishes in the background and
        /// can still touch the file briefly, so removal is repeated until the file is really gone.
        func cleanUp() async {
            if reader.status == .reading { reader.cancelReading() }
            if writer.status == .writing { writer.cancelWriting() }
            for _ in 0..<200 {
                try? fm.removeItem(at: workDirectory)
                if writer.status != .writing, !fm.fileExists(atPath: workDirectory.path) {
                    // Give a late flush one more chance to appear, then confirm.
                    try? await Task.sleep(for: .milliseconds(20))
                    if !fm.fileExists(atPath: workDirectory.path) { return }
                }
                try? await Task.sleep(for: .milliseconds(10))
            }
        }

        guard reader.startReading() else {
            await cleanUp()
            throw ExportError.readFailed(reader.error?.localizedDescription ?? "unknown error")
        }
        guard writer.startWriting() else {
            await cleanUp()
            throw ExportError.writeFailed(writer.error?.localizedDescription ?? "unknown error")
        }
        writer.startSession(atSourceTime: .zero)

        // Pump --------------------------------------------------------------------------------------
        // One loop feeds both inputs, so the writer's interleaving can never starve either of them.
        let total = max(built.duration.seconds, 0.001)
        var videoDone = false
        var audioDone = audioInput == nil
        var lastReported = -1.0
        progress(0)
        while !videoDone || !audioDone {
            if Task.isCancelled {
                await cleanUp()
                throw ExportError.cancelled
            }
            var advanced = false
            if !videoDone, videoInput.isReadyForMoreMediaData {
                if let sample = videoOutput.copyNextSampleBuffer() {
                    guard videoInput.append(sample) else {
                        let reason = writer.error?.localizedDescription ?? "the encoder rejected a frame"
                        await cleanUp()
                        throw ExportError.writeFailed(reason)
                    }
                    let fraction = min(1, sample.presentationTimeStamp.seconds / total)
                    if fraction - lastReported >= 0.005 {
                        lastReported = fraction
                        progress(fraction)
                    }
                } else {
                    videoInput.markAsFinished()
                    videoDone = true
                }
                advanced = true
            }
            if !audioDone, let audioInput, let audioOutput, audioInput.isReadyForMoreMediaData {
                if let sample = audioOutput.copyNextSampleBuffer() {
                    guard audioInput.append(sample) else {
                        let reason = writer.error?.localizedDescription ?? "the encoder rejected audio"
                        await cleanUp()
                        throw ExportError.writeFailed(reason)
                    }
                } else {
                    audioInput.markAsFinished()
                    audioDone = true
                }
                advanced = true
            }
            if reader.status == .failed {
                let reason = reader.error?.localizedDescription ?? "unknown error"
                await cleanUp()
                throw ExportError.readFailed(reason)
            }
            if !advanced { try? await Task.sleep(for: .milliseconds(2)) }
        }

        guard reader.status == .completed else {
            let reason = reader.error?.localizedDescription ?? "reading stopped early"
            await cleanUp()
            throw ExportError.readFailed(reason)
        }
        writer.endSession(atSourceTime: built.duration.cmTime)
        await writer.finishWriting()
        guard writer.status == .completed else {
            let reason = writer.error?.localizedDescription ?? "unknown error"
            await cleanUp()
            throw ExportError.writeFailed(reason)
        }
        if Task.isCancelled {
            try? fm.removeItem(at: workDirectory)
            throw ExportError.cancelled
        }

        // Verify, then publish ----------------------------------------------------------------------
        let result: ExportResult
        do {
            result = try await validate(tempURL, expectedDuration: built.duration.seconds, width: size.width, height: size.height,
                                        settings: settings, expectsAudio: audioOutput != nil)
        } catch {
            try? fm.removeItem(at: workDirectory)
            throw error
        }
        do {
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: destination.path) {
                _ = try fm.replaceItemAt(destination, withItemAt: tempURL)
            } else {
                try fm.moveItem(at: tempURL, to: destination)
            }
        } catch {
            try? fm.removeItem(at: workDirectory)
            throw ExportError.writeFailed(error.localizedDescription)
        }
        try? fm.removeItem(at: workDirectory)
        progress(1)
        var published = result
        published.url = destination
        return published
    }

    static func metadataItems(author: String?) -> [AVMetadataItem] {
        func item(_ identifier: AVMetadataIdentifier, _ value: String) -> AVMetadataItem {
            let item = AVMutableMetadataItem()
            item.identifier = identifier
            item.value = value as NSString
            return item
        }
        var items = [item(.commonIdentifierSoftware, "Framelo"),
                     item(.commonIdentifierCreationDate, ISO8601DateFormatter().string(from: Date()))]
        if let author = author?.trimmingCharacters(in: .whitespaces), !author.isEmpty {
            items.append(item(.commonIdentifierAuthor, author))
            items.append(item(.commonIdentifierArtist, author))
        }
        return items
    }

    static func videoSettings(_ settings: ExportSettings, width: Int, height: Int) -> [String: Any] {
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: settings.videoBitRate(width: width, height: height),
            AVVideoExpectedSourceFrameRateKey: settings.frameRate,
            AVVideoMaxKeyFrameIntervalKey: settings.frameRate * 2,
        ]
        if settings.codec == .h264 { compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel }
        return [
            AVVideoCodecKey: settings.codec == .h264 ? AVVideoCodecType.h264 : AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: compression,
        ]
    }

    /// Re-opens the written file and checks that it is what was asked for.
    static func validate(_ url: URL, expectedDuration: Double, width: Int, height: Int,
                         settings: ExportSettings, expectsAudio: Bool) async throws -> ExportResult {
        let facts: MediaFacts
        do {
            facts = try await MediaInspector.inspect(url)
        } catch {
            throw ExportError.validationFailed("the file cannot be opened")
        }
        let frame = 1.0 / Double(settings.frameRate)
        guard facts.hasVideo else { throw ExportError.validationFailed("it has no video track") }
        guard abs(facts.duration - expectedDuration) <= frame * 2 + 0.05 else {
            throw ExportError.validationFailed(String(format: "duration is %.2f s, expected %.2f s", facts.duration, expectedDuration))
        }
        guard facts.pixelWidth == width, facts.pixelHeight == height else {
            throw ExportError.validationFailed("size is \(facts.pixelWidth)×\(facts.pixelHeight), expected \(width)×\(height)")
        }
        let expectedCodecs = settings.codec == .h264 ? ["avc1", "avc3"] : ["hvc1", "hev1"]
        guard let codec = facts.videoCodec, expectedCodecs.contains(codec) else {
            throw ExportError.validationFailed("codec is \(facts.videoCodec ?? "unknown")")
        }
        guard abs(facts.frameRate - Double(settings.frameRate)) <= 1.5 else {
            throw ExportError.validationFailed(String(format: "frame rate is %.1f, expected %d", facts.frameRate, settings.frameRate))
        }
        guard facts.hasAudio == expectsAudio else {
            throw ExportError.validationFailed(expectsAudio ? "the audio track is missing" : "an unexpected audio track is present")
        }
        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        guard fileSize > 0 else { throw ExportError.validationFailed("the file is empty") }
        return ExportResult(url: url, duration: facts.duration, width: facts.pixelWidth, height: facts.pixelHeight,
                            frameRate: facts.frameRate, codec: codec, hasAudio: facts.hasAudio, fileSize: fileSize)
    }
}
