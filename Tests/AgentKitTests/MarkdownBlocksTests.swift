import Testing
@testable import AgentKit

/// Answers drawn as Markdown: each kind of block is recognised, and anything else stays a paragraph.
struct MarkdownBlocksTests {
    typealias B = MarkdownBlocks.Block

    @Test func plainTextIsAParagraph() {
        #expect(MarkdownBlocks.parse("Just one line.") == [.paragraph("Just one line.")])
    }
    @Test func wrappedLinesJoin() {
        #expect(MarkdownBlocks.parse("First line\nsecond line\n\nNew paragraph") ==
                [.paragraph("First line second line"), .paragraph("New paragraph")])
    }
    @Test func headings() {
        #expect(MarkdownBlocks.parse("# Title\n## Part\ntext") ==
                [.heading(level: 1, text: "Title"), .heading(level: 2, text: "Part"), .paragraph("text")])
        #expect(MarkdownBlocks.parse("#hashtag") == [.paragraph("#hashtag")])
    }
    @Test func bullets() {
        let blocks = MarkdownBlocks.parse("Summary:\n- one\n- **two**\n  - nested\n* three")
        #expect(blocks.count == 2)
        guard case .list(let ordered, let items) = blocks[1] else { Issue.record("not a list"); return }
        #expect(!ordered)
        #expect(items.map(\.text) == ["one", "**two**", "nested", "three"])
        #expect(items.map(\.level) == [0, 0, 1, 0])
    }
    @Test func numbered() {
        guard case .list(let ordered, let items) = MarkdownBlocks.parse("1. Open Gmail\n2) Read each\n10. Done").first
        else { Issue.record("not a list"); return }
        #expect(ordered)
        #expect(items.map(\.number) == [1, 2, 10])
    }
    @Test func checklist() {
        guard case .list(_, let items) = MarkdownBlocks.parse("- [x] Booked\n- [ ] Pay").first else { Issue.record("not a list"); return }
        #expect(items.map(\.checked) == [true, false])
        #expect(items.map(\.text) == ["Booked", "Pay"])
    }
    @Test func code() {
        #expect(MarkdownBlocks.parse("Run:\n```bash\nls -la\necho hi\n```\nDone") ==
                [.paragraph("Run:"), .code(language: "bash", text: "ls -la\necho hi"), .paragraph("Done")])
    }
    @Test func unclosedCodeKeepsText() {
        #expect(MarkdownBlocks.parse("```\nlet x = 1") == [.code(language: nil, text: "let x = 1")])
    }
    @Test func table() {
        let md = "| Name | Price |\n|---|---:|\n| Shoe A | ₹2,999 |\n| Shoe B | ₹3,499 |"
        #expect(MarkdownBlocks.parse(md) == [.table(header: ["Name", "Price"], rows: [["Shoe A", "₹2,999"], ["Shoe B", "₹3,499"]])])
    }
    @Test func quoteAndRule() {
        #expect(MarkdownBlocks.parse("> said this\n> and this\n\n---\nafter") ==
                [.quote("said this and this"), .rule, .paragraph("after")])
    }
    @Test func plainForPasting() {
        let md = "## Summary\n\n- **Bank** wants a form by *Friday*\n- See [the link](https://x.y)\n\n| A | B |\n|---|---|\n| 1 | 2 |"
        #expect(MarkdownBlocks.plain(md) == "Summary\n\n• Bank wants a form by Friday\n• See the link\n\nA\tB\n1\t2")
    }
    @Test func inlineKeepsUnderscoresInWords() {
        #expect(MarkdownBlocks.inline("snake_case_name is *really* _fine_, 2 * 3 = 6") == "snake_case_name is really fine, 2 * 3 = 6")
    }
}
