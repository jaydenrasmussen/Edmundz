import Foundation
import AppKit

public enum TokenKind { case comment, string, number, keyword, type }

/// Lexer state carried from one line to the next inside a fenced block.
public enum LexState: Equatable { case normal, blockComment, tripleDouble, tripleSingle, template }

/// Small, fast, per-line tokenizer for fenced code. It is deliberately simple (no multi-line state):
/// keywords, strings, numbers, comments and capitalized types for the common language families.
public enum CodeHighlighter {
    private static let cLike: Set<String> = ["if", "else", "for", "while", "do", "switch", "case", "default", "break", "continue", "return", "function", "func", "fn", "let", "var", "const", "static", "final", "class", "struct", "enum", "interface", "protocol", "extension", "impl", "trait", "type", "import", "export", "from", "package", "public", "private", "protected", "internal", "async", "await", "try", "catch", "throw", "throws", "new", "this", "self", "super", "null", "nil", "true", "false", "in", "is", "as", "of", "void", "int", "float", "double", "bool", "char", "string", "where", "guard", "defer", "mut", "use", "mod", "pub", "match", "go", "chan", "select", "range", "yield", "lambda", "def", "val", "object", "override", "typealias", "namespace", "using", "template", "typename", "unsigned", "long", "short", "extends", "implements"]
    private static let python: Set<String> = ["def", "class", "if", "elif", "else", "for", "while", "return", "import", "from", "as", "try", "except", "finally", "raise", "with", "lambda", "yield", "pass", "break", "continue", "in", "is", "not", "and", "or", "None", "True", "False", "async", "await", "global", "nonlocal", "assert", "del", "self"]
    private static let shell: Set<String> = ["if", "then", "else", "elif", "fi", "for", "while", "do", "done", "case", "esac", "function", "return", "in", "export", "local", "echo", "cd", "exit", "set", "source", "alias"]
    private static let sql: Set<String> = ["select", "from", "where", "insert", "into", "update", "delete", "create", "table", "drop", "alter", "join", "left", "right", "inner", "outer", "on", "group", "by", "order", "having", "limit", "and", "or", "not", "null", "as", "values", "set", "index", "primary", "key", "distinct", "union", "case", "when", "then", "else", "end"]
    private static let literals: Set<String> = ["true", "false", "null"]

    enum Family { case cLike, python, shell, sql, json, yaml, css, markup, plain }

    static func family(_ lang: String) -> Family {
        switch lang.lowercased() {
        case "js", "javascript", "jsx", "ts", "typescript", "tsx", "swift", "go", "rust", "rs", "java", "kotlin", "kt", "scala", "c", "cpp", "c++", "cc", "h", "hpp", "objc", "objective-c", "cs", "csharp", "dart", "php", "zig", "ruby", "rb", "lua", "perl": return .cLike
        case "py", "python": return .python
        case "sh", "bash", "zsh", "shell", "console", "fish": return .shell
        case "sql", "postgres", "mysql", "sqlite": return .sql
        case "json", "jsonc", "json5": return .json
        case "yaml", "yml", "toml", "ini": return .yaml
        case "css", "scss", "less": return .css
        case "html", "xml", "svg", "xhtml": return .markup
        default: return .plain
        }
    }

    /// Whether the language has constructs that span lines (so a line's meaning depends on the lines before it).
    static func isStateful(_ lang: String) -> Bool { let f = family(lang); return f == .cLike || f == .python || f == .css }

    static func tokens(in line: NSString, lang: String) -> [(NSRange, TokenKind)] { tokens(in: line, lang: lang, state: .normal).0 }

