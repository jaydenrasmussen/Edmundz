import Foundation
import cmark_gfm
import cmark_gfm_extensions

func now() -> Double {
    var t = mach_timebase_info_data_t(); mach_timebase_info(&t)
    return Double(mach_absolute_time()) * Double(t.numer) / Double(t.denom) / 1e6
}

cmark_gfm_core_extensions_ensure_registered()

func parse(_ s: String) -> UnsafeMutablePointer<cmark_node>? {
    let opts = CMARK_OPT_SOURCEPOS | CMARK_OPT_FOOTNOTES | CMARK_OPT_UNSAFE
    guard let p = cmark_parser_new(opts) else { return nil }
    defer { cmark_parser_free(p) }
    for name in ["table", "strikethrough", "tasklist", "autolink"] {
        if let e = cmark_find_syntax_extension(name) { cmark_parser_attach_syntax_extension(p, e) }
    }
    s.withCString { cmark_parser_feed(p, $0, strlen($0)) }
    return cmark_parser_finish(p)
}

func fixture(bytes: Int) -> String {
    var out = ""; var i = 0
    while out.utf8.count < bytes {
        if i % 12 == 0 { out += "## Section \(i / 12)\n\n" }
        out += "Paragraph \(i): lorem ipsum **bold text** and *italic text* with `inline code` and a [link](https://example.com) "
        out += "to make this line long enough to wrap, plus another **strong run** and *emphasis run* near the end.\n\n"
        if i % 20 == 0 { out += "| a | b |\n|---|---|\n| 1 | 2 |\n\n- [ ] task\n- [x] done\n\n" }
        i += 1
    }
    return out
}

func dump(_ md: String) {
    guard let root = parse(md) else { return }
    defer { cmark_node_free(root) }
    let iter = cmark_iter_new(root)!
    defer { cmark_iter_free(iter) }
    while true {
        let ev = cmark_iter_next(iter)
        if ev == CMARK_EVENT_DONE { break }
        guard ev == CMARK_EVENT_ENTER, let n = cmark_iter_get_node(iter) else { continue }
        let type = String(cString: cmark_node_get_type_string(n))
        let lit = cmark_node_get_literal(n).map { String(cString: $0) } ?? ""
        var extra = ""
        if type == "tasklist" { extra = " checked=\(cmark_gfm_extensions_get_tasklist_item_checked(n))" }
        if type == "table_row" || type == "table_header" { extra = " isHeader=\(cmark_gfm_extensions_get_table_row_is_header(n))" }
        if type == "heading" { extra = " level=\(cmark_node_get_heading_level(n))" }
        print("  \(type) \(cmark_node_get_start_line(n)):\(cmark_node_get_start_column(n))-\(cmark_node_get_end_line(n)):\(cmark_node_get_end_column(n))\(extra) \(lit.isEmpty ? "" : "\"\(lit)\"")")
    }
}

if CommandLine.arguments.count > 1 { dump(CommandLine.arguments[1].replacingOccurrences(of: "\\n", with: "\n")); exit(0) }
print("GFM semantics check")
print("__x__ and _x_ and <ins>:")
dump("a __bold?__ b _ital_ c <ins>under</ins> d ~~gone~~")

let doc = fixture(bytes: 1_048_576)
var t = now()
let r = parse(doc)!
print(String(format: "full parse of %d KB: %.1f ms", doc.utf8.count / 1024, now() - t))
cmark_node_free(r)

let block = "Paragraph 7: lorem ipsum **bold text** and *italic text* with `inline code` and a [link](https://example.com) to make this line long enough to wrap, plus another **strong run** and *emphasis run* near the end."
var samples: [Double] = []
for _ in 0..<5000 { let t0 = now(); let n = parse(block)!; cmark_node_free(n); samples.append(now() - t0) }
samples.sort()
print(String(format: "single-paragraph parse: p50 %.4f ms, p99 %.4f ms (n=5000)", samples[2500], samples[4950]))
let bigBlock = String(repeating: "- item with **bold** and `code`\n", count: 2000)
t = now(); let b = parse(bigBlock)!; cmark_node_free(b)
print(String(format: "2000-item list block parse: %.2f ms", now() - t))
let fence = "```swift\n" + String(repeating: "let x = 1 // comment\n", count: 10000) + "```\n"
t = now(); let f = parse(fence)!; cmark_node_free(f)
print(String(format: "10,000-line code fence parse: %.2f ms", now() - t))
