namespace Framelo.Core;

/// <summary>A recognised word or line, in seconds from the start of an audio file.</summary>
public sealed record TranscribedSegment(string Text, double Start, double End);

/// <summary>Turns recognised words into timeline captions.</summary>
public static class CaptionBuilder
{
    /// <summary>
    /// Groups words into readable lines: a new line starts after a pause, at sentence punctuation, or when the line
    /// gets too long. Lines never overlap. Same rules as the macOS app.
    /// </summary>
    public static List<TranscribedSegment> Lines(IEnumerable<TranscribedSegment> words, int maxWords = 8, double maxDuration = 3.6, double pause = 0.7)
    {
        var lines = new List<TranscribedSegment>();
        var current = new List<TranscribedSegment>();
        void Flush()
        {
            if (current.Count == 0) return;
            var text = string.Join(" ", current.Select(w => w.Text.Trim()));
            lines.Add(new TranscribedSegment(char.ToUpperInvariant(text[0]) + text[1..], current[0].Start, current[^1].End));
            current.Clear();
        }
        foreach (var word in words.Where(w => !string.IsNullOrWhiteSpace(w.Text)).OrderBy(w => w.Start))
        {
            if (current.Count > 0)
            {
                var last = current[^1];
                var endsSentence = ".!?".Contains(last.Text.TrimEnd()[^1]);
                if (word.Start - last.End > pause || endsSentence || current.Count >= maxWords || word.End - current[0].Start > maxDuration) Flush();
            }
            current.Add(word);
        }
        Flush();
        for (var i = 0; i < lines.Count - 1; i++)
            if (lines[i].End > lines[i + 1].Start) lines[i] = lines[i] with { End = lines[i + 1].Start };
        return lines.Where(l => l.End > l.Start).ToList();
    }

    /// <summary>
    /// Places lines from an audio file onto the timeline: file time → session time (file start offset) → every
    /// place that moment appears in the edit. Lines that were cut out are dropped.
    /// </summary>
    public static List<Caption> Place(IEnumerable<TranscribedSegment> lines, MediaFile file, Guid sourceId, TimeMap map)
    {
        var rate = file.RateCorrection > 0 ? file.RateCorrection : 1;
        var captions = new List<Caption>();
        foreach (var line in lines)
        {
            var start = MediaTime.FromSeconds(file.StartOffset + line.Start / rate);
            var end = MediaTime.FromSeconds(file.StartOffset + line.End / rate);
            foreach (var t in map.TimelineTimes(start, sourceId))
            {
                var segment = map.Segments.First(s => s.SourceId == sourceId && start >= s.SourceStart && start < s.SourceEnd);
                // Keep the caption inside the clip it starts in, scaled by that clip's speed.
                var visible = MediaTime.Min(end, segment.SourceEnd) - start;
                var length = visible.DividedBy(segment.Speed);
                if (length.Ticks > 0) captions.Add(new Caption { Text = line.Text, StartTime = t, EndTime = t + length });
            }
        }
        captions.Sort((a, b) => a.StartTime.CompareTo(b.StartTime));
        for (var i = 0; i < captions.Count - 1; i++)
            if (captions[i].EndTime > captions[i + 1].StartTime) captions[i].EndTime = captions[i + 1].StartTime;
        return captions.Where(c => c.EndTime > c.StartTime).ToList();
    }

    /// <summary>The file to transcribe for a project: the microphone, else the system or embedded audio.</summary>
    public static (MediaSource Source, MediaFile File)? SpeechFile(Project project)
    {
        foreach (var s in project.Sources)
        {
            if (s.Microphone != null) return (s, s.Microphone);
            if (s.Kind == SourceKind.Recording && s.SystemAudio != null) return (s, s.SystemAudio);
            if (s.Screen?.HasAudio == true) return (s, s.Screen);
        }
        return null;
    }
}

public static partial class TextEdits
{
    public static EditCommand AddText(TextOverlay overlay) => EditCommand.Timeline("Add Text", t => t.TextOverlays.Add(Copy(overlay)));

    public static EditCommand UpdateText(TextOverlay overlay, string name = "Edit Text", string? key = null) =>
        EditCommand.Timeline(name, t =>
        {
            var i = t.TextOverlays.FindIndex(o => o.Id == overlay.Id);
            if (i < 0) throw TimelineEditException.ClipNotFound();
            t.TextOverlays[i] = Copy(overlay);
        }, key ?? $"text-{overlay.Id}");

    public static EditCommand RemoveText(Guid id) => EditCommand.Timeline("Delete Text", t => t.TextOverlays.RemoveAll(o => o.Id == id));

    public static EditCommand SetCaptions(IEnumerable<Caption> captions, string name = "Generate Captions")
    {
        var list = captions.Select(Copy).ToList();
        return EditCommand.Timeline(name, t => t.Captions = list.Select(Copy).ToList());
    }

    public static EditCommand UpdateCaption(Caption caption, string name = "Edit Caption") =>
        EditCommand.Timeline(name, t =>
        {
            var i = t.Captions.FindIndex(c => c.Id == caption.Id);
            if (i < 0) throw TimelineEditException.ClipNotFound();
            t.Captions[i] = Copy(caption);
            t.Captions.Sort((a, b) => a.StartTime.CompareTo(b.StartTime));
        }, $"caption-{caption.Id}");

    public static EditCommand RemoveCaption(Guid id) => EditCommand.Timeline("Delete Caption", t => t.Captions.RemoveAll(c => c.Id == id));

    public static TextOverlay Copy(TextOverlay o) => new()
    {
        Id = o.Id, Text = o.Text, StartTime = o.StartTime, EndTime = o.EndTime, PositionX = o.PositionX, PositionY = o.PositionY,
        FontSize = o.FontSize, Weight = o.Weight, Color = o.Color, BackgroundColor = o.BackgroundColor, FadeDuration = o.FadeDuration,
    };

    public static Caption Copy(Caption c) => new() { Id = c.Id, Text = c.Text, StartTime = c.StartTime, EndTime = c.EndTime };
}