    public static func tokens(in line: NSString, lang: String, state start: LexState) -> ([(NSRange, TokenKind)], LexState) {
        let fam = family(lang)
        if fam == .plain { return ([], .normal) }
        var out: [(NSRange, TokenKind)] = []
        let n = line.length
        var i = 0
        var state = start
        // continue a construct that began on an earlier line
        func scanTo(_ terminator: [unichar], from: Int) -> Int? {   // index just past the terminator, or nil
            var j = from
            while j + terminator.count <= n {
                if line.character(at: j) == 0x5C && state != .blockComment { j += 2; continue }
                var match = true
                for (k, t) in terminator.enumerated() where line.character(at: j + k) != t { match = false; break }
                if match { return j + terminator.count }
                j += 1
            }
            return nil
        }
        switch state {
        case .normal: break
        case .blockComment:
            if let e = scanTo([0x2A, 0x2F], from: 0) { out.append((NSRange(location: 0, length: e), .comment)); i = e; state = .normal }
            else { return ([(NSRange(location: 0, length: n), .comment)], .blockComment) }
        case .tripleDouble, .tripleSingle:
            let q: unichar = state == .tripleDouble ? 0x22 : 0x27
            if let e = scanTo([q, q, q], from: 0) { out.append((NSRange(location: 0, length: e), .string)); i = e; state = .normal }
            else { return ([(NSRange(location: 0, length: n), .string)], state) }
        case .template:
            if let e = scanTo([0x60], from: 0) { out.append((NSRange(location: 0, length: e), .string)); i = e; state = .normal }
            else { return ([(NSRange(location: 0, length: n), .string)], .template) }
        }
        let keywords: Set<String>
        switch fam { case .cLike: keywords = cLike; case .python: keywords = python; case .shell: keywords = shell; case .sql: keywords = sql; default: keywords = literals }
        let hashComment = fam == .python || fam == .shell || fam == .yaml
        while i < n {
            let c = line.character(at: i)
            // comments
            if (c == 0x2F && i + 1 < n && line.character(at: i + 1) == 0x2F && fam != .shell && fam != .python && fam != .yaml && fam != .markup && fam != .json) ||
               (c == 0x23 && hashComment && (i == 0 || line.character(at: i - 1) == 0x20 || line.character(at: i - 1) == 0x09 || fam != .yaml)) ||
               (c == 0x2D && fam == .sql && i + 1 < n && line.character(at: i + 1) == 0x2D) {
                out.append((NSRange(location: i, length: n - i), .comment)); break
            }
            if c == 0x2F && i + 1 < n && line.character(at: i + 1) == 0x2A { // /* ... */, possibly continuing on later lines
                var j = i + 2
                while j + 1 < n, !(line.character(at: j) == 0x2A && line.character(at: j + 1) == 0x2F) { j += 1 }
                let closed = j + 1 < n
                let e = closed ? j + 2 : n
                out.append((NSRange(location: i, length: e - i), .comment)); i = e
                if !closed { state = .blockComment }
                continue
            }
            if fam == .python, (c == 0x22 || c == 0x27), i + 2 < n, line.character(at: i + 1) == c, line.character(at: i + 2) == c {
                var j = i + 3
                var closed = false
                while j + 2 < n + 0 { if line.character(at: j) == c, line.character(at: j + 1) == c, line.character(at: j + 2) == c { closed = true; break }; j += 1 }
                let e = closed ? j + 3 : n
                out.append((NSRange(location: i, length: e - i), .string)); i = e
                if !closed { state = c == 0x22 ? .tripleDouble : .tripleSingle }
                continue
            }
            if c == 0x22 || c == 0x27 || c == 0x60 {
                var j = i + 1
                while j < n {
                    let d = line.character(at: j)
                    if d == 0x5C { j += 2; continue }
                    if d == c { j += 1; break }
                    j += 1
                }
                let e = min(j, n)
                let terminated = j <= n && j - 1 < n && j > i + 1 && line.character(at: j - 1) == c && j - 1 > i
                out.append((NSRange(location: i, length: e - i), fam == .json && c == 0x22 && isKey(line, e) ? .type : .string)); i = e
                if c == 0x60 && !terminated && fam == .cLike { state = .template }
                continue
            }
            if c >= 0x30 && c <= 0x39 {
                var j = i
                while j < n {
                    let d = line.character(at: j)
                    if (d >= 0x30 && d <= 0x39) || d == 0x2E || d == 0x5F || d == 0x78 || (d >= 0x61 && d <= 0x66) || (d >= 0x41 && d <= 0x46) { j += 1 } else { break }
                }
                out.append((NSRange(location: i, length: j - i), .number)); i = j; continue
            }
            if isIdentStart(c) {
                var j = i + 1
                while j < n, isIdent(line.character(at: j)) { j += 1 }
                let word = line.substring(with: NSRange(location: i, length: j - i))
                if keywords.contains(fam == .sql ? word.lowercased() : word) { out.append((NSRange(location: i, length: j - i), .keyword)) }
                else if fam == .yaml, j < n, line.character(at: j) == 0x3A { out.append((NSRange(location: i, length: j - i), .type)) }
                else if fam == .cLike || fam == .python, let f = word.unicodeScalars.first, CharacterSet.uppercaseLetters.contains(f), word.count > 1 { out.append((NSRange(location: i, length: j - i), .type)) }
                i = j; continue
            }
            i += 1
        }
        return (out, state)
    }

    private static func isKey(_ s: NSString, _ end: Int) -> Bool {
        var j = end
        while j < s.length, s.character(at: j) == 0x20 { j += 1 }
        return j < s.length && s.character(at: j) == 0x3A
    }
    private static func isIdentStart(_ c: unichar) -> Bool { (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F || c == 0x24 || c == 0x40 }
    private static func isIdent(_ c: unichar) -> Bool { isIdentStart(c) || (c >= 0x30 && c <= 0x39) || c == 0x2D && false }

    static func color(_ k: TokenKind) -> NSColor {
        switch k {
        case .comment: return NSColor.secondaryLabelColor
        case .string: return NSColor(name: nil) { a in a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(red: 0.99, green: 0.55, blue: 0.45, alpha: 1) : NSColor(red: 0.77, green: 0.10, blue: 0.09, alpha: 1) }
        case .number: return NSColor(name: nil) { a in a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(red: 0.82, green: 0.78, blue: 0.40, alpha: 1) : NSColor(red: 0.11, green: 0.0, blue: 0.81, alpha: 1) }
        case .keyword: return NSColor(name: nil) { a in a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(red: 0.99, green: 0.37, blue: 0.64, alpha: 1) : NSColor(red: 0.61, green: 0.14, blue: 0.58, alpha: 1) }
        case .type: return NSColor(name: nil) { a in a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(red: 0.42, green: 0.80, blue: 0.85, alpha: 1) : NSColor(red: 0.11, green: 0.43, blue: 0.52, alpha: 1) }
        }
    }
}
