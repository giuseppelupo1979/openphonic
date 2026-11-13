using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Media;
using System.Windows.Media.Effects;

namespace OpenPhonic.UI;

static class Palette
{
    public static readonly Color Ember = Color.FromRgb(0xFF, 0x6B, 0x3D);
    public static readonly Color Rose = Color.FromRgb(0xFF, 0x3D, 0x8C);
    public static readonly Color Violet = Color.FromRgb(0x8C, 0x5C, 0xF7);

    public static LinearGradientBrush Accent(double x0 = 0, double x1 = 1) =>
        new(new GradientStopCollection { new(Ember, 0), new(Rose, 0.5), new(Violet, 1) },
            new Point(x0, 0.5), new Point(x1, 0.5));
}

/// <summary>Drifting, blurred colour blobs over a near-black base (the app's "aurora").</summary>
public sealed class AuroraBackground : FrameworkElement
{
    readonly (Color C, double X, double Y, double R, double Sx, double Sy, double Kx, double Ky)[] blobs =
    [
        (Color.FromArgb(150, 0x8C, 0x22, 0x4A), 0.62, 0.45, 0.42, 0.10, 0.08, 0.071, 0.093),
        (Color.FromArgb(120, 0x3C, 0x1A, 0x66), 0.20, 0.25, 0.45, 0.08, 0.10, 0.053, 0.067),
        (Color.FromArgb(120, 0x7A, 0x2E, 0x10), 0.35, 0.95, 0.40, 0.12, 0.05, 0.061, 0.049),
        (Color.FromArgb(100, 0x2A, 0x16, 0x5E), 0.95, 0.80, 0.38, 0.06, 0.09, 0.083, 0.057),
    ];

    public AuroraBackground()
    {
        IsHitTestVisible = false;
        Loaded += (_, _) => CompositionTarget.Rendering += Tick;
        Unloaded += (_, _) => CompositionTarget.Rendering -= Tick;
    }

    DateTime last;
    void Tick(object? s, EventArgs e)
    {
        if ((DateTime.Now - last).TotalMilliseconds < 50) return;   // 20 fps is plenty for a slow drift
        last = DateTime.Now;
        InvalidateVisual();
    }

    protected override void OnRender(DrawingContext dc)
    {
        double w = ActualWidth, h = ActualHeight;
        dc.DrawRectangle(new SolidColorBrush(Color.FromRgb(9, 9, 15)), null, new Rect(0, 0, w, h));
        double t = DateTime.Now.TimeOfDay.TotalSeconds;
        foreach (var b in blobs)
        {
            var c = new Point((b.X + b.Sx * Math.Sin(t * b.Kx * 6)) * w, (b.Y + b.Sy * Math.Cos(t * b.Ky * 6)) * h);
            double r = b.R * Math.Max(w, h);
            var brush = new RadialGradientBrush(b.C, Color.FromArgb(0, b.C.R, b.C.G, b.C.B));
            dc.DrawEllipse(brush, null, c, r, r * 0.8);
        }
        dc.DrawRectangle(new SolidColorBrush(Color.FromArgb(50, 0, 0, 0)), null, new Rect(0, 0, w, h));
    }
}

/// <summary>Animated equalizer bars (decorative).</summary>
public sealed class LiveBars : FrameworkElement
{
    public int Count { get; set; } = 9;
    public bool Intense { get; set; }

    public LiveBars()
    {
        IsHitTestVisible = false;
        Effect = new DropShadowEffect { Color = Palette.Rose, BlurRadius = 14, ShadowDepth = 0, Opacity = 0.6 };
        Loaded += (_, _) => CompositionTarget.Rendering += Tick;
        Unloaded += (_, _) => CompositionTarget.Rendering -= Tick;
    }

    void Tick(object? s, EventArgs e) => InvalidateVisual();

    protected override void OnRender(DrawingContext dc)
    {
        double h = ActualHeight, bw = h * 0.09, gap = h * 0.09;
        double total = Count * bw + (Count - 1) * gap, x0 = (ActualWidth - total) / 2;
        double t = DateTime.Now.TimeOfDay.TotalSeconds;
        var brush = Palette.Accent();
        brush.MappingMode = BrushMappingMode.Absolute;
        brush.StartPoint = new Point(x0, 0);
        brush.EndPoint = new Point(x0 + total, 0);
        for (int i = 0; i < Count; i++)
        {
            double v = 0.25 + 0.75 * Math.Abs(Math.Sin(t * (Intense ? 4.2 : 1.8) + i * 0.7) * Math.Cos(t * 1.3 + i * 1.7));
            double bh = h * v;
            dc.DrawRoundedRectangle(brush, null, new Rect(x0 + i * (bw + gap), (h - bh) / 2, bw, bh), bw / 2, bw / 2);
        }
    }
}

