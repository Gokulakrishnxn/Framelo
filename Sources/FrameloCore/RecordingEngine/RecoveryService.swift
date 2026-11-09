import Foundation

/// Turns the files of a recording session into a project. Used both when a recording stops normally
/// and when an interrupted session is recovered.
public enum RecordingFinalizer {
    public static func buildProject(package: URL, journal: RecordingJournal, recovered: Bool) async throws -> Project {
        func file(_ kind: RecordingJournal.TrackKind) async -> MediaFile? {
            let url = package.appendingPathComponent(kind.relativePath)
            guard let facts = try? await MediaInspector.inspect(url) else { return nil }
            let entry = journal.track(kind)
            return MediaFile(relativePath: kind.relativePath, startOffset: entry?.startOffset ?? 0,
                             duration: facts.duration, pixelWidth: facts.pixelWidth, pixelHeight: facts.pixelHeight,
                             hasAudio: facts.hasAudio, rateCorrection: entry?.rateCorrection ?? 1)
        }

        // The screen video defines the session. Without it there is nothing to edit.
        guard let screen = await file(.screen), screen.pixelWidth > 0 else {
            throw MediaError.noUsableTracks(package.appendingPathComponent(RecordingJournal.TrackKind.screen.relativePath))
        }
        let duration = screen.startOffset + screen.duration
        let cursorURL = package.appendingPathComponent(ProjectPackage.cursorFile)
        let source = MediaSource(
            kind: .recording, name: journal.name, screen: screen,
            camera: await file(.camera), microphone: await file(.microphone), systemAudio: await file(.systemAudio),
            cursorPath: FileManager.default.fileExists(atPath: cursorURL.path) ? ProjectPackage.cursorFile : nil,
            capture: journal.capture, duration: duration, createdAt: journal.startedAt)

        var project = Project.make(name: journal.name, source: source, id: journal.id)
        project.createdAt = journal.startedAt
        project.isRecovered = recovered
        // Leading time before the first video frame would show an empty canvas; start the clip at the first frame.
        if screen.startOffset > 0 {
            project.timeline.videoClips[0].sourceStart = MediaTime(seconds: screen.startOffset)
        }
        if recovered {
            project.name = journal.name + " (Recovered)"
        }
        return project
    }
}

public struct RecoveryReport: Sendable, Equatable {
    public var recovered: [UUID] = []
    public var quarantined: [URL] = []
    public var removedEmptyFiles = 0
    public var removedTempFiles = 0

    public var isEmpty: Bool { recovered.isEmpty && quarantined.isEmpty }
}

/// Runs once at launch: finishes interrupted recordings and tidies temporary files.
/// Nothing with content is ever deleted — unusable sessions are moved to a quarantine folder.
public enum RecoveryService {
    public static func run(store: ProjectStore) async -> RecoveryReport {
        var report = RecoveryReport()
        let fm = FileManager.default
        let location = store.location

        let packages = ((try? fm.contentsOfDirectory(at: location.projectsDirectory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "framelo" }

        for package in packages {
            let hasProject = fm.fileExists(atPath: package.appendingPathComponent(ProjectPackage.projectFile).path)
            if hasProject { continue }

            report.removedEmptyFiles += removeEmptyMediaFiles(in: package)

            guard var journal = try? RecordingJournal.read(from: package) else {
                // No journal and no project: an abandoned shell. Remove it only if it holds no data at all.
                if directorySize(package) == 0 {
                    try? fm.removeItem(at: package)
                } else if let moved = quarantine(package, location: location) {
                    report.quarantined.append(moved)
                }
                continue
            }

            do {
                let project = try await RecordingFinalizer.buildProject(package: package, journal: journal, recovered: true)
                try await store.save(project)
                await ThumbnailGenerator.writePoster(for: project, package: package)
                journal.state = .complete
                journal.failureReason = "Recovered after an interrupted recording."
                try? journal.write(to: package)
                report.recovered.append(project.id)
            } catch {
                if let moved = quarantine(package, location: location) { report.quarantined.append(moved) }
            }
        }

        // Export temp files never outlive the process that made them.
        if let temps = try? fm.contentsOfDirectory(at: location.exportTempDirectory, includingPropertiesForKeys: nil) {
            for url in temps {
                if (try? fm.removeItem(at: url)) != nil { report.removedTempFiles += 1 }
            }
        }
        return report
    }

    private static func removeEmptyMediaFiles(in package: URL) -> Int {
        let fm = FileManager.default
        let media = package.appendingPathComponent(ProjectPackage.mediaDirectory)
        var removed = 0
        for url in (try? fm.contentsOfDirectory(at: media, includingPropertiesForKeys: [.fileSizeKey])) ?? [] {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
            if size == 0, (try? fm.removeItem(at: url)) != nil { removed += 1 }
        }
        return removed
    }

    private static func directorySize(_ url: URL) -> Int {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total = 0
        for case let file as URL in enumerator {
            total += (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        return total
    }

    private static func quarantine(_ package: URL, location: LibraryLocation) -> URL? {
        let fm = FileManager.default
        try? fm.createDirectory(at: location.quarantineDirectory, withIntermediateDirectories: true)
        var destination = location.quarantineDirectory.appendingPathComponent(package.lastPathComponent)
        if fm.fileExists(atPath: destination.path) {
            destination = location.quarantineDirectory
                .appendingPathComponent("\(package.deletingPathExtension().lastPathComponent)-\(Int(Date().timeIntervalSince1970)).framelo")
        }
        return (try? fm.moveItem(at: package, to: destination)) != nil ? destination : nil
    }
}
