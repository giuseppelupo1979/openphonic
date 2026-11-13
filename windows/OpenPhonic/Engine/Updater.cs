using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Net.Http;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text.Json;

namespace OpenPhonic.Engine;

/// <summary>
/// Self-update from GitHub Releases: the latest release must carry OpenPhonic-&lt;rid&gt;.zip and
/// OpenPhonic-&lt;rid&gt;.zip.sha256. The download is verified before anything is replaced.
/// OPENPHONIC_UPDATE_URL overrides the release endpoint (used to test with a local fake release).
/// </summary>
public static class Updater
{
    public const string Repo = "giuseppelupo1979/openphonic";

    public sealed record Release(Version Version, string Tag, string Notes, string Url, string AssetName, string AssetUrl, string ShaUrl);

    public static Version Current
    {
        get
        {
            var v = Assembly.GetEntryAssembly()?.GetName().Version ?? new Version(1, 0, 0);
            return new Version(v.Major, v.Minor, Math.Max(0, v.Build));
        }
    }

    static string Rid => RuntimeInformation.ProcessArchitecture == Architecture.Arm64 ? "win-arm64" : "win-x64";

    static HttpClient Http()
    {
        var h = new HttpClient { Timeout = TimeSpan.FromMinutes(10) };
        h.DefaultRequestHeaders.UserAgent.ParseAdd($"OpenPhonic/{Current}");
        h.DefaultRequestHeaders.Accept.ParseAdd("application/vnd.github+json");
        return h;
    }

    static string Endpoint => Environment.GetEnvironmentVariable("OPENPHONIC_UPDATE_URL") is { Length: > 0 } u
        ? u : $"https://api.github.com/repos/{Repo}/releases/latest";

    /// <summary>The latest release if it is newer than this build and has a package for this machine.</summary>
    public static async Task<Release?> Check(CancellationToken ct = default)
    {
        using var http = Http();
        using var doc = JsonDocument.Parse(await http.GetStringAsync(Endpoint, ct).ConfigureAwait(false));
        var root = doc.RootElement;
        var tag = root.GetProperty("tag_name").GetString() ?? "";
        if (!Version.TryParse(tag.TrimStart('v', 'V'), out var v) || v <= Current) return null;
        var name = $"OpenPhonic-{Rid}.zip";
        string? asset = null, sha = null;
        foreach (var a in root.GetProperty("assets").EnumerateArray())
        {
            var n = a.GetProperty("name").GetString();
            var url = a.GetProperty("browser_download_url").GetString();
            if (n == name) asset = url;
            if (n == name + ".sha256") sha = url;
        }
        if (asset == null || sha == null) return null;   // no verified package for this architecture
        return new Release(v, tag, root.TryGetProperty("body", out var b) ? b.GetString() ?? "" : "",
                           root.TryGetProperty("html_url", out var h) ? h.GetString() ?? "" : "", name, asset, sha);
    }

    /// <summary>
    /// Downloads and verifies the package, then starts its installer once this process has exited.
    /// The caller must shut the app down right after this returns.
    /// </summary>
    public static async Task Prepare(Release r, Action<double> progress, CancellationToken ct = default)
    {
        var dir = Path.Combine(Path.GetTempPath(), "openphonic-update");
        if (Directory.Exists(dir)) Directory.Delete(dir, true);
        Directory.CreateDirectory(dir);
        var zip = Path.Combine(dir, r.AssetName);

        using var http = Http();
        var expected = (await http.GetStringAsync(r.ShaUrl, ct).ConfigureAwait(false))
            .Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).FirstOrDefault()?.ToLowerInvariant() ?? "";

        using (var resp = await http.GetAsync(r.AssetUrl, HttpCompletionOption.ResponseHeadersRead, ct).ConfigureAwait(false))
        {
            resp.EnsureSuccessStatusCode();
            long total = resp.Content.Headers.ContentLength ?? 0, done = 0;
            await using var src = await resp.Content.ReadAsStreamAsync(ct).ConfigureAwait(false);
            await using var dst = File.Create(zip);
            var buf = new byte[1 << 20];
            int n;
            while ((n = await src.ReadAsync(buf, ct).ConfigureAwait(false)) > 0)
            {
                await dst.WriteAsync(buf.AsMemory(0, n), ct).ConfigureAwait(false);
                done += n;
                if (total > 0) progress((double)done / total);
            }
        }

        string actual;
        await using (var fs = File.OpenRead(zip))
            actual = Convert.ToHexStringLower(await SHA256.HashDataAsync(fs, ct).ConfigureAwait(false));
        if (expected.Length != 64 || actual != expected)
            throw new Tools.ToolException("Il pacchetto scaricato non corrisponde all'impronta pubblicata: aggiornamento annullato");

        var pkg = Path.Combine(dir, "pkg");
        ZipFile.ExtractToDirectory(zip, pkg);
        var installer = Path.Combine(pkg, "installa.ps1");
        if (!File.Exists(installer)) throw new Tools.ToolException("Il pacchetto non contiene l'installatore");

        // wait for this process to exit, then run the package's own installer (it relaunches the app)
        int pid = Environment.ProcessId;
        var script = Path.Combine(dir, "aggiorna.ps1");
        File.WriteAllText(script,
            $"Wait-Process -Id {pid} -ErrorAction SilentlyContinue\r\n" +
            $"& '{installer.Replace("'", "''")}'\r\n");
        Process.Start(new ProcessStartInfo("powershell.exe",
            $"-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"{script}\"")
        {
            UseShellExecute = false,
            CreateNoWindow = true,
        });
    }
}
