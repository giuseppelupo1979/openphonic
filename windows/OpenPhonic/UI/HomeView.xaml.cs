using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Shapes;

namespace OpenPhonic.UI;

public partial class HomeView : UserControl
{
    AppModel? Model => (DataContext as HomeScreen)?.Model;

    public HomeView()
    {
        InitializeComponent();
        Loaded += (_, _) =>
        {
            if (Model is not { } model) return;
            PresetList.ItemsSource = model.Presets;
            Dispatcher.BeginInvoke(() =>
            {
                // tick the remembered preset (the view may already have been replaced)
                if (Model is not { } m) return;
                foreach (var rb in FindAll<RadioButton>(PresetList))
                    if ((string)rb.Tag == m.PresetId) rb.IsChecked = true;
            }, System.Windows.Threading.DispatcherPriority.Loaded);
            StartRings();
            var ease = new CubicEase { EasingMode = EasingMode.EaseOut };
            Body.BeginAnimation(OpacityProperty, new DoubleAnimation(1, TimeSpan.FromSeconds(0.6)) { EasingFunction = ease });
            Lift.BeginAnimation(TranslateTransform.YProperty, new DoubleAnimation(0, TimeSpan.FromSeconds(0.7)) { EasingFunction = ease });
        };
    }

    /// <summary>Concentric ellipses expanding from the centre of the drop zone.</summary>
    void StartRings()
    {
        Rings.Children.Clear();
        double w = Rings.ActualWidth, h = Rings.ActualHeight;
        for (int i = 0; i < 4; i++)
        {
            var e = new Ellipse
            {
                Width = w * 1.1, Height = h * 1.3, StrokeThickness = 1.4,
                Stroke = Palette.Accent(), RenderTransformOrigin = new Point(0.5, 0.5),
            };
            Canvas.SetLeft(e, (w - e.Width) / 2);
            Canvas.SetTop(e, (h - e.Height) / 2);
            var st = new ScaleTransform(0.15, 0.15);
            e.RenderTransform = st;
            Rings.Children.Add(e);
            var begin = TimeSpan.FromSeconds(i * 1.1);
            var dur = new Duration(TimeSpan.FromSeconds(4.4));
            st.BeginAnimation(ScaleTransform.ScaleXProperty, new DoubleAnimation(0.15, 1, dur) { BeginTime = begin, RepeatBehavior = RepeatBehavior.Forever });
            st.BeginAnimation(ScaleTransform.ScaleYProperty, new DoubleAnimation(0.15, 1, dur) { BeginTime = begin, RepeatBehavior = RepeatBehavior.Forever });
            e.BeginAnimation(OpacityProperty, new DoubleAnimation(1, 0, dur) { BeginTime = begin, RepeatBehavior = RepeatBehavior.Forever });
        }
    }

    static IEnumerable<T> FindAll<T>(DependencyObject root) where T : DependencyObject
    {
        for (int i = 0; i < VisualTreeHelper.GetChildrenCount(root); i++)
        {
            var c = VisualTreeHelper.GetChild(root, i);
            if (c is T t) yield return t;
            foreach (var d in FindAll<T>(c)) yield return d;
        }
    }

    void OnPreset(object sender, RoutedEventArgs e)
    {
        if (Model is { } m) m.PresetId = (string)((RadioButton)sender).Tag;
    }

    void OnChoose(object sender, RoutedEventArgs e)
    {
        if (Model is { } m) MainWindow.OpenFiles(m);
    }
}