/// <summary>Bar waveform with a played/unplayed split and a playhead; click or drag to seek.</summary>
public sealed class Waveform : FrameworkElement
{
    public static readonly DependencyProperty PeaksProperty = DependencyProperty.Register(nameof(Peaks), typeof(float[]),
        typeof(Waveform), new FrameworkPropertyMetadata(null, FrameworkPropertyMetadataOptions.AffectsRender));
    public static readonly DependencyProperty FractionProperty = DependencyProperty.Register(nameof(Fraction), typeof(double),
        typeof(Waveform), new FrameworkPropertyMetadata(-1.0, FrameworkPropertyMetadataOptions.AffectsRender));
    public static readonly DependencyProperty GlowProperty = DependencyProperty.Register(nameof(Glow), typeof(bool),
        typeof(Waveform), new FrameworkPropertyMetadata(false, FrameworkPropertyMetadataOptions.AffectsRender));

    public float[]? Peaks { get => (float[]?)GetValue(PeaksProperty); set => SetValue(PeaksProperty, value); }
    /// <summary>Playhead position 0..1, or a negative value for none.</summary>
    public double Fraction { get => (double)GetValue(FractionProperty); set => SetValue(FractionProperty, value); }
    public bool Glow { get => (bool)GetValue(GlowProperty); set => SetValue(GlowProperty, value); }

    public event Action<double>? Seek;

    public Waveform()
    {
        Cursor = System.Windows.Input.Cursors.Hand;
        MouseLeftButtonDown += (_, e) => { CaptureMouse(); Seek?.Invoke(Clamp(e.GetPosition(this).X)); };
        MouseMove += (_, e) => { if (IsMouseCaptured) Seek?.Invoke(Clamp(e.GetPosition(this).X)); };
        MouseLeftButtonUp += (_, _) => ReleaseMouseCapture();
    }

    double Clamp(double x) => Math.Clamp(x / Math.Max(1, ActualWidth), 0, 1);

    protected override void OnRender(DrawingContext dc)
    {
        double w = ActualWidth, h = ActualHeight, mid = h / 2;
        dc.DrawRectangle(Brushes.Transparent, null, new Rect(0, 0, w, h));   // hit-testable everywhere
        var peaks = Peaks;
        if (peaks == null || peaks.Length == 0 || w < 4) return;
        int n = (int)(w / 3);
        var played = new StreamGeometry();
        var rest = new StreamGeometry();
        using (var gp = played.Open())
        using (var gr = rest.Open())
            for (int i = 0; i < n; i++)
            {
                int lo = i * peaks.Length / n, hi = Math.Max(lo + 1, (i + 1) * peaks.Length / n);
                float v = 0;
                for (int k = lo; k < Math.Min(hi, peaks.Length); k++) v = Math.Max(v, peaks[k]);
                double bh = Math.Max(1.5, v * (mid - 3));
                var ctx = Fraction >= 0 && (double)i / n <= Fraction ? gp : gr;
                double x = i * 3;
                ctx.BeginFigure(new Point(x, mid - bh), true, true);
                ctx.LineTo(new Point(x + 2, mid - bh), false, false);
                ctx.LineTo(new Point(x + 2, mid + bh), false, false);
                ctx.LineTo(new Point(x, mid + bh), false, false);
            }
        Brush baseBrush = Glow ? Palette.Accent() : new SolidColorBrush(Color.FromArgb(150, 255, 255, 255));
        dc.PushOpacity(0.4);
        dc.DrawGeometry(baseBrush, null, rest);
        dc.Pop();
        dc.DrawGeometry(Glow ? Palette.Accent() : Brushes.White, null, played);
        if (Fraction >= 0)
            dc.DrawRectangle(Brushes.White, null, new Rect(Fraction * w - 1, 0, 2, h));
    }
}

