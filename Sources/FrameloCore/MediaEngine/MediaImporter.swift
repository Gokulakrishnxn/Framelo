@preconcurrency import AVFoundation
import Foundation

/// Brings existing media into Framelo. Files are referenced where they are and never modified or copied.
public enum MediaImporter {
    /// Creates a new project around a video file.
    public static func importVideo(_ url: URL, store: ProjectStore) async throws -> Project {
        let facts = try await MediaInspector.inspect(url)
        guard facts.hasVideo else { throw MediaError.noUsableTracks(url) }
        let file = MediaFile(relativePath: url.path, duration: facts.duration, pixelWidth: facts.pixelWidth,
                             pixelHeight: facts.pixelHeight, hasAudio: facts.hasAudio)
        let name = url.deletingPathExtension().lastPathComponent
        let source = MediaSource(kind: .importedVideo, name: name, screen: file, duration: facts.duration)
        let project = Project.make(name: name, source: source)
        try await store.save(project)
        await ThumbnailGenerator.writePoster(for: project, package: store.location.packageURL(for: project.id))
        return project
    }

    /// Describes an audio file as a source that can be placed on an audio track.
    public static func audioSource(_ url: URL) async throws -> MediaSource {
        let facts = try await MediaInspector.inspect(url)
        guard facts.hasAudio else { throw MediaError.noUsableTracks(url) }
        let file = MediaFile(relativePath: url.path, duration: facts.duration, hasAudio: true)
        return MediaSource(kind: .importedAudio, name: url.deletingPathExtension().lastPathComponent,
                           screen: file, duration: facts.duration)
    }
}

public enum WaveformGenerator {
    /// Peak level (0…1) per bucket for a file's first audio track. Empty when there is no audio.
    public static func peaks(url: URL, bucketsPerSecond: Int = 20) async -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let reader = try? AVAssetReader(asset: asset) else { return [] }
        let sampleRate = 8000
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
        ])
        guard reader.canAdd(output) else { return [] }
        reader.add(output)
        guard reader.startReading() else { return [] }

        let bucketSize = max(1, sampleRate / bucketsPerSecond)
        var peaks: [Float] = []
        var current: Int16 = 0
        var filled = 0
        while let sample = output.copyNextSampleBuffer() {
            if Task.isCancelled { reader.cancelReading(); return [] }
            guard let block = sample.dataBuffer else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var data = [Int16](repeating: 0, count: length / 2)
            let status = data.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!)
            }
            guard status == noErr else { continue }
            for value in data {
                let magnitude = value == Int16.min ? Int16.max : abs(value)
                if magnitude > current { current = magnitude }
                filled += 1
                if filled == bucketSize {
                    peaks.append(Float(current) / Float(Int16.max))
                    current = 0
                    filled = 0
                }
            }
        }
        if filled > 0 { peaks.append(Float(current) / Float(Int16.max)) }
        return peaks
    }
}
