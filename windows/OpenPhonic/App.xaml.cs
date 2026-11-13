using System.IO;
using System.Windows;
using OpenPhonic.Engine;

namespace OpenPhonic;

public partial class App : Application
{
    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        DispatcherUnhandledException += (_, ex) =>
        {
            // never vanish silently: log it and tell the user
            try
            {
                var dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "OpenPhonic");
                Directory.CreateDirectory(dir);
                File.AppendAllText(Path.Combine(dir, "errori.log"), $"[{DateTime.Now:s}] {ex.Exception}\n\n");
            }
            catch { }
            MessageBox.Show(ex.Exception.Message, "OpenPhonic", MessageBoxButton.OK, MessageBoxImage.Error);
            ex.Handled = true;
        };
        var i = Array.IndexOf(e.Args, "--process");
        if (i >= 0 && i + 1 < e.Args.Length)
        {
            Environment.ExitCode = Cli.Run(e.Args, e.Args[i + 1]);
            Shutdown();
            return;
        }
        var w = new UI.MainWindow();
        MainWindow = w;
        w.Show();
        // files passed on the command line ("Apri con", drag onto the exe)
        var files = e.Args.Where(File.Exists).ToArray();
        if (files.Length > 0) w.Model.Add(files);
    }
}

/// <summary>
/// Headless mode for testing: OpenPhonic.exe --process file [--out dir] [--preset id] [--cut] [--transcribe]
/// [--video] [--denoise ai|rnnoise|classic] [--amount auto|low|medium|high|max]
/// [--compressor auto|soft|medium|hard|off] [--model base|small|medium] [--intro f] [--outro f] [--cover f] [--all]
/// </summary>
static class Cli
{
    public static int Run(string[] args, string src)
    {
        string? Val(string flag)
        {
            var k = Array.IndexOf(args, flag);
            return k >= 0 && k + 1 < args.Length ? args[k + 1] : null;
        }
        T? Parse<T>(string flag) where T : struct, Enum =>
            Val(flag) is string v && Enum.TryParse<T>(v, true, out var r) ? r : null;

        src = Path.GetFullPath(src);
        var outDir = Val("--out") ?? Path.Combine(Path.GetDirectoryName(src)!, "OpenPhonic");
        var preset = Val("--preset") is string id ? Preset.All.FirstOrDefault(p => p.Id == id) : null;
        var s = preset?.Settings() ?? new ProductionSettings { Outputs = [new(OutFormat.Wav), new(OutFormat.Mp3)] };
        if (args.Contains("--transcribe")) s.Transcribe = true;
        if (args.Contains("--cut")) s.CutSilence = true;
        if (args.Contains("--video")) s.Outputs.Add(new(OutFormat.Video));
        if (Val("--model") is string model) s.WhisperModel = model;
        if (Parse<DenoiseMethod>("--denoise") is DenoiseMethod m) s.DenoiseMethod = m;
        if (Parse<Amount>("--amount") is Amount a) s.DenoiseAmount = a;
        if (Parse<Compressor>("--compressor") is Compressor c) s.Compressor = c;
        if (args.Contains("--all"))
        {
            s.Deesser = s.Deplosive = s.CutSilence = s.CutFillers = s.Transcribe = true;
            s.Title = "Prova completa"; s.Artist = "OpenPhonic"; s.Album = "Test";
            s.Outputs = Enum.GetValues<OutFormat>().Select(f => new Output(f)).ToList();
        }
        var input = new ProductionInput(src, Val("--intro"), Val("--outro"), Val("--cover"), outDir,
            Path.Combine(Path.GetTempPath(), "op-cli-" + Guid.NewGuid().ToString("N")));
        try
        {
            // run off the UI thread: blocking on it while the engine awaits would deadlock
            var r = Task.Run(() => new Pipeline(s, input, (step, p) => Console.WriteLine($"{p * 100,5:F1}%  {step}"), default)
                .Run()).GetAwaiter().GetResult();
            Console.WriteLine("NOTE: " + string.Join(" | ", r.Notes));
            Console.WriteLine("WARN: " + string.Join(" | ", r.Warnings));
            Console.WriteLine($"PRIMA  {r.Before.Integrated:F1} LUFS  TP {r.Before.TruePeak:F1}  LRA {r.Before.Lra:F1}  rumore {r.Before.NoiseFloor:F1}  SNR {r.Before.Snr:F1}");
            Console.WriteLine($"DOPO   {r.After.Integrated:F1} LUFS  TP {r.After.TruePeak:F1}  LRA {r.After.Lra:F1}  rumore {r.After.NoiseFloor:F1}  SNR {r.After.Snr:F1}");
            Console.WriteLine("FILE: " + string.Join("\n      ", r.Files));
            Console.WriteLine($"TEMPO  {r.Seconds:F1} s");
            if (r.Transcript.Count > 0) Console.WriteLine("TESTO: " + string.Join(" ", r.Transcript.Select(t => t.Text)));
            return 0;
        }
        catch (Exception ex)
        {
            Console.WriteLine("ERRORE: " + ex.Message);
            return 1;
        }
    }
}
