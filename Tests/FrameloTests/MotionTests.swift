import Foundation
import Testing
@testable import FrameloCore

private func cursor(for project: Project, clicks: [(t: Double, x: Double, y: Double)]) -> TimelineCursor {
    let track = SyntheticMedia.cursorTrack(duration: project.duration.seconds, clicks: clicks)
    return TimelineCursor(timeMap: TimeMap(project: project), tracks: [project.sources[0].id: track])
}

@Suite struct AutoZoomTests {
    let settings = MotionSettings()

    @Test func clustersNearbyClicksAndSeparatesDistantOnes() {
        let clicks = [1.5, 2.0, 3.5, 12.0, 12.4].map { TimelineClick(time: $0, x: 0.3, y: 0.4) }
        let events = AutoZoomGenerator.generate(clicks: clicks, duration: 20, settings: settings)
        #expect(events.count == 2)
        #expect(events.filter { !$0.isAutomatic }.isEmpty)
        #expect(events[0].startTime.seconds < 1.5 && events[0].endTime.seconds > 3.5)
        #expect(events[1].startTime.seconds < 12 && events[1].endTime.seconds > 12.4)
        #expect(events[0].endTime < events[1].startTime)
        #expect(events[0].targetX == 0.3 && events[0].targetY == 0.4)
    }

    @Test func mergesEventsThatWouldBounce() {
        // Two clusters 3.2 s apart by clicks, but the first one's hold + zoom-out reaches into the second.
        let clicks = [TimelineClick(time: 2, x: 0.2, y: 0.2), TimelineClick(time: 5.2, x: 0.8, y: 0.8)]
        let events = AutoZoomGenerator.generate(clicks: clicks, duration: 20, settings: settings)
        #expect(events.count == 1)
        #expect(events[0].followsCursor)
        #expect(events[0].endTime.seconds > 5.2)
    }

    @Test func ignoresClicksOutsideThePictureAndTheTimeline() {
        let clicks = [TimelineClick(time: 2, x: 1.4, y: 0.5), TimelineClick(time: 40, x: 0.5, y: 0.5)]
        #expect(AutoZoomGenerator.generate(clicks: clicks, duration: 20, settings: settings).isEmpty)
    }

    @Test func regenerationPreservesManualEventsAndSuppressedRanges() {
        var project = makeProject(duration: 30)
        let manual = ZoomEvent(startTime: t(4), endTime: t(8), scale: 3, targetX: 0.9, targetY: 0.1)
        project.timeline.zoomEvents = [manual, ZoomEvent(startTime: t(20), endTime: t(22), isAutomatic: true)]
        project.timeline.suppressedAutoZoomRanges = [MediaRange(start: t(14), end: t(18))]
        let cursor = cursor(for: project, clicks: [(5, 0.5, 0.5), (15, 0.5, 0.5), (25, 0.2, 0.7)])

        MotionEngine.regenerateAutomaticZooms(in: &project.timeline, cursor: cursor, settings: project.settings.motion)
        let events = project.timeline.zoomEvents
        #expect(events.contains(manual))
        let automatic = events.filter(\.isAutomatic)
        // The click at 5 s is under the manual zoom, the one at 15 s is in a suppressed range: only 25 s remains.
        #expect(automatic.count == 1)
        #expect(automatic[0].range.contains(t(25)))

        project.settings.motion.autoZoomEnabled = false
        MotionEngine.regenerateAutomaticZooms(in: &project.timeline, cursor: cursor, settings: project.settings.motion)
        #expect(project.timeline.zoomEvents == [manual])
    }

    @Test func clicksFollowTheEdit() throws {
        var project = makeProject(duration: 20)
        try TimelineEditor.deleteRange(&project.timeline, range: MediaRange(start: t(2), end: t(6)))
        let cursor = cursor(for: project, clicks: [(4, 0.5, 0.5), (10, 0.4, 0.4)])
        // The click at 4 s was cut out; the one at 10 s moved 4 s earlier.
        #expect(cursor.clicks.count == 1)
        #expect(abs(cursor.clicks[0].time - 6) < 1e-6)
    }
}

