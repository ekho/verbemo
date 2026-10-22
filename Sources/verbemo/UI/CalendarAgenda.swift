import AppKit

@MainActor
enum CalendarAgenda {
    static func render(_ source: String) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: 12)
        let plain = NSAttributedString(string: source, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        guard source.range(of: #"(?i)<\s*/?\s*(?:p|div|span|br|ul|ol|li|b|strong|i|em|u|a|html|body|h[1-6]|blockquote|pre|code|table)\b[^>]*>"#,
                           options: .regularExpression) != nil,
              let document = try? XMLDocument(xmlString: source, options: [.documentTidyHTML, .nodeLoadExternalEntitiesNever]),
              let root = document.rootElement(),
              let parsed = try? NSMutableAttributedString(data: Data(safeHTML(root).utf8), options: [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue,
              ], documentAttributes: nil) else { return plain }
        let range = NSRange(location: 0, length: parsed.length)
        parsed.enumerateAttribute(.font, in: range) { value, run, _ in
            let traits = (value as? NSFont).map { NSFontManager.shared.traits(of: $0) } ?? []
            parsed.addAttribute(.font, value: NSFontManager.shared.convert(font, toHaveTrait: traits), range: run)
        }
        parsed.addAttribute(.foregroundColor, value: NSColor.labelColor, range: range)
        let visible = parsed.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !visible.isEmpty else { return NSAttributedString(string: "") }
        return parsed.attributedSubstring(from: (parsed.string as NSString).range(of: visible))
    }

    // Only local text markup reaches AppKit's HTML importer: no CSS, scripts or resource requests.
    private static func safeHTML(_ node: XMLNode) -> String {
        if node.kind == .text { return node.xmlString }
        guard let element = node as? XMLElement else { return "" }
        let name = (element.localName ?? "").lowercased()
        if ["head", "script", "style", "iframe", "object", "embed", "img", "svg", "math"].contains(name) { return "" }
        let content = (element.children ?? []).map(safeHTML).joined()
        guard ["html", "body", "p", "div", "span", "br", "ul", "ol", "li", "b", "strong", "i", "em", "u",
               "s", "strike", "a", "blockquote", "pre", "code", "h1", "h2", "h3", "h4", "h5", "h6",
               "table", "tr", "td", "th"].contains(name) else { return content }
        if name == "br" { return "<br>" }
        var attribute = ""
        if name == "a", let href = element.attribute(forName: "href")?.stringValue,
           let url = URL(string: href), ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") {
            let link = XMLNode(kind: .attribute)
            link.name = "href"; link.stringValue = href
            attribute = " " + link.xmlString
        }
        return "<\(name)\(attribute)>\(content)</\(name)>"
    }
}
