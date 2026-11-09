import Foundation
import Testing
@testable import FrameloCore

func makeProject(duration: Double = 10) -> Project {
    let source = MediaSource(kind: .recording, name: "Test",
                             screen: MediaFile(relativePath: "media/screen.mov", duration: duration, pixelWidth: 1920, pixelHeight: 1080),
                             duration: duration)
    return Project.make(name: "Test", source: source)
}

func t(_ seconds: Double) -> MediaTime { MediaTime(seconds: seconds) }

@Suite struct MediaTimeTests {
    @Test func roundTripsFrameDurationsExactly() {
        for fps in [24, 25, 30, 50, 60, 120] {
            let frame = MediaTime(ticks: MediaTime.timescale / Int64(fps))
            #expect(frame.ticks * Int64(fps) == MediaTime.timescale)
        }
        #expect(MediaTime(MediaTime(seconds: 1.2345).cmTime) == MediaTime(seconds: 1.2345))
    }

    @Test func rangeIsHalfOpen() {
        let range = MediaRange(start: t(1), end: t(2))
        #expect(range.contains(t(1)))
        #expect(!range.contains(t(2)))
        #expect(!range.overlaps(MediaRange(start: t(2), end: t(3))))
        #expect(range.intersection(MediaRange(start: t(1.5), end: t(3))) == MediaRange(start: t(1.5), end: t(2)))
    }
}

@Suite struct EasingTests {
    @Test(arguments: Easing.allCases) func endpointsAreExact(easing: Easing) {
        #expect(abs(easing.value(0)) < 1e-9)
        #expect(abs(easing.value(1) - 1) < 1e-9)
        #expect(easing.value(-1) == easing.value(0))
        #expect(easing.value(2) == easing.value(1))
    }

    @Test func easeInOutStartsAndEndsAtRest() {
        let e = Easing.easeInOut
        #expect(e.value(0.001) < 1e-6)
        #expect(1 - e.value(0.999) < 1e-6)
        #expect(abs(e.value(0.5) - 0.5) < 1e-9)
    }

    @Test func monotonicCurvesNeverGoBackwards() {
        for easing in [Easing.linear, .easeIn, .easeOut, .easeInOut] {
            var previous = 0.0
            for i in 0...1000 {
                let v = easing.value(Double(i) / 1000)
                #expect(v >= previous - 1e-12)
                previous = v
            }
        }
    }

    @Test func springOvershootIsSmall() {
        let peak = (0...1000).map { Easing.spring.value(Double($0) / 1000) }.max() ?? 0
        #expect(peak > 1.0)
        #expect(peak < 1.05)
    }
}

@Suite struct TimeMapTests {
    @Test func identityForSingleClip() {
        let map = TimeMap(project: makeProject())
        #expect(map.duration == t(10))
        #expect(map.locate(t(3.5)) == .clip(segmentIndex: 0, sourceTime: t(3.5)))
        #expect(map.locate(t(10)) == .clip(segmentIndex: 0, sourceTime: t(10)))
        #expect(map.locate(t(10.5)) == .gap)
        #expect(map.gaps.isEmpty)
    }

    @Test func splitLosesAndDuplicatesNoFrame() throws {
        var project = makeProject()
        try TimelineEditor.split(&project.timeline, at: t(4))
        let map = TimeMap(project: project)
        #expect(map.segments.count == 2)
        let frame = MediaTime(ticks: 1000)
        // Walk every 60 fps frame: source time must equal timeline time on both sides of the cut.
        var time = MediaTime.zero
        while time < t(10) {
            guard case .clip(_, let source) = map.locate(time) else { Issue.record("gap at \(time)"); return }
            #expect(source == time)
            time += frame
        }
        #expect(map.locate(t(4)) == .clip(segmentIndex: 1, sourceTime: t(4)))
        #expect(map.locate(t(4) - MediaTime(ticks: 1)) == .clip(segmentIndex: 0, sourceTime: t(4) - MediaTime(ticks: 1)))
    }

    @Test func speedScalesDurationAndMapping() throws {
        var project = makeProject()
        let id = project.timeline.videoClips[0].id
        try TimelineEditor.setSpeed(&project.timeline, clipID: id, speed: 2)
        let map = TimeMap(project: project)
        #expect(map.duration == t(5))
        #expect(map.locate(t(2)) == .clip(segmentIndex: 0, sourceTime: t(4)))
        #expect(map.timelineTimes(forSource: t(4), sourceID: project.sources[0].id) == [t(2)])
    }

    @Test func gapsAreReported() throws {
        var project = makeProject()
        try TimelineEditor.deleteRange(&project.timeline, range: MediaRange(start: t(2), end: t(4)), ripple: false)
        let map = TimeMap(project: project)
        #expect(map.duration == t(10))
        #expect(map.gaps == [MediaRange(start: t(2), end: t(4))])
        #expect(map.locate(t(3)) == .gap)
        #expect(map.locate(t(4)) == .clip(segmentIndex: 1, sourceTime: t(4)))
    }

