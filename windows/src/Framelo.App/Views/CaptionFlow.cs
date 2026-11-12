using System.Globalization;
using Framelo.App.Services;
using Framelo.Core;
using Framelo.Platform.Media;
using Microsoft.UI.Xaml.Controls;

namespace Framelo.App.Views;

/// <summary>Generate captions: transcribe the voice track offline, group into lines, place them on the timeline.</summary>
public static class CaptionFlow
{
    public static bool IsRunning { get; private set; }

    public static async Task GenerateAsync(EditorPage page, EditorModel model, CultureInfo? language)
    {
        if (IsRunning) return;
        if (CaptionBuilder.SpeechFile(model.Project) is not { } speech)
        {
            await Message(page, "No voice audio", "This project has no microphone or audio track to transcribe.");
            return;
        }
        if (model.Project.Timeline.Captions.Count > 0)
        {
            var replace = new ContentDialog
            {
                Title = "Replace the captions?", Content = "Generating again replaces the current captions, including any you edited. You can undo it.",
                PrimaryButtonText = "Replace", CloseButtonText = "Cancel", XamlRoot = page.Root, DefaultButton = ContentDialogButton.Close,
            };
            if (await replace.ShowAsync() != ContentDialogResult.Primary) return;
        }

        IsRunning = true;
        var bar = new ProgressBar { Minimum = 0, Maximum = 1, Width = 340, IsIndeterminate = true };
        var dialog = new ContentDialog
        {
            Title = "Generating captions", CloseButtonText = "Cancel", XamlRoot = page.Root,
            Content = new StackPanel
            {
                Spacing = 10,
                Children = { bar, new TextBlock { Text = "Speech is recognised on this PC; nothing is uploaded.", FontSize = 12, Opacity = 0.7 } },
            },
        };
        using var cancel = new CancellationTokenSource();
        dialog.CloseButtonClick += (_, _) => cancel.Cancel();
        _ = dialog.ShowAsync();
        var progress = new Progress<double>(v => { bar.IsIndeterminate = false; bar.Value = v; });
        var path = model.Session.Resolve(speech.File.RelativePath);
        string? error = null;
        List<Caption>? captions = null;
        try
        {
            var words = await SpeechTranscriber.TranscribeAsync(path, App.Services.Store.Location.ExportTempDirectory, language, progress, cancel.Token);
            var lines = CaptionBuilder.Lines(words);
            captions = CaptionBuilder.Place(lines, speech.File, speech.Source.Id, new TimeMap(model.Project));
            if (captions.Count == 0) error = "No speech was recognised in this recording.";
        }
        catch (OperationCanceledException) { }
        catch (Exception e)
        {
            Log.Error("Transcription", e);
            error = e is TranscriptionException ? e.Message : $"Transcription failed: {e.Message}";
        }
        finally
        {
            IsRunning = false;
            dialog.Hide();
        }
        if (error != null) await Message(page, "Captions", error);
        else if (captions is { Count: > 0 })
        {
            page.Perform(TextEdits.SetCaptions(captions));
            if (!model.Project.Settings.Captions.IsVisible)
                page.Perform(EditCommand.Settings("Show Captions", s => s.Captions.IsVisible = true));
            page.ShowSection("captions");
        }
    }

    private static async Task Message(EditorPage page, string title, string text) =>
        await new ContentDialog { Title = title, Content = text, CloseButtonText = "OK", XamlRoot = page.Root }.ShowAsync();
}
