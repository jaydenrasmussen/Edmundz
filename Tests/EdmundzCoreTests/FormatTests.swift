import Testing
@testable import EdmundzCore

func run(_ md: String, _ sel: NSRange, _ f: (NSString, NSRange, DocumentModel) -> EditResult?) -> (String, NSRange)? {
    let ns = md as NSString
    let model = DocumentModel(text: ns)
    guard let r = f(ns, sel, model) else { return nil }
    return (r.applied(to: md), r.selection)
}

func sel(_ md: String, _ sub: String, in whole: String? = nil) -> NSRange {
    (md as NSString).range(of: sub)
}

@Suite struct InlineToggles {
    @Test func wrapSelection() {
        let md = "hello world"
        let r = run(md, sel(md, "world")) { FormatCommands.toggleInline(.bold, text: $0, selection: $1, model: $2) }!
        #expect(r.0 == "hello **world**")
        #expect((r.0 as NSString).substring(with: r.1) == "world")
    }

    @Test func unwrapSelection() {
        let md = "hello **world**"
        let r = run(md, sel(md, "world")) { FormatCommands.toggleInline(.bold, text: $0, selection: $1, model: $2) }!
        #expect(r.0 == "hello world")
        #expect((r.0 as NSString).substring(with: r.1) == "world")
    }

    @Test func unwrapFromCaretInside() {
        let md = "hello **world**"
        let r = run(md, NSRange(location: 11, length: 0)) { FormatCommands.toggleInline(.bold, text: $0, selection: $1, model: $2) }!
        #expect(r.0 == "hello world")
    }

    @Test func caretOnWordWrapsWord() {
        let md = "hello world"
        let r = run(md, NSRange(location: 8, length: 0)) { FormatCommands.toggleInline(.italic, text: $0, selection: $1, model: $2) }!
        #expect(r.0 == "hello *world*")
    }

    @Test func caretOnNothingInsertsPairAndPlacesCaretBetween() {
        let md = "hello "
        let r = run(md, NSRange(location: 6, length: 0)) { FormatCommands.toggleInline(.bold, text: $0, selection: $1, model: $2) }!
        #expect(r.0 == "hello ****")
        #expect(r.1 == NSRange(location: 8, length: 0))
    }

    @Test func underlineUsesInsTags() {
        let md = "make this loud"
        let r = run(md, sel(md, "this")) { FormatCommands.toggleInline(.underline, text: $0, selection: $1, model: $2) }!
        #expect(r.0 == "make <ins>this</ins> loud")
        let back = run(r.0, sel(r.0, "this")) { FormatCommands.toggleInline(.underline, text: $0, selection: $1, model: $2) }!
        #expect(back.0 == md)
    }

    @Test func underlineUnwrapsUTag() {
        let md = "a <u>b</u> c"
        let r = run(md, sel(md, "b")) { FormatCommands.toggleInline(.underline, text: $0, selection: $1, model: $2) }!
        #expect(r.0 == "a b c")
    }

    @Test func boldUnwrapsUnderscoreBold() {
        let md = "a __b__ c"
        let r = run(md, sel(md, "b")) { FormatCommands.toggleInline(.bold, text: $0, selection: $1, model: $2) }!
        #expect(r.0 == "a b c")
    }

    @Test func boldDoesNotUnwrapUnderline() {
        let md = "a <ins>b</ins> c"
        let r = run(md, sel(md, "b")) { FormatCommands.toggleInline(.bold, text: $0, selection: $1, model: $2) }!
        #expect(r.0 == "a <ins>**b**</ins> c")
    }

    @Test func nestedBoldInsideItalicUnwrapsOnlyBold() {
        let md = "*a **b** c*"
        let r = run(md, sel(md, "b")) { FormatCommands.toggleInline(.bold, text: $0, selection: $1, model: $2) }!
        #expect(r.0 == "*a b c*")
    }

    @Test func multiLineSelectionWrapsEachLine() {
        let md = "one\ntwo"
        let r = run(md, NSRange(location: 0, length: 7)) { FormatCommands.toggleInline(.bold, text: $0, selection: $1, model: $2) }!
        #expect(r.0 == "**one**\n**two**")
    }

    @Test func listSelectionKeepsMarkers() {
        let md = "- one\n- two"
        let r = run(md, NSRange(location: 0, length: 11)) { FormatCommands.toggleInline(.bold, text: $0, selection: $1, model: $2) }!
        #expect(r.0 == "- **one**\n- **two**")
    }

    @Test func trimsWhitespaceFromSelection() {
        let md = "a  word  b"
        let r = run(md, NSRange(location: 1, length: 8)) { FormatCommands.toggleInline(.bold, text: $0, selection: $1, model: $2) }!
        #expect(r.0 == "a  **word**  b")
    }

