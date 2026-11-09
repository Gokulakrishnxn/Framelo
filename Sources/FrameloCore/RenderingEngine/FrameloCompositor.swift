@preconcurrency import AVFoundation
import CoreVideo
import Foundation

/// Instruction covering the whole timeline; carries the render context to the compositor.
final class FrameloInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    let context: RenderContext

    init(timeRange: CMTimeRange, context: RenderContext, trackIDs: [CMPersistentTrackID]) {
        self.timeRange = timeRange
        self.context = context
        self.requiredSourceTrackIDs = trackIDs.map { NSNumber(value: $0) }
    }
}

/// Custom video compositor: AVFoundation hands it the decoded source frames for a composition time, it evaluates
/// the `FrameState` and draws the frame with Metal. The same class serves `AVPlayer` (preview),
/// `AVAssetImageGenerator` (thumbnails) and `AVAssetReader` (export), so they cannot differ.
///
/// Concurrency: AVFoundation creates one instance per consumer. All work happens under `lock`, which serialises
/// access to the instance's renderer and frame cache (the `@unchecked Sendable` invariant).
public final class FrameloCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    private struct CacheKey: Hashable {
        var revision: Int
        var ticks: Int64
        var width: Int
        var height: Int
    }

    private let lock = NSLock()
    private var renderer: MetalRenderer?
    private var cache: [CacheKey: CVPixelBuffer] = [:]
    private var cacheOrder: [CacheKey] = []
    /// Recently rendered frames kept for instant redisplay while scrubbing back and forth.
    private static let cacheLimit = 12

    public var sourcePixelBufferAttributes: [String: any Sendable]? {
        [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
    }

    public var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] {
        [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
    }

    public func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        lock.withLock {
            cache.removeAll()
            cacheOrder.removeAll()
        }
    }

    public func cancelAllPendingVideoCompositionRequests() {
        // Requests are rendered synchronously in `startRequest`; nothing is ever pending.
    }

    public func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        lock.lock()
        defer { lock.unlock() }
        guard let instruction = request.videoCompositionInstruction as? FrameloInstruction else {
            request.finish(with: RenderError.resource("unexpected composition instruction"))
            return
        }
        let context = instruction.context
        let plan = context.plan
        let time = MediaTime(request.compositionTime)
        let size = request.renderContext.size
        let key = CacheKey(revision: plan.revision, ticks: time.ticks, width: Int(size.width), height: Int(size.height))
        if let cached = cache[key] {
            request.finish(withComposedVideoFrame: cached)
            return
        }

        do {
            if renderer == nil { renderer = try MetalRenderer() }
            guard let renderer, let output = request.renderContext.newPixelBuffer() else {
                throw RenderError.resource("output pixel buffer")
            }
            let state = plan.evaluator.evaluate(at: time)
            let screen = state.screen != nil ? request.sourceFrame(byTrackID: context.screenTrackID) : nil
            var camera: CVPixelBuffer?
            if state.pip != nil, context.cameraTrackID != kCMPersistentTrackID_Invalid {
                camera = request.sourceFrame(byTrackID: context.cameraTrackID)
            }
            try renderer.render(state: state, plan: plan, screen: screen, camera: camera, into: output)

            cache[key] = output
            cacheOrder.append(key)
            if cacheOrder.count > Self.cacheLimit { cache[cacheOrder.removeFirst()] = nil }
            request.finish(withComposedVideoFrame: output)
        } catch {
            request.finish(with: error)
        }
    }
}
