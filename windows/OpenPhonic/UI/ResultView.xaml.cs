using System.Diagnostics;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using OpenPhonic.Engine;

namespace OpenPhonic.UI;

public partial class ResultView : UserControl
{
    const string PlayIcon = "", PauseIcon = "";

    ResultScreen? screen;
    ProductionResult R => screen!.P.Result!;
    readonly MediaPlayer before = new(), after = new();
    MediaPlayer active;
    bool playing;
    readonly DispatcherTimer timer = new() { Interval = TimeSpan.FromMilliseconds(33) };
    double split = 0.5;

    public ResultView()
    {
        InitializeComponent();
        active = after;
        PlayGlyph.Text = PlayIcon;
        timer.Tick += (_, _) => Tick();
        WaveBefore.Seek += f => SeekTo(before, f);
        WaveAfter.Seek += f => SeekTo(after, f);
        Spec.SizeChanged += (_, _) => LayoutSpec();
        Spec.MouseLeftButtonDown += (_, e) => { Spec.CaptureMouse(); DragSpec(e); };
        Spec.MouseMove += (_, e) => { if (Spec.IsMouseCaptured) DragSpec(e); };
        Spec.MouseLeftButtonUp += (_, _) => Spec.ReleaseMouseCapture();
        before.MediaEnded += (_, _) => Stop();
        after.MediaEnded += (_, _) => Stop();
        Loaded += (_, _) =>
        {
            Focusable = true;
            Keyboard.Focus(this);
            var spring = new ElasticEase { Oscillations = 1, Springiness = 6, EasingMode = EasingMode.EaseOut };
            CheckScale.BeginAnimation(ScaleTransform.ScaleXProperty, new DoubleAnimation(1, TimeSpan.FromSeconds(0.7)) { EasingFunction = spring });
            CheckScale.BeginAnimation(ScaleTransform.ScaleYProperty, new DoubleAnimation(1, TimeSpan.FromSeconds(0.7)) { EasingFunction = spring });
        };
        Unloaded += (_, _) => { timer.Stop(); before.Close(); after.Close(); };
        PreviewKeyDown += (_, e) =>
        {
            if (e.Key == Key.Space && e.OriginalSource is not TextBox) { Toggle(); e.Handled = true; }
        };
        DataContextChanged += (_, _) =>
        {
            screen = DataContext as ResultScreen;
            if (screen?.P.Result != null) Build();
        };
    }

    void Build()
    {
        var r = R;
        HeaderSub.Text = $"Pronta in {r.Seconds:0} secondi · {Fmt.Duration(r.After.Duration)} · {r.Files.Count} file";
        WaveBefore.Peaks = r.PeaksBefore;
        WaveAfter.Peaks = r.PeaksAfter;
        if (File.Exists(r.PreviewBefore)) before.Open(new Uri(r.PreviewBefore));
        if (File.Exists(r.PreviewAfter)) after.Open(new Uri(r.PreviewAfter));
        SpecBefore.Source = Load(r.SpectrumBefore);
        SpecAfter.Source = Load(r.SpectrumAfter);
        var s = screen!.P.Settings;

        Stats.Children.Clear();
        Stat("", "Loudness", "LUFS", r.Before.Integrated, r.After.Integrated, 0, $"target {s.LoudnessTarget:0}");
        Stat("", "Segnale/rumore", "dB", r.Before.Snr, r.After.Snr, +1);
        Stat("", "Rumore di fondo", "dBFS", r.Before.NoiseFloor, r.After.NoiseFloor, -1);
        Stat("", "Picco reale", "dBTP", r.Before.TruePeak, r.After.TruePeak, 0, $"max {s.TruePeak:0.0}");
        Stat("", "Escursione", "LU", r.Before.Lra, r.After.Lra, 0, "loudness range");

        Files.Children.Clear();
        foreach (var f in r.Files) Files.Children.Add(FileRow(f));
        Notes.Children.Clear();
        foreach (var w in r.Warnings) Notes.Children.Add(Note("", Brushes.Gold, w));
        foreach (var n in r.Notes) Notes.Children.Add(Note(IconFor(n), (Brush)FindResource("Ember"), n));

        if (r.Transcript.Count > 0)
        {
            TranscriptCard.Visibility = Visibility.Visible;
            Transcript.Children.Clear();
            foreach (var seg in r.Transcript)
            {
                var row = new DockPanel { Margin = new Thickness(0, 0, 0, 10) };
                var ts = new Button
                {
                    Style = (Style)FindResource("PlainButton"), Margin = new Thickness(0, 0, 10, 0), VerticalAlignment = VerticalAlignment.Top,
                    Content = new TextBlock { Text = Fmt.Duration(seg.Start), FontSize = 12, FontWeight = FontWeights.Bold, Foreground = (Brush)FindResource("Ember") },
                };
                double start = seg.Start;
                ts.Click += (_, _) => { if (SideAfter.IsChecked != true) SideAfter.IsChecked = true; after.Position = TimeSpan.FromSeconds(start); Play(); };
                DockPanel.SetDock(ts, Dock.Left);
                row.Children.Add(ts);
                row.Children.Add(new TextBox
                {
                    Text = seg.Text, IsReadOnly = true, TextWrapping = TextWrapping.Wrap, Background = Brushes.Transparent,
                    BorderThickness = new Thickness(0), Foreground = Brushes.White, FontSize = 14,
                });
                Transcript.Children.Add(row);
            }
        }
        Tick();
        AnimateStats();
    }

