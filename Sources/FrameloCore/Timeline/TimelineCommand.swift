import Foundation

/// An undoable edit. `apply` mutates the project and returns the command that reverses it.
public protocol TimelineCommand {
    var name: String { get }
    /// Consecutive commands with the same non-nil key (e.g. a slider drag) collapse into one undo step.
    var coalescingKey: String? { get }
    func apply(to project: inout Project) throws -> any TimelineCommand
}

/// Sets one value in the project. Its inverse sets the previous value.
public struct SetValueCommand<Value>: TimelineCommand {
    public let name: String
    public let coalescingKey: String?
    let keyPath: WritableKeyPath<Project, Value>
    let value: Value

    public init(_ name: String, _ keyPath: WritableKeyPath<Project, Value>, _ value: Value, coalescingKey: String? = nil) {
        self.name = name; self.keyPath = keyPath; self.value = value; self.coalescingKey = coalescingKey
    }

    public func apply(to project: inout Project) throws -> any TimelineCommand {
        let previous = project[keyPath: keyPath]
        project[keyPath: keyPath] = value
        return SetValueCommand(name, keyPath, previous, coalescingKey: coalescingKey)
    }
}

/// A structural timeline edit expressed with `TimelineEditor`. Its inverse restores the timeline it replaced
/// (a few kilobytes of edit decisions — never media).
public struct TimelineEditCommand: TimelineCommand {
    public let name: String
    public let coalescingKey: String?
    let edit: (inout Timeline) throws -> Void

    public init(_ name: String, coalescingKey: String? = nil, _ edit: @escaping (inout Timeline) throws -> Void) {
        self.name = name; self.coalescingKey = coalescingKey; self.edit = edit
    }

    public func apply(to project: inout Project) throws -> any TimelineCommand {
        let previous = project.timeline
        try edit(&project.timeline)
        return SetValueCommand(name, \Project.timeline, previous, coalescingKey: coalescingKey)
    }
}

public extension TimelineEditCommand {
    static func split(at time: MediaTime) -> TimelineEditCommand {
        TimelineEditCommand("Split Clip") { try TimelineEditor.split(&$0, at: time) }
    }

    static func trim(clipID: UUID, sourceStart: MediaTime? = nil, sourceEnd: MediaTime? = nil, ripple: Bool = true) -> TimelineEditCommand {
        TimelineEditCommand("Trim Clip", coalescingKey: "trim-\(clipID)") {
            try TimelineEditor.trim(&$0, clipID: clipID, sourceStart: sourceStart, sourceEnd: sourceEnd, ripple: ripple)
        }
    }

    static func delete(clipID: UUID, ripple: Bool = true) -> TimelineEditCommand {
        TimelineEditCommand("Delete Clip") { try TimelineEditor.delete(&$0, clipID: clipID, ripple: ripple) }
    }

    static func deleteRange(_ range: MediaRange, ripple: Bool = true) -> TimelineEditCommand {
        TimelineEditCommand("Delete Section") { try TimelineEditor.deleteRange(&$0, range: range, ripple: ripple) }
    }

    static func reorder(clipID: UUID, toIndex: Int) -> TimelineEditCommand {
        TimelineEditCommand("Reorder Clip") { try TimelineEditor.reorder(&$0, clipID: clipID, toIndex: toIndex) }
    }

    static func move(clipID: UUID, to position: MediaTime) -> TimelineEditCommand {
        TimelineEditCommand("Move Clip", coalescingKey: "move-\(clipID)") { try TimelineEditor.move(&$0, clipID: clipID, to: position) }
    }

    static func setSpeed(clipID: UUID, speed: Double) -> TimelineEditCommand {
        TimelineEditCommand("Change Speed", coalescingKey: "speed-\(clipID)") {
            try TimelineEditor.setSpeed(&$0, clipID: clipID, speed: speed)
        }
    }

    static func closeGaps() -> TimelineEditCommand {
        TimelineEditCommand("Close Gaps") { TimelineEditor.closeGaps(&$0) }
    }
}

/// Undo/redo history. Every command is applied to a copy, validated, and only then committed,
/// so a failing or invalid edit leaves the project untouched.
public struct CommandStack {
    private struct Entry {
        var name: String
        var key: String?
        var inverse: any TimelineCommand
        var date: Date
    }

    private var undoStack: [Entry] = []
    private var redoStack: [Entry] = []
    /// Bumped on every committed change; used to invalidate caches.
    public private(set) var revision: Int = 0
    public var coalescingWindow: TimeInterval = 1.0
    public var limit = 500

    public init() {}

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    public var undoName: String? { undoStack.last?.name }
    public var redoName: String? { redoStack.last?.name }

    public mutating func perform(_ command: any TimelineCommand, on project: inout Project, now: Date = Date()) throws {
        var candidate = project
        let inverse = try command.apply(to: &candidate)
        try TimelineValidator.validate(candidate)
        candidate.updatedAt = now
        project = candidate
        revision += 1
        redoStack.removeAll()

        if let key = command.coalescingKey, let last = undoStack.last, last.key == key,
           now.timeIntervalSince(last.date) < coalescingWindow {
            // Keep the older inverse so one undo returns to the state before the whole gesture.
            undoStack[undoStack.count - 1].date = now
            return
        }
        undoStack.append(Entry(name: command.name, key: command.coalescingKey, inverse: inverse, date: now))
        if undoStack.count > limit { undoStack.removeFirst(undoStack.count - limit) }
    }

    /// Ends the current coalescing run (call when a drag finishes).
    public mutating func breakCoalescing() {
        if !undoStack.isEmpty { undoStack[undoStack.count - 1].key = nil }
    }

    @discardableResult
    public mutating func undo(on project: inout Project) throws -> String? {
        guard let entry = undoStack.popLast() else { return nil }
        var candidate = project
        let redo = try entry.inverse.apply(to: &candidate)
        candidate.updatedAt = Date()
        project = candidate
        revision += 1
        redoStack.append(Entry(name: entry.name, key: nil, inverse: redo, date: Date()))
        return entry.name
    }

    @discardableResult
    public mutating func redo(on project: inout Project) throws -> String? {
        guard let entry = redoStack.popLast() else { return nil }
        var candidate = project
        let undo = try entry.inverse.apply(to: &candidate)
        candidate.updatedAt = Date()
        project = candidate
        revision += 1
        undoStack.append(Entry(name: entry.name, key: nil, inverse: undo, date: Date()))
        return entry.name
    }
}