/// <summary>Glowing progress ring.</summary>
public sealed class ProgressHalo : FrameworkElement
{
    public static readonly DependencyProperty ValueProperty = DependencyProperty.Register(nameof(Value), typeof(double),
        typeof(ProgressHalo), new FrameworkPropertyMetadata(0.0, FrameworkPropertyMetadataOptions.AffectsRender));
    public double Value { get => (double)GetValue(ValueProperty); set => SetValue(ValueProperty, value); }

    public ProgressHalo()
    {
        Effect = new DropShadowEffect { Color = Palette.Rose, BlurRadius = 30, ShadowDepth = 0, Opacity = 0.8 };
        Loaded += (_, _) => CompositionTarget.Rendering += Tick;
        Unloaded += (_, _) => CompositionTarget.Rendering -= Tick;
    }

    void Tick(object? s, EventArgs e) => InvalidateVisual();

    protected override void OnRender(DrawingContext dc)
    {
        double size = Math.Min(ActualWidth, ActualHeight), r = size / 2 - 14;
        var c = new Point(ActualWidth / 2, ActualHeight / 2);
        double t = DateTime.Now.TimeOfDay.TotalSeconds;
        var glow = new RadialGradientBrush(Color.FromArgb((byte)(70 + 20 * Math.Sin(t * 2)), 0xFF, 0x3D, 0x8C), Colors.Transparent);
        dc.DrawEllipse(glow, null, c, r * 1.25, r * 1.25);
        dc.DrawEllipse(null, new Pen(new SolidColorBrush(Color.FromArgb(18, 255, 255, 255)), 16), c, r, r);
        double v = Math.Clamp(Value, 0.005, 0.9999);
        var end = new Point(c.X + r * Math.Sin(v * 2 * Math.PI), c.Y - r * Math.Cos(v * 2 * Math.PI));
        var arc = new StreamGeometry();
        using (var g = arc.Open())
        {
            g.BeginFigure(new Point(c.X, c.Y - r), false, false);
            g.ArcTo(end, new Size(r, r), 0, v > 0.5, SweepDirection.Clockwise, true, false);
        }
        var pen = new Pen(Palette.Accent(), 16) { StartLineCap = PenLineCap.Round, EndLineCap = PenLineCap.Round };
        dc.DrawGeometry(null, pen, arc);
        // orbiting spark
        double a = t * 2.1;
        var spark = new Point(c.X + (r + 18) * Math.Sin(a), c.Y - (r + 18) * Math.Cos(a));
        dc.DrawEllipse(new RadialGradientBrush(Colors.White, Colors.Transparent), null, spark, 6, 6);
    }
}

/// <summary>Two-way bridge between a RadioButton and an enum / number / string setting.</summary>
public sealed class EqualsConverter : IValueConverter
{
    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture) =>
        value != null && parameter != null && Same(value, parameter.ToString()!);

    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture)
    {
        if (value is not true || parameter is not string p) return Binding.DoNothing;
        var t = Nullable.GetUnderlyingType(targetType) ?? targetType;
        if (t.IsEnum) return Enum.Parse(t, p, true);
        if (t == typeof(double)) return double.Parse(p, CultureInfo.InvariantCulture);
        if (t == typeof(int)) return int.Parse(p, CultureInfo.InvariantCulture);
        return p;
    }

    static bool Same(object v, string p) => v switch
    {
        double d => double.TryParse(p, NumberStyles.Float, CultureInfo.InvariantCulture, out var x) && Math.Abs(d - x) < 1e-9,
        int i => int.TryParse(p, out var x) && i == x,
        Enum e => string.Equals(e.ToString(), p, StringComparison.OrdinalIgnoreCase),
        _ => string.Equals(v.ToString(), p, StringComparison.Ordinal),
    };
}

public sealed class OpacityConverter : IValueConverter
{
    public object Convert(object? value, Type t, object? p, CultureInfo c) => value is true ? 1.0 : 0.62;
    public object ConvertBack(object? value, Type t, object? p, CultureInfo c) => Binding.DoNothing;
}

public sealed class NotNullToVisConverter : IValueConverter
{
    public object Convert(object? value, Type t, object? p, CultureInfo c) =>
        value is null || (value is string s && s.Length == 0) || (value is System.Collections.ICollection col && col.Count == 0)
            ? Visibility.Collapsed : Visibility.Visible;
    public object ConvertBack(object? value, Type t, object? p, CultureInfo c) => Binding.DoNothing;
}

