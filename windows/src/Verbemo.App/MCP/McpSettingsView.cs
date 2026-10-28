using System.Globalization;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;
using Verbemo.Core.MCP;
using static Verbemo.Core.Localization.Localized;

namespace Verbemo.App.MCP;

internal sealed record McpUiState(bool Enabled,int Port,bool Readable,string Status,string? ActiveEndpoint);

internal sealed class McpSettingsView
{
    private readonly Func<McpUiState> state;
    private readonly Action<int> savePort;
    private readonly string executable;
    private readonly StackPanel card=new();
    private readonly CheckBox enabled;
    private readonly TextBox port=new() { Width=110,HorizontalAlignment=HorizontalAlignment.Left };
    private readonly ComboBox clients=new() { ItemsSource=McpConnectionInstructions.Clients,SelectedIndex=0,HorizontalAlignment=HorizontalAlignment.Stretch };
    private readonly TextBlock status=Ui.Detail(""), selected=Ui.Detail(""), active=Ui.Detail(""), problem=Ui.Status("",Ui.Caution), manual=Ui.Detail("");
    private readonly TextBox endpoint=ReadOnly(),command=ReadOnly(),prompt=ReadOnly();
    private readonly TextBlock commandLabel=Ui.Heading(T("Console command","Консольная команда"));
    private readonly List<Button> copyButtons=[];
    private readonly Expander serverSection,connectionSection,accessSection;
    private readonly UIElement toggleRow;
    private int lastSavedPort;
    private bool refreshing;
    public FrameworkElement View { get; }
    public McpSettingsView(Func<McpUiState> state,Action<bool> setEnabled,Action<int> savePort,Func<string?> readToken,Func<Task> rotate,string executable)
    {
        this.state=state; this.savePort=savePort; this.executable=executable;
        enabled=Ui.Switch(T("Enable MCP","Включить MCP"));
        toggleRow=Ui.Row(enabled,Ui.Title("MCP")); card.Children.Add(toggleRow);
        var box=Ui.Box(card); View=box;
        AutomationProperties.SetName(port,T("MCP port","Порт MCP")); AutomationProperties.SetName(clients,T("MCP client","Клиент MCP"));
        enabled.Click+=(_,_)=> { if(refreshing) return; try { setEnabled(enabled.IsChecked==true); } catch { problem.Text=T("MCP could not be changed. Check configuration and protected storage.","Не удалось изменить MCP. Проверьте конфигурацию и защищённое хранилище."); } Refresh(); };
        var server=Ui.Group(8,status,Ui.Detail(T("Port","Порт")),port,Ui.Button(T("Apply port","Применить порт"),ApplyPort),selected,active,
            Ui.Detail(T("Changing the port disconnects active clients.","Смена порта отключает активных клиентов.")));
        var connection=Ui.Group(12,clients,Block(Ui.Heading("MCP URL"),endpoint,()=>Content().Endpoint),Block(commandLabel,command,()=>Content().ConsoleCommand),
            Block(Ui.Heading(T("Agent prompt","Промпт для агента")),prompt,()=>Content().AgentPrompt),problem,manual);
        var token=new McpTokenField(readToken);
        var access=Ui.Group(8,Ui.Detail(T("Token for direct HTTP","Токен для прямого HTTP")),token,Ui.Button(T("Copy token","Копировать токен"),()=>
        { try { token.CopyCurrent(); } catch { problem.Text=T("The protected token could not be read.","Не удалось прочитать защищённый токен."); } }),
            Ui.Detail(T("Copying inserts the full token","При копировании будет подставлен полный токен")),
            Ui.Button(T("Rotate token","Заменить токен"),async ()=> { try { await rotate(); } catch { problem.Text=T("Token rotation failed; MCP is closed.","Не удалось заменить токен; MCP закрыт."); } Refresh(); }),
            Ui.Detail(T("The native bridge reads the token itself. Rotation disconnects active clients.","Нативный мост сам читает токен. Замена токена отключает активных клиентов.")));
        serverSection=Section(T("Server","Сервер"),server,false);
        connectionSection=Section(T("Connection","Подключение"),connection,true);
        accessSection=Section(T("Access","Доступ"),access,false);
        port.TextChanged+=(_,_)=> { if(!refreshing) UpdateContent(); };
        port.KeyDown+=(_,eventArgs)=> { if(eventArgs.Key==Key.Enter) { ApplyPort(); eventArgs.Handled=true; } };
        clients.SelectionChanged+=(_,_)=> { if(!refreshing) UpdateContent(); };
        lastSavedPort=state().Port; port.Text=lastSavedPort.ToString(CultureInfo.InvariantCulture); Refresh();
    }
    private static Expander Section(string title,UIElement content,bool expanded)
    {
        var section=new Expander { Header=title,IsExpanded=expanded,Content=content,Margin=new Thickness(16,8,16,12),HorizontalContentAlignment=HorizontalAlignment.Stretch };
        AutomationProperties.SetName(section,title); return section;
    }
    private FrameworkElement Block(TextBlock title,TextBox field,Func<string> value)
    {
        var copy=Ui.Button(T("Copy","Копировать"),()=> { var content=Content(); if(content.Error is null) Clipboard.SetText(value()); });
        copy.HorizontalAlignment=HorizontalAlignment.Left; AutomationProperties.SetName(copy,T("Copy ","Копировать: ")+title.Text);
        AutomationProperties.SetLabeledBy(field,title);
        copyButtons.Add(copy); return Ui.Group(4,title,field,copy);
    }
    private static TextBox ReadOnly() => new() { IsReadOnly=true,TextWrapping=TextWrapping.Wrap,AcceptsReturn=true,HorizontalScrollBarVisibility=ScrollBarVisibility.Disabled,VerticalScrollBarVisibility=ScrollBarVisibility.Auto,MaxHeight=220,MinWidth=0,HorizontalAlignment=HorizontalAlignment.Stretch };
    private McpConnectionContent Content()
    {
        var selectedPort=int.TryParse(port.Text,NumberStyles.None,CultureInfo.InvariantCulture,out var value) ? value : 0;
        return McpConnectionInstructions.Create(clients.SelectedItem as string ?? McpConnectionInstructions.Clients[0],selectedPort,executable,state().Readable);
    }
    private void ApplyPort()
    {
        if(Content().Error is not null) { UpdateContent(); return; }
        try { savePort(int.Parse(port.Text,CultureInfo.InvariantCulture)); Refresh(); }
        catch { problem.Text=T("The port could not be saved.","Не удалось сохранить порт."); }
    }
    public void Refresh()
    {
        refreshing=true;
        try
        {
            var current=state(); enabled.IsChecked=current.Enabled; enabled.IsEnabled=current.Readable;
            if(current.Port!=lastSavedPort) { lastSavedPort=current.Port; port.Text=lastSavedPort.ToString(CultureInfo.InvariantCulture); }
            if(!current.Enabled) { while(card.Children.Count>1) card.Children.RemoveAt(1); return; }
            if(card.Children.Count==1) { card.Children.Add(serverSection); card.Children.Add(connectionSection); card.Children.Add(accessSection); }
            var label=current.Status switch { "running"=>T("Listening","Работает"),"starting"=>T("Starting","Запускается"),"reconfiguring"=>T("Reconfiguring","Применяются настройки"),"token_missing"=>T("No local token: use Rotate token in Access","Нет локального токена: нажмите «Заменить токен» в разделе «Доступ»"),"disabled"=>T("Disabled","Выключен"),"stopped" or "stopping"=>T("Stopped","Остановлен"),"configuration_unreadable" or "configuration_changed"=>T("Configuration unavailable or changed","Конфигурация недоступна или изменилась"),_=>T("Could not start: check port and protected storage","Не удалось запустить: проверьте порт и защищённое хранилище") };
            status.Text=T("Actual server state: ","Фактическое состояние сервера: ")+label;
            active.Text=T("Active endpoint: ","Активный адрес: ")+(current.ActiveEndpoint ?? T("not listening","не работает"));
            serverSection.Header=T("Server — ","Сервер — ")+label;
            UpdateContent();
        }
        finally { refreshing=false; }
    }
    private void UpdateContent()
    {
        var content=Content(); endpoint.Text=content.Endpoint; command.Text=content.ConsoleCommand; prompt.Text=content.AgentPrompt; manual.Text=content.ManualSteps;
        selected.Text=content.Error ?? T("Selected endpoint: ","Выбранный адрес: ")+content.Endpoint;
        problem.Text=content.Error ?? ""; problem.Visibility=content.Error is null ? Visibility.Collapsed : Visibility.Visible;
        commandLabel.Text=clients.SelectedItem is "Claude Desktop" or "OpenChamber" ? T("Console command — launch bridge only","Консольная команда — только запуск моста") : T("Console registration command","Консольная команда регистрации");
        foreach(var copy in copyButtons) copy.IsEnabled=content.Error is null;
    }
}

internal sealed class McpTokenField : TextBox
{
    private readonly Func<string?> readToken;
    public McpTokenField(Func<string?> readToken)
    {
        this.readToken=readToken; Text="***"; IsReadOnly=true; Width=140; HorizontalAlignment=HorizontalAlignment.Left;
        AutomationProperties.SetName(this,T("MCP token, masked","Токен MCP, скрыт"));
        CommandBindings.Add(new CommandBinding(ApplicationCommands.Copy,(_,e)=> { if(SelectionLength>0) CopyCurrent(); e.Handled=true; },(_,e)=> { e.CanExecute=SelectionLength>0; e.Handled=true; }));
        ContextMenu=new ContextMenu(); ContextMenu.Items.Add(new MenuItem { Header=T("Copy","Копировать"),Command=ApplicationCommands.Copy,CommandTarget=this });
    }
    internal void CopyCurrent()
    {
        // Resolve only during the user's copy action; the visual/automation value stays masked.
        var token=readToken(); if(!McpController.ValidToken(token)) throw new McpFailure("credentials_unavailable");
        Clipboard.SetText(token!);
    }
}
