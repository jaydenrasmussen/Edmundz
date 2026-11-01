import Foundation

public struct MathSpan: Equatable {
    public var range: NSRange      // whole span with delimiters, block-relative
    public var open: NSRange
    public var close: NSRange
    public var display: Bool
    public var content: NSRange { NSRange(location: open.end, length: close.location - open.end) }
}

/// Finds inline `$…$` and display `$$…$$` math in a block of text with pandoc's rules, skipping code spans and escapes.
/// "$5 and $10" is not math: the opener needs a non-space on its right, the closer a non-space on its left and no digit after.
public enum MathScanner {
    public static func scan(_ text: NSString) -> [MathSpan] {
        let n = text.length
        var buf = [unichar](repeating: 0, count: n)
        text.getCharacters(&buf, range: NSRange(location: 0, length: n))
        var out: [MathSpan] = []
        var i = 0
        let dollar: unichar = 0x24, tick: unichar = 0x60, backslash: unichar = 0x5C

        func isSpace(_ c: unichar) -> Bool { c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D }
        func isDigit(_ c: unichar) -> Bool { c >= 0x30 && c <= 0x39 }

        while i < n {
            let c = buf[i]
            if c == backslash { i += 2; continue }
            if c == tick {
                var j = i
                while j < n, buf[j] == tick { j += 1 }
                let count = j - i
                var k = j
                var found = false
                while k < n {
                    if buf[k] == tick {
                        var m = k
                        while m < n, buf[m] == tick { m += 1 }
                        if m - k == count { i = m; found = true; break }
                        k = m
                    } else { k += 1 }
                }
                if !found { i = j }
                continue
            }
            guard c == dollar else { i += 1; continue }
            if i + 1 < n, buf[i + 1] == dollar {
                // display: find closing $$
                var j = i + 2
                var closed = false
                while j + 1 < n {
                    if buf[j] == backslash { j += 2; continue }
                    if buf[j] == dollar && buf[j + 1] == dollar { closed = true; break }
                    j += 1
                }
                if closed, j > i + 2 {
                    out.append(MathSpan(range: NSRange(location: i, length: j + 2 - i), open: NSRange(location: i, length: 2),
                                        close: NSRange(location: j, length: 2), display: true))
                    i = j + 2
                } else { i += 2 }
                continue
            }
            // inline
            guard i + 1 < n, !isSpace(buf[i + 1]) else { i += 1; continue }
            var j = i + 1
            var closed = false
            while j < n, j - i < 2000 {
                let d = buf[j]
                if d == backslash { j += 2; continue }
                if d == 0x0A && j + 1 < n && buf[j + 1] == 0x0A { break }
                if d == dollar {
                    if !isSpace(buf[j - 1]) && !(j + 1 < n && isDigit(buf[j + 1])) { closed = true }
                    break
                }
                j += 1
            }
            if closed {
                out.append(MathSpan(range: NSRange(location: i, length: j + 1 - i), open: NSRange(location: i, length: 1),
                                    close: NSRange(location: j, length: 1), display: false))
                i = j + 1
            } else { i += 1 }
        }
        return out
    }

    /// Replaces every math span (delimiters included) with "x", keeping newlines, so a Markdown parser cannot misread
    /// `_` or `*` inside formulas. Length-preserving.
    public static func mask(_ text: NSString, spans: [MathSpan]) -> String {
        guard !spans.isEmpty else { return text as String }
        let m = NSMutableString(string: text)
        for s in spans {
            let sub = text.substring(with: s.range) as NSString
            var out = ""
            for i in 0..<sub.length {
                let c = sub.character(at: i)
                out.append(c == 0x0A ? "\n" : "x")
            }
            m.replaceCharacters(in: s.range, with: out)
        }
        return m as String
    }
}
