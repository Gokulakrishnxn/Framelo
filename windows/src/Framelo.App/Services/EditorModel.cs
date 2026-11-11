using System.Diagnostics;
using Framelo.Core;
using Framelo.Platform.Media;

namespace Framelo.App.Services;

/// <summary>A rendered preview picture: top-down BGRA.</summary>
public sealed record PreviewImage(int Width, int Height, byte[] Bgra);

/// <summary>Turns (project state, time) into a picture. The rendering stage plugs the compositor in here.</summary>
public interface IPreviewRenderer : IDisposable
{
    PreviewImage? Render(EditorSession session, double seconds, int maxWidth, int maxHeight);
}

public enum EditorSelectionKind { None, Clip, Zoom }

/// <summary>
/// UI-thread state of the editor: the session (project + undo), the playhead, playback, selection.
/// Rendering and audio decoding run off the UI thread.
/// </summary>
public sealed class EditorModel : IDisposable
{
    private readonly Stopwatch _clock = new();
    private double _playStart;
    private AudioMixer? _mixer;
    private int _mixerRevision = -1;

    public EditorSession Session { get; }
    public VideoSourceCache Video { get; }
    public AudioSourceCache Audio { get; }
    public AudioPlayer Player { get; } = new();
    public IPreviewRenderer Renderer { get; set; }

    public double Playhead { get; private set; }
    public bool IsPlaying { get; private set; }
    public EditorSelectionKind SelectionKind { get; private set; }
    public Guid? SelectedId { get; private set; }

    public event Action? PlayheadChanged;
    public event Action? SelectionChanged;

    public EditorModel(EditorSession session, IPreviewRenderer renderer)
    {
        Session = session;
        Video = new VideoSourceCache(session.PackagePath);
        Audio = new AudioSourceCache(session.PackagePath);
        Renderer = renderer;
        _ = Audio.WarmUpAsync(session.Project);
        Session.Changed += () =>
        {
            if (Playhead > Duration) Seek(Duration);
            if (SelectedId is Guid id && !Exists(id)) Select(EditorSelectionKind.None, null);
        };
    }

    public Project Project => Session.Project;
    public double Duration => Project.Duration.Seconds;

    public AudioMixer Mixer
    {
        get
        {
            if (_mixer == null || _mixerRevision != Session.Revision)
            {
                _mixer = new AudioMixer(Project, Audio);
                _mixerRevision = Session.Revision;
            }
            return _mixer;
        }
    }

    public void Seek(double seconds)
    {
        Playhead = Math.Clamp(seconds, 0, Duration);
        if (IsPlaying) { _playStart = Playhead; _clock.Restart(); Player.Play(Mixer, Playhead); }
        PlayheadChanged?.Invoke();
    }

    public void TogglePlay()
    {
        if (IsPlaying) { Pause(); return; }
        if (Playhead >= Duration - 0.05) Playhead = 0;
        IsPlaying = true;
        _playStart = Playhead;
        _clock.Restart();
        Player.Play(Mixer, Playhead);
        PlayheadChanged?.Invoke();
    }

    public void Pause()
    {
        if (!IsPlaying) return;
        IsPlaying = false;
        Player.Stop();
        PlayheadChanged?.Invoke();
    }

    /// <summary>Advances the playhead from the wall clock while playing. Call from a UI timer.</summary>
    public void Tick()
    {
        if (!IsPlaying) return;
        Playhead = Math.Min(_playStart + _clock.Elapsed.TotalSeconds, Duration);
        if (Playhead >= Duration) Pause();
        PlayheadChanged?.Invoke();
    }

    public void Select(EditorSelectionKind kind, Guid? id)
    {
        SelectionKind = id == null ? EditorSelectionKind.None : kind;
        SelectedId = id;
        SelectionChanged?.Invoke();
    }

    public ZoomEvent? SelectedZoom => SelectionKind == EditorSelectionKind.Zoom
        ? Project.Timeline.ZoomEvents.FirstOrDefault(z => z.Id == SelectedId) : null;
    public VideoClip? SelectedClip => SelectionKind == EditorSelectionKind.Clip
        ? Project.Timeline.VideoClips.FirstOrDefault(c => c.Id == SelectedId) : null;

    private bool Exists(Guid id) =>
        Project.Timeline.VideoClips.Any(c => c.Id == id) || Project.Timeline.ZoomEvents.Any(z => z.Id == id);

    public void Dispose()
    {
        Player.Dispose();
        Renderer.Dispose();
        Video.Dispose();
        Session.Dispose();
    }
}

/// <summary>Stage-3 preview: the raw screen frame at the playhead, without styling. Replaced by the compositor.</summary>
public sealed class RawFrameRenderer(VideoSourceCache video) : IPreviewRenderer
{
    public PreviewImage? Render(EditorSession session, double seconds, int maxWidth, int maxHeight)
    {
        var map = new TimeMap(session.Project);
        if (map.Locate(MediaTime.FromSeconds(seconds)) is not { } hit) return null;
        var source = session.Project.Source(map.Segments[hit.Index].SourceId);
        if (source?.Screen is not MediaFile file || video.Screen(source) is not MfVideoReader reader) return null;
        var frame = reader.FrameAt((hit.SourceTime.Seconds - file.StartOffset) * file.RateCorrection);
        return frame == null ? null : new PreviewImage(frame.Width, frame.Height, frame.Bgra);
    }

    public void Dispose() { }
}
