import Foundation
import cmark_gfm
import cmark_gfm_extensions

/// GFM to HTML with the cmark-gfm renderer (tables, task lists, strikethrough, autolinks, footnotes). Math and Mermaid
/// blocks are emitted as source in `<pre>` elements.
public enum HTMLExport {
    public static func body(markdown: String) -> String {
        cmark_gfm_core_extensions_ensure_registered()
        let opts = CMARK_OPT_FOOTNOTES | CMARK_OPT_UNSAFE
        guard let parser = cmark_parser_new(opts) else { return "" }
        defer { cmark_parser_free(parser) }
        var extList: UnsafeMutablePointer<cmark_llist>? = nil
        for name in ["table", "strikethrough", "tasklist", "autolink"] {
            if let e = cmark_find_syntax_extension(name) { cmark_parser_attach_syntax_extension(parser, e); extList = cmark_llist_append(cmark_get_default_mem_allocator(), extList, UnsafeMutableRawPointer(e)) }
        }
        let bytes = Array(strippingFrontMatter(markdown).utf8)
        bytes.withUnsafeBufferPointer { buf in
            buf.baseAddress.map { $0.withMemoryRebound(to: CChar.self, capacity: buf.count) { cmark_parser_feed(parser, $0, buf.count) } }
        }
        guard let doc = cmark_parser_finish(parser) else { return "" }
        defer { cmark_node_free(doc) }
        guard let cstr = cmark_render_html(doc, opts, extList) else { return "" }
        defer { free(cstr) }
        return String(cString: cstr)
    }

    static func strippingFrontMatter(_ md: String) -> String {
        let ns = md as NSString
        let idx = FenceIndex(text: ns)
        if let s = idx.spans.first, s.kind == .frontMatter { return ns.substring(from: s.range.end) }
        return md
    }

    public static func page(markdown: String, title: String) -> String {
        let esc = title.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        return """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <title>\(esc)</title>
        <style>
        body{max-width:46rem;margin:3rem auto;padding:0 1.25rem;font:17px/1.6 -apple-system,system-ui,sans-serif;color:#1c1c1e;background:#fff}
        @media(prefers-color-scheme:dark){body{color:#f2f2f7;background:#1c1c1e}a{color:#64a8ff}pre,code{background:#2c2c2e}th,td{border-color:#48484a}}
        h1,h2,h3{line-height:1.25} pre{padding:.8rem 1rem;border-radius:8px;overflow:auto;background:#f2f2f7} code{font:.88em ui-monospace,SFMono-Regular,Menlo,monospace;background:#f2f2f7;padding:.1em .3em;border-radius:4px} pre code{background:none;padding:0}
        blockquote{margin:1em 0;padding:0 1em;border-left:4px solid #c7c7cc;color:#636366} table{border-collapse:collapse} th,td{border:1px solid #d1d1d6;padding:.35em .7em} img{max-width:100%}
        </style></head><body>
        \(body(markdown: markdown))
        </body></html>
        """
    }
}
