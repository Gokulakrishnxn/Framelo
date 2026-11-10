import CoreGraphics
import CoreVideo
import Foundation
import Metal

public enum RenderError: Error, LocalizedError {
    case noDevice
    case shaderCompilation(String)
    case resource(String)
    case gpu(String)

    public var errorDescription: String? {
        switch self {
        case .noDevice: "This Mac has no Metal-capable graphics device available."
        case .shaderCompilation(let log): "Framelo's shaders failed to compile: \(log)"
        case .resource(let what): "A rendering resource could not be created: \(what)"
        case .gpu(let reason): "The graphics device reported an error: \(reason)"
        }
    }
}

/// Mirrors the `Uniforms` struct in `Shaders.swift`. Every field is a `SIMD4<Float>`, so the layouts are identical.
struct FrameUniforms {
    var canvas = SIMD4<Float>()
    var card = SIMD4<Float>()
    var content = SIMD4<Float>()
    var cam = SIMD4<Float>()
    var cardStyle = SIMD4<Float>()
    var blur = SIMD4<Float>()
    var bgA = SIMD4<Float>()
    var bgB = SIMD4<Float>()
    var bgParams = SIMD4<Float>()
    var bgImage = SIMD4<Float>(1, 1, 0, 0)
    var cursorRect = SIMD4<Float>()
    var cursorParams = SIMD4<Float>()
    var rippleParams = SIMD4<Float>()
    var rippleColor = SIMD4<Float>()
    var ripples = (SIMD4<Float>(), SIMD4<Float>(), SIMD4<Float>(), SIMD4<Float>())
    var pipRect = SIMD4<Float>()
    var pipStyle = SIMD4<Float>()
    var pipBorderColor = SIMD4<Float>()
    var pipBackground = SIMD4<Float>()
    var pipUV = SIMD4<Float>(1, 1, 0, 0)
    var titleBar = SIMD4<Float>(0.16, 0.16, 0.18, 1)
    var crop = SIMD4<Float>(0, 0, 1, 1)
    var insetColor = SIMD4<Float>(0.11, 0.11, 0.12, 1)
}

struct QuadUniforms {
    var rect = SIMD4<Float>()
    var params = SIMD4<Float>()
}

private extension RGBAColor {
    var simd: SIMD4<Float> { SIMD4(Float(r), Float(g), Float(b), Float(a)) }
}

/// Device-wide rendering state shared by every renderer: the compiled shader library, pipeline states and sampler.
/// Built once; pipeline states are cached per pixel format. Immutable apart from the lock-protected cache.
final class RenderDevice: @unchecked Sendable {
    let device: MTLDevice
    let library: MTLLibrary
    let sampler: MTLSamplerState
    private let lock = NSLock()
    private var composite: [MTLPixelFormat: MTLRenderPipelineState] = [:]
    private var quad: [MTLPixelFormat: MTLRenderPipelineState] = [:]

    static let shared: Result<RenderDevice, RenderError> = {
        guard let device = MTLCreateSystemDefaultDevice() else { return .failure(.noDevice) }
        do {
            return .success(try RenderDevice(device: device))
        } catch let error as RenderError {
            return .failure(error)
        } catch {
            return .failure(.shaderCompilation(error.localizedDescription))
        }
    }()

