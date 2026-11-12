namespace Framelo.Core;

/// <summary>Where Framelo keeps its data. Each project is a self-contained &lt;UUID&gt;.framelo directory.</summary>
public sealed record LibraryLocation(string Root)
{
    /// <summary>Default: %USERPROFILE%\Videos\Framelo (the Windows counterpart of ~/Movies/Framelo).</summary>
    public static LibraryLocation Default
    {
        get
        {
            var videos = Environment.GetFolderPath(Environment.SpecialFolder.MyVideos);
            if (string.IsNullOrEmpty(videos))
                videos = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Videos");
            return new LibraryLocation(Path.Combine(videos, "Framelo"));
        }
    }

    public string ProjectsDirectory => Path.Combine(Root, "Projects");
    public string QuarantineDirectory => Path.Combine(Root, "Recovery", "Quarantine");
    public string ExportTempDirectory => Path.Combine(Root, "ExportTemp");
    public string PackagePath(Guid id) => Path.Combine(ProjectsDirectory, id.ToString("D").ToUpperInvariant() + ".framelo");
}

public static class ProjectPackage
{
    public const string ProjectFile = "project.json";
    public const string SessionFile = "session.json";
    public const string CursorFile = "cursor.jsonl";
    public const string PosterFile = "poster.jpg";
    public const string MediaDirectory = "media";

    /// <summary>Absolute paths (imported files referenced in place) are used as-is; others are package-relative.</summary>
    public static string Resolve(string path, string package)
    {
        if (Path.IsPathRooted(path) || path.StartsWith('/')) return path;
        return Path.Combine(package, path.Replace('/', Path.DirectorySeparatorChar));
    }
}

public sealed record ProjectSummary(Guid Id, string Name, DateTimeOffset UpdatedAt, DateTimeOffset CreatedAt, double Duration,
    string PackagePath, string? PosterPath, bool IsRecovered, bool IsRecording);

public sealed class ProjectStoreException(string message) : Exception(message);

/// <summary>Owns all project file I/O. Saves are atomic: write a temporary file, then replace.</summary>
public sealed class ProjectStore(LibraryLocation location)
{
    private readonly object _gate = new();
    public LibraryLocation Location { get; } = location;

    public void PrepareLibrary() => Directory.CreateDirectory(Location.ProjectsDirectory);

    public string CreatePackage(Guid id)
    {
        var path = Location.PackagePath(id);
        Directory.CreateDirectory(Path.Combine(path, ProjectPackage.MediaDirectory));
        return path;
    }

    public void Save(Project project)
    {
        lock (_gate)
        {
            var package = CreatePackage(project.Id);
            AtomicFile.WriteAllText(Path.Combine(package, ProjectPackage.ProjectFile), ProjectJson.Serialize(project));
        }
    }

    public Project Load(Guid id)
    {
        var file = Path.Combine(Location.PackagePath(id), ProjectPackage.ProjectFile);
        if (!File.Exists(file)) throw new ProjectStoreException("The project could not be found. It may have been moved or deleted.");
        return Read(file);
    }

    public static Project Read(string file)
    {
        Project project;
        try { project = ProjectJson.Deserialize(File.ReadAllText(file)); }
        catch (Exception e) when (e is IOException or System.Text.Json.JsonException or UnauthorizedAccessException)
        {
            throw new ProjectStoreException($"“{Path.GetFileName(Path.GetDirectoryName(file))}” could not be read: {e.Message}");
        }
        if (project.FormatVersion > Project.CurrentFormatVersion)
            throw new ProjectStoreException($"This project was saved by a newer version of Framelo (format {project.FormatVersion}).");
        return project;
    }

    /// <summary>All readable projects, newest first. Interrupted recordings are handled by RecoveryService.</summary>
    public IReadOnlyList<ProjectSummary> List()
    {
        if (!Directory.Exists(Location.ProjectsDirectory)) return Array.Empty<ProjectSummary>();
        var result = new List<ProjectSummary>();
        foreach (var package in Directory.EnumerateDirectories(Location.ProjectsDirectory, "*.framelo"))
        {
            var file = Path.Combine(package, ProjectPackage.ProjectFile);
            if (!File.Exists(file)) continue;
            Project p;
            try { p = Read(file); } catch (ProjectStoreException) { continue; }
            var poster = Path.Combine(package, ProjectPackage.PosterFile);
            result.Add(new ProjectSummary(p.Id, p.Name, p.UpdatedAt, p.CreatedAt, p.Duration.Seconds, package,
                File.Exists(poster) ? poster : null, p.IsRecovered, p.Sources.Any(s => s.Kind == SourceKind.Recording)));
        }
        return result.OrderByDescending(s => s.UpdatedAt).ToList();
    }

    public void Rename(Guid id, string name)
    {
        var p = Load(id);
        p.Name = name;
        p.UpdatedAt = DateTimeOffset.UtcNow;
        Save(p);
    }
}

public static class AtomicFile
{
    public static void WriteAllText(string path, string text)
    {
        var temp = path + ".tmp-" + Guid.NewGuid().ToString("N")[..8];
        using (var stream = new FileStream(temp, FileMode.CreateNew, FileAccess.Write, FileShare.None, 4096, FileOptions.WriteThrough))
        using (var writer = new StreamWriter(stream, new System.Text.UTF8Encoding(false)))
        {
            writer.Write(text);
            writer.Flush();
            stream.Flush(true);
        }
        File.Move(temp, path, overwrite: true);
    }
}
