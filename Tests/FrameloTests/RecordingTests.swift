@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import FrameloCore

@Suite struct RecordingClockTests {
    private func host(_ seconds: Double) -> CMTime { CMTime(seconds: 1000 + seconds, preferredTimescale: 1_000_000) }

    @Test func pausesAreRemovedFromSessionTime() {
        let clock = RecordingClock()
        #expect(clock.sessionTime(forHost: host(0)) == nil)
        clock.begin(at: host(0))
        #expect(abs(clock.sessionTime(forHost: host(2))!.seconds - 2) < 1e-6)
        clock.pause(at: host(3))
        #expect(clock.sessionTime(forHost: host(4)) == nil)
        clock.resume(at: host(8))
        // 5 s were spent paused: host 9 is session 4.
        #expect(abs(clock.sessionTime(forHost: host(9))!.seconds - 4) < 1e-6)
        clock.pause(at: host(10))
        clock.resume(at: host(11))
        let end = clock.stop(at: host(13))
        #expect(abs(end.seconds - 7) < 1e-6)
        #expect(clock.sessionTime(forHost: host(14)) == nil)
        #expect(abs(clock.elapsed - 7) < 1e-6)
    }

    @Test func stoppingWhilePausedEndsAtThePause() {
        let clock = RecordingClock()
        clock.begin(at: host(0))
        clock.pause(at: host(5))
        #expect(abs(clock.stop(at: host(60)).seconds - 5) < 1e-6)
    }
}

@Suite struct DriftTests {
    @Test func ignoresNegligibleDriftAndCorrectsRealDrift() {
        #expect(DriftAnalysis.rateCorrection(mediaDuration: 600.005, wallDuration: 600) == nil)
        let rate = DriftAnalysis.rateCorrection(mediaDuration: 600.06, wallDuration: 600)
        #expect(rate != nil)
        #expect(abs((rate ?? 0) - 1.0001) < 1e-6)
        // A 3 % mismatch is dropped audio, not drift: never stretch.
        #expect(DriftAnalysis.rateCorrection(mediaDuration: 582, wallDuration: 600) == nil)
        #expect(DriftAnalysis.rateCorrection(mediaDuration: 2.5, wallDuration: 2) == nil)
    }
}

@Suite struct CursorTrackTests {
    @Test func parsesLinesAndToleratesATruncatedTail() {
        var text = CursorTrack.encodeMove(CursorSample(t: 0, x: 0.1, y: 0.2))
        text += CursorTrack.encodeMove(CursorSample(t: 1, x: 0.3, y: 0.4))
        text += CursorTrack.encodeDown(t: 1.2, x: 0.3, y: 0.4)
        text += CursorTrack.encodeUp(t: 1.3)
        text += CursorTrack.encodeKind(t: 1.5, kind: .iBeam)
        text += "{\"k\":\"m\",\"t\":2.0,\"x\":0.5"   // the process died mid-line
        let track = CursorTrack.parse(jsonLines: text)
        #expect(track.samples.count == 2)
        #expect(track.clicks == [ClickEvent(t: 1.2, x: 0.3, y: 0.4, releaseTime: 1.3)])
        #expect(track.kind(at: 1.4) == .arrow)
        #expect(track.kind(at: 2) == .iBeam)
        let middle = track.position(at: 0.5)!
        #expect(abs(middle.x - 0.2) < 1e-9 && abs(middle.y - 0.3) < 1e-9)
    }
}

@Suite(.serialized) struct TrackWriterTests {
    /// Appends frames the way a recorder does, waiting for the real-time encoder when it is busy.
    private func append(_ writer: TrackWriter, frames: Range<Int>, fps: Int, offset: Double) async throws {
        for index in frames {
            while !writer.isReady { try await Task.sleep(for: .milliseconds(1)) }
            let time = MediaTime(seconds: offset + Double(index) / Double(fps)).cmTime
            #expect(writer.append(pixelBuffer: SyntheticMedia.frame(index: index, width: 320, height: 240), at: time))
        }
    }