@Suite struct MotionResolveTests {
    @Test func manualWinsOverOverlappingAutomatic() {
        var project = makeProject(duration: 30)
        let manual = ZoomEvent(startTime: t(5), endTime: t(9), scale: 2.5)
        let conflicting = ZoomEvent(startTime: t(8), endTime: t(12), isAutomatic: true)
        let free = ZoomEvent(startTime: t(20), endTime: t(24), isAutomatic: true)
        project.timeline.zoomEvents = [manual, conflicting, free]
        let resolved = MotionEngine.resolve(timeline: project.timeline, cursor: .empty)
        #expect(resolved.events.map(\.id) == [manual.id, free.id])
    }

    @Test func overlappingManualEventsAreSequenced() {
        var project = makeProject(duration: 30)
        project.timeline.zoomEvents = [ZoomEvent(startTime: t(2), endTime: t(8)), ZoomEvent(startTime: t(6), endTime: t(12))]
        let resolved = MotionEngine.resolve(timeline: project.timeline, cursor: .empty)
        #expect(resolved.events.count == 2)
        #expect(resolved.events[1].startTime == t(8))
        for (a, b) in zip(resolved.path.zooms, resolved.path.zooms.dropFirst()) { #expect(a.end <= b.start) }
    }

    @Test func viewportNeverLeavesTheContent() {
        var project = makeProject(duration: 20)
        project.timeline.zoomEvents = [
            ZoomEvent(startTime: t(1), endTime: t(6), scale: 3, targetX: 0, targetY: 1, followsCursor: false),
            ZoomEvent(startTime: t(8), endTime: t(15), scale: 4, targetX: 0.98, targetY: 0.02),
        ]
        let cursor = cursor(for: project, clicks: [(9, 0.99, 0.01), (11, 0.01, 0.99), (13, 1, 1)])
        let path = MotionEngine.resolve(timeline: project.timeline, cursor: cursor).path
        for i in 0...(20 * 240) {
            let state = path.state(at: Double(i) / 240)
            let half = 0.5 / state.scale
            #expect(state.scale >= 1)
            #expect(state.centerX >= half - 1e-9 && state.centerX <= 1 - half + 1e-9)
            #expect(state.centerY >= half - 1e-9 && state.centerY <= 1 - half + 1e-9)
        }
    }

    @Test(arguments: Easing.allCases) func cameraNeverJumps(easing: Easing) {
        var project = makeProject(duration: 30)
        project.timeline.zoomEvents = [
            ZoomEvent(startTime: t(1), endTime: t(5), scale: 2.5, targetX: 0.2, targetY: 0.3, easing: easing),
            // Starts exactly where the previous one ends, with a far-away target and instant transitions requested.
            ZoomEvent(startTime: t(5), endTime: t(9), scale: 4, targetX: 0.9, targetY: 0.8, easing: easing, transitionIn: 0, transitionOut: 0),
            ZoomEvent(startTime: t(12), endTime: t(12.2), scale: 6, easing: easing),   // too short: dropped
            ZoomEvent(startTime: t(14), endTime: t(22), scale: 2, targetX: 0.5, targetY: 0.5, easing: easing, isAutomatic: true),
        ]
        let cursor = cursor(for: project, clicks: [(2, 0.2, 0.3), (15, 0.1, 0.9), (17, 0.9, 0.1), (19, 0.5, 0.5)])
        let resolved = MotionEngine.resolve(timeline: project.timeline, cursor: cursor)
        #expect(resolved.events.count == 3)

        // Sampled at 240 Hz, no single step may move the view by more than a small fraction of the frame.
        var previous = resolved.path.state(at: 0)
        var worst = 0.0
        for i in 1...(30 * 240) {
            let state = resolved.path.state(at: Double(i) / 240)
            let step = max(abs(state.centerX - previous.centerX), abs(state.centerY - previous.centerY),
                           abs(state.viewport - previous.viewport))
            worst = max(worst, step)
            previous = state
        }
        // A cut would show up as a step of 0.3 or more.
        #expect(worst < 0.05, "largest 1/240 s step was \(worst)")
        #expect(resolved.path.state(at: 0) == .identity)
        #expect(resolved.path.state(at: 29.9) == .identity)
    }

    @Test func keyframesOverrideZoomsAndBlendInAndOut() {
        var project = makeProject(duration: 30)
        project.timeline.zoomEvents = [ZoomEvent(startTime: t(9), endTime: t(13), scale: 5), ZoomEvent(startTime: t(20), endTime: t(24))]
        project.timeline.keyframes = [
            MotionKeyframe(timestamp: t(10), scale: 2, positionX: 0.3, positionY: 0.3),
            MotionKeyframe(timestamp: t(12), scale: 3, positionX: 0.7, positionY: 0.6, easing: .spring),
        ]
        let resolved = MotionEngine.resolve(timeline: project.timeline, cursor: .empty)
        #expect(resolved.events.count == 1)
        let path = resolved.path
        #expect(path.state(at: 9) == .identity)
        #expect(abs(path.state(at: 10).scale - 2) < 1e-9)
        #expect(abs(path.state(at: 12 - 1e-9).scale - 3) < 1e-3)
        #expect(path.state(at: 13) == .identity)
        var previous = path.state(at: 8)
        for i in 1...(6 * 240) {
            let state = path.state(at: 8 + Double(i) / 240)
            #expect(abs(state.centerX - previous.centerX) < 0.03 && abs(state.viewport - previous.viewport) < 0.03)
            previous = state
        }
    }

    @Test func followStartsAtRestOnTheEventTarget() {
        var project = makeProject(duration: 20)
        let event = ZoomEvent(startTime: t(2), endTime: t(10), scale: 2, targetX: 0.3, targetY: 0.3)
        project.timeline.zoomEvents = [event]
        let cursor = cursor(for: project, clicks: [(3, 0.3, 0.3), (6, 0.75, 0.7)])
        let zoom = MotionEngine.resolve(timeline: project.timeline, cursor: cursor).path.zooms[0]
        #expect(zoom.targets.count > 100)
        #expect(abs(zoom.targets[0].x - 0.3) < 1e-9)
        // By the end the camera has followed the cursor to the second click (to within its dead zone).
        #expect(abs(zoom.targets.last!.x - 0.75) < 0.07)
        #expect(abs(zoom.targets.last!.y - 0.7) < 0.07)
    }
}

@Suite struct CursorSmootherTests {
    @Test func smoothingAddsNoLagAndRestsOnClickTargets() {
        // Cursor moves to a target, stops, and is clicked while resting.
        let track = SyntheticMedia.cursorTrack(duration: 6, clicks: [(2, 0.8, 0.2), (4, 0.8, 0.2)])
        let resting = CursorSmoother.position(in: track, at: 3, smoothing: 1)!
        #expect(abs(resting.x - 0.8) < 1e-6 && abs(resting.y - 0.2) < 1e-6)
        // On a straight, constant-speed stretch the symmetric kernel returns the raw position.
        let raw = track.position(at: 1)!
        let smooth = CursorSmoother.position(in: track, at: 1, smoothing: 1)!
        #expect(abs(raw.x - smooth.x) < 1e-6)
        // No smoothing returns the raw path.
        let corner = track.position(at: 2)!
        #expect(CursorSmoother.position(in: track, at: 2, smoothing: 0)! == corner)
    }

