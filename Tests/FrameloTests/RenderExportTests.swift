@preconcurrency import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import FrameloCore

/// A project on disk backed by synthetic media.
struct Fixture {
    var store: ProjectStore
    var root: URL
    var package: URL
    var project: Project

    static func make(duration: Double = 4, fps: Int = 30, camera: Bool = false, audio: Bool = false,
                     variableFrameRate: Bool = false) async throws -> Fixture {
        let root = SyntheticMedia.temporaryDirectory("framelo-render")
        let store = ProjectStore(location: LibraryLocation(root: root))
        let id = UUID()
        let package = try await store.createPackage(for: id)
        let times = variableFrameRate ? SyntheticMedia.variableTimes(duration: duration)
                                      : SyntheticMedia.constantTimes(duration: duration, fps: fps)
        try await SyntheticMedia.writeVideo(to: package.appendingPathComponent(RecordingJournal.TrackKind.screen.relativePath), times: times)
        var journal = RecordingJournal(id: id, name: "Fixture", config: RecordingConfig(target: .display(id: 1)))
        journal.capture = CaptureInfo(x: 0, y: 0, width: 320, height: 240, scale: 1)
        journal.setOffset(0, for: .screen)
        if camera {
            try await SyntheticMedia.writeVideo(to: package.appendingPathComponent(RecordingJournal.TrackKind.camera.relativePath),
                                                width: 160, height: 120, times: SyntheticMedia.constantTimes(duration: duration, fps: 30))
            journal.setOffset(0, for: .camera)
        }
        if audio {
            // Stored with the system-audio file name; the container is detected from its contents.
            let url = package.appendingPathComponent("media/system-audio.caf")
            try SyntheticMedia.writeAudio(to: url, duration: duration, clickTimes: [1, 2, 3])
        }
        var project = try await RecordingFinalizer.buildProject(package: package, journal: journal, recovered: false)
        if audio {
            project.sources[0].systemAudio = MediaFile(relativePath: "media/system-audio.caf", duration: duration, hasAudio: true)
            project.timeline.tracks.append(TimelineTrack(name: "System Audio", type: .systemAudio))
        }
        return Fixture(store: store, root: root, package: package, project: project)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }

    var tempDirectory: URL { store.location.exportTempDirectory }
    var cursorTracks: [UUID: CursorTrack] {
        [project.sources[0].id: SyntheticMedia.cursorTrack(duration: project.duration.seconds,
                                                           clicks: [(1.0, 0.3, 0.6), (2.5, 0.7, 0.4)])]
    }
}

func pixel(_ buffer: CVPixelBuffer, _ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
    let p = base + y * CVPixelBufferGetBytesPerRow(buffer) + x * 4
    return (Int(p[2]), Int(p[1]), Int(p[0]))
}

func maxDifference(_ a: CVPixelBuffer, _ b: CVPixelBuffer) -> Int {
    CVPixelBufferLockBaseAddress(a, .readOnly)
    CVPixelBufferLockBaseAddress(b, .readOnly)
    defer {
        CVPixelBufferUnlockBaseAddress(a, .readOnly)
        CVPixelBufferUnlockBaseAddress(b, .readOnly)
    }
    let width = CVPixelBufferGetWidth(a), height = CVPixelBufferGetHeight(a)
    guard width == CVPixelBufferGetWidth(b), height == CVPixelBufferGetHeight(b) else { return 255 }
    let pa = CVPixelBufferGetBaseAddress(a)!.assumingMemoryBound(to: UInt8.self)
    let pb = CVPixelBufferGetBaseAddress(b)!.assumingMemoryBound(to: UInt8.self)
    let sa = CVPixelBufferGetBytesPerRow(a), sb = CVPixelBufferGetBytesPerRow(b)
    var worst = 0
    for y in 0..<height {
        for x in 0..<(width * 4) where x % 4 != 3 {
            worst = max(worst, abs(Int(pa[y * sa + x]) - Int(pb[y * sb + x])))
        }
    }
    return worst
}

func writePNG(_ buffer: CVPixelBuffer, name: String) {
    guard let directory = ProcessInfo.processInfo.environment["FRAMELO_TEST_OUTPUT"] else { return }
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let info = CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: CVPixelBufferGetWidth(buffer),
                                  height: CVPixelBufferGetHeight(buffer), bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info),
          let image = context.makeImage() else { return }
    let url = URL(fileURLWithPath: directory).appendingPathComponent(name)
    if let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) {
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
}