    @Test func videoFileStartsAtItsFirstSampleAndReportsItsOffset() async throws {
        let dir = SyntheticMedia.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let writer = try TrackWriter.video(url: dir.appendingPathComponent("v.mov"), width: 320, height: 240, frameRate: 60)
        try await append(writer, frames: 0..<120, fps: 60, offset: 0.5)
        let result = try #require(await writer.finish(endTime: MediaTime(seconds: 2.5).cmTime))
        #expect(writer.failure == nil)
        #expect(abs(result.startOffset - 0.5) < 1e-6)
        #expect(result.sampleCount == 120)

        let frames = try await SyntheticMedia.readFrames(result.url)
        #expect(frames.count == 120)
        #expect(abs(frames[0].time) < 1e-3)
        #expect(frames.map(\.index) == Array(0..<120))
        let facts = try await MediaInspector.inspect(result.url)
        #expect(abs(facts.duration - 2.0) < 0.05)
        #expect(facts.pixelWidth == 320 && facts.pixelHeight == 240)
    }

    @Test func pcmAudioIsWrittenAsAAC() async throws {
        let dir = SyntheticMedia.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pcm = SyntheticMedia.pcm(duration: 0.1)
        let writer = try TrackWriter.audio(url: dir.appendingPathComponent("a.mov"), sampleRate: 48_000, channels: 2,
                                           formatHint: pcm.format.formatDescription)
        var written: Int64 = 0
        for _ in 0..<20 {
            let time = CMTime(value: 48_000 + written, timescale: 48_000)   // session time 1 s onward
            let buffer = try #require(CMSampleBuffer.make(from: pcm, at: time))
            while !writer.isReady { try await Task.sleep(for: .milliseconds(1)) }
            #expect(writer.append(audio: buffer, at: time))
            written += Int64(pcm.frameLength)
        }
        let result = try #require(await writer.finish())
        #expect(writer.failure == nil)
        #expect(abs(result.startOffset - 1) < 1e-6)
        let facts = try await MediaInspector.inspect(result.url)
        #expect(facts.hasAudio && !facts.hasVideo)
        #expect(abs(facts.duration - 2.0) < 0.1)
    }

