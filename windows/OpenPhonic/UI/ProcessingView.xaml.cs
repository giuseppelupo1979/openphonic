using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace OpenPhonic.UI;

public partial class ProcessingView : UserControl
{
    static readonly (double At, string Glyph, string Name)[] StageList =
    [
        (0.10, "", "Analisi"), (0.20, "", "Filtri"), (0.32, "", "Riduzione\nrumore AI"),
        (0.44, "", "Voice\nAutoEQ"), (0.66, "", "Adaptive\nLeveler"), (0.80, "", "Tagli e\ntrascrizione"),
        (0.85, "", "Loudness"), (0.95, "", "Esportazione"), (1.00, "", "Misure\nfinali"),
    ];

    ProcessingScreen? screen;
    readonly List<(Border Circle, TextBlock Glyph, TextBlock Label)> items = [];

    public ProcessingView()
    {
        InitializeComponent();
        foreach (var st in StageList)
        {
            var glyph = new TextBlock { FontFamily = new FontFamily("Segoe Fluent Icons"), Text = st.Glyph, FontSize = 15,
                                        HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
            var circle = new Border { Width = 40, Height = 40, CornerRadius = new CornerRadius(20), Child = glyph };
            var label = new TextBlock { Text = st.Name, FontSize = 10, FontWeight = FontWeights.SemiBold, TextAlignment = TextAlignment.Center,
                                        Width = 82, Margin = new Thickness(0, 7, 0, 0) };
            var sp = new StackPanel();
            sp.Children.Add(circle);
            sp.Children.Add(label);
            Stages.Children.Add(sp);
            items.Add((circle, glyph, label));
        }
        DataContextChanged += (_, _) =>
        {
            if (screen != null) screen.P.PropertyChanged -= OnChanged;
            screen = DataContext as ProcessingScreen;
            if (screen != null) { screen.P.PropertyChanged += OnChanged; Refresh(); }
        };
        Unloaded += (_, _) => { if (screen != null) screen.P.PropertyChanged -= OnChanged; };
    }

    void OnChanged(object? s, PropertyChangedEventArgs e) => Refresh();

    void Refresh()
    {
        var p = screen!.P;
        Pct.Text = $"{p.Progress * 100:0}";
        Sub.Text = p.Status == Status.Queued ? "In coda: parte appena finisce la produzione in corso" : "Elaborazione in corso sul tuo PC";
        for (int i = 0; i < items.Count; i++)
        {
            bool done = p.Progress >= StageList[i].At;
            bool active = !done && (i == 0 || p.Progress >= StageList[i - 1].At);
            var (circle, glyph, label) = items[i];
            circle.Background = done ? (Brush)FindResource("AccentDiagonal")
                : new SolidColorBrush(Color.FromArgb((byte)(active ? 36 : 15), 255, 255, 255));
            circle.Effect = done ? (System.Windows.Media.Effects.Effect)FindResource("RoseGlowSoft") : null;
            glyph.Text = done ? "" : StageList[i].Glyph;
            glyph.Foreground = done || active ? Brushes.White : (Brush)FindResource("Text3");
            label.Foreground = done || active ? Brushes.White : (Brush)FindResource("Text3");
        }
    }

    void OnCancel(object sender, RoutedEventArgs e) => screen?.Model.Cancel();
}