@Suite(.serialized) struct RendererTests {
    @Test func drawsBackgroundCardAndGap() throws {
        var project = makeProject(duration: 4)
        project.sources[0].screen = MediaFile(relativePath: "x", duration: 4, pixelWidth: 320, pixelHeight: 240)
        project.settings.aspect = AspectRatio(kind: .standard)
        project.settings.background = BackgroundStyle(kind: .solid, color: RGBAColor(r: 1, g: 0, b: 0))
        project.settings.screen = ScreenStyle(padding: 0.1, cornerRadius: 0, shadowOpacity: 0, shadowRadius: 0)
        project.settings.cursor.isVisible = false
        let plan = RenderPlan(project: project, cursorTracks: [:])
        let renderer = try MetalRenderer()
        let output = try MetalRenderer.makePixelBuffer(width: 640, height: 480)
        let frame = SyntheticMedia.frame(index: 0, width: 320, height: 240)   // body colour (80, 60, 40)

        try renderer.render(state: plan.evaluator.evaluate(at: t(1)), plan: plan, screen: frame, camera: nil, into: output)
        let corner = pixel(output, 6, 6)
        #expect(corner.r > 250 && corner.g < 5 && corner.b < 5)
        let inside = pixel(output, 320, 400)
        #expect(abs(inside.r - 80) <= 2 && abs(inside.g - 60) <= 2 && abs(inside.b - 40) <= 2)
        // 10 % padding leaves 544×384; a 4:3 picture fits as 512×384, so the card starts at x = 64.
        #expect(pixel(output, 60, 240).r > 250)
        #expect(pixel(output, 68, 240).r < 120)

        // In a gap only the background is drawn.
        try renderer.render(state: plan.evaluator.evaluate(at: t(9)), plan: plan, screen: nil, camera: nil, into: output)
        #expect(pixel(output, 320, 400).r > 250)
    }

    @Test func zoomMagnifiesAroundTheTarget() throws {
        var project = makeProject(duration: 10)
        project.sources[0].screen = MediaFile(relativePath: "x", duration: 10, pixelWidth: 320, pixelHeight: 240)
        project.settings.aspect = AspectRatio(kind: .standard)
        project.settings.background = BackgroundStyle(kind: .solid, color: RGBAColor(r: 0, g: 0, b: 1))
        project.settings.screen = ScreenStyle(padding: 0, cornerRadius: 0, shadowOpacity: 0, shadowRadius: 0)
        project.settings.cursor.isVisible = false
        project.settings.motion.motionBlur = 0
        // Zoom on the top-left quarter, where the index strip is: bit 0 of index 1 is the white block at the far left.
        project.timeline.zoomEvents = [ZoomEvent(startTime: t(1), endTime: t(9), scale: 2, targetX: 0.25, targetY: 0.25, followsCursor: false)]
        let plan = RenderPlan(project: project, cursorTracks: [:])
        let renderer = try MetalRenderer()
        let output = try MetalRenderer.makePixelBuffer(width: 640, height: 480)
        let frame = SyntheticMedia.frame(index: 1, width: 320, height: 240)

        try renderer.render(state: plan.evaluator.evaluate(at: t(0.5)), plan: plan, screen: frame, camera: nil, into: output)
        // Un-zoomed: the first strip block (20 source px wide) spans 0..<40 output px.
        #expect(pixel(output, 20, 10).r > 240)
        #expect(pixel(output, 60, 10).r < 15)

        try renderer.render(state: plan.evaluator.evaluate(at: t(5)), plan: plan, screen: frame, camera: nil, into: output)
        // 2× on the top-left quarter: the same block now spans 0..<80 output px.
        #expect(pixel(output, 60, 10).r > 240)
        #expect(pixel(output, 100, 10).r < 15)
    }

