namespace Framelo.Core;

/// <summary>
/// The open project plus its undo history. Every change goes through Perform (validated, undoable) and is
/// saved atomically a moment later, so a crash loses at most the last half second of editing.
/// </summary>
public sealed class EditorSession : IDisposable
{
    private readonly ProjectStore _store;
    private readonly CommandStack _stack = new();
    private readonly Timer _saveTimer;
    private readonly object _gate = new();
    private bool _dirty;

    public Project Project { get; private set; }
    public string PackagePath { get; }
    public IReadOnlyDictionary<Guid, CursorTrack> CursorTracks { get; }
    public int Revision => _stack.Revision;
    public bool CanUndo => _stack.CanUndo;
    public bool CanRedo => _stack.CanRedo;
    public string? UndoName => _stack.UndoName;
    public string? RedoName => _stack.RedoName;
    public TimeSpan SaveDelay { get; set; } = TimeSpan.FromMilliseconds(500);

    /// <summary>Raised after every committed change, undo and redo.</summary>
    public event Action? Changed;
    public event Action<Exception>? SaveFailed;

    public EditorSession(ProjectStore store, Project project)
    {
        _store = store;
        Project = project;
        PackagePath = store.Location.PackagePath(project.Id);
        CursorTracks = project.Sources
            .Where(s => s.CursorPath != null)
            .ToDictionary(s => s.Id, s => CursorTrack.Load(ProjectPackage.Resolve(s.CursorPath!, PackagePath)));
        _saveTimer = new Timer(_ => Save(), null, Timeout.Infinite, Timeout.Infinite);
    }

    public string Resolve(string path) => ProjectPackage.Resolve(path, PackagePath);

    /// <summary>Applies an edit. Throws (and changes nothing) when the result would be invalid.</summary>
    public void Perform(EditCommand command)
    {
        lock (_gate) Project = _stack.Perform(command, Project);
        Committed();
    }

    public bool TryPerform(EditCommand command, out string? error)
    {
        try { Perform(command); error = null; return true; }
        catch (Exception e) when (e is TimelineEditException or TimelineValidationException) { error = e.Message; return false; }
    }

    public void BreakCoalescing() => _stack.BreakCoalescing();

    public void Undo()
    {
        lock (_gate) { if (!_stack.CanUndo) return; Project = _stack.Undo(Project); }
        Committed();
    }

    public void Redo()
    {
        lock (_gate) { if (!_stack.CanRedo) return; Project = _stack.Redo(Project); }
        Committed();
    }

    private void Committed()
    {
        _dirty = true;
        _saveTimer.Change(SaveDelay, Timeout.InfiniteTimeSpan);
        Changed?.Invoke();
    }

    /// <summary>Writes the project now if it has unsaved changes.</summary>
    public void Save()
    {
        Project snapshot;
        lock (_gate)
        {
            if (!_dirty) return;
            _dirty = false;
            snapshot = Project;
        }
        try { _store.Save(snapshot); }
        catch (Exception e) { _dirty = true; SaveFailed?.Invoke(e); }
    }

    public void Dispose()
    {
        _saveTimer.Dispose();
        Save();
    }
}
