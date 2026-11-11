import Foundation

/// Where Framelo keeps its data. Each project is a self-contained `<uuid>.framelo` directory.
public struct LibraryLocation: Sendable, Hashable {
    public var root: URL

    public init(root: URL) { self.root = root }

    /// UserDefaults key holding a custom library folder chosen in Settings › Storage.
    public static let customPathKey = "library.path"

    public static var standard: LibraryLocation {
        if let custom = UserDefaults.standard.string(forKey: customPathKey), !custom.isEmpty {
            return LibraryLocation(root: URL(fileURLWithPath: custom, isDirectory: true))
        }
        return defaultLocation
    }

    public static var defaultLocation: LibraryLocation {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies")
        return LibraryLocation(root: movies.appendingPathComponent("Framelo", isDirectory: true))
    }

    public var projectsDirectory: URL { root.appendingPathComponent("Projects", isDirectory: true) }
    public var quarantineDirectory: URL { root.appendingPathComponent("Recovery/Quarantine", isDirectory: true) }
    public var exportTempDirectory: URL { root.appendingPathComponent("ExportTemp", isDirectory: true) }

    public func packageURL(for id: UUID) -> URL {
        projectsDirectory.appendingPathComponent("\(id.uuidString).framelo", isDirectory: true)
    }
}

public enum ProjectPackage {
    public static let projectFile = "project.json"
    public static let sessionFile = "session.json"
    public static let cursorFile = "cursor.jsonl"
    public static let posterFile = "poster.jpg"
    public static let mediaDirectory = "media"

    /// Resolves a stored media path: absolute paths (imported files referenced in place) are used as they are,
    /// everything else is relative to the package.
    public static func resolve(_ path: String, in package: URL) -> URL {
        path.hasPrefix("/") ? URL(fileURLWithPath: path) : package.appendingPathComponent(path)
    }
}

public struct ProjectSummary: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var updatedAt: Date
    public var createdAt: Date
    public var duration: Double
    public var packageURL: URL
    public var posterURL: URL?
    public var isRecovered: Bool
    public var isRecording: Bool
}

public enum ProjectStoreError: Error, LocalizedError {
    case notFound(UUID)
    case unreadable(URL, String)
    case newerFormat(Int)

    public var errorDescription: String? {
        switch self {
        case .notFound: "The project could not be found. It may have been moved or deleted."
        case .unreadable(let url, let reason): "“\(url.lastPathComponent)” could not be read: \(reason)"
        case .newerFormat(let version): "This project was saved by a newer version of Framelo (format \(version))."
        }
    }
}

/// Owns all project file I/O. Saves are atomic (write to a temporary file, then rename).
public actor ProjectStore {
    public nonisolated let location: LibraryLocation
    private let fileManager = FileManager()

    public init(location: LibraryLocation = .standard) {
        self.location = location
    }

    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public func prepareLibrary() throws {
        try fileManager.createDirectory(at: location.projectsDirectory, withIntermediateDirectories: true)
    }

    /// Creates the package directory (and its media folder) for a new project or recording.
    @discardableResult
    public func createPackage(for id: UUID) throws -> URL {
        let url = location.packageURL(for: id)
        try fileManager.createDirectory(at: url.appendingPathComponent(ProjectPackage.mediaDirectory),
                                        withIntermediateDirectories: true)
        return url
    }

    public func save(_ project: Project) throws {
        let package = try createPackage(for: project.id)
        let data = try Self.makeEncoder().encode(project)
        try data.write(to: package.appendingPathComponent(ProjectPackage.projectFile), options: .atomic)
    }

    public func load(id: UUID) throws -> Project {
        let url = location.packageURL(for: id).appendingPathComponent(ProjectPackage.projectFile)
        guard fileManager.fileExists(atPath: url.path) else { throw ProjectStoreError.notFound(id) }
        return try Self.read(url)
    }

    public static func read(_ url: URL) throws -> Project {
        do {
            let data = try Data(contentsOf: url)
            let project = try makeDecoder().decode(Project.self, from: data)
            guard project.formatVersion <= Project.currentFormatVersion else {
                throw ProjectStoreError.newerFormat(project.formatVersion)
            }
            return project
        } catch let error as ProjectStoreError {
            throw error
        } catch {
            throw ProjectStoreError.unreadable(url.deletingLastPathComponent(), error.localizedDescription)
        }
    }

    /// All projects in the library, newest first. Packages without a readable project file are skipped
    /// (interrupted recordings are handled by `RecoveryService`).
    public func list() -> [ProjectSummary] {
        let contents = (try? fileManager.contentsOfDirectory(at: location.projectsDirectory,
                                                              includingPropertiesForKeys: nil)) ?? []
        var result: [ProjectSummary] = []
        for package in contents where package.pathExtension == "framelo" {
            let file = package.appendingPathComponent(ProjectPackage.projectFile)
            guard let project = try? Self.read(file) else { continue }
            let poster = package.appendingPathComponent(ProjectPackage.posterFile)
            result.append(ProjectSummary(
                id: project.id, name: project.name, updatedAt: project.updatedAt, createdAt: project.createdAt,
                duration: project.duration.seconds, packageURL: package,
                posterURL: fileManager.fileExists(atPath: poster.path) ? poster : nil,
                isRecovered: project.isRecovered,
                isRecording: project.sources.contains { $0.kind == .recording }))
        }
        return result.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Moves a project to the Trash (recoverable), never deleting media outright.
    public func trash(id: UUID) throws {
        let url = location.packageURL(for: id)
        guard fileManager.fileExists(atPath: url.path) else { throw ProjectStoreError.notFound(id) }
        try fileManager.trashItem(at: url, resultingItemURL: nil)
    }

    public func rename(id: UUID, to name: String) throws {
        var project = try load(id: id)
        project.name = name
        project.updatedAt = Date()
        try save(project)
    }
}
