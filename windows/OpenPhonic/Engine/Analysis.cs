namespace OpenPhonic.Engine;

/// <summary>Signal analysis driving the automatic decisions (port of analysis.py / Analysis.swift).</summary>
public static class Analysis
{
    public const int SR = 16000;

    public sealed record NoiseProfile(double NoiseFloor, double SignalLevel, double Snr);
    public sealed record Hum(bool Detected, int? BaseFreq, double Strength);

    public static double Db(double x) => 20 * Math.Log10(Math.Max(x, 1e-9));

    /// <summary>RMS of <paramref name="frame"/>-sample windows every <paramref name="hop"/> samples.</summary>
    public static double[] FrameRms(float[] x, int frame, int hop)
    {
        if (x.Length < frame)
        {
            if (x.Length == 0) return [0];
            return [Math.Sqrt(x.Select(v => (double)v * v).Average())];
        }
        var cum = new double[x.Length + 1];
        for (int i = 0; i < x.Length; i++) cum[i + 1] = cum[i] + (double)x[i] * x[i];
        int n = 1 + (x.Length - frame) / hop;
        var r = new double[n];
        for (int i = 0; i < n; i++) r[i] = Math.Sqrt((cum[i * hop + frame] - cum[i * hop]) / frame);
        return r;
    }

    public static double Percentile(IReadOnlyList<double> v, double p)
    {
        if (v.Count == 0) return 0;
        var s = v.OrderBy(x => x).ToArray();
        var pos = p / 100 * (s.Length - 1);
        int lo = (int)Math.Floor(pos), hi = Math.Min(lo + 1, s.Length - 1);
        return s[lo] + (s[hi] - s[lo]) * (pos - lo);
    }

    public static NoiseProfile Noise(float[] x)
    {
        var rms = FrameRms(x, SR / 20, SR / 40).Where(v => v > 1e-6).ToArray();
        if (rms.Length == 0) return new NoiseProfile(-99, -99, 0);
        double floor = Db(Percentile(rms, 10)), level = Db(Percentile(rms, 95));
        return new NoiseProfile(Math.Round(floor, 1), Math.Round(level, 1), Math.Round(level - floor, 1));
    }

    /// <summary>In-place radix-2 FFT (length must be a power of two).</summary>
    public static void Fft(double[] re, double[] im)
    {
        int n = re.Length;
        for (int i = 1, j = 0; i < n; i++)
        {
            int bit = n >> 1;
            for (; (j & bit) != 0; bit >>= 1) j ^= bit;
            j ^= bit;
            if (i < j) { (re[i], re[j]) = (re[j], re[i]); (im[i], im[j]) = (im[j], im[i]); }
        }
        for (int len = 2; len <= n; len <<= 1)
        {
            double ang = -2 * Math.PI / len;
            double wr = Math.Cos(ang), wi = Math.Sin(ang);
            for (int i = 0; i < n; i += len)
            {
                double cr = 1, ci = 0;
                for (int k = 0; k < len / 2; k++)
                {
                    int a = i + k, b = a + len / 2;
                    double tr = re[b] * cr - im[b] * ci, ti = re[b] * ci + im[b] * cr;
                    re[b] = re[a] - tr; im[b] = im[a] - ti;
                    re[a] += tr; im[a] += ti;
                    (cr, ci) = (cr * wr - ci * wi, cr * wi + ci * wr);
                }
            }
        }
    }

    public static double[] Hann(int n) =>
        Enumerable.Range(0, n).Select(i => 0.5 - 0.5 * Math.Cos(2 * Math.PI * i / n)).ToArray();

    /// <summary>Power spectrum (n/2 bins) of x[start..start+n] with a window.</summary>
    public static double[] PowerSpectrum(float[] x, int start, int n, double[] window)
    {
        var re = new double[n];
        var im = new double[n];
        for (int i = 0; i < n; i++) re[i] = x[start + i] * window[i];
        Fft(re, im);
        var p = new double[n / 2];
        for (int i = 0; i < n / 2; i++) p[i] = re[i] * re[i] + im[i] * im[i];
        return p;
    }

    /// <summary>Mains hum (50/60 Hz + harmonics) in the quietest ~1 s frames.</summary>
    public static Hum DetectHum(float[] x)
    {
        const int frame = 16384, hop = 8000;
        if (x.Length < frame) return new Hum(false, null, 0);
        var rms = FrameRms(x, frame, hop);
        var pick = Enumerable.Range(0, rms.Length).OrderBy(i => rms[i]).Take(Math.Max(3, (int)(rms.Length * 0.3)));
        var win = Hann(frame);
        var spec = new double[frame / 2];
        foreach (var i in pick)
        {
            var s = PowerSpectrum(x, i * hop, frame, win);
            for (int k = 0; k < spec.Length; k++) spec[k] += s[k];
        }
        double binHz = (double)SR / frame;
        double Score(int f0)
        {
            var vals = new List<double>();
            for (int k = 1; k <= 4; k++)
            {
                int c = (int)Math.Round(f0 * k / binHz);
                double peak = Math.Max(spec[c - 1], Math.Max(spec[c], spec[c + 1]));
                var neigh = spec[(c - 15)..(c - 2)].Concat(spec[(c + 4)..(c + 17)]).ToArray();
                double med = Math.Max(Percentile(neigh, 50), 1e-20);
                vals.Add(10 * Math.Log10(Math.Max(peak, 1e-20) / med));
            }
            return vals.OrderBy(v => v).TakeLast(3).Average();
        }
        double s50 = Score(50), s60 = Score(60);
        var (b, strength) = s50 >= s60 ? (50, s50) : (60, s60);
        bool det = strength > 9;
        return new Hum(det, det ? b : null, Math.Round(strength, 1));
    }

    /// <summary>Max-abs envelope for drawing (0..1).</summary>
    public static float[] Peaks(float[] x, int points = 1600)
    {
        if (x.Length == 0) return [];
        int chunk = Math.Max(1, x.Length / points), n = x.Length / chunk;
        var r = new float[n];
        for (int i = 0; i < n; i++)
        {
            float m = 0;
            for (int j = i * chunk; j < (i + 1) * chunk; j++) m = Math.Max(m, Math.Abs(x[j]));
            r[i] = Math.Min(1, m);
        }
        return r;
    }

    /// <summary>Pauses: runs of 20 ms frames under the threshold lasting at least minDur seconds.</summary>
    public static List<(double, double)> Silences(float[] x, double thresholdDb, double minDur)
    {
        int hop = SR / 50;
        var rms = FrameRms(x, hop, hop).Select(Db).ToArray();
        var outp = new List<(double, double)>();
        int? start = null;
        for (int i = 0; i <= rms.Length; i++)
        {
            if (i < rms.Length && rms[i] < thresholdDb) { start ??= i; continue; }
            if (start is int st)
            {
                if ((double)(i - st) * hop / SR >= minDur) outp.Add(((double)st * hop / SR, (double)i * hop / SR));
                start = null;
            }
        }
        return outp;
    }
}