    @Test func roundTripSourceToTimeline() throws {
        var project = makeProject()
        try TimelineEditor.split(&project.timeline, at: t(3))
        try TimelineEditor.split(&project.timeline, at: t(7))
        let middle = project.timeline.videoClips[1].id
        try TimelineEditor.setSpeed(&project.timeline, clipID: middle, speed: 0.5)
        let map = TimeMap(project: project)
        #expect(map.duration == t(14))
        let sourceID = project.sources[0].id
        for seconds in stride(from: 0.0, to: 10.0, by: 0.25) {
            let times = map.timelineTimes(forSource: t(seconds), sourceID: sourceID)
            #expect(times.count == 1)
            guard let timeline = times.first, case .clip(_, let source) = map.locate(timeline) else {
                Issue.record("no mapping for \(seconds)"); continue
            }
            #expect(abs(source.ticks - t(seconds).ticks) <= 1)
        }
    }

    @Test func variableSpeedSegmentsStayContiguous() throws {
        var project = makeProject(duration: 3600)
        var cut = 100.0
        while cut < 3500 {
            try TimelineEditor.split(&project.timeline, at: project.timeline.videoClips.first { $0.sourceStart <= t(cut) && $0.sourceEnd > t(cut) }!.timelineTime(forSource: t(cut)))
            cut += 100
        }
        for (i, clip) in project.timeline.videoClips.enumerated() {
            try TimelineEditor.setSpeed(&project.timeline, clipID: clip.id, speed: [0.5, 1, 1.5, 2, 3][i % 5])
        }
        try TimelineValidator.validate(project)
        let map = TimeMap(project: project)
        #expect(map.gaps.isEmpty)
        for (a, b) in zip(map.segments, map.segments.dropFirst()) {
            #expect(a.timeline.end == b.timeline.start)
            #expect(a.sourceEnd == b.sourceStart)
        }
    }
}

@Suite struct TimelineEditorTests {
    @Test func trimWithRippleMovesLaterClips() throws {
        var project = makeProject()
        let ids = try TimelineEditor.split(&project.timeline, at: t(5))
        try TimelineEditor.trim(&project.timeline, clipID: ids.left, sourceEnd: t(3))
        let clips = project.timeline.videoClips
        #expect(clips[0].timelineDuration == t(3))
        #expect(clips[1].timelinePosition == t(3))
        #expect(project.timeline.duration == t(8))
        try TimelineValidator.validate(project)
    }

    @Test func trimHeadWithoutRippleKeepsEndInPlace() throws {
        var project = makeProject()
        let id = project.timeline.videoClips[0].id
        try TimelineEditor.trim(&project.timeline, clipID: id, sourceStart: t(2), ripple: false)
        let clip = project.timeline.videoClips[0]
        #expect(clip.timelinePosition == t(2))
        #expect(clip.timelineEnd == t(10))
    }

    @Test func deleteRangeRipplesAnnotations() throws {
        var project = makeProject()
        project.timeline.zoomEvents = [
            ZoomEvent(startTime: t(1), endTime: t(2)),
            ZoomEvent(startTime: t(3), endTime: t(5)),
            ZoomEvent(startTime: t(7), endTime: t(8)),
        ]
        project.timeline.captions = [Caption(text: "gone", startTime: t(4.2), endTime: t(4.8))]
        try TimelineEditor.deleteRange(&project.timeline, range: MediaRange(start: t(4), end: t(6)))
        #expect(project.timeline.duration == t(8))
        #expect(project.timeline.zoomEvents.map(\.startTime) == [t(1), t(3), t(5)])
        #expect(project.timeline.zoomEvents[1].endTime == t(4))
        #expect(project.timeline.captions.isEmpty)
        try TimelineValidator.validate(project)
    }

    @Test func reorderRepacksWithoutGaps() throws {
        var project = makeProject()
        let first = try TimelineEditor.split(&project.timeline, at: t(2))
        try TimelineEditor.split(&project.timeline, at: t(6))
        try TimelineEditor.reorder(&project.timeline, clipID: first.left, toIndex: 2)
        let clips = project.timeline.videoClips
        #expect(clips.map(\.sourceStart) == [t(2), t(6), t(0)])
        #expect(clips.map(\.timelinePosition) == [t(0), t(4), t(8)])
        #expect(TimeMap(project: project).gaps.isEmpty)
        try TimelineValidator.validate(project)
    }

    @Test func splitTooCloseToEdgeIsRejected() {
        var project = makeProject()
        #expect(throws: TimelineEditError.tooCloseToEdge) {
            try TimelineEditor.split(&project.timeline, at: MediaTime(ticks: 10))
        }
        #expect(throws: TimelineEditError.nothingAtPlayhead) {
            try TimelineEditor.split(&project.timeline, at: t(11))
        }
    }

    @Test func removingAutomaticZoomSuppressesItsRange() {
        var project = makeProject()
        let auto = ZoomEvent(startTime: t(1), endTime: t(3), isAutomatic: true)
        let manual = ZoomEvent(startTime: t(5), endTime: t(6))
        project.timeline.zoomEvents = [auto, manual]
        TimelineEditor.removeZoom(&project.timeline, id: auto.id)
        TimelineEditor.removeZoom(&project.timeline, id: manual.id)
        #expect(project.timeline.suppressedAutoZoomRanges == [auto.range])
        #expect(project.timeline.zoomEvents.isEmpty)
    }
}

