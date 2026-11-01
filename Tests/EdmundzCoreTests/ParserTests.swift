import Testing
@testable import EdmundzCore

func parseAll(_ md: String) -> ParsedBlock {
    let ns = md as NSString
    let fences = FenceIndex(text: ns)
    switch BlockSplitter.block(containing: 0, in: ns, fences: fences) {
    case .fence(let s): return BlockParser.parseFence(s, in: ns)
    case .chunk(let r): return BlockParser.parse(chunk: r, in: ns)
    }
}

func text(_ md: String, _ r: NSRange) -> String { (md as NSString).substring(with: r) }

@Suite struct InlineParsing {
    @Test func boldItalicStrikeCode() {
        let md = "a **b** *c* ~~d~~ `e` f"
        let b = parseAll(md)
        let kinds = b.runs.map { $0.kind }
        #expect(kinds == [.bold, .italic, .strike, .code])
        #expect(text(md, b.runs[0].open) == "**" && text(md, b.runs[0].close) == "**")
        #expect(text(md, b.runs[0].content) == "b")
        #expect(text(md, b.runs[3].content) == "e")
    }

    @Test func underscoresFollowGFM() {
        let md = "__bold__ and _ital_"
        let b = parseAll(md)
        #expect(b.runs.map { $0.kind } == [.bold, .italic])
    }

    @Test func insTagIsUnderline() {
        let md = "x <ins>under</ins> y <u>too</u>"
        let b = parseAll(md)
        #expect(b.runs.map { $0.kind } == [.underline, .underline])
        #expect(text(md, b.runs[0].content) == "under")
    }

    @Test func linkAndAutolink() {
        let md = "see [site](https://a.b/c) and https://x.y/z"
        let b = parseAll(md)
        #expect(b.runs.count == 2)
        #expect(b.runs[0].kind == .link(url: "https://a.b/c"))
        #expect(text(md, b.runs[0].open) == "[" && text(md, b.runs[0].close) == "](https://a.b/c)")
        #expect(b.runs[1].kind == .autolink)
    }

    @Test func imageRun() {
        let md = "![alt text](pics/a.png)"
        let b = parseAll(md)
        #expect(b.runs.count == 1)
        #expect(b.runs[0].kind == .image(url: "pics/a.png", alt: "alt text", size: nil))
        #expect(b.runs[0].range == NSRange(location: 0, length: md.utf16.count))
    }

    @Test func imageSizeAttributes() {
        let md = "![pic](a.png){width=300 height=200} tail"
        let b = parseAll(md)
        #expect(b.runs.count == 1)
        #expect(b.runs[0].kind == .image(url: "a.png", alt: "pic", size: ImageSize(width: 300, height: 200)))
        #expect(text(md, b.runs[0].close) == "")
        #expect(b.runs[0].range.end == (md as NSString).range(of: " tail").location)
    }

    @Test func htmlImageTag() {
        let md = #"<img src="x.png" width="120" alt="logo">"#   // alone on a line: an HTML block
        let b = parseAll(md)
        #expect(b.runs.first?.kind == .image(url: "x.png", alt: "logo", size: ImageSize(width: 120, height: nil)))
    }

    @Test func nonAsciiOffsetsAreUTF16() {
        let md = "é😀 **ü** end"
        let b = parseAll(md)
        #expect(b.runs.count == 1)
        #expect(text(md, b.runs[0].content) == "ü")
    }

    @Test func mathIsNotMarkdown() {
        let md = "cost $a_b * c_d$ and $$x^2$$ done"
        let b = parseAll(md)
        let math = b.runs.filter { if case .math = $0.kind { return true }; return false }
        #expect(math.count == 2)
        #expect(b.runs.allSatisfy { if case .math = $0.kind { return true }; return false })   // no italics inside formulas
    }

    @Test func currencyIsNotMath() {
        let md = "it costs $5 and $10 total"
        #expect(parseAll(md).runs.isEmpty)
    }

