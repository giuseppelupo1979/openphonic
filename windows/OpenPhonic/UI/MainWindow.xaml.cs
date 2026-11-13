using System.Diagnostics;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using Microsoft.Win32;

namespace OpenPhonic.UI;

public partial class MainWindow : Window
{
    public AppModel Model { get; } = new();

    public MainWindow()
    {
        InitializeComponent();
        DataContext = Model;
        if (!Model.FfmpegAvailable) FfStatus.Text = " mancante: reinstalla";
        if (!Model.DeepFilterAvailable) DfStatus.Text = " non trovata";
        Model.Productions.CollectionChanged += (_, _) => UpdateEmpty();
        Model.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(AppModel.Selected)) List.SelectedItem = Model.Selected;
            if (e.PropertyName is nameof(AppModel.Screen) or nameof(AppModel.Selected)) Model.Save();
        };
        UpdateEmpty();
        DragEnter += (_, e) => { if (e.Data.GetDataPresent(DataFormats.FileDrop)) DropOverlay.Visibility = Visibility.Visible; };
        DragLeave += (_, e) => DropOverlay.Visibility = Visibility.Collapsed;
        Drop += (_, e) =>
        {
            DropOverlay.Visibility = Visibility.Collapsed;
            if (e.Data.GetData(DataFormats.FileDrop) is string[] files) Model.Add(files.Where(File.Exists));
        };
        Closing += (_, _) => { Model.Cancel(); Model.Save(); };
        // look for a new version a few seconds after start, without slowing the launch down
        Loaded += async (_, _) => { await Task.Delay(3000); await Model.CheckForUpdate(); };
    }

    async void OnUpdate(object s, RoutedEventArgs e) => await Model.ApplyUpdate();
    async void OnCheckUpdate(object s, RoutedEventArgs e)
    {
        Model.UpdateStatus = "Controllo in corso…";
        await Model.CheckForUpdate(userAsked: true);
    }

    void UpdateEmpty() => EmptyHint.Visibility = Model.Productions.Count == 0 ? Visibility.Visible : Visibility.Collapsed;

    public static void OpenFiles(AppModel model)
    {
        var dlg = new OpenFileDialog
        {
            Multiselect = true,
            Title = "Scegli uno o più file audio o video da elaborare",
            Filter = "Audio e video|*.mp3;*.wav;*.m4a;*.aac;*.flac;*.ogg;*.opus;*.wma;*.aiff;*.aif;*.mp4;*.mov;*.mkv;*.webm;*.avi|Tutti i file|*.*",
        };
        if (dlg.ShowDialog() == true) model.Add(dlg.FileNames);
    }

    void OnNew(object s, RoutedEventArgs e) { List.SelectedItem = null; Model.ShowHome(); }
    void OnStartAll(object s, RoutedEventArgs e) => Model.StartAll();
    void OnPick(object s, SelectionChangedEventArgs e)
    {
        if (List.SelectedItem is Production p && p != Model.Selected) Model.Open(p);
        else if (List.SelectedItem is Production q && Model.ShowingHome) Model.Open(q);
    }

    void OnFolder(object s, RoutedEventArgs e)
    {
        var dlg = new OpenFolderDialog { Title = "Cartella dove salvare i file elaborati", InitialDirectory = Model.OutputFolder };
        if (dlg.ShowDialog() == true) Model.OutputFolder = dlg.FolderName;
    }

    static Production? Item(object sender) => (sender as FrameworkElement)?.DataContext as Production;

    void OnReveal(object s, RoutedEventArgs e)
    {
        if (Item(s) is not { } p) return;
        var target = p.Result?.Files.FirstOrDefault(File.Exists) ?? p.Source;
        Process.Start("explorer.exe", $"/select,\"{target}\"");
    }

    void OnRemove(object s, RoutedEventArgs e)
    {
        if (Item(s) is { } p) Model.Remove(p);
    }

    void OnMin(object s, RoutedEventArgs e) => WindowState = WindowState.Minimized;
    void OnMax(object s, RoutedEventArgs e) =>
        WindowState = WindowState == WindowState.Maximized ? WindowState.Normal : WindowState.Maximized;
    void OnClose(object s, RoutedEventArgs e) => Close();
}