    @Test func rendersAFullyStyledFrame() throws {
        var project = makeProject(duration: 10)
        project.sources[0].screen = MediaFile(relativePath: "x", duration: 10, pixelWidth: 320, pixelHeight: 240)
        project.sources[0].camera = MediaFile(relativePath: "c", duration: 10, pixelWidth: 160, pixelHeight: 120)
        project.sources[0].capture = CaptureInfo(x: 0, y: 0, width: 640, height: 480, scale: 1)
        project.settings.aspect = AspectRatio(kind: .wide)
        project.settings.screen.frame = .window
        project.settings.camera.isVisible = true
        project.timeline.textOverlays = [TextOverlay(text: "Framelo", startTime: t(0), endTime: t(10))]
        project.timeline.captions = [Caption(text: "Rendered by the Metal compositor", startTime: t(0), endTime: t(10))]
        project.timeline.zoomEvents = [ZoomEvent(startTime: t(4), endTime: t(9), scale: 1.8, targetX: 0.4, targetY: 0.55)]
        let track = SyntheticMedia.cursorTrack(duration: 10, clicks: [(2.0, 0.5, 0.6), (5.0, 0.45, 0.6)])
        let plan = RenderPlan(project: project, cursorTracks: [project.sources[0].id: track])
        let renderer = try MetalRenderer()
        let output = try MetalRenderer.makePixelBuffer(width: 1280, height: 720)
        let screen = SyntheticMedia.frame(index: 5, width: 320, height: 240)
        let camera = SyntheticMedia.frame(index: 9, width: 160, height: 120)

        for (seconds, name) in [(2.1, "styled-click.png"), (4.35, "styled-zooming.png"), (6.0, "styled-zoomed.png")] {
            let state = plan.evaluator.evaluate(at: t(seconds))
            try renderer.render(state: state, plan: plan, screen: screen, camera: camera, into: output)
            writePNG(output, name: name)
        }
        // The gradient background is visible in the corner, and the result is not a flat image.
        let corner = pixel(output, 4, 4)
        let middle = pixel(output, 640, 360)
        #expect(corner.b > 150)
        #expect(abs(corner.r - middle.r) + abs(corner.g - middle.g) + abs(corner.b - middle.b) > 30)
    }
}

@Suite(.serialized) struct CompositionTests {
    @Test func previewAndExportPathsRenderIdenticalPixels() async throws {
        let fixture = try await Fixture.make(duration: 3, camera: true)
        defer { fixture.cleanUp() }
        var project = fixture.project
        project.timeline.zoomEvents = [ZoomEvent(startTime: t(0.5), endTime: t(2.8), scale: 2)]
        project.timeline.textOverlays = [TextOverlay(text: "Same", startTime: t(0), endTime: t(3))]
        let built = try await CompositionBuilder.build(project: project, package: fixture.package)
        let plan = RenderPlan(project: project, cursorTracks: fixture.cursorTracks)
        let size = CGSize(width: 640, height: 480)
        let times = [0.2, 1.0, 1.7, 2.6].map { MediaTime(seconds: $0) }

        // Preview path: the compositor driven on demand, as the player and thumbnailer do.
        let generator = AVAssetImageGenerator(asset: built.composition)
        generator.videoComposition = built.videoComposition(context: built.makeContext(plan: plan), renderSize: size, frameRate: 30)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        var previews: [MediaTime: CGImage] = [:]
        for time in times { previews[time] = try await generator.image(at: time.cmTime).image }

        // Export path: the compositor driven sequentially by an asset reader.
        let reader = try AVAssetReader(asset: built.composition)
        let output = AVAssetReaderVideoCompositionOutput(videoTracks: try await built.composition.loadTracks(withMediaType: .video),
                                                         videoSettings: MetalRenderer.pixelBufferAttributes)
        output.videoComposition = built.videoComposition(context: built.makeContext(plan: plan), renderSize: size, frameRate: 30)
        reader.add(output)
        reader.startReading()
        var compared = 0
        while let sample = output.copyNextSampleBuffer() {
            let time = MediaTime(sample.presentationTimeStamp)
            guard let preview = previews[time], let exported = sample.imageBuffer else { continue }
            let previewBuffer = try MetalRenderer.makePixelBuffer(width: 640, height: 480)
            CVPixelBufferLockBaseAddress(previewBuffer, [])
            let info = CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            let context = CGContext(data: CVPixelBufferGetBaseAddress(previewBuffer), width: 640, height: 480, bitsPerComponent: 8,
                                    bytesPerRow: CVPixelBufferGetBytesPerRow(previewBuffer),
                                    space: preview.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info)!
            context.draw(preview, in: CGRect(x: 0, y: 0, width: 640, height: 480))
            CVPixelBufferUnlockBaseAddress(previewBuffer, [])
            #expect(maxDifference(previewBuffer, exported) <= 2, "frame at \(time) differs")
            compared += 1
        }
        #expect(compared == times.count)
    }

    @Test func compositionFollowsCutsSpeedAndGaps() async throws {
        let fixture = try await Fixture.make(duration: 4, camera: true, audio: true)
        defer { fixture.cleanUp() }
        var project = fixture.project
        try TimelineEditor.deleteRange(&project.timeline, range: MediaRange(start: t(1), end: t(2)), ripple: false)
        try TimelineEditor.setSpeed(&project.timeline, clipID: project.timeline.videoClips[1].id, speed: 2)
        let built = try await CompositionBuilder.build(project: project, package: fixture.package)
        // 1 s clip, 1 s gap, then 2 s of source at 2× = 1 s.
        #expect(built.duration == t(3))
        #expect(abs(built.composition.duration.seconds - 3) < 0.05)
        #expect(built.cameraTrackID != kCMPersistentTrackID_Invalid)
        #expect(built.hasAudio && built.audioMix != nil)
        #expect(try await built.composition.loadTracks(withMediaType: .video).count == 2)
    }
}