@Suite struct ValidatorTests {
    @Test func rejectsOverlapSpeedAndBounds() throws {
        var project = makeProject()
        try TimelineValidator.validate(project)

        var overlapping = project
        var second = overlapping.timeline.videoClips[0]
        second.id = UUID()
        second.timelinePosition = t(5)
        overlapping.timeline.videoClips.append(second)
        #expect(throws: TimelineValidationError.self) { try TimelineValidator.validate(overlapping) }

        var fast = project
        fast.timeline.videoClips[0].playbackSpeed = 50
        #expect(throws: TimelineValidationError.self) { try TimelineValidator.validate(fast) }

        var beyond = project
        beyond.timeline.videoClips[0].sourceEnd = t(12)
        #expect(throws: TimelineValidationError.self) { try TimelineValidator.validate(beyond) }

        project.timeline.zoomEvents = [ZoomEvent(startTime: t(3), endTime: t(2))]
        #expect(throws: TimelineValidationError.self) { try TimelineValidator.validate(project) }
    }
}

@Suite struct CommandStackTests {
    @Test func applyThenUndoIsIdentity() throws {
        var project = makeProject()
        project.timeline.zoomEvents = [ZoomEvent(startTime: t(1), endTime: t(3))]
        let original = project
        var stack = CommandStack()
        let clipID = project.timeline.videoClips[0].id

        try stack.perform(TimelineEditCommand.split(at: t(4)), on: &project)
        try stack.perform(TimelineEditCommand.setSpeed(clipID: clipID, speed: 2), on: &project)
        try stack.perform(TimelineEditCommand.deleteRange(MediaRange(start: t(0.5), end: t(1))), on: &project)
        try stack.perform(SetValueCommand("Padding", \Project.settings.screen.padding, 0.2), on: &project)
        let edited = project
        #expect(edited.timeline != original.timeline)

        while stack.canUndo { try stack.undo(on: &project) }
        #expect(project.timeline == original.timeline)
        #expect(project.settings == original.settings)

        while stack.canRedo { try stack.redo(on: &project) }
        #expect(project.timeline == edited.timeline)
        #expect(project.settings == edited.settings)
    }

    @Test func invalidCommandLeavesProjectUntouched() {
        var project = makeProject()
        let before = project
        var stack = CommandStack()
        let clipID = project.timeline.videoClips[0].id
        #expect(throws: TimelineValidationError.self) {
            try stack.perform(TimelineEditCommand.setSpeed(clipID: clipID, speed: 100), on: &project)
        }
        #expect(throws: TimelineEditError.self) {
            try stack.perform(TimelineEditCommand.delete(clipID: UUID()), on: &project)
        }
        #expect(project == before)
        #expect(!stack.canUndo)
        #expect(stack.revision == 0)
    }

    @Test func sliderDragCoalescesIntoOneUndoStep() throws {
        var project = makeProject()
        var stack = CommandStack()
        let start = Date()
        for i in 1...20 {
            let command = SetValueCommand("Padding", \Project.settings.screen.padding, Double(i) / 100, coalescingKey: "padding")
            try stack.perform(command, on: &project, now: start.addingTimeInterval(Double(i) * 0.05))
        }
        #expect(project.settings.screen.padding == 0.2)
        try stack.undo(on: &project)
        #expect(project.settings.screen.padding == ScreenStyle().padding)
        #expect(!stack.canUndo)
    }
}

@Suite struct ProjectStoreTests {
    @Test func savesLoadsListsAndRoundTrips() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("framelo-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(location: LibraryLocation(root: root))
        var project = makeProject()
        project.timeline.zoomEvents = [ZoomEvent(startTime: t(1), endTime: t(2), easing: .spring, isAutomatic: true)]
        project.timeline.keyframes = [MotionKeyframe(timestamp: t(4), scale: 1.5)]
        project.timeline.textOverlays = [TextOverlay(text: "Hello", startTime: t(0), endTime: t(2))]
        try await store.save(project)

        let loaded = try await store.load(id: project.id)
        // Dates are stored with second precision; everything else must match exactly.
        #expect(loaded.timeline == project.timeline)
        #expect(loaded.settings == project.settings)
        #expect(loaded.sources.map(\.id) == project.sources.map(\.id))

        let list = await store.list()
        #expect(list.map(\.id) == [project.id])
        #expect(list[0].duration == 10)

        await #expect(throws: ProjectStoreError.self) { try await store.load(id: UUID()) }
    }
}