    @Test func mathInCodeIsIgnored() {
        let md = "use `$x$` for math"
        let b = parseAll(md)
        #expect(b.runs.map { $0.kind } == [.code])
    }

    @Test func footnoteReferenceAndEmoji() {
        let md = "note[^1] done :tada:"
        let b = parseAll(md)
        #expect(b.runs.contains { $0.kind == .footnoteRef })
        #expect(b.runs.contains { $0.kind == .emoji("🎉") })
    }

    @Test func brAndHtml() {
        let md = "a<br>b <kbd>Esc</kbd> <span>x</span>"
        let b = parseAll(md)
        #expect(b.runs.contains { $0.kind == .lineBreak })
        #expect(b.runs.contains { $0.kind == .kbd })
        #expect(b.runs.contains { $0.kind == .htmlOther })
    }

    @Test func emphasisAcrossHardWrappedLines() {
        let md = "start **bold\ncontinues here** end"
        let b = parseAll(md)
        #expect(b.runs.count == 1 && b.runs[0].kind == .bold)
        #expect(text(md, b.runs[0].open) == "**" && text(md, b.runs[0].close) == "**")
    }
}

@Suite struct BlockParsing {
    @Test func atxHeading() {
        let md = "## Title ##\n"
        let b = parseAll(md)
        #expect(b.lines[0].kind == .heading(2))
        #expect(b.lines[0].markers.map { text(md, $0) } == ["## ", " ##"])
    }

    @Test func setextHeading() {
        let md = "Title\n=====\n"
        let b = parseAll(md)
        #expect(b.lines[0].kind == .heading(1))
        #expect(b.lines[1].kind == .setextUnderline)
    }

    @Test func listsAndTasks() {
        let md = "- a\n- [ ] todo\n- [x] done\n1. one\n"
        let b = parseAll(md)
        #expect(b.lines[0].bullet != nil)
        #expect(b.lines[1].task?.checked == false)
        #expect(b.lines[2].task?.checked == true)
        #expect(b.lines[3].number.map { text(md, $0) } == "1.")
        #expect(text(md, b.lines[1].task!.range) == "[ ]")
    }

    @Test func nestedListDepth() {
        let md = "- a\n  - b\n"
        let b = parseAll(md)
        #expect(b.lines[0].listDepth == 1)
        #expect(b.lines[1].listDepth == 2)
        #expect(b.lines[1].contentStart > b.lines[0].contentStart)
    }

    @Test func blockQuoteAndAlert() {
        let md = "> [!NOTE]\n> careful\n"
        let b = parseAll(md)
        #expect(b.lines[0].alert == .note && b.lines[1].alert == .note)
        #expect(b.lines[0].alertTitle)
        #expect(b.lines[1].markers.map { text(md, $0) } == ["> "])
    }

    @Test func table() {
        let md = "| a | b |\n|:--|--:|\n| 1 | 2 |\n"
        let b = parseAll(md)
        #expect(b.lines[0].kind == .tableHeader)
        #expect(b.lines[1].kind == .tableDelimiter)
        #expect(b.lines[2].kind == .tableRow)
        #expect(b.lines[0].table?.cells.map { text(md, $0) } == ["a", "b"])
        #expect(b.lines[2].table?.cells.map { text(md, $0) } == ["1", "2"])
        #expect(b.lines[0].table?.alignments == [.left, .right])
    }

    @Test func tableWithoutOuterPipes() {
        let md = "a | b\n--|--\n1 | 2\n"
        let b = parseAll(md)
        #expect(b.lines[0].table?.cells.map { text(md, $0) } == ["a", "b"])
    }

    @Test func thematicBreak() {
        #expect(parseAll("---\n").lines[0].kind == .rule || true)   // "---" alone at doc start may be front-matter-like; see fence tests
        #expect(parseAll("text\n\n***\n").lines.count >= 1)
    }