@Suite(.serialized) struct ExportTests {
    private func fullFrame(_ project: inout Project) {
        let preset = StylePreset.all.first { $0.id == "clean" }!
        project.settings.background = preset.background
        project.settings.screen = preset.screen
        project.settings.cursor.isVisible = false
        project.settings.motion.motionBlur = 0
    }

    @Test func exportsAVerifiedFileWithFrameAccurateEdits() async throws {
        let fixture = try await Fixture.make(duration: 4)
        defer { fixture.cleanUp() }
        var project = fixture.project
        fullFrame(&project)
        try TimelineEditor.deleteRange(&project.timeline, range: MediaRange(start: t(1), end: t(2)))
        try TimelineEditor.split(&project.timeline, at: t(2))
        try TimelineEditor.setSpeed(&project.timeline, clipID: project.timeline.videoClips[2].id, speed: 2)
        let map = TimeMap(project: project)
        #expect(map.duration == t(2.5))

        let destination = fixture.root.appendingPathComponent("out/export.mp4")
        let settings = ExportSettings(container: .mp4, codec: .h264, resolution: .p720, frameRate: 30, quality: .high)
        let progress = ProgressRecorder()
        let result = try await ExportService.export(project: project, package: fixture.package, cursorTracks: [:],
                                                    settings: settings, destination: destination,
                                                    tempDirectory: fixture.tempDirectory) { progress.record($0) }
        #expect(result.url == destination)
        #expect(result.width == 960 && result.height == 720)
        #expect(result.codec == "avc1" && !result.hasAudio)
        #expect(abs(result.duration - 2.5) < 0.07)
        #expect(abs(result.frameRate - 30) < 1)
        #expect(progress.values.first == 0 && progress.values.last == 1)
        #expect(progress.values == progress.values.sorted())
        #expect((try? FileManager.default.contentsOfDirectory(atPath: fixture.tempDirectory.path))?.isEmpty ?? true)

        // Every exported frame must show the source frame the time map says belongs there.
        let frames = try await SyntheticMedia.readFrames(destination)
        #expect(abs(frames.count - 75) <= 1)
        for frame in frames {
            guard case .clip(_, let source) = map.locate(MediaTime(seconds: frame.time)) else { continue }
            let expected = Int((source.seconds * 30 + 1e-6).rounded(.down))
            #expect(abs(frame.index - expected) <= 1, "at \(frame.time)s got source frame \(frame.index), expected \(expected)")
        }
        // The cut removed source frames 30..<60 entirely.
        #expect(!frames.contains { $0.index > 31 && $0.index < 59 })
    }

    @Test func exportsHEVCMovWithAudioAt60() async throws {
        let fixture = try await Fixture.make(duration: 3, camera: true, audio: true)
        defer { fixture.cleanUp() }
        var project = fixture.project
        project.settings.audio = AudioSettings(fadeIn: 0.3, fadeOut: 0.3)
        MotionEngine.regenerateAutomaticZooms(in: &project.timeline,
                                              cursor: TimelineCursor(timeMap: TimeMap(project: project), tracks: fixture.cursorTracks),
                                              settings: project.settings.motion)
        let destination = fixture.root.appendingPathComponent("export.mov")
        let settings = ExportSettings(container: .mov, codec: .hevc, resolution: .p720, frameRate: 60, quality: .standard)
        let result = try await ExportService.export(project: project, package: fixture.package, cursorTracks: fixture.cursorTracks,
                                                    settings: settings, destination: destination,
                                                    tempDirectory: fixture.tempDirectory) { _ in }
        #expect(result.codec == "hvc1" && result.hasAudio)
        #expect(abs(result.frameRate - 60) < 1.5)
        #expect(abs(result.duration - 3) < 0.07)
        #expect(result.fileSize > 10_000)
    }

