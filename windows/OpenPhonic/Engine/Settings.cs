using System.ComponentModel;
using System.Runtime.CompilerServices;

namespace OpenPhonic.Engine;

public enum Content { Speech, Music }
public enum Compressor { Auto, Soft, Medium, Hard, Off }
public enum DenoiseMethod { Ai, Rnnoise, Classic }
public enum Amount { Auto, Low, Medium, High, Max }
public enum OutFormat { Mp3, Aac, Opus, Flac, Wav, Video }
public enum OutChannels { Keep, Mono, Stereo }

public sealed record Output(OutFormat Format = OutFormat.Mp3, int Bitrate = 160, OutChannels Channels = OutChannels.Keep)
{
    public Guid Id { get; init; } = Guid.NewGuid();
    public string Ext => Format switch
    {
        OutFormat.Mp3 => "mp3", OutFormat.Aac => "m4a", OutFormat.Opus => "opus",
        OutFormat.Flac => "flac", OutFormat.Wav => "wav", _ => "mp4",
    };
    public bool IsLossless => Format is OutFormat.Flac or OutFormat.Wav;
}

/// <summary>Production settings (same options as the Mac and web versions).</summary>
public sealed class ProductionSettings : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler? PropertyChanged;

    void Set<T>(ref T f, T v, [CallerMemberName] string? n = null)
    {
        if (EqualityComparer<T>.Default.Equals(f, v)) return;
        f = v;
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(n));
    }

    public Content Content { get; set => Set(ref field, value); } = Content.Speech;

    public bool LevelerOn { get; set => Set(ref field, value); } = true;
    public double LevelerStrength { get; set => Set(ref field, value); } = 100;
    public Compressor Compressor { get; set => Set(ref field, value); } = Compressor.Auto;

    public bool FilterOn { get; set => Set(ref field, value); } = true;
    public int Highpass { get; set => Set(ref field, value); } = 75;
    public bool HumAuto { get; set => Set(ref field, value); } = true;
    public bool AutoEQ { get; set => Set(ref field, value); } = true;
    public bool Deesser { get; set => Set(ref field, value); }
    public bool Deplosive { get; set => Set(ref field, value); }

    public bool DenoiseOn { get; set => Set(ref field, value); } = true;
    public DenoiseMethod DenoiseMethod { get; set => Set(ref field, value); } = DenoiseMethod.Ai;
    public Amount DenoiseAmount { get; set => Set(ref field, value); } = Amount.Auto;

    public bool LoudnessOn { get; set => Set(ref field, value); } = true;
    public double LoudnessTarget { get; set => Set(ref field, value); } = -16;
    public double TruePeak { get; set => Set(ref field, value); } = -1;

    public bool CutSilence { get; set => Set(ref field, value); }
    public double MinSilence { get; set => Set(ref field, value); } = 1.0;
    public double KeepSilence { get; set => Set(ref field, value); } = 0.4;
    public bool CutFillers { get; set => Set(ref field, value); }

    public bool Transcribe { get; set => Set(ref field, value); }
    public string Language { get; set => Set(ref field, value); } = "it";
    /// <summary>Whisper model: base (fast), small (accurate), medium (best, slow).</summary>
    public string WhisperModel { get; set => Set(ref field, value); } = "small";

    public List<Output> Outputs { get; set => Set(ref field, value); } = [new()];

    public string Title { get; set => Set(ref field, value); } = "";
    public string Artist { get; set => Set(ref field, value); } = "";
    public string Album { get; set => Set(ref field, value); } = "";

    public ProductionSettings Clone()
    {
        var c = (ProductionSettings)MemberwiseClone();
        c.PropertyChanged = null;
        c.Outputs = Outputs.Select(o => o with { Id = Guid.NewGuid() }).ToList();
        return c;
    }
}

public sealed record Preset(string Id, string Name, string Subtitle, string Glyph, Action<ProductionSettings> Apply)
{
    public ProductionSettings Settings()
    {
        var s = new ProductionSettings();
        Apply(s);
        return s;
    }

    // Glyphs are Segoe Fluent Icons code points.
    public static readonly Preset[] All =
    [
        new("podcast", "Podcast", "−16 LUFS · voce pulita e presente", "", _ => { }),
        new("youtube", "YouTube & Spotify", "−14 LUFS · più forte", "", s => s.LoudnessTarget = -14),
        new("broadcast", "Broadcast EBU", "−23 LUFS · radio e TV", "", s => s.LoudnessTarget = -23),
        new("audiobook", "Audiolibro ACX", "−19 LUFS · mono 192 kbps", "", s =>
        {
            s.LoudnessTarget = -19; s.TruePeak = -3;
            s.Outputs = [new(OutFormat.Mp3, 192, OutChannels.Mono)];
        }),
        new("rescue", "Salvataggio", "Registrazioni difficili e rumorose", "", s =>
        {
            s.DenoiseAmount = Amount.High; s.Deesser = true; s.Deplosive = true; s.CutSilence = true;
        }),
        new("music", "Musica", "Solo loudness, nessun trattamento voce", "", s =>
        {
            s.Content = Content.Music; s.DenoiseOn = false; s.FilterOn = false;
            s.Outputs = [new(OutFormat.Flac), new(OutFormat.Mp3, 256)];
        }),
    ];
}
