using System.Diagnostics;
using System.Runtime.InteropServices;

namespace OpenPhonic.Engine;

/// <summary>
/// Voice activity, Voice AutoEQ and the phrase-level Adaptive Leveler (port of leveler.py).
/// The leveler measures loudness of speech only (400 ms windows), computes the gain that brings each
/// phrase to the programme's typical level and smooths it in both directions (zero phase). In pauses
/// the gain is interpolated between neighbouring phrases, so noise is never pulled up.
/// </summary>
public static class Leveler
{
    public const int SR = 16000;
    const int Hop = SR / 100;   // 10 ms frames

    static double Db10(double x) => 10 * Math.Log10(Math.Max(x, 1e-12));

    /// <summary>Mean power of win-sample windows centred on every 10 ms hop.</summary>
    static double[] PowerFrames(float[] x, int win)
    {
        var cum = new double[x.Length + 1];
        for (int i = 0; i < x.Length; i++) cum[i + 1] = cum[i] + (double)x[i] * x[i];
        int n = x.Length / Hop;
        var r = new double[n];
        for (int i = 0; i < n; i++)
        {
            int c = i * Hop + Hop / 2, a = Math.Max(0, c - win / 2), b = Math.Min(x.Length, c + win / 2);
            r[i] = (cum[b] - cum[a]) / Math.Max(b - a, 1);
        }
        return r;
    }

    static List<(int, int)> Runs(bool[] m, bool value)
    {
        var r = new List<(int, int)>();
        int? s = null;
        for (int i = 0; i <= m.Length; i++)
        {
            bool v = i < m.Length && m[i] == value;
            if (v && s == null) s = i;
            if (!v && s is int st) { r.Add((st, i)); s = null; }
        }
        return r;
    }

    public static bool[] VoiceActivity(float[] x)
    {
        var e = PowerFrames(x, 480).Select(Db10).ToArray();
        if (e.Length == 0) return [];
        double floor = Analysis.Percentile(e, 10), peak = Analysis.Percentile(e, 99.5);
        double thr = Math.Max(floor + 12, peak - 42);
        var v = e.Select(d => d > thr).ToArray();
        foreach (var (a, b) in Runs(v, false))                      // bridge gaps < 200 ms
            if (b - a < 20 && a > 0 && b < v.Length) for (int i = a; i < b; i++) v[i] = true;
        foreach (var (a, b) in Runs(v, true))                       // drop clicks < 60 ms
            if (b - a < 6) for (int i = a; i < b; i++) v[i] = false;
        var hang = new bool[v.Length];                              // 150 ms hangover
        for (int i = 0; i < v.Length; i++)
            if (v[i]) for (int j = Math.Max(0, i - 7); j <= Math.Min(v.Length - 1, i + 7); j++) hang[j] = true;
        return hang;
    }

    static double[] ZeroPhaseSmooth(double[] g, double tau)
    {
        if (g.Length < 2) return g;
        double a = 1 - Math.Exp(-1 / (tau * 100));
        var o = (double[])g.Clone();
        double prev = o[0];
        for (int i = 1; i < o.Length; i++) { prev += a * (o[i] - prev); o[i] = prev; }
        prev = o[^1];
        for (int i = o.Length - 2; i >= 0; i--) { prev += a * (o[i] - prev); o[i] = prev; }
        return o;
    }

    public sealed record CurveInfo(double Range, double? SpeechLevel);

    /// <summary>Gain in dB per 10 ms frame.</summary>
    public static (double[] Gain, CurveInfo Info) Curve(float[] x, bool[] vad, double strength)
    {
        int n = vad.Length;
        if (n == 0 || vad.Count(b => b) < 50) return (new double[n], new CurveInfo(0, null));
        var p = PowerFrames(x, 400 * SR / 1000);
        const int k = 40;
        double[] Centered(double[] v)
        {
            var cum = new double[v.Length + 1];
            for (int i = 0; i < v.Length; i++) cum[i + 1] = cum[i] + v[i];
            var r = new double[v.Length];
            for (int i = 0; i < v.Length; i++) r[i] = cum[Math.Min(v.Length, i + k / 2)] - cum[Math.Max(0, i - k / 2)];
            return r;
        }
        var sp = Centered(Enumerable.Range(0, n).Select(i => vad[i] && i < p.Length ? p[i] : 0).ToArray());
        var cnt = Centered(vad.Select(b => b ? 1.0 : 0).ToArray());
        var valid = Enumerable.Range(0, n).Select(i => vad[i] && cnt[i] >= k * 0.3).ToArray();
        var loud = new double[n];
        var vals = new List<double>();
        for (int i = 0; i < n; i++)
            if (valid[i]) { loud[i] = Db10(sp[i] / cnt[i]); vals.Add(loud[i]); }
        double target = Analysis.Percentile(vals, 60);
        double maxBoost = 3 + 13 * strength, maxCut = 2 + 8 * strength;
        var idx = Enumerable.Range(0, n).Where(i => valid[i]).ToArray();
        var g = new double[n];
        foreach (var i in idx) g[i] = Math.Clamp((target - loud[i]) * strength, -maxCut, maxBoost);
        // pauses: linear bridge between phrases, edges hold
        int j = 0;
        var filled = new double[n];
        for (int i = 0; i < n; i++)
        {
            while (j + 1 < idx.Length && idx[j + 1] <= i) j++;
            if (i <= idx[0]) filled[i] = g[idx[0]];
            else if (i >= idx[^1]) filled[i] = g[idx[^1]];
            else
            {
                int a = idx[j], b = idx[j + 1];
                filled[i] = g[a] + (g[b] - g[a]) * (i - a) / (b - a);
            }
        }
        var smooth = ZeroPhaseSmooth(filled, 0.6);
        var gv = idx.Select(i => smooth[i]).ToArray();
        double range = Analysis.Percentile(gv, 95) - Analysis.Percentile(gv, 5);
        return (smooth, new CurveInfo(Math.Round(range, 1), Math.Round(target, 1)));
    }

