using System.IO;
using System.Windows;
using System.Windows.Controls;
using Verbemo.Core.Processing;
using static Verbemo.Core.Localization.Localized;

namespace Verbemo.App;

internal sealed class ModelFilesView
{
    private readonly VerbemoRuntime runtime;
    private readonly Dictionary<string,(TextBlock Status, System.Windows.Controls.Button Download, System.Windows.Controls.Button Delete, System.Windows.Controls.Button Cancel)> controls = [];
    public StackPanel View { get; } = new();
    public ModelFilesView(VerbemoRuntime runtime)
    {
        this.runtime = runtime;
        View.Children.Add(Ui.Heading(T("Model files", "Файлы моделей")));
        foreach(var (id,artifact) in ModelCatalog.Models)
        {
            var status = Ui.Detail("");
            var download = Ui.Button(T("Download", "Скачать"), () => _ = DownloadAsync(id));
            var cancel = Ui.Button(T("Cancel", "Отменить"), () => runtime.CancelModelDownload(id));
            var delete = Ui.Button(T("Delete", "Удалить"), () =>
            {
                if(System.Windows.MessageBox.Show(Ui.OwnerOf(View),T("Delete these model files?", "Удалить файлы этой модели?"),"Verbemo",MessageBoxButton.OKCancel,MessageBoxImage.Question,MessageBoxResult.Cancel) != MessageBoxResult.OK) return;
                try { runtime.DeleteModel(id); Refresh(); }
                catch(Exception error) when(error is IOException or InvalidOperationException or UnauthorizedAccessException) { Ui.ShowError(Ui.OwnerOf(View),"Verbemo",error.Message); }
            });
            var row = new StackPanel { Margin = new Thickness(0,10,0,12) };
            row.Children.Add(Ui.Heading(id == "nemotron-live" ? "Nemotron Live" : EngineResolver.DisplayName(id)));
            row.Children.Add(Ui.Detail(Ui.Megabytes(artifact.Size)));
            row.Children.Add(status);
            var actions = new WrapPanel();
            actions.Children.Add(download); actions.Children.Add(cancel); actions.Children.Add(delete);
            row.Children.Add(actions);
            View.Children.Add(row);
            controls[id] = (status,download,delete,cancel);
        }
        runtime.DownloadProgressChanged += Progress;
        runtime.SettingsChanged += Changed;
        runtime.StateChanged += StateChanged;
        Refresh();
    }
    private async Task DownloadAsync(string id)
    {
        try { var task = runtime.EnsureLocalModelAsync(id); Refresh(); await task; }
        catch(Exception error) when(error is IOException or InvalidOperationException or System.Net.Http.HttpRequestException or OperationCanceledException)
        { controls[id].Status.Text = error is OperationCanceledException ? T("Download cancelled; the next attempt resumes.", "Загрузка отменена; следующая попытка продолжит её.") : error.Message; }
        finally { Refresh(); }
    }
    private void Changed(object? sender,EventArgs e) => View.Dispatcher.InvokeAsync(Refresh);
    private void StateChanged(object? sender,Verbemo.Core.Recording.RecordingState e) => View.Dispatcher.InvokeAsync(Refresh);
    private void Progress(object? sender,DownloadProgress e) => View.Dispatcher.InvokeAsync(() =>
    {
        var id = e.Item.Replace("Model ","",StringComparison.Ordinal);
        if(controls.TryGetValue(id,out var control)) control.Status.Text = $"{e.Percentage}% · {Ui.Megabytes(e.Received)} / {Ui.Megabytes(e.Total)}";
    });
    private void Refresh()
    {
        foreach(var (id,c) in controls)
        {
            var downloading = runtime.IsLocalModelDownloading(id);
            c.Download.IsEnabled = !downloading && !runtime.IsLocalModelReady(id);
            c.Cancel.Visibility = downloading ? Visibility.Visible : Visibility.Collapsed;
            c.Delete.IsEnabled = !downloading && runtime.LocalModelBytes(id) is not null && !runtime.ModelInUse(id);
            if(runtime.LocalModelBytes(id) is { } size) c.Status.Text = T("Downloaded · ", "Скачано · ")+Ui.Megabytes(size);
        }
    }
    public void Detach() { runtime.DownloadProgressChanged -= Progress; runtime.SettingsChanged -= Changed; runtime.StateChanged -= StateChanged; }
}