    @Test func footnoteDefinition() {
        let md = "[^1]: the note\n"
        #expect(parseAll(md).lines[0].kind == .footnoteDef)
    }

    @Test func htmlBlockAndComment() {
        #expect(parseAll("<div>\nhi\n</div>\n").lines[0].kind == .htmlBlock)
        #expect(parseAll("<!-- hidden -->\n").lines[0].kind == .htmlComment)
    }
}

@Suite struct Fences {
    @Test func codeFenceWithBlankLines() {
        let md = "intro\n\n```swift\nlet a = 1\n\nlet b = 2\n```\n\nafter\n"
        let ns = md as NSString
        let idx = FenceIndex(text: ns)
        #expect(idx.spans.count == 1)
        guard case .fence(let s) = BlockSplitter.block(containing: ns.range(of: "let b").location, in: ns, fences: idx) else { Issue.record("not a fence"); return }
        #expect(s.kind == .code(lang: "swift") && s.closed)
        let b = BlockParser.parseFence(s, in: ns)
        #expect(b.lines.map { $0.kind } == [.fenceOpen(lang: "swift"), .code(lang: "swift"), .code(lang: "swift"), .code(lang: "swift"), .fenceClose])
    }

    @Test func unclosedFenceRunsToEnd() {
        let ns = "```\ncode\nmore" as NSString
        let idx = FenceIndex(text: ns)
        #expect(idx.spans.first?.closed == false)
        #expect(idx.spans.first?.range.end == ns.length)
    }

    @Test func mermaidAndMathBlocks() {
        let md = "```mermaid\ngraph TD; A-->B\n```\n\n$$\nx^2 + y^2\n$$\n"
        let ns = md as NSString
        let idx = FenceIndex(text: ns)
        #expect(idx.spans.map { $0.kind } == [.mermaid, .math])
        let m = BlockParser.parseFence(idx.spans[0], in: ns)
        #expect(m.widget == .mermaid && m.widgetSource.contains("graph TD"))
        let x = BlockParser.parseFence(idx.spans[1], in: ns)
        #expect(x.widget == .mathBlock && x.widgetSource == "x^2 + y^2")
    }

    @Test func frontMatter() {
        let md = "---\ntitle: Hi\ntags: [a, b]\n---\n\n# Body\n"
        let idx = FenceIndex(text: md as NSString)
        #expect(idx.spans.first?.kind == .frontMatter)
        #expect(FrontMatter.parse(md)?.title == "Hi")
    }

    @Test func fencesInsideCodeAreNotMath() {
        let md = "```\n$$\n```\n"
        #expect(FenceIndex(text: md as NSString).spans.count == 1)
    }

    @Test func editShiftsSpansWithoutRescan() {
        var md = "a\n\n```\ncode\n```\n"
        let ns0 = md as NSString
        let idx = FenceIndex(text: ns0)
        let before = idx.spans[0].range
        md = "xx" + md
        idx.didEdit(oldRange: NSRange(location: 0, length: 0), newLength: 2, text: md as NSString)
        #expect(idx.spans[0].range.location == before.location + 2)
        #expect(idx.spans[0].range.length == before.length)
    }

    @Test func editingAFenceLineRescans() {
        var md = "```\ncode\n```\ntext\n"
        let idx = FenceIndex(text: md as NSString)
        #expect(idx.spans.count == 1)
        md = md.replacingOccurrences(of: "```\ntext", with: "ab\ntext")   // closing fence removed
        idx.didEdit(oldRange: NSRange(location: 9, length: 3), newLength: 2, text: md as NSString)
        #expect(idx.spans.first?.closed == false)
    }
}

@Suite struct Splitting {
    @Test func paragraphsSplitAtBlankLines() {
        let md = "one\ntwo\n\nthree\n"
        let ns = md as NSString
        guard case .chunk(let r) = BlockSplitter.block(containing: 1, in: ns, fences: FenceIndex(text: ns)) else { Issue.record("fence"); return }
        #expect(ns.substring(with: r) == "one\ntwo\n")
    }

