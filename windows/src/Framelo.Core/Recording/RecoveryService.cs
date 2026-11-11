namespace Framelo.Core;

/// <summary>What the platform layer learns by opening a media file.</summary>
public sealed record MediaFacts(double Duration, int PixelWidth, int PixelHeight, bool HasAudio, bool HasVideo,
    string? VideoCodec = null, double FrameRate = 0);

/// <summary>Opens media files. Implemented with Media Foundation on Windows; faked in tests.</summary>
public interface IMediaInspector
{
    /// <summary>Returns null when the file is missing or unreadable.</summary>
    MediaFacts? Inspect(string path);
}

/// <summary>Turns the files of a recording session into a project — after a normal stop and after a crash.</summary>
public static class RecordingFinalizer
{
    public static Project BuildProject(string package, RecordingJournal journal, bool recovered, IMediaInspector inspector)
    {
        MediaFile? File(JournalTrackKind kind)
        {
            var entry = journal.TrackFor(kind);
            var relative = entry?.RelativePath ?? RecordingJournal.RelativePathFor(kind);
            var path = ProjectPackage.Resolve(relative, package);
            if (kind != JournalTrackKind.Screen && relative.EndsWith(".wav", StringComparison.OrdinalIgnoreCase)) WavFile.Repair(path);
            var facts = inspector.Inspect(path);
            if (facts == null) return null;
            return new MediaFile
            {
                RelativePath = relative, StartOffset = entry?.StartOffset ?? 0, Duration = facts.Duration,
                PixelWidth = facts.PixelWidth, PixelHeight = facts.PixelHeight, HasAudio = facts.HasAudio,
                RateCorrection = entry?.RateCorrection ?? 1,
            };
        }

        // The screen video defines the session. Without it there is nothing to edit.
        var screen = File(JournalTrackKind.Screen);
        if (screen == null || screen.PixelWidth <= 0)
            throw new InvalidOperationException("The screen recording could not be read.");
        var cursor = Path.Combine(package, ProjectPackage.CursorFile);
        var source = new MediaSource
        {
            Kind = SourceKind.Recording, Name = journal.Name, Screen = screen,
            Camera = File(JournalTrackKind.Camera), Microphone = File(JournalTrackKind.Microphone),
            SystemAudio = File(JournalTrackKind.SystemAudio),
            CursorPath = System.IO.File.Exists(cursor) ? ProjectPackage.CursorFile : null,
            Capture = journal.Capture, Duration = screen.StartOffset + screen.Duration, CreatedAt = journal.StartedAt,
        };
        var project = Project.Make(journal.Name, source, journal.Id);
        project.CreatedAt = journal.StartedAt;
        project.IsRecovered = recovered;
        // Leading time before the first video frame would show an empty canvas; start at the first frame.
        if (screen.StartOffset > 0) project.Timeline.VideoClips[0].SourceStart = MediaTime.FromSeconds(screen.StartOffset);
        if (recovered) project.Name = journal.Name + " (Recovered)";
        return project;
    }
}

public sealed class RecoveryReport
{
    public List<Guid> Recovered { get; } = new();
    public List<string> Quarantined { get; } = new();
    public int RemovedEmptyFiles { get; set; }
    public int RemovedTempFiles { get; set; }
    public bool IsEmpty => Recovered.Count == 0 && Quarantined.Count == 0;
}

/// <summary>
/// Runs once at launch: finishes interrupted recordings and tidies temporary files.
/// Nothing with content is ever deleted — unusable sessions are moved to a quarantine folder.
/// </summary>
public static class RecoveryService
{
    public static RecoveryReport Run(ProjectStore store, IMediaInspector inspector)
    {
        var report = new RecoveryReport();
        var location = store.Location;
        if (Directory.Exists(location.ProjectsDirectory))
        {
            foreach (var package in Directory.EnumerateDirectories(location.ProjectsDirectory, "*.framelo").ToList())
            {
                if (File.Exists(Path.Combine(package, ProjectPackage.ProjectFile))) continue;
                report.RemovedEmptyFiles += RemoveEmptyMediaFiles(package);
                RecordingJournal journal;
                try { journal = RecordingJournal.Read(package); }
                catch (Exception)
                {
                    if (DirectorySize(package) == 0) TryDelete(package);
                    else if (Quarantine(package, location) is string moved) report.Quarantined.Add(moved);
                    continue;
                }
                try
                {
                    var project = RecordingFinalizer.BuildProject(package, journal, recovered: true, inspector);
                    store.Save(project);
                    journal.State = JournalState.Complete;
                    journal.FailureReason = "Recovered after an interrupted recording.";
                    try { journal.Write(package); } catch (IOException) { }
                    report.Recovered.Add(project.Id);
                }
                catch (Exception)
                {
                    if (Quarantine(package, location) is string moved) report.Quarantined.Add(moved);
                }
            }
        }
        // Export temp files never outlive the process that made them.
        if (Directory.Exists(location.ExportTempDirectory))
        {
            foreach (var entry in Directory.EnumerateFileSystemEntries(location.ExportTempDirectory).ToList())
                if (TryDelete(entry)) report.RemovedTempFiles++;
        }
        return report;
    }

    private static int RemoveEmptyMediaFiles(string package)
    {
        var media = Path.Combine(package, ProjectPackage.MediaDirectory);
        if (!Directory.Exists(media)) return 0;
        var removed = 0;
        foreach (var f in Directory.EnumerateFiles(media).ToList())
            if (new FileInfo(f).Length == 0 && TryDelete(f)) removed++;
        return removed;
    }

    private static long DirectorySize(string dir) =>
        Directory.EnumerateFiles(dir, "*", SearchOption.AllDirectories).Sum(f => new FileInfo(f).Length);

    private static bool TryDelete(string path)
    {
        try
        {
            if (Directory.Exists(path)) Directory.Delete(path, true); else File.Delete(path);
            return true;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return false; }
    }

    private static string? Quarantine(string package, LibraryLocation location)
    {
        try
        {
            Directory.CreateDirectory(location.QuarantineDirectory);
            var dest = Path.Combine(location.QuarantineDirectory, Path.GetFileName(package));
            if (Directory.Exists(dest))
                dest = Path.Combine(location.QuarantineDirectory,
                    $"{Path.GetFileNameWithoutExtension(package)}-{DateTimeOffset.UtcNow.ToUnixTimeSeconds()}.framelo");
            Directory.Move(package, dest);
            return dest;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return null; }
    }
}