    @Test func emptyWriterLeavesNoFileBehind() async throws {
        let dir = SyntheticMedia.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("empty.mov")
        let writer = try TrackWriter.video(url: url, width: 320, height: 240, frameRate: 30)
        #expect(await writer.finish() == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}

@Suite(.serialized) struct RecoveryTests {
    private func makeStore() -> (ProjectStore, URL) {
        let root = SyntheticMedia.temporaryDirectory("framelo-library")
        return (ProjectStore(location: LibraryLocation(root: root)), root)
    }

    /// Simulates a crash: the recording is copied off disk while the writer is still open, and never finished.
    private func writeInterruptedSession(store: ProjectStore, seconds: Double) async throws -> (id: UUID, package: URL) {
        let id = UUID()
        let package = try await store.createPackage(for: id)
        var journal = RecordingJournal(id: id, name: "Crash Test", config: RecordingConfig(target: .display(id: 1)))
        journal.state = .recording
        journal.capture = CaptureInfo(x: 0, y: 0, width: 320, height: 240, scale: 1)
        journal.setOffset(0.25, for: .screen)
        try journal.write(to: package)

        let live = package.appendingPathComponent("media/live.mov")
        let writer = try TrackWriter.video(url: live, width: 320, height: 240, frameRate: 30)
        for index in 0..<Int(seconds * 30) {
            while !writer.isReady { try await Task.sleep(for: .milliseconds(1)) }
            writer.append(pixelBuffer: SyntheticMedia.frame(index: index, width: 320, height: 240),
                          at: MediaTime(seconds: 0.25 + Double(index) / 30).cmTime)
        }
        try await Task.sleep(for: .milliseconds(400))   // let the last complete fragment reach the disk
        try FileManager.default.copyItem(at: live, to: package.appendingPathComponent(RecordingJournal.TrackKind.screen.relativePath))
        writer.abandon()
        try? FileManager.default.removeItem(at: live)

        let cursor = CursorTrack.encodeMove(CursorSample(t: 0.3, x: 0.5, y: 0.5)) + "{\"k\":\"m\",\"t\":"
        try Data(cursor.utf8).write(to: package.appendingPathComponent(ProjectPackage.cursorFile))
        return (id, package)
    }

    @Test func interruptedRecordingIsRecoveredWithoutTouchingItsMedia() async throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let (id, package) = try await writeInterruptedSession(store: store, seconds: 8)
        let media = package.appendingPathComponent(RecordingJournal.TrackKind.screen.relativePath)
        let before = try Data(contentsOf: media)
        #expect(await store.list().isEmpty)

        let report = await RecoveryService.run(store: store)
        #expect(report.recovered == [id])
        #expect(report.quarantined.isEmpty)

        let project = try await store.load(id: id)
        #expect(project.isRecovered)
        #expect(project.name.contains("Recovered"))
        // Fragments are flushed every 2 s, so at least 6 of the 8 seconds must survive.
        let duration = project.sources[0].screen!.duration
        #expect(duration >= 5.9 && duration <= 8.1)
        #expect(project.sources[0].screen!.startOffset == 0.25)
        #expect(project.sources[0].cursorPath != nil)
        try TimelineValidator.validate(project)
        #expect(try Data(contentsOf: media) == before)
        #expect(try RecordingJournal.read(from: package).state == .complete)

        let frames = try await SyntheticMedia.readFrames(media)
        #expect(frames.count >= 177)
        #expect(frames.prefix(100).map(\.index) == Array(0..<100))

        // A second launch finds nothing left to do.
        #expect(await RecoveryService.run(store: store).isEmpty)
        #expect(await store.list().count == 1)
    }

    @Test func unusableSessionsAreQuarantinedNotDeleted() async throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        // Journal present, screen file is garbage.
        let broken = UUID()
        let brokenPackage = try await store.createPackage(for: broken)
        try RecordingJournal(id: broken, name: "Broken", config: RecordingConfig(target: .display(id: 1))).write(to: brokenPackage)
        try Data(repeating: 7, count: 4096).write(to: brokenPackage.appendingPathComponent(RecordingJournal.TrackKind.screen.relativePath))
        try Data().write(to: brokenPackage.appendingPathComponent("media/camera.mov"))

        // Completely empty shell.
        let empty = UUID()
        let emptyPackage = try await store.createPackage(for: empty)

        // Leftover export temp file.
        let temp = store.location.exportTempDirectory
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: temp.appendingPathComponent("partial.mp4"))

        let report = await RecoveryService.run(store: store)
        #expect(report.recovered.isEmpty)
        #expect(report.quarantined.count == 1)
        #expect(report.removedEmptyFiles == 1)
        #expect(report.removedTempFiles == 1)
        #expect(!FileManager.default.fileExists(atPath: brokenPackage.path))
        #expect(!FileManager.default.fileExists(atPath: emptyPackage.path))
        let kept = report.quarantined[0].appendingPathComponent(RecordingJournal.TrackKind.screen.relativePath)
        #expect(try Data(contentsOf: kept).count == 4096)
    }

    @Test func finalizerBuildsAProjectFromACompleteSession() async throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let package = try await store.createPackage(for: id)
        try await SyntheticMedia.writeVideo(to: package.appendingPathComponent(RecordingJournal.TrackKind.screen.relativePath),
                                            times: SyntheticMedia.constantTimes(duration: 3, fps: 30))
        try await SyntheticMedia.writeVideo(to: package.appendingPathComponent(RecordingJournal.TrackKind.camera.relativePath),
                                            width: 160, height: 120, times: SyntheticMedia.constantTimes(duration: 2.5, fps: 30))
        var journal = RecordingJournal(id: id, name: "Demo", config: RecordingConfig(target: .display(id: 1)))
        journal.setOffset(0, for: .screen)
        journal.setOffset(0.4, for: .camera)

        let project = try await RecordingFinalizer.buildProject(package: package, journal: journal, recovered: false)
        #expect(project.id == id && !project.isRecovered)
        #expect(project.sources[0].camera?.startOffset == 0.4)
        #expect(project.sources[0].microphone == nil)
        #expect(project.timeline.tracks.map(\.type) == [.video, .camera])
        #expect(abs(project.duration.seconds - 3) < 0.05)
        #expect(abs(project.sourceAspect - 4.0 / 3.0) < 1e-6)
        try TimelineValidator.validate(project)
    }
}