    /// <summary>Long-term average speech spectrum, octave bands, dB re 1 kHz (Byrne et al. 1994).</summary>
    static readonly (int F, double Db)[] Ltass = [(125, 4), (250, 7), (500, 6), (1000, 0), (2000, -5), (4000, -9), (8000, -14)];

    /// <summary>Gentle corrective EQ: move the voice's long-term spectrum part of the way towards LTASS.</summary>
    public static List<(int F, double Gain)> AutoEQ(float[] x, bool[] vad, double amount = 0.6, double limit = 4)
    {
        var frames = Enumerable.Range(0, vad.Length).Where(i => vad[i]).ToArray();
        if (frames.Length < 100) return [];
        const int win = 2048;
        var window = Analysis.Hann(win);
        var spec = new double[win / 2];
        int step = Math.Max(1, frames.Length / 600), used = 0;
        for (int f = 0; f < frames.Length; f += step)
        {
            int s = frames[f] * Hop;
            if (s + win > x.Length) continue;
            var ps = Analysis.PowerSpectrum(x, s, win, window);
            for (int i = 0; i < spec.Length; i++) spec[i] += ps[i];
            used++;
        }
        if (used == 0) return [];
        double binHz = (double)SR / win;
        double Band(int c)
        {
            int lo = (int)(c / 1.414 / binHz);
            int hi = Math.Min((int)(Math.Min(c * 1.414, SR / 2.0 - 100) / binHz), spec.Length);
            double sum = 0;
            for (int i = lo; i < hi; i++) sum += spec[i];
            return Db10(sum);
        }
        double reference = Band(1000);
        var outp = new List<(int, double)>();
        foreach (var (c, t) in Ltass)
        {
            if (c == 1000) continue;
            double diff = (t - (Band(c) - reference)) * amount;
            if (c == 125) diff = Math.Min(diff, 0);
            if (c == 8000) diff = Math.Min(diff, 3);
            double gdb = Math.Clamp(diff, -limit, limit);
            if (Math.Abs(gdb) >= 0.75) outp.Add((c, Math.Round(gdb, 1)));
        }
        return outp;
    }

    /// <summary>Streams src through a per-sample gain curve (10 ms resolution, linear interpolation).</summary>
    public static void ApplyGain(string src, string dst, double[] gainDb, int sampleRate, int channels)
    {
        var ff = Tools.Ffmpeg ?? throw new Tools.ToolException("ffmpeg non trovato");
        ProcessStartInfo Psi(params string[] args)
        {
            var p = new ProcessStartInfo(ff) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardError = true };
            foreach (var a in args) p.ArgumentList.Add(a);
            return p;
        }
        var rpsi = Psi("-v", "error", "-i", src, "-f", "f32le", "-ac", $"{channels}", "-ar", $"{sampleRate}", "-");
        rpsi.RedirectStandardOutput = true;
        var wpsi = Psi("-v", "error", "-y", "-f", "f32le", "-ar", $"{sampleRate}", "-ac", $"{channels}", "-i", "-",
                       "-c:a", "pcm_f32le", dst);
        wpsi.RedirectStandardInput = true;
        using var rd = Process.Start(rpsi)!;
        using var wr = Process.Start(wpsi)!;
        _ = rd.StandardError.ReadToEndAsync();
        _ = wr.StandardError.ReadToEndAsync();
        var lin = gainDb.Select(d => (float)Math.Pow(10, d / 20)).ToArray();
        var input = rd.StandardOutput.BaseStream;
        var output = wr.StandardInput.BaseStream;
        int frameBytes = channels * 4;
        var buf = new byte[sampleRate * frameBytes];
        int carry = 0;
        long pos = 0;
        while (true)
        {
            int read = input.Read(buf, carry, buf.Length - carry);
            if (read <= 0) break;
            int total = carry + read, usable = total / frameBytes * frameBytes;
            var samples = MemoryMarshal.Cast<byte, float>(buf.AsSpan(0, usable));
            int frames = usable / frameBytes;
            for (int f = 0; f < frames; f++)
            {
                double t = (double)(pos + f) / sampleRate * 100 - 0.5;   // frame-centre index
                float g = 1;
                if (lin.Length > 0)
                {
                    if (t <= 0) g = lin[0];
                    else if (t >= lin.Length - 1) g = lin[^1];
                    else
                    {
                        int i = (int)t;
                        float fr = (float)(t - i);
                        g = lin[i] + (lin[i + 1] - lin[i]) * fr;
                    }
                }
                for (int c = 0; c < channels; c++) samples[f * channels + c] *= g;
            }
            output.Write(buf, 0, usable);
            pos += frames;
            carry = total - usable;
            if (carry > 0) Array.Copy(buf, usable, buf, 0, carry);
        }
        output.Close();
        rd.WaitForExit();
        wr.WaitForExit();
        if (rd.ExitCode != 0 || wr.ExitCode != 0) throw new Tools.ToolException("Applicazione del guadagno non riuscita");
    }
}