    @Test func smoothingReducesJitter() {
        var track = CursorTrack()
        var generator = SeededGenerator(seed: 7)
        for i in 0..<600 {
            let time = Double(i) / 120
            track.samples.append(CursorSample(t: time, x: 0.2 + time * 0.1 + Double.random(in: -0.004...0.004, using: &generator), y: 0.5))
        }
        func roughness(_ smoothing: Double) -> Double {
            var total = 0.0
            for i in 60..<540 {
                let a = CursorSmoother.position(in: track, at: Double(i - 1) / 120, smoothing: smoothing)!.x
                let b = CursorSmoother.position(in: track, at: Double(i) / 120, smoothing: smoothing)!.x
                let c = CursorSmoother.position(in: track, at: Double(i + 1) / 120, smoothing: smoothing)!.x
                total += abs(a - 2 * b + c)
            }
            return total
        }
        #expect(roughness(0.6) < roughness(0) * 0.1)
    }
}

@Suite struct FrameStateTests {
    private func plan() throws -> RenderPlan {
        var project = makeProject(duration: 20)
        project.sources[0].camera = MediaFile(relativePath: "media/camera.mov", startOffset: 0.5, duration: 19, pixelWidth: 1280, pixelHeight: 720)
        project.settings.camera.isVisible = true
        try TimelineEditor.deleteRange(&project.timeline, range: MediaRange(start: t(8), end: t(10)), ripple: false)
        project.timeline.videoClips[1].transitionIn = ClipTransition(kind: .zoomFade, duration: 0.5)
        project.timeline.zoomEvents = [ZoomEvent(startTime: t(2), endTime: t(6), scale: 2.5, targetX: 0.3, targetY: 0.4)]
        project.timeline.textOverlays = [TextOverlay(text: "Hi", startTime: t(1), endTime: t(3), fadeDuration: 0.5)]
        project.timeline.captions = [Caption(text: "Caption", startTime: t(4), endTime: t(5))]
        let track = SyntheticMedia.cursorTrack(duration: 20, clicks: [(3, 0.3, 0.4), (12, 0.6, 0.6)])
        return RenderPlan(project: project, cursorTracks: [project.sources[0].id: track])
    }

