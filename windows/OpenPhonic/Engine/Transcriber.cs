using System.IO;
using System.Text;
using Whisper.net;
using Whisper.net.Ggml;

namespace OpenPhonic.Engine;

/// <summary>Local transcription with Whisper (whisper.cpp via Whisper.net): subtitles and filler cutting.</summary>
public static class Transcriber
{
    public sealed record Word(string Text, double Start, double End);
    public sealed record Segment(string Text, double Start, double End, List<Word> Words);

    static readonly HashSet<string> Fillers =
    [
        "um", "umm", "uh", "uhm", "hmm", "hm", "mm", "mmm", "er", "erm", "ah", "eh", "ehm", "ehh",
        "mhm", "m", "mh", "mmh", "eeh", "ehhm",
    ];

    // Whisper drops disfluencies unless the prompt contains some
    const string FillerPrompt = "Ehm, allora, uhm... dunque, eh, vediamo. Umm, let me think, uh, like.";

    public static bool IsFiller(string w) =>
        Fillers.Contains(w.Trim().Trim('.', ',', '!', '?', '…', ';', ':', '-', '"', '\'').ToLowerInvariant());

    static string ModelDir => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                                           "OpenPhonic", "models");

    /// <summary>Downloads the ggml model the first time (base ≈ 150 MB, small ≈ 470 MB, medium ≈ 1.5 GB).</summary>
    static async Task<string> EnsureModel(GgmlType type, Action<string>? status)
    {
        Directory.CreateDirectory(ModelDir);
        var path = Path.Combine(ModelDir, $"ggml-{type.ToString().ToLowerInvariant()}.bin");
        if (File.Exists(path) && new FileInfo(path).Length > 1_000_000) return path;
        status?.Invoke("Download del modello Whisper (solo la prima volta)");
        var tmp = path + ".part";
        await using (var model = await WhisperGgmlDownloader.Default.GetGgmlModelAsync(type).ConfigureAwait(false))
        await using (var fs = File.Create(tmp))
            await model.CopyToAsync(fs).ConfigureAwait(false);
        File.Move(tmp, path, true);
        return path;
    }

    public static async Task<List<Segment>> Transcribe(float[] samples16k, string language, string modelName, bool keepFillers,
                                                       Action<string>? status, Action<double>? progress,
                                                       CancellationToken ct)
    {
        var type = modelName switch { "base" => GgmlType.Base, "medium" => GgmlType.Medium, _ => GgmlType.Small };
        var model = await EnsureModel(type, status).ConfigureAwait(false);
        using var factory = WhisperFactory.FromPath(model);
        var builder = factory.CreateBuilder()
            .WithLanguage(string.IsNullOrEmpty(language) ? "auto" : language)
            .WithTokenTimestamps()
            .WithThreads(Math.Max(1, Environment.ProcessorCount - 1));
        if (keepFillers) builder = builder.WithPrompt(FillerPrompt);
        using var processor = builder.Build();
        double total = samples16k.Length / 16000.0;
        var segs = new List<Segment>();
        await foreach (var s in processor.ProcessAsync(samples16k, ct).ConfigureAwait(false))
        {
            var words = new List<Word>();
            foreach (var t in s.Tokens ?? [])
            {
                var text = t.Text ?? "";
                if (text.StartsWith("[") || text.StartsWith("<|") || string.IsNullOrWhiteSpace(text)) continue;
                // token times are in centiseconds; a leading space starts a new word
                if (words.Count > 0 && !text.StartsWith(' '))
                    words[^1] = words[^1] with { Text = words[^1].Text + text, End = t.End / 100.0 };
                else
                    words.Add(new Word(text.Trim(), t.Start / 100.0, t.End / 100.0));
            }
            var txt = s.Text.Trim();
            if (txt.Length == 0) continue;
            segs.Add(new Segment(txt, s.Start.TotalSeconds, s.End.TotalSeconds, words));
            if (total > 0) progress?.Invoke(Math.Min(1, s.End.TotalSeconds / total));
        }
        return segs;
    }

    static string Ts(double t, char sep)
    {
        var ms = (long)Math.Round(t * 1000);
        return $"{ms / 3_600_000:00}:{ms / 60_000 % 60:00}:{ms / 1000 % 60:00}{sep}{ms % 1000:000}";
    }

    public static List<string> Write(List<Segment> segs, string dir, string stem)
    {
        var srt = new StringBuilder();
        var vtt = new StringBuilder("WEBVTT\n\n");
        for (int i = 0; i < segs.Count; i++)
        {
            var s = segs[i];
            srt.Append($"{i + 1}\n{Ts(s.Start, ',')} --> {Ts(s.End, ',')}\n{s.Text}\n\n");
            vtt.Append($"{Ts(s.Start, '.')} --> {Ts(s.End, '.')}\n{s.Text}\n\n");
        }
        var files = new List<string>();
        foreach (var (ext, body) in new[] { ("srt", srt.ToString()), ("vtt", vtt.ToString()),
                                            ("txt", string.Join("\n", segs.Select(s => s.Text)) + "\n") })
        {
            var p = Path.Combine(dir, $"{stem}.{ext}");
            File.WriteAllText(p, body, new UTF8Encoding(false));
            files.Add(p);
        }
        return files;
    }
}