    init(device: MTLDevice) throws {
        self.device = device
        do {
            library = try device.makeLibrary(source: Shaders.source, options: nil)
        } catch {
            throw RenderError.shaderCompilation(error.localizedDescription)
        }
        let descriptor = MTLSamplerDescriptor()
        descriptor.minFilter = .linear
        descriptor.magFilter = .linear
        descriptor.sAddressMode = .clampToEdge
        descriptor.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: descriptor) else { throw RenderError.resource("sampler") }
        self.sampler = sampler
    }

    func compositePipeline(_ format: MTLPixelFormat) throws -> MTLRenderPipelineState {
        try pipeline(format, cache: \.composite, vertex: "fullscreenVertex", fragment: "compositeFragment", blended: false)
    }

    func quadPipeline(_ format: MTLPixelFormat) throws -> MTLRenderPipelineState {
        try pipeline(format, cache: \.quad, vertex: "quadVertex", fragment: "quadFragment", blended: true)
    }

    private func pipeline(_ format: MTLPixelFormat,
                          cache: ReferenceWritableKeyPath<RenderDevice, [MTLPixelFormat: MTLRenderPipelineState]>,
                          vertex: String, fragment: String, blended: Bool) throws -> MTLRenderPipelineState {
        lock.lock()
        defer { lock.unlock() }
        if let existing = self[keyPath: cache][format] { return existing }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: vertex)
        descriptor.fragmentFunction = library.makeFunction(name: fragment)
        let attachment = descriptor.colorAttachments[0]!
        attachment.pixelFormat = format
        if blended {
            attachment.isBlendingEnabled = true
            attachment.sourceRGBBlendFactor = .one
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
            attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        }
        do {
            let state = try device.makeRenderPipelineState(descriptor: descriptor)
            self[keyPath: cache][format] = state
            return state
        } catch {
            throw RenderError.shaderCompilation(error.localizedDescription)
        }
    }
}

/// Draws one `FrameState` into a pixel buffer with Metal.
///
/// Ownership: one renderer per consumer (the preview compositor, each export). An instance is not thread-safe;
/// its owner calls it from one thread at a time. Pipelines come from the shared `RenderDevice`; the texture cache,
/// command queue and static textures belong to this instance and are reused across frames.
public final class MetalRenderer {
    private let shared: RenderDevice
    private let queue: MTLCommandQueue
    private let textureCache: CVMetalTextureCache
    private let transparent: MTLTexture
    private var staticTextures: [String: MTLTexture] = [:]
    private var textTextures: [TextRasterizer.Spec: MTLTexture] = [:]
    private var textOrder: [TextRasterizer.Spec] = []
    private static let textCacheLimit = 48
    static let pixelFormat = MTLPixelFormat.bgra8Unorm

    /// Attributes a pixel buffer needs so it can be used as a Metal texture without copying.
    public static var pixelBufferAttributes: [String: Any] {
        [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]
    }

