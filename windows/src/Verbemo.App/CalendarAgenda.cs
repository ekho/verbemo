using System.Globalization;
using System.Net;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using HtmlAgilityPack;

namespace Verbemo.App;

internal sealed class CalendarAgenda
{
    private readonly List<(string Text, bool Bold, bool Italic, bool Underline, Uri? Link)> parts = [];
    public string Text { get; }
    public string Preview { get; }

    public CalendarAgenda(string source)
    {
        if (!Regex.IsMatch(source, @"<\s*/?\s*(?:p|div|span|br|ul|ol|li|b|strong|i|em|u|a|html|body|h[1-6]|blockquote|pre|code|table)\b[^>]*>", RegexOptions.IgnoreCase))
            parts.Add((source, false, false, false, null));
        else
        {
            var document = new HtmlDocument();
            document.LoadHtml(source);
            Read(document.DocumentNode);
            while (parts.Count > 0 && string.IsNullOrWhiteSpace(parts[^1].Text)) parts.RemoveAt(parts.Count - 1);
            if (parts.Count > 0) parts[^1] = parts[^1] with { Text = parts[^1].Text.TrimEnd() };
        }
        Text = string.Concat(parts.Select(part => part.Text));
        var characters = StringInfo.ParseCombiningCharacters(Text);
        Preview = Text;
        if (characters.Length > 100)
        {
            var end = characters[100];
            while (end > 0 && !char.IsWhiteSpace(Text[end])) end--;
            Preview = Text[..end].TrimEnd();
        }
    }

    public void Show(TextBlock field, bool expanded)
    {
        field.Inlines.Clear();
        var remaining = expanded ? Text.Length : Preview.Length;
        foreach (var part in parts)
        {
            if (remaining <= 0) break;
            var count = Math.Min(remaining, part.Text.Length);
            var run = new Run(part.Text[..count]);
            if (part.Bold) run.FontWeight = FontWeights.Bold;
            if (part.Italic) run.FontStyle = FontStyles.Italic;
            if (part.Underline) run.TextDecorations = TextDecorations.Underline;
            if (part.Link is { } url)
            {
                var link = new Hyperlink(run) { NavigateUri = url, ToolTip = url.AbsoluteUri };
                link.SetResourceReference(TextElement.ForegroundProperty, "AccentTextFillColorPrimaryBrush");
                link.RequestNavigate += (_, args) => { VerbemoRuntime.Open(args.Uri.AbsoluteUri); args.Handled = true; };
                field.Inlines.Add(link);
            }
            else field.Inlines.Add(run);
            remaining -= count;
        }
        if (!expanded && Preview != Text) field.Inlines.Add(new Run("…"));
    }

    // Parse into native text only; never load HTML resources or execute invitation content.
    private void Read(HtmlNode node)
    {
        if (node.NodeType == HtmlNodeType.Comment || node.Name is "head" or "script" or "style" or "iframe" or "object" or "embed" or "img" or "svg" or "math") return;
        if (node.NodeType == HtmlNodeType.Text)
        {
            var text = WebUtility.HtmlDecode(node.InnerText);
            if (!node.Ancestors("pre").Any()) text = Regex.Replace(text, @"[\t\r\n ]+", " ");
            if (parts.Count == 0 || parts[^1].Text.EndsWith('\n') || parts[^1].Text.EndsWith(' ')) text = text.TrimStart(' ');
            if (text.Length == 0) return;
            var parents = node.Ancestors().ToArray();
            var href = WebUtility.HtmlDecode(parents.FirstOrDefault(parent => parent.Name == "a")?.GetAttributeValue("href", ""));
            var link = Uri.TryCreate(href, UriKind.Absolute, out var url) && url.Scheme is "http" or "https" or "mailto" ? url : null;
            parts.Add((text, parents.Any(parent => parent.Name is "b" or "strong"),
                parents.Any(parent => parent.Name is "i" or "em"), parents.Any(parent => parent.Name == "u"), link));
            return;
        }
        if (node.Name == "br") { parts.Add(("\n", false, false, false, null)); return; }
        var block = node.Name is "p" or "div" or "li" or "ul" or "ol" or "blockquote" or "pre" or "h1" or "h2" or "h3" or "h4" or "h5" or "h6" or "tr";
        if (block) Break();
        if (node.Name == "li")
        {
            var marker = node.ParentNode.Name == "ol"
                ? (node.ParentNode.ChildNodes.TakeWhile(sibling => sibling != node).Count(sibling => sibling.Name == "li") + 1) + ". " : "• ";
            parts.Add((marker, false, false, false, null));
        }
        foreach (var child in node.ChildNodes) Read(child);
        if (block) Break();
    }

    private void Break()
    {
        if (parts.Count > 0 && !parts[^1].Text.EndsWith('\n')) parts.Add(("\n", false, false, false, null));
    }
}
