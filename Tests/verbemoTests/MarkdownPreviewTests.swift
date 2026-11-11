import AppKit
import Testing

@testable import verbemo

struct MarkdownPreviewTests {
    @Test("Action items written with em dashes keep their source lines and inline formatting")
    @MainActor
    func actionItemLines() {
        let markdown = "## Задачи\n\n— **Анна**: подготовить план.\n— Борис: [проверить](https://example.com) план."
        let expected = "Задачи\n— Анна: подготовить план.\n— Борис: проверить план."
        let rendered = MarkdownPreview.render(markdown)
        #expect(rendered.string == expected)
        #expect(MarkdownPreview.searchableText(markdown) == expected)
        let bold = (rendered.string as NSString).range(of: "Анна")
        let font = rendered.attribute(.font, at: bold.location, effectiveRange: nil) as? NSFont
        #expect(font.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } == true)
        let link = (rendered.string as NSString).range(of: "проверить")
        #expect(rendered.attribute(.link, at: link.location, effectiveRange: nil) as? URL
                == URL(string: "https://example.com"))
    }

    @Test("Markdown line breaks survive without changing code whitespace", arguments: [
        ("First\nSecond", "First\nSecond"),
        ("First  \nSecond", "First\nSecond"),
        ("First\\\nSecond", "First\nSecond"),
        ("```\none\ntwo\n```", "one\ntwo\n"),
        ("Inline `one\ntwo`", "Inline one two"),
    ])
    @MainActor
    func lineBreaks(markdown: String, expected: String) {
        #expect(MarkdownPreview.render(markdown).string == expected)
        #expect(MarkdownPreview.searchableText(markdown) == expected)
    }

    @Test("List continuation lines keep their hanging indent", arguments: ["\n", "  \n", "\\\n"])
    @MainActor
    func listContinuationIndent(lineBreak: String) throws {
        let rendered = MarkdownPreview.render(
            "- First\(lineBreak)  Second **bold**\n  - Child\(lineBreak)    Continuation\n- Next")
        #expect(rendered.string == "• First\nSecond bold\n• Child\nContinuation\n• Next")
        let paragraphs: [(String, CGFloat, CGFloat)] = [
            ("First", 0, 20), ("Second", 20, 20), ("bold", 20, 20),
            ("Child", 20, 40), ("Continuation", 40, 40), ("Next", 0, 20),
        ]
        for (text, first, rest) in paragraphs {
            let range = (rendered.string as NSString).range(of: text)
            try #require(range.location != NSNotFound)
            let paragraph = try #require(rendered.attribute(.paragraphStyle, at: range.location,
                                                            effectiveRange: nil) as? NSParagraphStyle)
            #expect(paragraph.firstLineHeadIndent == first)
            #expect(paragraph.headIndent == rest)
        }
        let storage = NSTextStorage(attributedString: rendered)
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 400, height: 1000))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        layout.ensureLayout(for: container)
        for (text, expectedX) in [("Second", 20.0), ("Continuation", 40.0)] {
            let range = (rendered.string as NSString).range(of: text)
            let glyph = layout.glyphIndexForCharacter(at: range.location)
            let bounds = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
            #expect(abs(bounds.minX - expectedX) < 0.01)
        }
    }

    @Test("Nested lists use their nearest list's marker and their own depth")
    @MainActor
    func nestedLists() throws {
        let rendered = MarkdownPreview.render("""
            - Stages:
              1. Upload
              2. Generate
                 - Review
                 - Approve
              3. Launch
            - Next
            """)
        #expect(rendered.string == "• Stages:\n1. Upload\n2. Generate\n• Review\n• Approve\n3. Launch\n• Next")
        let lines: [(String, CGFloat, CGFloat)] = [
            ("• Stages:", 0.0, 20.0), ("1. Upload", 20, 40),
            ("2. Generate", 20, 40), ("• Review", 40, 60),
            ("• Approve", 40, 60), ("3. Launch", 20, 40), ("• Next", 0, 20),
        ]
        for (line, first, rest) in lines {
            let range = (rendered.string as NSString).range(of: line)
            try #require(range.location != NSNotFound)
            let paragraph = try #require(rendered.attribute(.paragraphStyle, at: range.location,
                                                            effectiveRange: nil) as? NSParagraphStyle)
            #expect(paragraph.firstLineHeadIndent == first)
            #expect(paragraph.headIndent == rest)
        }
    }

    @Test("Bullets inside an ordered list stay bullets and the outer numbering continues")
    @MainActor
    func bulletsInsideNumbering() {
        let rendered = MarkdownPreview.render("""
            1. First
               - Inner **bold**
               - Another
            2. Second

            ## Heading

            A [link](https://example.com) and `code`.
            """)
        #expect(rendered.string == "1. First\n• Inner bold\n• Another\n2. Second\nHeading\nA link and code.")
        let bold = (rendered.string as NSString).range(of: "bold")
        let font = rendered.attribute(.font, at: bold.location, effectiveRange: nil) as? NSFont
        #expect(font.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } == true)
        let link = (rendered.string as NSString).range(of: "link")
        #expect(rendered.attribute(.link, at: link.location, effectiveRange: nil) as? URL
                == URL(string: "https://example.com"))
    }
}