    public init() throws {
        shared = try RenderDevice.shared.get()
        guard let queue = shared.device.makeCommandQueue() else { throw RenderError.resource("command queue") }
        self.queue = queue
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, shared.device, nil, &cache)
        guard let cache else { throw RenderError.resource("texture cache") }
        textureCache = cache
        guard let transparent = Self.makeTexture(device: shared.device, width: 1, height: 1, bytes: [0, 0, 0, 0]) else {
            throw RenderError.resource("placeholder texture")
        }
        self.transparent = transparent
        // Fail early, with the compiler log, rather than on the first frame.
        _ = try shared.compositePipeline(Self.pixelFormat)
        _ = try shared.quadPipeline(Self.pixelFormat)
    }

    // MARK: Textures

    private static func makeTexture(device: MTLDevice, width: Int, height: Int, bytes: [UInt8]) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        bytes.withUnsafeBytes { pointer in
            texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                            withBytes: pointer.baseAddress!, bytesPerRow: width * 4)
        }
        return texture
    }

    private func texture(_ bitmap: Bitmap?) -> MTLTexture? {
        guard let bitmap else { return nil }
        return Self.makeTexture(device: shared.device, width: bitmap.width, height: bitmap.height, bytes: bitmap.bytes)
    }

    private func staticTexture(_ key: String, _ make: () -> Bitmap?) -> MTLTexture? {
        if let existing = staticTextures[key] { return existing }
        guard let created = texture(make()) else { return nil }
        if staticTextures.count > 16 { staticTextures.removeAll() }
        staticTextures[key] = created
        return created
    }

    private func textTexture(_ spec: TextRasterizer.Spec) -> MTLTexture? {
        if let existing = textTextures[spec] { return existing }
        guard let created = texture(TextRasterizer.bitmap(spec)) else { return nil }
        textTextures[spec] = created
        textOrder.append(spec)
        if textOrder.count > Self.textCacheLimit {
            textTextures[textOrder.removeFirst()] = nil
        }
        return created
    }

    /// Wraps a BGRA pixel buffer as a texture without copying. The returned `CVMetalTexture` must stay alive
    /// until the GPU has finished with it.
    private func wrap(_ buffer: CVPixelBuffer) -> (MTLTexture, CVMetalTexture)? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else { return nil }
        var wrapped: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, textureCache, buffer, nil, Self.pixelFormat,
                                                  CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer), 0, &wrapped)
        guard let wrapped, let texture = CVMetalTextureGetTexture(wrapped) else { return nil }
        return (texture, wrapped)
    }

    // MARK: Render

    /// Renders `state` into `output` (a BGRA, Metal-compatible pixel buffer). Blocks until the GPU has finished.
    public func render(state: FrameState, plan: RenderPlan, screen: CVPixelBuffer?, camera: CVPixelBuffer?,
                       into output: CVPixelBuffer) throws {
        guard let (target, targetRef) = wrap(output) else { throw RenderError.resource("render target") }
        var keepAlive: [CVMetalTexture] = [targetRef]
        let project = plan.project
        let settings = project.settings
        let canvas = CGSize(width: target.width, height: target.height)
        let layout = FrameLayout(project: project, canvas: canvas)
        var uniforms = FrameUniforms()
        uniforms.canvas = SIMD4(Float(canvas.width), Float(canvas.height), 0, 1)

        // Background
        var backgroundTexture = transparent
        let background = settings.background
        switch background.kind {
        case .none:
            uniforms.bgA = SIMD4(0, 0, 0, 1)
        case .solid:
            uniforms.bgA = background.color.simd
        case .gradient:
            let angle = background.gradientAngle * .pi / 180
            let norm = abs(cos(angle)) + abs(sin(angle))
            uniforms.bgA = background.gradientStart.simd
            uniforms.bgB = background.gradientEnd.simd
            uniforms.bgParams = SIMD4(1, Float(cos(angle) / norm), Float(sin(angle) / norm), 0)
        case .image, .wallpaper:
            uniforms.bgA = background.color.simd
            let blur = background.blurAmount
            if let path = background.imagePath,
               let image = staticTexture("bg:\(path):\(Int(blur * 100))", { Bitmap.file(path, blur: blur) }) {
                backgroundTexture = image
                let imageAspect = Float(image.width) / Float(image.height)
                let canvasAspect = Float(canvas.width / canvas.height)
                uniforms.bgParams = SIMD4(2, 0, 0, 0)
                uniforms.bgImage = canvasAspect > imageAspect ? SIMD4(1, imageAspect / canvasAspect, 0, 0)
                                                              : SIMD4(canvasAspect / imageAspect, 1, 0, 0)
            }
        }

        // Screen card
        var screenTexture = transparent
        var cursorTexture = transparent
        if let screenState = state.screen, let screen, let (texture, ref) = wrap(screen) {
            screenTexture = texture
            keepAlive.append(ref)
            let scale = state.camera.scale * screenState.transitionScale
            let centre = layout.cameraCentre(state.camera)
            uniforms.card = SIMD4(Float(layout.card.minX), Float(layout.card.minY), Float(layout.card.width), Float(layout.card.height))
            uniforms.crop = SIMD4(Float(layout.crop.x), Float(layout.crop.y), Float(layout.crop.width), Float(layout.crop.height))
            uniforms.content = SIMD4(Float(layout.content.minX), Float(layout.content.minY),
                                     Float(layout.content.width), Float(layout.content.height))
            uniforms.cam = SIMD4(Float(centre.x), Float(centre.y), Float(scale), Float(screenState.opacity))
            uniforms.cardStyle = SIMD4(Float(layout.cornerRadius), Float(layout.shadowRadius),
                                       Float(settings.screen.shadowOpacity), 1)

            // Motion blur: how far this frame's view moves during the shutter interval.
            let shutter = settings.motion.motionBlur / 60
            var blurX = shutter * state.cameraVelocityX * Double(layout.content.width)
            var blurY = shutter * state.cameraVelocityY * Double(layout.content.height)
            var blurScale = -shutter * state.cameraVelocityScale / max(state.camera.scale, 1)
            var cursorBlurX = 0.0
            var cursorBlurY = 0.0

            if let cursor = state.cursor, let sprite = staticTexture("cursor:" + cursor.kind.rawValue, { CursorSprites.bitmap(cursor.kind) }) {
                cursorTexture = sprite
                let size = Double(layout.cursorUnit) * cursor.scale
                let hotspot = CursorSprites.hotspot(cursor.kind)
                let position = layout.contentPoint(x: cursor.x, y: cursor.y)
                uniforms.cursorRect = SIMD4(Float(Double(position.x) - size * Double(hotspot.x)),
                                            Float(Double(position.y) - size * Double(hotspot.y)), Float(size), Float(size))
                cursorBlurX = shutter * state.cursorVelocityX * Double(layout.content.width)
                cursorBlurY = shutter * state.cursorVelocityY * Double(layout.content.height)
                uniforms.cursorParams = SIMD4(1, Float(cursor.opacity), Float(cursorBlurX), Float(cursorBlurY))
            }

            let cameraBlur = (hypot(blurX, blurY) + abs(blurScale) * Double(max(layout.card.width, layout.card.height)) / 2) * scale
            let cursorBlur = hypot(cursorBlurX, cursorBlurY) * scale
            let magnitude = max(cameraBlur, cursorBlur > 2 ? cursorBlur : 0)
            var taps = 1
            if magnitude >= 0.75 {
                taps = min(16, max(4, Int((magnitude / 2).rounded(.up))))
            } else {
                blurX = 0; blurY = 0; blurScale = 0
                uniforms.cursorParams.z = 0
                uniforms.cursorParams.w = 0
            }
            uniforms.canvas.w = Float(taps)
            uniforms.blur = SIMD4(Float(blurX), Float(blurY), Float(blurScale), Float(layout.titleBarHeight))

            if settings.cursor.clickEffect != .none, !state.ripples.isEmpty {
                let ripples = state.ripples.suffix(4).map { ripple -> SIMD4<Float> in
                    let p = layout.contentPoint(x: ripple.x, y: ripple.y)
                    return SIMD4(Float(p.x), Float(p.y), Float(ripple.progress), 0)
                }
                uniforms.ripples.0 = ripples.count > 0 ? ripples[0] : SIMD4()
                uniforms.ripples.1 = ripples.count > 1 ? ripples[1] : SIMD4()
                uniforms.ripples.2 = ripples.count > 2 ? ripples[2] : SIMD4()
                uniforms.ripples.3 = ripples.count > 3 ? ripples[3] : SIMD4()
                let radius = Double(layout.cursorUnit) * settings.cursor.size * 1.1
                uniforms.rippleParams = SIMD4(Float(ripples.count), Float(radius),
                                              settings.cursor.clickEffect == .ring ? 2 : 1, 0)
                uniforms.rippleColor = settings.cursor.clickColor.simd
            }
        }

        // Camera picture-in-picture
        var cameraTexture = transparent
        if let pip = state.pip {
            var aspect = 16.0 / 9.0
            if let camera, let (texture, ref) = wrap(camera) {
                cameraTexture = texture
                keepAlive.append(ref)
                aspect = Double(texture.width) / Double(texture.height)
            }
            let style = settings.camera
            let rect = layout.pipRect(pip, shape: style.shape, cameraAspect: aspect)
            let rectAspect = Double(rect.width / rect.height)
            uniforms.pipRect = SIMD4(Float(rect.midX), Float(rect.midY), Float(rect.width / 2), Float(rect.height / 2))
            let radius = style.shape == .circle ? Double(rect.height) / 2 : style.cornerRadius * Double(rect.height)
            uniforms.pipStyle = SIMD4(1, Float(min(radius, Double(min(rect.width, rect.height)) / 2)),
                                      Float(style.borderWidth * Double(rect.height)), Float(style.shadowOpacity))
            uniforms.pipBorderColor = style.borderColor.simd
            uniforms.pipBackground = style.backgroundColor.simd
            uniforms.pipUV = rectAspect > aspect ? SIMD4(1, Float(aspect / rectAspect), style.isMirrored ? 1 : 0, 0)
                                                 : SIMD4(Float(rectAspect / aspect), 1, style.isMirrored ? 1 : 0, 0)
        }

        // Text and captions
        var quads: [(MTLTexture, QuadUniforms)] = []
        func addQuad(_ texture: MTLTexture, centreX: Double, centreY: Double, opacity: Double) {
            let width = Double(texture.width) / Double(canvas.width) * 2
            let height = Double(texture.height) / Double(canvas.height) * 2
            let x = centreX * 2 - 1 - width / 2
            let y = 1 - centreY * 2 - height / 2
            quads.append((texture, QuadUniforms(rect: SIMD4(Float(x), Float(y), Float(width), Float(height)),
                                                params: SIMD4(Float(opacity), 0, 0, 0))))
        }
        for overlayState in state.overlays {
            guard let overlay = project.timeline.textOverlays.first(where: { $0.id == overlayState.id }) else { continue }
            let spec = TextRasterizer.Spec(text: overlay.text, fontSize: (CGFloat(overlay.fontSize) * canvas.height).rounded(),
                                           weight: overlay.weight, color: overlay.color, background: overlay.backgroundColor,
                                           maxWidth: canvas.width * 0.9)
            if let texture = textTexture(spec) {
                addQuad(texture, centreX: overlay.positionX, centreY: overlay.positionY, opacity: overlayState.opacity)
            }
        }
        if let id = state.captionID, let caption = project.timeline.captions.first(where: { $0.id == id }) {
            let style = settings.captions
            let spec = TextRasterizer.Spec(text: caption.text, fontSize: (CGFloat(style.fontSize) * canvas.height).rounded(),
                                           weight: .semibold, color: style.color, background: style.backgroundColor,
                                           maxWidth: canvas.width * 0.8)
            if let texture = textTexture(spec) {
                addQuad(texture, centreX: 0.5, centreY: style.positionY, opacity: 1)
            }
        }

        // Encode
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let commands = queue.makeCommandBuffer(),
              let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else {
            throw RenderError.resource("command buffer")
        }
        encoder.setRenderPipelineState(try shared.compositePipeline(Self.pixelFormat))
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<FrameUniforms>.stride, index: 0)
        encoder.setFragmentTexture(screenTexture, index: 0)
        encoder.setFragmentTexture(cameraTexture, index: 1)
        encoder.setFragmentTexture(cursorTexture, index: 2)
        encoder.setFragmentTexture(backgroundTexture, index: 3)
        encoder.setFragmentSamplerState(shared.sampler, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        if !quads.isEmpty {
            encoder.setRenderPipelineState(try shared.quadPipeline(Self.pixelFormat))
            for (texture, quad) in quads {
                var quad = quad
                encoder.setVertexBytes(&quad, length: MemoryLayout<QuadUniforms>.stride, index: 0)
                encoder.setFragmentBytes(&quad, length: MemoryLayout<QuadUniforms>.stride, index: 0)
                encoder.setFragmentTexture(texture, index: 0)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            }
        }
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        withExtendedLifetime(keepAlive) {}
        if let error = commands.error { throw RenderError.gpu(error.localizedDescription) }
    }

    /// Creates a pixel buffer suitable as a render target.
    public static func makePixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                            pixelBufferAttributes as CFDictionary, &buffer)
        guard let buffer else { throw RenderError.resource("pixel buffer") }
        return buffer
    }
}
