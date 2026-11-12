using System.Globalization;
using System.Speech.Recognition;
using Framelo.Core;

namespace Framelo.Platform.Media;

public sealed class TranscriptionException(string message, Exception? inner = null) : Exception(message, inner);

/// <summary>
/// Offline speech-to-text with the speech recogniser built into Windows (SAPI dictation). Audio never leaves the PC
/// and nothing is downloaded. The audio is first converted to the 16 kHz mono PCM the recogniser expects.
/// </summary>
public static class SpeechTranscriber
{
    /// <summary>Languages Windows can recognise on this PC.</summary>
    public static IReadOnlyList<CultureInfo> Languages()
    {
        try { return SpeechRecognitionEngine.InstalledRecognizers().Select(r => r.Culture).ToList(); }
        catch (Exception) { return Array.Empty<CultureInfo>(); }
    }

    /// <summary>Recognises the words in an audio or video file, with times in seconds from the start of the file.</summary>
    public static async Task<List<TranscribedSegment>> TranscribeAsync(string mediaPath, string tempDirectory, CultureInfo? language,
        IProgress<double>? progress, CancellationToken cancel)
    {
        var recognizers = SpeechRecognitionEngine.InstalledRecognizers();
        var preferred = language ?? CultureInfo.CurrentUICulture;
        var info = recognizers.FirstOrDefault(r => r.Culture.Name == preferred.Name)
                   ?? recognizers.FirstOrDefault(r => r.Culture.TwoLetterISOLanguageName == preferred.TwoLetterISOLanguageName)
                   ?? recognizers.FirstOrDefault(r => r.Culture.Name == "en-US")
                   ?? recognizers.FirstOrDefault()
                   ?? throw new TranscriptionException("Windows speech recognition is not installed. Add a speech language in Settings › Time & language › Speech.");

        var pcm = await Task.Run(() => MfAudioDecoder.Decode(mediaPath), cancel) ?? throw new TranscriptionException("The audio could not be read.");
        if (pcm.Frames == 0) throw new TranscriptionException("This project has no voice audio to transcribe.");
        Directory.CreateDirectory(tempDirectory);
        var wav = Path.Combine(tempDirectory, $"transcribe-{Guid.NewGuid():N}.wav");
        try
        {
            await Task.Run(() => WriteRecognizerWav(pcm, wav), cancel);
            return await Recognize(info, wav, pcm.Duration, progress, cancel);
        }
        finally
        {
            try { File.Delete(wav); } catch (Exception) { }
        }
    }

    private static void WriteRecognizerWav(PcmBuffer pcm, string path)
    {
        const int rate = 16_000;
        var mono = PcmConvert.Resample(pcm.Samples, PcmBuffer.Rate, PcmBuffer.Channels, rate, 1);
        // Normalise quiet recordings so the recogniser hears them, without clipping loud ones.
        var peak = mono.Length > 0 ? mono.Max(Math.Abs) : 0;
        if (peak is > 0.001f and < 0.5f) for (var i = 0; i < mono.Length; i++) mono[i] *= 0.5f / peak;
        var samples = new short[mono.Length];
        PcmConvert.FloatToInt16(mono, samples);
        using var file = new WavFile(path, rate, 1, 16, isFloat: false);
        file.Write(System.Runtime.InteropServices.MemoryMarshal.AsBytes(samples.AsSpan()));
    }

    private static Task<List<TranscribedSegment>> Recognize(RecognizerInfo info, string wav, double duration,
        IProgress<double>? progress, CancellationToken cancel)
    {
        var words = new List<TranscribedSegment>();
        var done = new TaskCompletionSource<List<TranscribedSegment>>(TaskCreationOptions.RunContinuationsAsynchronously);
        var engine = new SpeechRecognitionEngine(info);
        engine.LoadGrammar(new DictationGrammar());
        engine.SetInputToWaveFile(wav);
        engine.SpeechRecognized += (_, e) =>
        {
            lock (words) words.AddRange(Words(e.Result));
        };
        engine.RecognizeCompleted += (_, e) =>
        {
            if (e.Cancelled) done.TrySetCanceled();
            else if (e.Error != null) done.TrySetException(new TranscriptionException($"Transcription failed: {e.Error.Message}", e.Error));
            else lock (words) done.TrySetResult(words.OrderBy(w => w.Start).ToList());
        };
        var registration = cancel.Register(() => { try { engine.RecognizeAsyncCancel(); } catch (Exception) { } done.TrySetCanceled(); });
        var timer = new Timer(_ =>
        {
            try { progress?.Report(Math.Clamp(engine.RecognizerAudioPosition.TotalSeconds / Math.Max(duration, 0.1), 0, 1)); } catch (Exception) { }
        }, null, 250, 250);
        engine.RecognizeAsync(RecognizeMode.Multiple);
        return done.Task.ContinueWith(t =>
        {
            timer.Dispose();
            registration.Dispose();
            engine.Dispose();
            return t;
        }, TaskScheduler.Default).Unwrap();
    }

    /// <summary>
    /// Word timings from a phrase. Per-word audio positions are not reliably relative to the file, so they are
    /// taken as offsets from the phrase's first word and added to the phrase start. When the recogniser cannot
    /// give per-word audio, words share the phrase evenly.
    /// </summary>
    private static IEnumerable<TranscribedSegment> Words(RecognitionResult result)
    {
        if (result.Words.Count == 0 || result.Audio == null) yield break;
        var phraseStart = result.Audio.AudioPosition.TotalSeconds;
        var phraseLength = Math.Max(result.Audio.Duration.TotalSeconds, 0.05);
        var count = result.Words.Count;
        var timings = new (double Start, double Length)?[count];
        try
        {
            for (var i = 0; i < count; i++)
            {
                var audio = result.GetAudioForWordRange(result.Words[i], result.Words[i]);
                timings[i] = (audio.AudioPosition.TotalSeconds, Math.Max(audio.Duration.TotalSeconds, 0.05));
            }
        }
        catch (Exception)
        {
            Array.Clear(timings);
        }
        var origin = timings[0]?.Start ?? 0;
        for (var i = 0; i < count; i++)
        {
            var text = result.Words[i].Text;
            if (string.IsNullOrWhiteSpace(text)) continue;
            double start, end;
            if (timings[i] is { } t)
            {
                start = phraseStart + Math.Clamp(t.Start - origin, 0, phraseLength);
                end = Math.Min(start + t.Length, phraseStart + phraseLength);
            }
            else
            {
                start = phraseStart + phraseLength * i / count;
                end = phraseStart + phraseLength * (i + 1) / count;
            }
            yield return new TranscribedSegment(text, start, Math.Max(end, start + 0.05));
        }
    }
}