    @Test func noFormattingInsideCodeFence() {
        let md = "```\ncode\n```\n"
        let r = run(md, sel(md, "code")) { FormatCommands.toggleInline(.bold, text: $0, selection: $1, model: $2) }
        #expect(r == nil)
    }

    @Test func inlineCodeAndStrike() {
        let md = "x y z"
        #expect(run(md, sel(md, "y")) { FormatCommands.toggleInline(.code, text: $0, selection: $1, model: $2) }!.0 == "x `y` z")
        #expect(run(md, sel(md, "y")) { FormatCommands.toggleInline(.strike, text: $0, selection: $1, model: $2) }!.0 == "x ~~y~~ z")
    }

    @Test func unicodeSelection() {
        let md = "héllo 😀 wörld"
        let r = run(md, sel(md, "wörld")) { FormatCommands.toggleInline(.bold, text: $0, selection: $1, model: $2) }!
        #expect(r.0 == "héllo 😀 **wörld**")
    }

    @Test func crlfLines() {
        let md = "one\r\ntwo"
        let r = run(md, NSRange(location: 0, length: 8)) { FormatCommands.toggleInline(.bold, text: $0, selection: $1, model: $2) }!
        #expect(r.0 == "**one**\r\n**two**")
    }
}

@Suite struct Headings {
    func h(_ md: String, _ level: Int, _ s: NSRange) -> (String, NSRange) {
        run(md, s) { FormatCommands.setHeading(level, text: $0, selection: $1, model: $2) }!
    }

    @Test func setLevel() {
        #expect(h("title", 2, NSRange(location: 2, length: 0)).0 == "## title")
        #expect(h("title", 1, NSRange(location: 0, length: 0)).0 == "# title")
        #expect(h("title", 5, NSRange(location: 0, length: 0)).0 == "##### title")
    }

    @Test func sameLevelTogglesOff() {
        #expect(h("## title", 2, NSRange(location: 4, length: 0)).0 == "title")
    }

    @Test func changeLevel() {
        #expect(h("# title", 2, NSRange(location: 3, length: 0)).0 == "## title")
        #expect(h("### t", 1, NSRange(location: 5, length: 0)).0 == "# t")
    }

    @Test func paragraphRemovesHeading() {
        #expect(h("### title", 0, NSRange(location: 6, length: 0)).0 == "title")
    }

    @Test func multipleLines() {
        #expect(h("a\nb\nc", 2, NSRange(location: 0, length: 5)).0 == "## a\n## b\n## c")
    }

    @Test func caretStaysOnText() {
        let r = h("title", 2, NSRange(location: 2, length: 0))
        #expect(r.1 == NSRange(location: 5, length: 0))
    }

    @Test func skipsBlankAndCode() {
        #expect(h("a\n\nb", 1, NSRange(location: 0, length: 4)).0 == "# a\n\n# b")
        let fenced = "```\nx\n```\n"
        #expect(run(fenced, NSRange(location: 5, length: 0)) { FormatCommands.setHeading(1, text: $0, selection: $1, model: $2) }!.0 == fenced)
    }

    @Test func setextBecomesAtx() {
        #expect(h("Title\n=====\n", 2, NSRange(location: 1, length: 0)).0 == "## Title\n")
    }
}

@Suite struct Lists {
    @Test func bulletOnPlainLines() {
        let r = run("a\nb", NSRange(location: 0, length: 3)) { FormatCommands.toggleList(.bullet, text: $0, selection: $1, model: $2) }!
        #expect(r.0 == "- a\n- b")
    }

    @Test func bulletToggleOff() {
        let r = run("- a\n- b", NSRange(location: 0, length: 7)) { FormatCommands.toggleList(.bullet, text: $0, selection: $1, model: $2) }!
        #expect(r.0 == "a\nb")
    }

    @Test func orderedNumbers() {
        let r = run("a\nb\nc", NSRange(location: 0, length: 5)) { FormatCommands.toggleList(.ordered, text: $0, selection: $1, model: $2) }!
        #expect(r.0 == "1. a\n2. b\n3. c")
    }

    @Test func convertBulletToTask() {
        let r = run("- a\n- b", NSRange(location: 0, length: 7)) { FormatCommands.toggleList(.task, text: $0, selection: $1, model: $2) }!
        #expect(r.0 == "- [ ] a\n- [ ] b")
    }

    @Test func convertBulletToOrdered() {
        let r = run("- a\n- b", NSRange(location: 0, length: 7)) { FormatCommands.toggleList(.ordered, text: $0, selection: $1, model: $2) }!
        #expect(r.0 == "1. a\n2. b")
    }

    @Test func indentAndOutdent() {
        let md = "- a\n- b"
        let i = run(md, NSRange(location: 6, length: 0)) { FormatCommands.indent(outdent: false, text: $0, selection: $1, model: $2) }!
        #expect(i.0 == "- a\n  - b")
        let o = run(i.0, NSRange(location: 8, length: 0)) { FormatCommands.indent(outdent: true, text: $0, selection: $1, model: $2) }!
        #expect(o.0 == md)
    }