    static BitmapImage? Load(string path)
    {
        if (!File.Exists(path)) return null;
        var b = new BitmapImage();
        b.BeginInit();
        b.CacheOption = BitmapCacheOption.OnLoad;   // don't keep the file locked
        b.UriSource = new Uri(path);
        b.EndInit();
        return b;
    }

    // ---------------------------------------------------------------- stats with count-up

    readonly List<(TextBlock Value, double From, double To)> counters = [];

    void Stat(string glyph, string title, string unit, double before, double after, int better, string? note = null)
    {
        var value = new TextBlock { FontSize = 32, FontWeight = FontWeights.Heavy, Foreground = (Brush)FindResource("Accent") };
        counters.Add((value, before, after));
        var head = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, 0, 8) };
        head.Children.Add(new TextBlock { FontFamily = new FontFamily("Segoe Fluent Icons"), Text = glyph, FontSize = 12,
                                          Foreground = (Brush)FindResource("Rose"), Margin = new Thickness(0, 0, 6, 0), VerticalAlignment = VerticalAlignment.Center });
        head.Children.Add(new TextBlock { Text = title, FontSize = 12, FontWeight = FontWeights.SemiBold, Foreground = (Brush)FindResource("Text2") });
        var big = new StackPanel { Orientation = Orientation.Horizontal };
        big.Children.Add(value);
        big.Children.Add(new TextBlock { Text = " " + unit, FontSize = 12, FontWeight = FontWeights.SemiBold, Foreground = (Brush)FindResource("Text3"),
                                         VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(0, 0, 0, 7) });
        var foot = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 8, 0, 0) };
        foot.Children.Add(new TextBlock { Text = $"prima {before:0.0}", FontSize = 11, Foreground = (Brush)FindResource("Text3"), VerticalAlignment = VerticalAlignment.Center });
        if (better != 0)
        {
            double d = after - before;
            bool good = better > 0 ? d > 0 : d < 0;
            var col = good ? Color.FromRgb(0x4D, 0xE6, 0x9E) : Colors.Orange;
            foot.Children.Add(new Border
            {
                Background = new SolidColorBrush(Color.FromArgb(38, col.R, col.G, col.B)), CornerRadius = new CornerRadius(8),
                Padding = new Thickness(6, 1, 6, 1), Margin = new Thickness(8, 0, 0, 0),
                Child = new TextBlock { Text = $"{(d > 0 ? "+" : "")}{d:0}", FontSize = 11, FontWeight = FontWeights.Bold, Foreground = new SolidColorBrush(col) },
            });
        }
        else if (note != null)
            foot.Children.Add(new TextBlock { Text = "  " + note, FontSize = 11, Foreground = (Brush)FindResource("Text3") });
        var sp = new StackPanel();
        sp.Children.Add(head);
        sp.Children.Add(big);
        sp.Children.Add(foot);
        Stats.Children.Add(new Border { Style = (Style)FindResource("Glass"), CornerRadius = new CornerRadius(20), Padding = new Thickness(16),
                                        Margin = new Thickness(0, 0, Stats.Children.Count < 4 ? 14 : 0, 0), Child = sp });
    }

    void AnimateStats()
    {
        var t0 = DateTime.Now;
        var anim = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(16) };
        anim.Tick += (_, _) =>
        {
            double k = Math.Min(1, (DateTime.Now - t0).TotalSeconds / 1.1);
            double e = 1 - Math.Pow(1 - k, 3);
            foreach (var (tb, from, to) in counters) tb.Text = (from + (to - from) * e).ToString("0.0");
            if (k >= 1) anim.Stop();
        };
        foreach (var (tb, from, _) in counters) tb.Text = from.ToString("0.0");
        anim.Start();
    }

    // ---------------------------------------------------------------- player

    void SelectSide(MediaPlayer target)
    {
        if (target == active) return;
        var from = active;
        double frac = from.NaturalDuration.HasTimeSpan && from.NaturalDuration.TimeSpan.TotalSeconds > 0
            ? from.Position.TotalSeconds / from.NaturalDuration.TimeSpan.TotalSeconds : 0;
        from.Pause();
        active = target;
        if (target.NaturalDuration.HasTimeSpan) target.Position = TimeSpan.FromSeconds(frac * target.NaturalDuration.TimeSpan.TotalSeconds);
        if (playing) target.Play();
        Tick();
    }

    void OnSide(object sender, RoutedEventArgs e)
    {
        if (!IsLoaded) return;
        SelectSide(sender == SideBefore ? before : after);
    }

    void SeekTo(MediaPlayer p, double f)
    {
        if (p == before && SideBefore.IsChecked != true) SideBefore.IsChecked = true;
        if (p == after && SideAfter.IsChecked != true) SideAfter.IsChecked = true;
        if (p.NaturalDuration.HasTimeSpan) p.Position = TimeSpan.FromSeconds(f * p.NaturalDuration.TimeSpan.TotalSeconds);
        Tick();
    }

    void OnPlay(object sender, RoutedEventArgs e) => Toggle();

    void Toggle()
    {
        if (playing) { active.Pause(); playing = false; timer.Stop(); PlayGlyph.Text = PlayIcon; }
        else Play();
    }

    void Play()
    {
        active.Play();
        playing = true;
        timer.Start();
        PlayGlyph.Text = PauseIcon;
    }

    void Stop()
    {
        playing = false;
        timer.Stop();
        PlayGlyph.Text = PlayIcon;
        Tick();
    }

    void Tick()
    {
        double pos = active.Position.TotalSeconds;
        double dur = active.NaturalDuration.HasTimeSpan ? active.NaturalDuration.TimeSpan.TotalSeconds : (screen?.P.Result?.After.Duration ?? 0);
        double f = dur > 0 ? pos / dur : 0;
        WaveBefore.Fraction = active == before ? f : -1;
        WaveAfter.Fraction = active == after ? f : -1;
        WaveBefore.Opacity = active == before ? 1 : 0.55;
        WaveAfter.Opacity = active == after ? 1 : 0.55;
        Time.Text = $"{Fmt.Duration(pos)} / {Fmt.Duration(dur)}";
    }

    // ---------------------------------------------------------------- spectrogram compare

    void LayoutSpec()
    {
        double w = Spec.ActualWidth;
        Spec.Height = w * 300 / 1400;
        double h = Spec.Height;
        SpecRound.Rect = new Rect(0, 0, w, h);
        SpecClip.Rect = new Rect(0, 0, w * split, h);
        SpecLine.Height = h;
        Canvas.SetLeft(SpecLine, w * split - 1);
        Canvas.SetLeft(SpecHandle, w * split - 13);
        Canvas.SetTop(SpecHandle, h / 2 - 13);
    }

    void DragSpec(MouseEventArgs e)
    {
        split = Math.Clamp(e.GetPosition(Spec).X / Math.Max(1, Spec.ActualWidth), 0, 1);
        LayoutSpec();
    }

    // ---------------------------------------------------------------- files and notes

    UIElement FileRow(string path)
    {
        var size = File.Exists(path) ? new FileInfo(path).Length : 0;
        var row = new DockPanel();
        var badge = new Border
        {
            Background = (Brush)FindResource("AccentDiagonal"), CornerRadius = new CornerRadius(8), Width = 46,
            Padding = new Thickness(0, 6, 0, 6), Margin = new Thickness(0, 0, 12, 0),
            Child = new TextBlock { Text = Path.GetExtension(path).TrimStart('.').ToUpperInvariant(), FontSize = 10, FontWeight = FontWeights.Heavy,
                                    HorizontalAlignment = HorizontalAlignment.Center },
        };
        DockPanel.SetDock(badge, Dock.Left);
        row.Children.Add(badge);
        var open = new TextBlock { FontFamily = new FontFamily("Segoe Fluent Icons"), Text = "", FontSize = 13,
                                   Foreground = (Brush)FindResource("Text3"), VerticalAlignment = VerticalAlignment.Center };
        DockPanel.SetDock(open, Dock.Right);
        row.Children.Add(open);
        var names = new StackPanel();
        names.Children.Add(new TextBlock { Text = Path.GetFileName(path), FontSize = 13, FontWeight = FontWeights.Medium, TextTrimming = TextTrimming.CharacterEllipsis });
        names.Children.Add(new TextBlock { Text = SizeText(size), FontSize = 11, Foreground = (Brush)FindResource("Text3") });
        row.Children.Add(names);
        var b = new Border
        {
            Background = new SolidColorBrush(Color.FromArgb(10, 255, 255, 255)), CornerRadius = new CornerRadius(12), Padding = new Thickness(10),
            Margin = new Thickness(0, 0, 0, 8), Child = row, Cursor = Cursors.Hand, ToolTip = path,
        };
        b.MouseEnter += (_, _) => b.Background = new SolidColorBrush(Color.FromArgb(24, 255, 255, 255));
        b.MouseLeave += (_, _) => b.Background = new SolidColorBrush(Color.FromArgb(10, 255, 255, 255));
        Point? down = null;
        b.MouseLeftButtonDown += (_, e) => down = e.GetPosition(b);
        b.MouseMove += (_, e) =>
        {
            // drag the file out to another app
            if (down is Point d && e.LeftButton == MouseButtonState.Pressed && (e.GetPosition(b) - d).Length > 6)
            {
                down = null;
                DragDrop.DoDragDrop(b, new DataObject(DataFormats.FileDrop, new[] { path }), DragDropEffects.Copy);
            }
        };
        b.MouseLeftButtonUp += (_, _) =>
        {
            if (down != null && File.Exists(path)) Process.Start(new ProcessStartInfo(path) { UseShellExecute = true });
            down = null;
        };
        return b;
    }

    static string SizeText(long b) => b > 1_000_000 ? $"{b / 1e6:0.0} MB" : b > 1000 ? $"{b / 1e3:0} KB" : $"{b} B";

    static string IconFor(string note) =>
        note.Contains("rumore") ? "" : note.Contains("AutoEQ") ? "" : note.Contains("Leveler") ? ""
        : note.Contains("Ronzio") ? "" : note.Contains("Tagliat") ? "" : note.Contains("Trascritt") ? "" : "";

    UIElement Note(string glyph, Brush color, string text)
    {
        var row = new DockPanel { Margin = new Thickness(0, 0, 0, 10) };
        var g = new TextBlock { FontFamily = new FontFamily("Segoe Fluent Icons"), Text = glyph, FontSize = 13, Foreground = color,
                                Width = 20, Margin = new Thickness(0, 2, 8, 0), VerticalAlignment = VerticalAlignment.Top };
        DockPanel.SetDock(g, Dock.Left);
        row.Children.Add(g);
        row.Children.Add(new TextBlock { Text = text, FontSize = 13, Foreground = new SolidColorBrush(Color.FromArgb(225, 255, 255, 255)), TextWrapping = TextWrapping.Wrap });
        return row;
    }

    void OnReveal(object sender, RoutedEventArgs e)
    {
        var f = R.Files.FirstOrDefault(File.Exists);
        if (f != null) Process.Start("explorer.exe", $"/select,\"{f}\"");
    }

    void OnReprocess(object sender, RoutedEventArgs e) => screen!.Model.Reprocess(screen.P);
}
