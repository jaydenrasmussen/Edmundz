import Foundation

/// Divides a document into independently parseable blocks: runs of non-blank lines, joined across blank lines when the
/// following line is indented (list/quote continuation), and whole fence spans.
public enum BlockSplitter {
    public static let maxBlockLength = 64 * 1024

    public enum Result { case fence(FenceSpan), chunk(NSRange) }

    static func isBlank(_ t: NSString, _ range: NSRange) -> Bool {
        var i = range.location
        let end = range.end
        while i < end {
            let c = t.character(at: i)
            if c != 0x20 && c != 0x09 && c != 0x0A && c != 0x0D { return false }
            i += 1
        }
        return true
    }

    static func indent(_ t: NSString, _ lineStart: Int, _ end: Int) -> Int {
        var i = lineStart, w = 0
        while i < end {
            let c = t.character(at: i)
            if c == 0x20 { w += 1 } else if c == 0x09 { w += 4 } else { break }
            i += 1
        }
        return w
    }

    public static func block(containing offset: Int, in t: NSString, fences: FenceIndex) -> Result {
        let n = t.length
        let at = min(max(offset, 0), max(0, n - 1))
        if let s = fences.span(containing: at) { return .fence(s) }
        var start = t.lineRange(for: NSRange(location: at, length: 0))
        var end = start

        func fenceStarts(at loc: Int) -> Bool { fences.span(containing: loc) != nil }

        // expand up
        while start.location > 0, end.end - start.location < maxBlockLength {
            let prev = t.lineRange(for: NSRange(location: start.location - 1, length: 0))
            if fenceStarts(at: prev.location) { break }
            if !isBlank(t, prev) { start = NSRange(location: prev.location, length: end.end - prev.location); continue }
            // prev is blank: continue across blanks only when this chunk's first line is indented
            guard indent(t, start.location, start.end) >= 2 else { break }
            var q = prev
            while q.location > 0 && isBlank(t, q) { q = t.lineRange(for: NSRange(location: q.location - 1, length: 0)) }
            if isBlank(t, q) || fenceStarts(at: q.location) { break }
            start = NSRange(location: q.location, length: end.end - q.location)
        }
        // expand down
        while end.end < n, end.end - start.location < maxBlockLength {
            let next = t.lineRange(for: NSRange(location: end.end, length: 0))
            if fenceStarts(at: next.location) { break }
            if !isBlank(t, next) { end = NSRange(location: start.location, length: next.end - start.location); continue }
            var q = next
            while q.end < n && isBlank(t, q) { q = t.lineRange(for: NSRange(location: q.end, length: 0)) }
            if isBlank(t, q) || fenceStarts(at: q.location) { break }
            guard indent(t, q.location, q.end) >= 2 else { break }
            end = NSRange(location: start.location, length: q.end - start.location)
        }
        return .chunk(NSRange(location: start.location, length: end.end - start.location))
    }
}