    @Test func indentIgnoresPlainText() {
        #expect(run("plain", NSRange(location: 0, length: 0)) { FormatCommands.indent(outdent: false, text: $0, selection: $1, model: $2) } == nil)
    }
}

@Suite struct ReturnKey {
    func ret(_ md: String, _ at: Int) -> (String, NSRange)? {
        run(md, NSRange(location: at, length: 0)) { FormatCommands.newline(text: $0, selection: $1, model: $2) }
    }

    @Test func continuesBullet() {
        let r = ret("- one", 5)!
        #expect(r.0 == "- one\n- ")
        #expect(r.1 == NSRange(location: 8, length: 0))
    }

    @Test func continuesNumberAndIncrements() {
        #expect(ret("1. one", 6)!.0 == "1. one\n2. ")
        #expect(ret("9. one", 6)!.0 == "9. one\n10. ")
    }

    @Test func continuesTaskUnchecked() {
        #expect(ret("- [x] done", 10)!.0 == "- [x] done\n- [ ] ")
    }

    @Test func emptyItemExitsList() {
        let r = ret("- one\n- ", 8)!
        #expect(r.0 == "- one\n")
    }

    @Test func keepsIndentOfNestedItem() {
        #expect(ret("- a\n  - b", 9)!.0 == "- a\n  - b\n  - ")
    }

    @Test func splitsItemAtCaret() {
        #expect(ret("- onetwo", 5)!.0 == "- one\n- two")
    }

    @Test func plainParagraphUsesDefault() {
        #expect(ret("just text", 9) == nil)
    }

    @Test func continuesQuote() {
        #expect(ret("> quoted", 8)!.0 == "> quoted\n> ")
    }
}

@Suite struct Links {
    @Test func wrapsSelection() {
        let r = run("see site now", NSRange(location: 4, length: 4)) { FormatCommands.link(text: $0, selection: $1, model: $2) }!
        #expect(r.0 == "see [site]() now")
        #expect(r.1 == NSRange(location: 11, length: 0))
    }

    @Test func selectsExistingDestination() {
        let md = "a [b](http://x.y) c"
        let r = run(md, NSRange(location: 4, length: 0)) { FormatCommands.link(text: $0, selection: $1, model: $2) }!
        #expect((md as NSString).substring(with: r.1) == "http://x.y")
    }
}

@Suite struct TableNavigation {
    let md = "| a | b |\n|---|---|\n| 1 | 2 |\n"

    func tab(_ at: Int, backward: Bool = false) -> (String, NSRange)? {
        run(md, NSRange(location: at, length: 0)) { FormatCommands.nextCell(text: $0, selection: $1, backward: backward, model: $2) }
    }

    @Test func movesToNextCellAndSelectsIt() {
        let r = tab(2)!
        #expect((md as NSString).substring(with: r.1) == "b")
    }

    @Test func skipsDelimiterRowToNextRow() {
        let r = tab(6)!   // in "b" of the header
        #expect((md as NSString).substring(with: r.1) == "1")
    }

    @Test func shiftTabGoesBack() {
        let one = (md as NSString).range(of: "1").location
        let r = tab(one, backward: true)!
        #expect((md as NSString).substring(with: r.1) == "b")
    }

    @Test func tabInLastCellAddsRow() {
        let two = (md as NSString).range(of: "2").location
        let r = tab(two)!
        #expect(r.0 == "| a | b |\n|---|---|\n| 1 | 2 |\n|   |   |\n" || r.0.hasPrefix("| a | b |\n|---|---|\n| 1 | 2 |\n|"))
        #expect(r.0.contains("| 2 |\n|"))
    }

    @Test func notInTableReturnsNil() {
        #expect(run("plain text", NSRange(location: 2, length: 0)) { FormatCommands.nextCell(text: $0, selection: $1, backward: false, model: $2) } == nil)
    }
}

@Suite struct AssetImport {
    @Test func uniqueNames() {
        var taken: Set<String> = ["image.png", "image-2.png"]
        #expect(AssetNaming.uniqueName(base: "image", ext: "png", exists: { taken.contains($0) }) == "image-3.png")
        taken = []
        #expect(AssetNaming.uniqueName(base: "", ext: "png", exists: { taken.contains($0) }) == "image.png")
        #expect(AssetNaming.uniqueName(base: "a/b", ext: "jpg", exists: { taken.contains($0) }) == "a-b.jpg")
    }

    @Test func markdownLinkEncodesSpaces() {
        #expect(AssetNaming.markdownImage(alt: "My pic", folder: "assets", name: "my pic.png") == "![My pic](assets/my%20pic.png)")
        #expect(AssetNaming.markdownImage(alt: "x[1]", folder: "", name: "a.png") == "![x(1)](a.png)")
    }
}
