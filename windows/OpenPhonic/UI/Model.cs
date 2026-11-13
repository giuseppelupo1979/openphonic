using System.Collections.ObjectModel;
using System.ComponentModel;
using System.IO;
using System.Media;
using System.Runtime.CompilerServices;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Windows;
using OpenPhonic.Engine;

namespace OpenPhonic.UI;

public abstract class Observable : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler? PropertyChanged;
    protected void Raise([CallerMemberName] string? n = null) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(n));
    protected bool Set<T>(ref T f, T v, [CallerMemberName] string? n = null)
    {
        if (EqualityComparer<T>.Default.Equals(f, v)) return false;
        f = v;
        Raise(n);
        return true;
    }
}

public enum Status { Setup, Queued, Processing, Done, Failed }

public sealed class Production : Observable
{
    public Guid Id { get; init; } = Guid.NewGuid();
    public string Source { get; init; } = "";
    public DateTime Created { get; init; } = DateTime.Now;
    public FF.ProbeInfo? Info { get; set; }

    public ProductionSettings Settings { get; set { field = value; Raise(); Raise(nameof(Name)); } } = new();
    public string? Intro { get; set => Set(ref field, value); }
    public string? Outro { get; set => Set(ref field, value); }
    public string? Cover { get; set => Set(ref field, value); }

    public Status Status { get; set { if (Set(ref field, value)) Raise(nameof(Subtitle)); } }
    public string Step { get; set { if (Set(ref field, value)) Raise(nameof(Subtitle)); } } = "";
    public double Progress { get; set { if (Set(ref field, value)) Raise(nameof(Subtitle)); } }
    public string? Error { get; set => Set(ref field, value); }
    public ProductionResult? Result { get; set => Set(ref field, value); }

    [JsonIgnore]
    public string Name => string.IsNullOrWhiteSpace(Settings.Title) ? Path.GetFileNameWithoutExtension(Source) : Settings.Title;

    [JsonIgnore]
    public string Subtitle => Status switch
    {
        Status.Setup => string.Join(" · ", new[] { Info is { } i ? Fmt.Duration(i.Duration) : null,
                                                    Info?.HasVideo == true ? "video" : null, "da elaborare" }.OfType<string>()),
        Status.Queued => "In coda",
        Status.Processing => $"{Progress * 100:0}% · {Step}",
        Status.Done => Result is { } r ? $"Pronta · {r.After.Integrated:0} LUFS · {Fmt.Duration(r.After.Duration)}" : "Pronta",
        _ => "Errore",
    };

    public void NotifyName() => Raise(nameof(Name));
}

public sealed class AppModel : Observable
{
    public ObservableCollection<Production> Productions { get; } = [];
    public Preset[] Presets => Preset.All;

    public Production? Selected { get; set { if (Set(ref field, value)) Raise(nameof(Screen)); } }
    public bool ShowingHome { get; set { if (Set(ref field, value)) Raise(nameof(Screen)); } } = true;
    public string PresetId { get; set { if (Set(ref field, value)) SaveSettings(); } } = "podcast";
    public string OutputFolder { get; set { if (Set(ref field, value)) { Raise(nameof(OutputFolderName)); SaveSettings(); } } }
    public string OutputFolderName => Path.GetFileName(OutputFolder.TrimEnd('\\'));

    public bool FfmpegAvailable { get; } = Tools.Ffmpeg != null && Tools.Ffprobe != null;

    // ---- self-update
    public string CurrentVersion => Updater.Current.ToString(3);
    public Updater.Release? Update { get; set { if (Set(ref field, value)) Raise(nameof(HasUpdate)); } }
    public bool HasUpdate => Update != null;
    public string UpdateStatus { get; set => Set(ref field, value); } = "";
    public bool UpdateBusy { get; set => Set(ref field, value); }

    /// <summary>Asks GitHub for a newer release; silent on any network problem.</summary>
    public async Task CheckForUpdate(bool userAsked = false)
    {
        try
        {
            Update = await Updater.Check();
            if (Update != null) UpdateStatus = "";
            else if (userAsked) UpdateStatus = $"OpenPhonic {CurrentVersion} è aggiornato";
        }
        catch (Exception e)
        {
            if (userAsked) UpdateStatus = "Impossibile controllare gli aggiornamenti: " + e.Message;
        }
    }

    public async Task ApplyUpdate()
    {
        if (Update is not { } r || UpdateBusy) return;
        if (Productions.Any(p => p.Status is Status.Processing or Status.Queued))
        {
            UpdateStatus = "Attendi la fine delle elaborazioni in corso";
            return;
        }
        UpdateBusy = true;
        try
        {
            var ui = Application.Current.Dispatcher;
            await Updater.Prepare(r, f => ui.BeginInvoke(() => UpdateStatus = $"Download {f * 100:0}%"));
            UpdateStatus = "Installazione…";
            Save();
            Application.Current.Shutdown();
        }
        catch (Exception e)
        {
            UpdateStatus = e.Message;
            UpdateBusy = false;
        }
    }
    public bool DeepFilterAvailable { get; } = Tools.DeepFilter != null;

    /// <summary>
    /// What the main area shows: a fresh object per phase, so the ContentControl picks the
    /// matching DataTemplate again whenever the phase changes.
    /// </summary>
    public object Screen => ShowingHome || Selected is not { } p ? new HomeScreen(this) : p.Status switch
    {
        Status.Setup or Status.Failed => new SetupScreen(p, this),
        Status.Queued or Status.Processing => new ProcessingScreen(p, this),
        _ => new ResultScreen(p, this),
    };

    bool running;
    CancellationTokenSource? cts;