/// <summary>Sidebar status glyph: progress ring while working, gradient check when done.</summary>
public sealed class ProgressRing : FrameworkElement
{
    public static readonly DependencyProperty ValueProperty = DependencyProperty.Register(nameof(Value), typeof(double),
        typeof(ProgressRing), new FrameworkPropertyMetadata(0.0, FrameworkPropertyMetadataOptions.AffectsRender));
    public static readonly DependencyProperty StatusProperty = DependencyProperty.Register(nameof(Status), typeof(Status),
        typeof(ProgressRing), new FrameworkPropertyMetadata(Status.Setup, FrameworkPropertyMetadataOptions.AffectsRender));
    public double Value { get => (double)GetValue(ValueProperty); set => SetValue(ValueProperty, value); }
    public Status Status { get => (Status)GetValue(StatusProperty); set => SetValue(StatusProperty, value); }

    static readonly Typeface Icons = new("Segoe Fluent Icons");

    void Glyph(DrawingContext dc, string g, double size, Brush b)
    {
        var ft = new FormattedText(g, CultureInfo.InvariantCulture, FlowDirection.LeftToRight, Icons, size, b,
                                   VisualTreeHelper.GetDpi(this).PixelsPerDip);
        dc.DrawText(ft, new Point((ActualWidth - ft.Width) / 2, (ActualHeight - ft.Height) / 2));
    }

    protected override void OnRender(DrawingContext dc)
    {
        var c = new Point(ActualWidth / 2, ActualHeight / 2);
        double r = Math.Min(ActualWidth, ActualHeight) / 2 - 2;
        switch (Status)
        {
            case Status.Done:
                dc.DrawEllipse(new LinearGradientBrush(Palette.Ember, Palette.Violet, 45), null, c, r + 2, r + 2);
                Glyph(dc, "", 13, Brushes.White);
                break;
            case Status.Failed:
                Glyph(dc, "", 15, Brushes.Gold);
                break;
            case Status.Processing or Status.Queued:
                double v = Math.Clamp(Value, 0.03, 0.9999);
                var end = new Point(c.X + r * Math.Sin(v * 2 * Math.PI), c.Y - r * Math.Cos(v * 2 * Math.PI));
                var arc = new StreamGeometry();
                using (var g = arc.Open())
                {
                    g.BeginFigure(new Point(c.X, c.Y - r), false, false);
                    g.ArcTo(end, new Size(r, r), 0, v > 0.5, SweepDirection.Clockwise, true, false);
                }
                dc.DrawGeometry(null, new Pen(Palette.Accent(), 3) { StartLineCap = PenLineCap.Round, EndLineCap = PenLineCap.Round }, arc);
                Glyph(dc, "", 11, Brushes.White);
                break;
            default:
                Glyph(dc, "", 13, new SolidColorBrush(Color.FromArgb(160, 255, 255, 255)));
                break;
        }
    }
}

/// <summary>Glass card for one algorithm: glyph badge, title, subtitle, on/off switch; body shown when on.</summary>
public sealed class AlgoCard : ContentControl
{
    public static readonly DependencyProperty GlyphProperty = DependencyProperty.Register(nameof(Glyph), typeof(string), typeof(AlgoCard));
    public static readonly DependencyProperty HeaderProperty = DependencyProperty.Register(nameof(Header), typeof(string), typeof(AlgoCard));
    public static readonly DependencyProperty SubtitleProperty = DependencyProperty.Register(nameof(Subtitle), typeof(string), typeof(AlgoCard));
    public static readonly DependencyProperty IsOnProperty = DependencyProperty.Register(nameof(IsOn), typeof(bool), typeof(AlgoCard),
        new FrameworkPropertyMetadata(true, FrameworkPropertyMetadataOptions.BindsTwoWayByDefault));
    public static readonly DependencyProperty HasSwitchProperty = DependencyProperty.Register(nameof(HasSwitch), typeof(bool), typeof(AlgoCard),
        new PropertyMetadata(true));

    public string Glyph { get => (string)GetValue(GlyphProperty); set => SetValue(GlyphProperty, value); }
    public string Header { get => (string)GetValue(HeaderProperty); set => SetValue(HeaderProperty, value); }
    public string Subtitle { get => (string)GetValue(SubtitleProperty); set => SetValue(SubtitleProperty, value); }
    public bool IsOn { get => (bool)GetValue(IsOnProperty); set => SetValue(IsOnProperty, value); }
    public bool HasSwitch { get => (bool)GetValue(HasSwitchProperty); set => SetValue(HasSwitchProperty, value); }
}