    @Test func describesScreenCursorRipplesCameraAndOverlays() throws {
        let evaluator = try plan().evaluator
        let zoomed = evaluator.evaluate(at: t(3.1))
        #expect(zoomed.screen?.sourceTime == t(3.1))
        #expect(zoomed.camera.scale > 2.4)
        #expect(zoomed.cursor != nil)
        #expect(zoomed.ripples.count == 1 && zoomed.ripples[0].progress > 0 && zoomed.ripples[0].progress < 0.3)
        #expect(zoomed.pip != nil && zoomed.pip!.height < 0.24)   // camera shrinks while zoomed in
        #expect(zoomed.overlays.isEmpty)
        #expect(evaluator.evaluate(at: t(1.25)).overlays.first?.opacity == 0.5)
        #expect(evaluator.evaluate(at: t(4.5)).captionID != nil)

        let pressed = evaluator.evaluate(at: t(3.05))
        #expect(pressed.cursor!.scale < evaluator.evaluate(at: t(1)).cursor!.scale)

        let gap = evaluator.evaluate(at: t(9))
        #expect(gap.screen == nil && gap.cursor == nil && gap.pip == nil && gap.ripples.isEmpty)

        let entering = evaluator.evaluate(at: t(10.1))
        #expect(entering.screen!.opacity < 1 && entering.screen!.transitionScale < 1)
        #expect(evaluator.evaluate(at: t(11)).screen!.opacity == 1)

        // Before the camera file starts there is no picture-in-picture.
        #expect(evaluator.evaluate(at: t(0.2)).pip == nil)
    }

    @Test func previewAndExportPathsProduceIdenticalStates() throws {
        // Two independently built plans from the same project, evaluated in different orders
        // (export walks forward, preview scrubs randomly) must agree exactly.
        let a = try plan()
        let b = RenderPlan(project: a.project, cursorTracks: a.cursor.tracks)
        let times = (0..<600).map { MediaTime(ticks: Int64($0) * 2000) }
        let forward = times.map { a.evaluator.evaluate(at: $0) }
        var generator = SeededGenerator(seed: 3)
        let shuffled = times.shuffled(using: &generator)
        var scrubbed: [MediaTime: FrameState] = [:]
        for time in shuffled { scrubbed[time] = b.evaluator.evaluate(at: time) }
        for (time, state) in zip(times, forward) { #expect(scrubbed[time] == state) }
    }
}
