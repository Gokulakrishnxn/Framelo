namespace Framelo.Core;

/// <summary>
/// An undoable edit. Apply mutates a copy of the project; CommandStack validates the copy and only then commits.
/// </summary>
public sealed class EditCommand(string name, Action<Project> apply, string? coalescingKey = null)
{
    public string Name { get; } = name;
    /// <summary>Consecutive commands with the same non-null key (e.g. a slider drag) collapse into one undo step.</summary>
    public string? CoalescingKey { get; } = coalescingKey;
    public void Apply(Project project) => apply(project);

    public static EditCommand Timeline(string name, Action<Timeline> edit, string? key = null) => new(name, p => edit(p.Timeline), key);

    public static EditCommand Split(MediaTime time) => Timeline("Split Clip", t => TimelineEditor.Split(t, time));
    public static EditCommand Trim(Guid clip, MediaTime? start = null, MediaTime? end = null, bool ripple = true) =>
        Timeline("Trim Clip", t => TimelineEditor.Trim(t, clip, start, end, ripple), $"trim-{clip}");
    public static EditCommand Delete(Guid clip, bool ripple = true) => Timeline("Delete Clip", t => TimelineEditor.Delete(t, clip, ripple));
    public static EditCommand DeleteRange(MediaRange range, bool ripple = true) => Timeline("Delete Section", t => TimelineEditor.DeleteRange(t, range, ripple));
    public static EditCommand Reorder(Guid clip, int index) => Timeline("Reorder Clip", t => TimelineEditor.Reorder(t, clip, index));
    public static EditCommand Move(Guid clip, MediaTime to) => Timeline("Move Clip", t => TimelineEditor.Move(t, clip, to), $"move-{clip}");
    public static EditCommand SetSpeed(Guid clip, double speed) => Timeline("Change Speed", t => TimelineEditor.SetSpeed(t, clip, speed), $"speed-{clip}");
    public static EditCommand CloseGaps() => Timeline("Close Gaps", TimelineEditor.CloseGaps);
    public static EditCommand UpsertZoom(ZoomEvent e, string name = "Edit Zoom") => Timeline(name, t => TimelineEditor.UpsertZoom(t, e.Copy()), $"zoom-{e.Id}");
    public static EditCommand RemoveZoom(Guid id) => Timeline("Delete Zoom", t => TimelineEditor.RemoveZoom(t, id));
    public static EditCommand Settings(string name, Action<ProjectSettings> change, string? key = null) => new(name, p => change(p.Settings), key);
}

/// <summary>
/// Undo/redo history. Each entry keeps the project as it was before the command — a few kilobytes of edit
/// decisions, never media — so undo is exact and cannot be corrupted by a buggy inverse.
/// </summary>
public sealed class CommandStack
{
    private sealed class Entry
    {
        public required string Name;
        public string? Key;
        public required string Snapshot;
        public DateTimeOffset Date;
    }

    private readonly List<Entry> _undo = new();
    private readonly List<Entry> _redo = new();

    public int Revision { get; private set; }
    public TimeSpan CoalescingWindow { get; set; } = TimeSpan.FromSeconds(1);
    public int Limit { get; set; } = 500;

    public bool CanUndo => _undo.Count > 0;
    public bool CanRedo => _redo.Count > 0;
    public string? UndoName => _undo.Count > 0 ? _undo[^1].Name : null;
    public string? RedoName => _redo.Count > 0 ? _redo[^1].Name : null;

    /// <summary>Applies the command to a copy, validates, and returns the committed project.</summary>
    public Project Perform(EditCommand command, Project project, DateTimeOffset? now = null)
    {
        var time = now ?? DateTimeOffset.UtcNow;
        var before = ProjectJson.Serialize(project);
        var candidate = ProjectJson.Deserialize(before);
        command.Apply(candidate);
        TimelineValidator.Validate(candidate);
        candidate.UpdatedAt = time;
        Revision++;
        _redo.Clear();

        if (command.CoalescingKey != null && _undo.Count > 0 && _undo[^1].Key == command.CoalescingKey &&
            time - _undo[^1].Date < CoalescingWindow)
        {
            // Keep the older snapshot so one undo returns to the state before the whole gesture.
            _undo[^1].Date = time;
            return candidate;
        }
        _undo.Add(new Entry { Name = command.Name, Key = command.CoalescingKey, Snapshot = before, Date = time });
        if (_undo.Count > Limit) _undo.RemoveRange(0, _undo.Count - Limit);
        return candidate;
    }

    /// <summary>Ends the current coalescing run (call when a drag finishes).</summary>
    public void BreakCoalescing()
    {
        if (_undo.Count > 0) _undo[^1].Key = null;
    }

    public Project Undo(Project project) => Swap(_undo, _redo, project);
    public Project Redo(Project project) => Swap(_redo, _undo, project);

    private Project Swap(List<Entry> from, List<Entry> to, Project project)
    {
        if (from.Count == 0) return project;
        var entry = from[^1];
        from.RemoveAt(from.Count - 1);
        to.Add(new Entry { Name = entry.Name, Snapshot = ProjectJson.Serialize(project), Date = DateTimeOffset.UtcNow });
        var restored = ProjectJson.Deserialize(entry.Snapshot);
        restored.UpdatedAt = DateTimeOffset.UtcNow;
        Revision++;
        return restored;
    }
}
