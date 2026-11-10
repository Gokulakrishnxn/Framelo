import Foundation
import Testing
@testable import FrameloCore

/// Optional end-to-end check against a real recording on this Mac.
/// Run with: FRAMELO_REAL_PROJECT=<path to .framelo> FRAMELO_TEST_OUTPUT=<dir> Scripts/test.sh --filter RealProjectTests
@Suite struct RealProjectTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["FRAMELO_REAL_PROJECT"] != nil))
    func exportsARealRecording() async throws {
        let environment = ProcessInfo.processInfo.environment
        let package = URL(fileURLWithPath: environment["FRAMELO_REAL_PROJECT"]!)
        let output = URL(fileURLWithPath: environment["FRAMELO_TEST_OUTPUT"] ?? NSTemporaryDirectory())
        let project = try ProjectStore.read(package.appendingPathComponent(ProjectPackage.projectFile))
        var cursors: [UUID: CursorTrack] = [:]
        for source in project.sources {
            if let path = source.cursorPath { cursors[source.id] = CursorTrack.load(from: ProjectPackage.resolve(path, in: package)) }
        }
        let destination = output.appendingPathComponent("real-export.mp4")
        let result = try await ExportService.export(project: project, package: package, cursorTracks: cursors,
                                                    settings: ExportSettings(resolution: .p1080, frameRate: 60),
                                                    destination: destination,
                                                    tempDirectory: output.appendingPathComponent("tmp")) { _ in }
        #expect(abs(result.duration - project.duration.seconds) < 0.1)
        print("EXPORTED \(result.width)x\(result.height) \(result.frameRate)fps \(result.codec) audio=\(result.hasAudio) \(result.fileSize) bytes, \(project.timeline.zoomEvents.count) zooms, \(cursors.values.first?.clicks.count ?? 0) clicks")
    }
}