    public static readonly string Support = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "OpenPhonic");
    static string Store => Path.Combine(Support, "productions.json");
    static string Prefs => Path.Combine(Support, "settings.json");

    static readonly JsonSerializerOptions Json = new()
    {
        WriteIndented = false,
        Converters = { new JsonStringEnumConverter() },
    };

    public AppModel()
    {
        Directory.CreateDirectory(Support);
        OutputFolder = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyMusic), "OpenPhonic");
        try
        {
            if (File.Exists(Prefs))
            {
                var p = JsonSerializer.Deserialize<Dictionary<string, string>>(File.ReadAllText(Prefs)) ?? [];
                if (p.TryGetValue("outputFolder", out var o)) OutputFolder = o;
                if (p.TryGetValue("preset", out var pr)) PresetId = pr;
            }
            if (File.Exists(Store))
                foreach (var p in JsonSerializer.Deserialize<List<Production>>(File.ReadAllText(Store), Json) ?? [])
                {
                    // anything interrupted by quitting goes back to setup
                    if (p.Status is Status.Processing or Status.Queued) { p.Status = Status.Setup; p.Progress = 0; }
                    Productions.Add(p);
                }
        }
        catch { /* a corrupt history must never stop the app from starting */ }
    }

    void SaveSettings()
    {
        try
        {
            File.WriteAllText(Prefs, JsonSerializer.Serialize(new Dictionary<string, string>
            {
                ["outputFolder"] = OutputFolder ?? "", ["preset"] = PresetId,
            }));
        }
        catch { }
    }

    public void Save()
    {
        try { File.WriteAllText(Store, JsonSerializer.Serialize(Productions.ToList(), Json)); } catch { }
    }

    public Preset CurrentPreset => Preset.All.FirstOrDefault(p => p.Id == PresetId) ?? Preset.All[0];

    public void Add(IEnumerable<string> files)
    {
        Production? last = null;
        foreach (var f in files)
        {
            var p = new Production { Source = f, Settings = CurrentPreset.Settings() };
            try { p.Info = FF.Probe(f); } catch { }
            // a video in, a video out: the cleaned audio goes back into the film as well
            if (p.Info?.HasVideo == true && !p.Settings.Outputs.Any(o => o.Format == OutFormat.Video))
                p.Settings.Outputs = [.. p.Settings.Outputs, new Output(OutFormat.Video)];
            Productions.Insert(0, p);
            last = p;
        }
        if (last != null) { Selected = last; ShowingHome = false; }
        Save();
    }

    public void ShowHome() { ShowingHome = true; Selected = null; }

    public void Open(Production p) { Selected = p; ShowingHome = false; Raise(nameof(Screen)); }

    public void Remove(Production p)
    {
        if (p.Status == Status.Processing) return;
        try { Directory.Delete(Path.Combine(Support, "work", p.Id.ToString()), true); } catch { }
        Productions.Remove(p);
        if (Selected == p) ShowHome();
        Save();
    }

    public void Start(Production p)
    {
        p.Status = Status.Queued;
        p.Step = "In coda";
        p.Progress = 0;
        p.Error = null;
        Raise(nameof(Screen));
        Save();
        Pump();
    }

    public void StartAll()
    {
        foreach (var p in Productions.Where(p => p.Status == Status.Setup).ToList()) Start(p);
    }

    public void Reprocess(Production p)
    {
        p.Status = Status.Setup;
        p.Result = null;
        Raise(nameof(Screen));
        Save();
    }

    public void Cancel() => cts?.Cancel();

    /// <summary>Processes the queue one production at a time.</summary>
    async void Pump()
    {
        if (running) return;
        var next = Productions.LastOrDefault(p => p.Status == Status.Queued);
        if (next == null) return;
        running = true;
        next.Status = Status.Processing;
        next.Step = "Preparazione";
        Raise(nameof(Screen));
        var input = new ProductionInput(next.Source, next.Intro, next.Outro, next.Cover,
            Path.Combine(OutputFolder, Sanitize(next.Name)), Path.Combine(Support, "work", next.Id.ToString()));
        var settings = next.Settings.Clone();
        cts = new CancellationTokenSource();
        var token = cts.Token;
        var ui = Application.Current.Dispatcher;
        try
        {
            try { Directory.Delete(input.WorkDir, true); } catch { }
            var r = await Task.Run(() => new Pipeline(settings, input,
                (step, prog) => ui.BeginInvoke(() => { next.Step = step; next.Progress = prog; }), token).Run(), token);
            next.Result = r;
            next.Progress = 1;
            next.Status = Status.Done;
            SystemSounds.Asterisk.Play();
        }
        catch (OperationCanceledException)
        {
            next.Status = Status.Setup;
            next.Progress = 0;
        }
        catch (Exception e)
        {
            next.Error = e.Message;
            next.Status = Status.Failed;
        }
        running = false;
        Raise(nameof(Screen));
        Save();
        Pump();
    }

    static string Sanitize(string s)
    {
        var r = new string(s.Select(c => char.IsLetterOrDigit(c) || "-_ ".Contains(c) ? c : '_').ToArray()).Trim();
        return r.Length == 0 ? "OpenPhonic" : r[..Math.Min(80, r.Length)];
    }
}

public sealed record HomeScreen(AppModel Model);
public sealed record SetupScreen(Production P, AppModel Model);
public sealed record ProcessingScreen(Production P, AppModel Model);
public sealed record ResultScreen(Production P, AppModel Model);

public static class Fmt
{
    public static string Duration(double t)
    {
        var s = (int)Math.Round(t);
        return s >= 3600 ? $"{s / 3600}:{s / 60 % 60:00}:{s % 60:00}" : $"{s / 60}:{s % 60:00}";
    }
}
