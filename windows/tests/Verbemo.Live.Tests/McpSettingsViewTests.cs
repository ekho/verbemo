using System.Windows;
using System.Windows.Automation.Peers;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using Verbemo.App;
using Verbemo.App.MCP;
using Verbemo.Core.Localization;
using Xunit;

namespace Verbemo.Live.Tests;

[Collection("McpClipboard")]
public sealed class McpSettingsViewTests
{
    private static IEnumerable<DependencyObject> Descendants(DependencyObject root)
    {
        yield return root;
        foreach(var child in LogicalTreeHelper.GetChildren(root).OfType<DependencyObject>()) foreach(var item in Descendants(child)) yield return item;
    }
    [Fact]
    public void Mcp_has_one_dedicated_destination_without_general_editors()
    {
        Assert.Contains("mcp.enabled",SettingsContentView.EditorPaths[ApplicationDestination.Mcp]);
        Assert.Contains("mcp.port",SettingsContentView.EditorPaths[ApplicationDestination.Mcp]);
        Assert.DoesNotContain("mcp.enabled",SettingsContentView.EditorPaths[ApplicationDestination.General]);
        Assert.Contains("mcp.enabled",SettingsContentView.PrimaryPaths);
    }
    [Theory]
    [InlineData(InterfaceLanguage.English)]
    [InlineData(InterfaceLanguage.Russian)]
    public void Disabled_card_has_only_toggle_and_retains_inline_disclosures(InterfaceLanguage language) => ApplicationWindowTests.OnSta(() =>
    {
        using var locale=Localized.Use(language);
        var state=new McpUiState(false,54321,true,"disabled",null);
        var view=new McpSettingsView(()=>state,enabled=>state=state with { Enabled=enabled },port=>state=state with { Port=port },()=>"synthetic-unused",()=>Task.CompletedTask,@"C:\Private Apps\Verbemo.exe");
        Assert.Single(Descendants(view.View).OfType<CheckBox>());
        Assert.Empty(Descendants(view.View).OfType<TextBox>()); Assert.Empty(Descendants(view.View).OfType<Expander>()); Assert.Empty(Descendants(view.View).OfType<Button>());
        state=state with { Enabled=true, Status="unavailable" }; view.Refresh();
        var sections=Descendants(view.View).OfType<Expander>().ToArray(); Assert.Equal(3,sections.Length); Assert.False(sections[0].IsExpanded); Assert.True(sections[1].IsExpanded); Assert.False(sections[2].IsExpanded);
        Assert.Contains(Descendants(view.View).OfType<TextBox>(),box=>box.Text=="http://127.0.0.1:54321/mcp");
        sections[2].IsExpanded=true; state=state with { Enabled=false }; view.Refresh(); Assert.Empty(Descendants(view.View).OfType<Expander>());
        state=state with { Enabled=true }; view.Refresh(); Assert.True(Descendants(view.View).OfType<Expander>().Last().IsExpanded);
        view.View.Measure(new Size(360,double.PositiveInfinity)); view.View.Arrange(new Rect(0,0,360,view.View.DesiredSize.Height)); Assert.True(view.View.DesiredSize.Width<=360);
    });
    [Theory]
    [InlineData(InterfaceLanguage.English)]
    [InlineData(InterfaceLanguage.Russian)]
    public void Failed_enable_uses_existing_error_surface_and_keeps_off_card_empty(InterfaceLanguage language) => ApplicationWindowTests.OnSta(() =>
    {
        using var locale=Localized.Use(language); string? displayed=null;
        var state=new McpUiState(false,54321,true,"disabled",null);
        var view=new McpSettingsView(()=>state,_=>throw new InvalidOperationException("private-marker"),_=>{},()=>null,()=>Task.CompletedTask,@"C:\Verbemo.exe",message=>displayed=message);
        var toggle=Assert.Single(Descendants(view.View).OfType<CheckBox>()); toggle.IsChecked=true; toggle.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        Assert.False(toggle.IsChecked); Assert.NotNull(displayed); Assert.DoesNotContain("private-marker",displayed);
        Assert.Contains(language==InterfaceLanguage.Russian ? "Не удалось" : "could not",displayed);
        view.Refresh(); Assert.Empty(Descendants(view.View).OfType<TextBox>()); Assert.Empty(Descendants(view.View).OfType<Button>()); Assert.Empty(Descendants(view.View).OfType<Expander>());
    });

