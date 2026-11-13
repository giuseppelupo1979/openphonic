using System.Diagnostics;
using System.IO;
using System.Text;

namespace OpenPhonic.Engine;

/// <summary>Locates and runs the bundled command line tools (ffmpeg, ffprobe, DeepFilterNet).</summary>
public static class Tools
{
    public sealed class ToolException(string message) : Exception(message);

    static readonly string ToolsDir = Path.Combine(AppContext.BaseDirectory, "tools");

    static string? Find(string exe)
    {
        var local = Path.Combine(ToolsDir, exe);
        if (File.Exists(local)) return local;
        foreach (var dir in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator))
        {
            try
            {
                var p = Path.Combine(dir.Trim(), exe);
                if (File.Exists(p)) return p;
            }
            catch (ArgumentException) { }
        }
        return null;
    }

    public static string? Ffmpeg => Find("ffmpeg.exe");
    public static string? Ffprobe => Find("ffprobe.exe");
    public static string? DeepFilter => Find("deep-filter.exe");
    public static string? RnnoiseModel
    {
        get
        {
            var p = Path.Combine(ToolsDir, "std.rnnn");
            return File.Exists(p) ? p : null;
        }
    }

    public sealed record Result(byte[] Out, string Err);

    /// <summary>Runs a tool to completion, capturing stdout as bytes and stderr as text.</summary>
    public static Result Run(string exe, IEnumerable<string> args, CancellationToken ct = default)
    {
        var psi = new ProcessStartInfo(exe)
        {
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            RedirectStandardInput = true,
            UseShellExecute = false,
            CreateNoWindow = true,
            StandardErrorEncoding = Encoding.UTF8,
        };
        foreach (var a in args) psi.ArgumentList.Add(a);
        using var p = Process.Start(psi) ?? throw new ToolException($"Impossibile avviare {Path.GetFileName(exe)}");
        p.StandardInput.Close();
        // drain both pipes concurrently so a chatty process never blocks on a full buffer
        var errTask = p.StandardError.ReadToEndAsync();
        using var ms = new MemoryStream();
        p.StandardOutput.BaseStream.CopyTo(ms);
        using (ct.Register(() => { try { p.Kill(true); } catch { } }))
            p.WaitForExit();
        var err = errTask.Result;
        ct.ThrowIfCancellationRequested();
        if (p.ExitCode != 0)
        {
            var tail = string.Join("\n", err.Split('\n', StringSplitOptions.RemoveEmptyEntries).TakeLast(6));
            throw new ToolException($"{Path.GetFileNameWithoutExtension(exe)} non riuscito:\n{tail}");
        }
        return new Result(ms.ToArray(), err);
    }

    public static string FfmpegRun(params string[] args) => FfmpegRun((IEnumerable<string>)args);

    public static string FfmpegRun(IEnumerable<string> args, CancellationToken ct = default)
    {
        var exe = Ffmpeg ?? throw new ToolException("ffmpeg non trovato: reinstalla OpenPhonic");
        return Run(exe, new[] { "-hide_banner", "-nostdin", "-y" }.Concat(args), ct).Err;
    }
}