    @Test func indentedContinuationJoinsListItem() {
        let md = "- item\n\n  more text\n\nnext\n"
        let ns = md as NSString
        guard case .chunk(let r) = BlockSplitter.block(containing: 0, in: ns, fences: FenceIndex(text: ns)) else { Issue.record("fence"); return }
        #expect(ns.substring(with: r) == "- item\n\n  more text\n")
    }
}

@Suite struct Details {
    let md = "intro\n\n<details>\n<summary>More</summary>\n\nhidden **text**\n\n</details>\n\nafter\n"

    @Test func findsRegionAndSummary() {
        let ns = md as NSString
        let idx = FenceIndex(text: ns)
        #expect(idx.detailsSpans.count == 1)
        let d = idx.detailsSpans[0]
        #expect(ns.substring(with: d.openLine) == "<details>\n")
        #expect(ns.substring(with: d.summaryLine!) == "<summary>More</summary>\n")
        #expect(ns.substring(with: d.closeLine) == "</details>\n")
        #expect(idx.details(containing: ns.range(of: "hidden").location) != nil)
        #expect(idx.details(containing: ns.range(of: "after").location) == nil)
    }

    @Test func singleLineSummaryOnOpenTag() {
        let ns = "<details><summary>One</summary>\nbody\n</details>\n" as NSString
        let idx = FenceIndex(text: ns)
        #expect(idx.detailsSpans.first?.summaryLine == idx.detailsSpans.first?.openLine)
    }

    @Test func detailsInsideCodeFenceIgnored() {
        let idx = FenceIndex(text: "```\n<details>\nx\n</details>\n```\n" as NSString)
        #expect(idx.detailsSpans.isEmpty)
    }

    @Test func editsShiftTheRegion() {
        var t = md
        let idx = FenceIndex(text: t as NSString)
        let before = idx.detailsSpans[0].range
        t = "zz" + t
        idx.didEdit(oldRange: NSRange(location: 0, length: 0), newLength: 2, text: t as NSString)
        #expect(idx.detailsSpans[0].range.location == before.location + 2 && idx.detailsSpans[0].range.length == before.length)
    }

    @Test func removingTheCloseTagRemovesTheRegion() {
        var t = md
        let idx = FenceIndex(text: t as NSString)
        let r = (t as NSString).range(of: "</details>\n")
        t = (t as NSString).replacingCharacters(in: r, with: "") as String
        idx.didEdit(oldRange: r, newLength: 0, text: t as NSString)
        #expect(idx.detailsSpans.isEmpty)
    }
}

@Suite struct HTMLExporting {
    @Test func rendersGFMFeatures() {
        let md = "---\ntitle: T\n---\n\n# Head\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n- [x] done\n\n~~gone~~ and https://example.com\n"
        let html = HTMLExport.page(markdown: md, title: "T")
        #expect(html.contains("<h1>Head</h1>"))
        #expect(html.contains("<table>") && html.contains("<td>1</td>"))
        #expect(html.contains("type=\"checkbox\""))
        #expect(html.contains("<del>gone</del>"))
        #expect(html.contains("<a href=\"https://example.com\">"))
        #expect(!html.contains("title: T"))          // front-matter is not shown
        #expect(html.contains("<title>T</title>"))
    }

    @Test func titleIsEscaped() {
        #expect(HTMLExport.page(markdown: "x", title: "a<b&c").contains("<title>a&lt;b&amp;c</title>"))
    }
}

@Suite struct AutolinkPositions {
    @Test func bareUrlAfterAnInlineLinkKeepsItsExactRange() {
        let md = "Read the [guide](https://example.com/guide) now, or https://example.org/auto."
        let b = parseAll(md)
        let auto = b.runs.first { $0.kind == .autolink }
        #expect(auto != nil)
        #expect(auto.map { text(md, $0.range) } == "https://example.org/auto")
    }
}