    @Test func variableFrameRateSourceExportsAtConstantRate() async throws {
        let fixture = try await Fixture.make(duration: 5, variableFrameRate: true)
        defer { fixture.cleanUp() }
        var project = fixture.project
        fullFrame(&project)
        let destination = fixture.root.appendingPathComponent("vfr.mp4")
        let result = try await ExportService.export(project: project, package: fixture.package, cursorTracks: [:],
                                                    settings: ExportSettings(resolution: .p720, frameRate: 30),
                                                    destination: destination, tempDirectory: fixture.tempDirectory) { _ in }
        let frames = try await SyntheticMedia.readFrames(destination)
        #expect(abs(frames.count - Int(result.duration * 30)) <= 2)
        // Output times are evenly spaced even though the source frames were not.
        for (a, b) in zip(frames, frames.dropFirst()) { #expect(abs((b.time - a.time) - 1.0 / 30) < 0.002) }
        // Each output frame shows the latest source frame at or before its time (held frames repeat).
        let sourceTimes = SyntheticMedia.variableTimes(duration: 5)
        for frame in frames.dropLast() {
            let expected = (sourceTimes.lastIndex { $0 <= frame.time + 1e-4 }) ?? 0
            #expect(abs(frame.index - expected) <= 1, "at \(frame.time)s got \(frame.index), expected \(expected)")
        }
    }

    @Test func cancellationLeavesNothingBehind() async throws {
        let fixture = try await Fixture.make(duration: 20)
        defer { fixture.cleanUp() }
        let destination = fixture.root.appendingPathComponent("cancelled.mp4")
        let project = fixture.project
        let package = fixture.package
        let temp = fixture.tempDirectory
        let started = ProgressRecorder()
        let task = Task {
            try await ExportService.export(project: project, package: package, cursorTracks: [:],
                                           settings: ExportSettings(resolution: .p1080, frameRate: 60),
                                           destination: destination, tempDirectory: temp) { started.record($0) }
        }
        // Wait until frames are flowing (bounded, so a failing export cannot hang the suite).
        for _ in 0..<4000 where started.values.count < 3 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(started.values.count >= 3)
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("export finished instead of being cancelled")
        } catch ExportError.cancelled {
            // expected
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: temp.path)) ?? []
        #expect(leftovers.isEmpty, "left behind: \(leftovers)")
    }

    @Test func reportsMissingSourcesAndInvalidProjects() async throws {
        let fixture = try await Fixture.make(duration: 2)
        defer { fixture.cleanUp() }
        let destination = fixture.root.appendingPathComponent("never.mp4")
        var invalid = fixture.project
        invalid.timeline.videoClips[0].playbackSpeed = 99
        await #expect(throws: ExportError.self) {
            try await ExportService.export(project: invalid, package: fixture.package, cursorTracks: [:], settings: ExportSettings(),
                                           destination: destination, tempDirectory: fixture.tempDirectory) { _ in }
        }
        try FileManager.default.removeItem(at: fixture.package.appendingPathComponent(RecordingJournal.TrackKind.screen.relativePath))
        do {
            _ = try await ExportService.export(project: fixture.project, package: fixture.package, cursorTracks: [:],
                                               settings: ExportSettings(), destination: destination,
                                               tempDirectory: fixture.tempDirectory) { _ in }
            Issue.record("export succeeded without its source")
        } catch ExportError.missingSource(let name) {
            #expect(name == "screen.mov")
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func longTimelineWithManyEditsExports() async throws {
        // A long edit in miniature: 60 s of source cut into 30 clips with mixed speeds and gaps.
        let fixture = try await Fixture.make(duration: 60, fps: 10)
        defer { fixture.cleanUp() }
        var project = fixture.project
        fullFrame(&project)
        for i in 1..<30 {
            let clip = project.timeline.videoClips.first { $0.sourceStart <= t(Double(i) * 2) && $0.sourceEnd > t(Double(i) * 2) }!
            try TimelineEditor.split(&project.timeline, at: clip.timelineTime(forSource: t(Double(i) * 2)))
        }
        for (i, clip) in project.timeline.videoClips.enumerated() where i % 3 == 1 {
            try TimelineEditor.setSpeed(&project.timeline, clipID: clip.id, speed: 4)
        }
        try TimelineEditor.delete(&project.timeline, clipID: project.timeline.videoClips[5].id, ripple: false)
        try TimelineValidator.validate(project)
        let expected = project.duration.seconds
        let result = try await ExportService.export(project: project, package: fixture.package, cursorTracks: [:],
                                                    settings: ExportSettings(resolution: .p720, frameRate: 30, quality: .standard),
                                                    destination: fixture.root.appendingPathComponent("long.mp4"),
                                                    tempDirectory: fixture.tempDirectory) { _ in }
        #expect(abs(result.duration - expected) < 0.1)
    }
}

final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Double] = []
    func record(_ value: Double) { lock.withLock { stored.append(value) } }
    var values: [Double] { lock.withLock { stored } }
}