    [Theory]
    [InlineData(InterfaceLanguage.English,"copy")]
    [InlineData(InterfaceLanguage.Russian,"copy")]
    [InlineData(InterfaceLanguage.English,"rotate")]
    [InlineData(InterfaceLanguage.Russian,"rotate")]
    [InlineData(InterfaceLanguage.English,"port")]
    [InlineData(InterfaceLanguage.Russian,"port")]
    [InlineData(InterfaceLanguage.English,"keyboard")]
    [InlineData(InterfaceLanguage.Russian,"context")]
    public void Failed_operations_remain_visible_after_content_refresh(InterfaceLanguage language,string operation) => ApplicationWindowTests.OnSta(() =>
    {
        using var locale=Localized.Use(language); var previous=Clipboard.GetDataObject();
        try
        {
            Clipboard.SetText("synthetic-sentinel");
            var state=new McpUiState(true,54321,true,"running","http://127.0.0.1:54321/mcp");
            var view=new McpSettingsView(()=>state,_=>{},_=>throw new InvalidOperationException("private-marker"),()=>throw new InvalidOperationException("private-marker"),()=>Task.FromException(new InvalidOperationException("private-marker")),@"C:\Verbemo.exe");
            foreach(var section in Descendants(view.View).OfType<Expander>()) section.IsExpanded=true;
            if(operation is "keyboard" or "context")
            {
                var field=Assert.Single(Descendants(view.View).OfType<McpTokenField>()); field.Select(1,1);
                if(operation=="keyboard") ApplicationCommands.Copy.Execute(null,field);
                else { var menu=Assert.IsType<MenuItem>(field.ContextMenu.Items[0]); Assert.IsAssignableFrom<RoutedCommand>(menu.Command).Execute(menu.CommandParameter,menu.CommandTarget); }
            }
            else
            {
                var label=(operation,language) switch { ("copy",InterfaceLanguage.English)=>"Copy token",("copy",_)=>"Копировать токен",("rotate",InterfaceLanguage.English)=>"Rotate token",("rotate",_)=>"Заменить токен",(_,InterfaceLanguage.English)=>"Apply port",_=>"Применить порт" };
                Assert.Single(Descendants(view.View).OfType<Button>(),button=>Equals(button.Content,label)).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            }
            foreach(var section in Descendants(view.View).OfType<Expander>()) section.IsExpanded=false;
            Assert.Single(Descendants(view.View).OfType<ComboBox>()).SelectedIndex=1;
            view.Refresh();
            var expected=(operation,language) switch { ("rotate",InterfaceLanguage.English)=>"Token rotation failed",("rotate",_)=>"Не удалось заменить токен",("port",InterfaceLanguage.English)=>"The port could not be saved",("port",_)=>"Не удалось сохранить порт",(_,InterfaceLanguage.English)=>"The protected token could not be read",_=>"Не удалось прочитать защищённый токен" };
            var error=Assert.Single(Descendants(view.View).OfType<TextBlock>(),text=>text.Visibility==Visibility.Visible && text.Text.Contains(expected,StringComparison.Ordinal));
            for(var parent=LogicalTreeHelper.GetParent(error); parent is not null; parent=LogicalTreeHelper.GetParent(parent))
                if(parent is Expander section) Assert.True(section.IsExpanded,"Operation errors must not be hidden in a collapsed section.");
            Assert.DoesNotContain(Descendants(view.View).OfType<TextBlock>(),text=>text.Text.Contains("private-marker",StringComparison.Ordinal));
            Assert.True(Clipboard.GetText()=="synthetic-sentinel","A failed token copy must preserve the prior synthetic clipboard without printing it.");
        }
        finally { if(previous is null) Clipboard.Clear(); else Clipboard.SetDataObject(previous); }
    });

    [Fact]
    public void Masked_token_button_keyboard_and_context_copy_resolve_fresh_secret_without_exposure() => ApplicationWindowTests.OnSta(() =>
    {
        var previous=Clipboard.GetDataObject(); var token=Guid.NewGuid().ToString("N")+Guid.NewGuid().ToString("N");
        try
        {
            var field=new McpTokenField(()=>token); Assert.Equal("***",field.Text);
            field.CopyCurrent(); Assert.True(Clipboard.GetText()==token,"Copy button must resolve the current synthetic token.");
            token=Guid.NewGuid().ToString("N")+Guid.NewGuid().ToString("N"); field.Select(1,1); ApplicationCommands.Copy.Execute(null,field);
            Assert.True(Clipboard.GetText()==token,"Keyboard Copy must resolve the rotated synthetic token.");
            token=Guid.NewGuid().ToString("N")+Guid.NewGuid().ToString("N"); var menu=Assert.IsType<MenuItem>(field.ContextMenu.Items[0]); Assert.IsAssignableFrom<RoutedCommand>(menu.Command).Execute(menu.CommandParameter,menu.CommandTarget);
            Assert.True(Clipboard.GetText()==token,"Context Copy must use the same current-token policy.");
            Assert.Equal("***",field.Text); var peer=FrameworkElementAutomationPeer.CreatePeerForElement(field); Assert.DoesNotContain(token,peer?.GetName() ?? "");
            field.Select(0,0); Clipboard.SetText("sentinel"); ApplicationCommands.Copy.Execute(null,field); Assert.Equal("sentinel",Clipboard.GetText());
        }
        finally { if(previous is null) Clipboard.Clear(); else Clipboard.SetDataObject(previous); }
    });
}
[CollectionDefinition("McpClipboard",DisableParallelization=true)]
public sealed class McpClipboardCollection;
