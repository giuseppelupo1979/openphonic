using System.ComponentModel;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using Microsoft.Win32;
using OpenPhonic.Engine;

namespace OpenPhonic.UI;

public partial class SetupView : UserControl
{
    SetupScreen? screen;
    Production P => screen!.P;
    ProductionSettings? watched;

    public SetupView()
    {
        InitializeComponent();
        DataContextChanged += (_, _) =>
        {
            screen = DataContext as SetupScreen;
            if (screen == null) return;
            P.PropertyChanged += OnProductionChanged;
            Build();
        };
        Unloaded += (_, _) =>
        {
            if (screen != null) P.PropertyChanged -= OnProductionChanged;
            if (watched != null) watched.PropertyChanged -= OnSettingsChanged;
        };
    }

    void OnProductionChanged(object? s, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(Production.Settings)) { Watch(); RefreshOutputs(); RefreshSummary(); }
        if (e.PropertyName is nameof(Production.Intro) or nameof(Production.Outro) or nameof(Production.Cover)) RefreshExtras();
    }

    void OnSettingsChanged(object? s, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(ProductionSettings.Outputs)) RefreshOutputs();
        RefreshSummary();
    }

    void Watch()
    {
        if (watched != null) watched.PropertyChanged -= OnSettingsChanged;
        watched = P.Settings;
        watched.PropertyChanged += OnSettingsChanged;
    }

    void Build()
    {
        Watch();
        var info = P.Info;
        KindGlyph.Text = info?.HasVideo == true ? "" : "";
        InfoChips.Children.Clear();
        if (info != null)
        {
            Chip("", Fmt.Duration(info.Duration));
            Chip("", $"{info.Codec.ToUpperInvariant()} · {info.SampleRate / 1000} kHz");
            Chip("", info.Channels > 1 ? "Stereo" : "Mono");
            if (info.HasVideo) Chip("", $"Video {info.VideoCodec?.ToUpperInvariant()}");
        }
        PresetBar.Children.Clear();
        foreach (var pr in Preset.All)
        {
            var b = new Button { Style = (Style)FindResource("GhostButton"), Margin = new Thickness(0, 0, 10, 10) };
            b.Content = Row(pr.Glyph, pr.Name, 12);
            var preset = pr;
            b.Click += (_, _) =>
            {
                var c = preset.Settings();
                c.Title = P.Settings.Title; c.Artist = P.Settings.Artist; c.Album = P.Settings.Album;
                if (P.Info?.HasVideo == true && !c.Outputs.Any(o => o.Format == OutFormat.Video))
                    c.Outputs = [.. c.Outputs, new Output(OutFormat.Video)];
                P.Settings = c;
            };
            PresetBar.Children.Add(b);
        }
        FormatMenu.Items.Clear();
        foreach (var f in Enum.GetValues<OutFormat>())
        {
            var mi = new MenuItem { Header = FormatName(f) };
            var fmt = f;
            mi.Click += (_, _) => P.Settings.Outputs = [.. P.Settings.Outputs, new Output(fmt)];
            FormatMenu.Items.Add(mi);
        }
        RefreshOutputs();
        RefreshExtras();
        RefreshSummary();
    }

    static StackPanel Row(string glyph, string text, double size)
    {
        var sp = new StackPanel { Orientation = Orientation.Horizontal };
        sp.Children.Add(new TextBlock { FontFamily = new FontFamily("Segoe Fluent Icons"), Text = glyph, FontSize = size,
                                        Margin = new Thickness(0, 0, 8, 0), VerticalAlignment = VerticalAlignment.Center, Foreground = Brushes.White });
        sp.Children.Add(new TextBlock { Text = text, FontSize = 13, Foreground = Brushes.White, VerticalAlignment = VerticalAlignment.Center });
        return sp;
    }

    void Chip(string glyph, string text)
    {
        var b = new Border
        {
            Background = new SolidColorBrush(Color.FromArgb(18, 255, 255, 255)), CornerRadius = new CornerRadius(12),
            Padding = new Thickness(10, 4, 10, 4), Margin = new Thickness(0, 0, 8, 0),
        };
        var sp = Row(glyph, text, 11);
        foreach (TextBlock t in sp.Children) t.Foreground = (Brush)FindResource("Text2");
        b.Child = sp;
        InfoChips.Children.Add(b);
    }

    public static string FormatName(OutFormat f) => f switch
    {
        OutFormat.Mp3 => "MP3", OutFormat.Aac => "AAC (M4A)", OutFormat.Opus => "Opus",
        OutFormat.Flac => "FLAC lossless", OutFormat.Wav => "WAV 24 bit", _ => "Video MP4",
    };

    void RefreshOutputs()
    {
        var panel = new StackPanel();
        var outs = P.Settings.Outputs;
        for (int i = 0; i < outs.Count; i++)
        {
            var o = outs[i];
            int idx = i;
            var row = new DockPanel { Margin = new Thickness(0, 0, 0, 8) };
            var border = new Border
            {
                Background = new SolidColorBrush(Color.FromArgb(10, 255, 255, 255)), CornerRadius = new CornerRadius(12),
                Padding = new Thickness(10), Child = row, Margin = new Thickness(0, 0, 0, 8),
            };
            var badge = new Border
            {
                Background = (Brush)FindResource("AccentDiagonal"), CornerRadius = new CornerRadius(7), Width = 50,
                Padding = new Thickness(0, 4, 0, 4), Margin = new Thickness(0, 0, 10, 0),
                Child = new TextBlock { Text = o.Ext.ToUpperInvariant(), FontSize = 11, FontWeight = FontWeights.Heavy,
                                        HorizontalAlignment = HorizontalAlignment.Center },
            };
            var remove = new Button
            {
                Style = (Style)FindResource("PlainButton"), IsEnabled = outs.Count > 1, Margin = new Thickness(8, 0, 0, 0),
                Content = new TextBlock { FontFamily = new FontFamily("Segoe Fluent Icons"), Text = "", FontSize = 12,
                                          Foreground = (Brush)FindResource("Text3"), VerticalAlignment = VerticalAlignment.Center },
            };
            remove.Click += (_, _) => P.Settings.Outputs = P.Settings.Outputs.Where((_, k) => k != idx).ToList();
            DockPanel.SetDock(badge, Dock.Left);
            DockPanel.SetDock(remove, Dock.Right);
            row.Children.Add(badge);
            row.Children.Add(remove);
            row.Children.Add(MenuButton(o.Channels switch { OutChannels.Mono => "Mono", OutChannels.Stereo => "Stereo", _ => "Originale" },
                [("Canali originali", () => Replace(idx, o with { Channels = OutChannels.Keep })),
                 ("Mono", () => Replace(idx, o with { Channels = OutChannels.Mono })),
                 ("Stereo", () => Replace(idx, o with { Channels = OutChannels.Stereo }))]));
            if (!o.IsLossless)
                row.Children.Add(MenuButton($"{o.Bitrate} kbps",
                    new[] { 64, 96, 128, 160, 192, 256, 320 }.Select(b => ($"{b} kbps", (Action)(() => Replace(idx, o with { Bitrate = b })))).ToArray()));
            row.Children.Add(new TextBlock { Text = FormatName(o.Format), FontSize = 13, VerticalAlignment = VerticalAlignment.Center });
            panel.Children.Add(border);
        }
        OutputsList.ItemsSource = null;
        OutputsList.Items.Clear();
        OutputsList.Items.Add(panel);
    }

    Button MenuButton(string label, (string, Action)[] items)
    {
        var b = new Button { Style = (Style)FindResource("GhostButton"), Margin = new Thickness(6, 0, 0, 0), Padding = new Thickness(10, 4, 10, 4) };
        b.Content = new TextBlock { Text = label, FontSize = 12, Foreground = Brushes.White };
        DockPanel.SetDock(b, Dock.Right);
        var menu = new ContextMenu();
        foreach (var (text, act) in items)
        {
            var mi = new MenuItem { Header = text };
            mi.Click += (_, _) => act();
            menu.Items.Add(mi);
        }
        b.ContextMenu = menu;
        b.Click += (_, _) => { menu.PlacementTarget = b; menu.IsOpen = true; };
        return b;
    }

    void Replace(int i, Output o)
    {
        var list = P.Settings.Outputs.ToList();
        list[i] = o;
        P.Settings.Outputs = list;
    }

    void RefreshExtras()
    {
        Pill(IntroBtn, "Intro", "", P.Intro);
        Pill(OutroBtn, "Outro", "", P.Outro);
        Pill(CoverBtn, "Copertina", "", P.Cover);
    }

    void Pill(Button b, string label, string glyph, string? file)
    {
        bool has = file != null;
        var sp = new StackPanel { HorizontalAlignment = HorizontalAlignment.Center };
        sp.Children.Add(new TextBlock { FontFamily = new FontFamily("Segoe Fluent Icons"), Text = has ? "" : glyph, FontSize = 16,
                                        HorizontalAlignment = HorizontalAlignment.Center,
                                        Foreground = has ? (Brush)FindResource("Rose") : (Brush)FindResource("Text2") });
        sp.Children.Add(new TextBlock { Text = label, FontSize = 12, FontWeight = FontWeights.SemiBold, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 4, 0, 0) });
        sp.Children.Add(new TextBlock { Text = has ? Path.GetFileName(file) : "aggiungi", FontSize = 10, Foreground = (Brush)FindResource("Text3"),
                                        HorizontalAlignment = HorizontalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis });
        b.Content = new Border
        {
            Background = new SolidColorBrush(Color.FromArgb((byte)(has ? 24 : 10), 255, 255, 255)), CornerRadius = new CornerRadius(12),
            BorderBrush = has ? (Brush)FindResource("Accent") : new SolidColorBrush(Color.FromArgb(20, 255, 255, 255)),
            BorderThickness = new Thickness(1), Padding = new Thickness(6, 10, 6, 10), Child = sp,
        };
        b.ToolTip = has ? "Clic per rimuovere" : "Scegli un file";
    }

    void OnExtra(object sender, RoutedEventArgs e)
    {
        var kind = (string)((Button)sender).Tag;
        string? current = kind switch { "Intro" => P.Intro, "Outro" => P.Outro, _ => P.Cover };
        string? value = null;
        if (current == null)
        {
            var dlg = new OpenFileDialog
            {
                Filter = kind == "Cover" ? "Immagini|*.jpg;*.jpeg;*.png" : "Audio|*.mp3;*.wav;*.m4a;*.aac;*.flac;*.ogg;*.opus|Tutti i file|*.*",
            };
            if (dlg.ShowDialog() != true) return;
            value = dlg.FileName;
        }
        switch (kind)
        {
            case "Intro": P.Intro = value; break;
            case "Outro": P.Outro = value; break;
            default: P.Cover = value; break;
        }
    }

    void RefreshSummary()
    {
        var s = P.Settings;
        TargetHint.Text = s.LoudnessTarget switch
        {
            -23 => "Radio e TV europee (EBU R128)",
            -19 => "Podcast mono, audiolibri",
            -18 => "Apple Podcasts",
            -14 => "YouTube, Spotify, piattaforme di streaming",
            _ => "Podcast stereo, lo standard più diffuso",
        };
        var parts = new List<string>();
        if (s.DenoiseOn) parts.Add("rumore");
        if (s.LevelerOn) parts.Add("leveler");
        if (s.FilterOn && s.AutoEQ) parts.Add("AutoEQ");
        if (s.LoudnessOn) parts.Add($"{s.LoudnessTarget:0} LUFS");
        if (s.CutSilence) parts.Add("tagli");
        if (s.Transcribe) parts.Add("trascrizione");
        Summary.Text = string.Join(" · ", parts) + " → " + string.Join(", ", s.Outputs.Select(o => o.Ext.ToUpperInvariant()));
    }

    void OnTitle(object sender, TextChangedEventArgs e) => P.NotifyName();
    void OnAddOutput(object sender, RoutedEventArgs e)
    {
        FormatMenu.PlacementTarget = (UIElement)sender;
        FormatMenu.IsOpen = true;
    }
    void OnStart(object sender, RoutedEventArgs e) => screen!.Model.Start(P);
}
