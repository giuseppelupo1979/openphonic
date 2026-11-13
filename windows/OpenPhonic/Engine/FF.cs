using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace OpenPhonic.Engine;

/// <summary>ffmpeg / ffprobe helpers (same measurements as the web and Mac engines).</summary>
public static partial class FF
{
    static readonly CultureInfo Inv = CultureInfo.InvariantCulture;

    public sealed record ProbeInfo(double Duration, int Channels, int SampleRate, string Codec, bool HasVideo, string? VideoCodec);

    public static ProbeInfo Probe(string path)
    {
        var exe = Tools.Ffprobe ?? throw new Tools.ToolException("ffprobe non trovato: reinstalla OpenPhonic");
        Tools.Result r;
        try
        {
            r = Tools.Run(exe, ["-v", "error", "-print_format", "json", "-show_format", "-show_streams", path]);
        }
        catch (Tools.ToolException)
        {
            throw new Tools.ToolException($"Impossibile leggere {Path.GetFileName(path)}: non è un file audio o video valido");
        }
        using var doc = JsonDocument.Parse(r.Out);
        var streams = doc.RootElement.TryGetProperty("streams", out var s) ? s.EnumerateArray().ToList() : [];
        string? Str(JsonElement e, string k) => e.TryGetProperty(k, out var v) ? v.ToString() : null;
        var audio = streams.FirstOrDefault(e => Str(e, "codec_type") == "audio");
        if (audio.ValueKind == JsonValueKind.Undefined)
            throw new Tools.ToolException($"{Path.GetFileName(path)} non contiene audio");
        var video = streams.FirstOrDefault(e => Str(e, "codec_type") == "video"
            && !(e.TryGetProperty("disposition", out var d) && d.TryGetProperty("attached_pic", out var ap) && ap.GetInt32() == 1));
        var fmt = doc.RootElement.TryGetProperty("format", out var f) ? f : default;
        var dur = (fmt.ValueKind != JsonValueKind.Undefined ? Str(fmt, "duration") : null) ?? Str(audio, "duration") ?? "0";
        return new ProbeInfo(
            double.Parse(dur, Inv),
            audio.TryGetProperty("channels", out var ch) ? ch.GetInt32() : 1,
            int.Parse(Str(audio, "sample_rate") ?? "48000", Inv),
            Str(audio, "codec_name") ?? "?",
            video.ValueKind != JsonValueKind.Undefined,
            video.ValueKind != JsonValueKind.Undefined ? Str(video, "codec_name") : null);
    }

    public static double Duration(string path)
    {
        try { return Probe(path).Duration; } catch { return 0; }
    }

    public static void Decode(string src, string dst, int channels, int sr = 48000) =>
        Tools.FfmpegRun("-i", src, "-vn", "-map", "0:a:0", "-ac", $"{channels}", "-ar", $"{sr}", "-c:a", "pcm_f32le", dst);

    /// <summary>Mono float samples at the analysis rate (16 kHz by default).</summary>
    public static float[] ReadMono(string path, int sr = 16000)
    {
        var exe = Tools.Ffmpeg ?? throw new Tools.ToolException("ffmpeg non trovato");
        var r = Tools.Run(exe, ["-hide_banner", "-nostdin", "-i", path, "-vn", "-ac", "1", "-ar", $"{sr}", "-f", "f32le", "-"]);
        return MemoryMarshal.Cast<byte, float>(r.Out).ToArray();
    }

    public sealed record Loudness(double Integrated, double TruePeak, double Lra, double Threshold);

    public static Loudness MeasureLoudness(string path)
    {
        var err = Tools.FfmpegRun("-i", path, "-vn", "-af", "loudnorm=I=-16:TP=-1:LRA=11:print_format=json", "-f", "null", "-");
        var a = err.LastIndexOf('{');
        var b = err.LastIndexOf('}');
        if (a < 0 || b < a) throw new Tools.ToolException("Misura della loudness non riuscita");
        using var doc = JsonDocument.Parse(err[a..(b + 1)]);
        double V(string k)
        {
            var s = doc.RootElement.GetProperty(k).GetString() ?? "0";
            return s == "-inf" ? -99 : s == "inf" ? 99 : double.Parse(s, Inv);
        }
        return new Loudness(V("input_i"), V("input_tp"), V("input_lra"), V("input_thresh"));
    }

    [GeneratedRegex(@"max_volume: (-?[\d.]+) dB")]
    private static partial Regex MaxVolume();

    public static double Peak(string path)
    {
        var err = Tools.FfmpegRun("-i", path, "-af", "volumedetect", "-f", "null", "-");
        var m = MaxVolume().Match(err);
        return m.Success ? Math.Pow(10, double.Parse(m.Groups[1].Value, Inv) / 20) : 1;
    }

    public static void Spectrogram(string src, string dst) =>
        Tools.FfmpegRun("-i", src, "-lavfi", "showspectrumpic=s=1400x300:legend=0:color=magma:scale=log:fscale=lin:stop=12000",
                        "-frames:v", "1", dst);

    public static string F(double v, int decimals = 2) => v.ToString("F" + decimals, Inv);
}
