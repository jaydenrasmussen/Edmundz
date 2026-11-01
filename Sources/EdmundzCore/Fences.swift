import Foundation

/// A `<details>` … `</details>` region. Unlike fences its interior is ordinary Markdown; the editor only collapses it.
public struct DetailsSpan: Equatable {
    public var range: NSRange        // open line start .. close line end
    public var openLine: NSRange
    public var summaryLine: NSRange? // the line holding <summary> (may be the open line itself)
    public var closeLine: NSRange
}

public enum FenceKind: Equatable {
    case code(lang: String)
    case mermaid
    case math
    case frontMatter
}

public struct FenceSpan: Equatable {
    /// Opening line start .. closing line end (incl. newline), or EOF when unclosed.
    public var range: NSRange
    public var kind: FenceKind
    public var closed: Bool
    public var firstLine: NSRange
    public var lastLine: NSRange
}

/// Finds multi-line constructs whose interior may contain blank lines: fenced code, mermaid, `$$` math, front-matter.
/// Edits only force a rescan when they can change fence topology; otherwise spans are shifted.
public final class FenceIndex {
    public private(set) var spans: [FenceSpan] = []
    public private(set) var rebuildCount = 0
    public private(set) var detailsSpans: [DetailsSpan] = []

    public init(text: NSString) { rebuild(text) }

    // MARK: lookup

    public func span(containing offset: Int) -> FenceSpan? {
        var lo = 0, hi = spans.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let r = spans[mid].range
            if offset < r.location { hi = mid - 1 }
            else if offset >= r.end { lo = mid + 1 }
            else { return spans[mid] }
        }
        return nil
    }

    public func details(containing offset: Int) -> DetailsSpan? {
        var lo = 0, hi = detailsSpans.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let r = detailsSpans[mid].range
            if offset < r.location { hi = mid - 1 } else if offset >= r.end { lo = mid + 1 } else { return detailsSpans[mid] }
        }
        return nil
    }

    // MARK: scanning

    public func rebuild(_ text: NSString) {
        rebuildCount += 1
        spans.removeAll(keepingCapacity: true)
        detailsSpans.removeAll(keepingCapacity: true)
        var detailsOpen: [(line: NSRange, summary: NSRange?)] = []
        let n = text.length
        var pos = 0
        if let fm = frontMatterSpan(text) { spans.append(fm); pos = fm.range.end }
        while pos < n {
            var ls = 0, le = 0, ce = 0
            text.getLineStart(&ls, end: &le, contentsEnd: &ce, for: NSRange(location: pos, length: 0))
            guard let open = FenceIndex.openFence(text, ls, ce) else {
                // <details> bookkeeping happens on lines outside fences only
                if ce > ls, text.character(at: min(ls + 20, ce - 1)) != 0 || true {
                    let raw = text.substring(with: NSRange(location: ls, length: min(ce - ls, 200))).lowercased()
                    let trimmed = raw.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("<details") && !trimmed.contains("</details>") {
                        detailsOpen.append((NSRange(location: ls, length: le - ls), trimmed.contains("<summary") ? NSRange(location: ls, length: le - ls) : nil))
                    } else if trimmed.hasPrefix("<summary"), var last = detailsOpen.popLast() {
                        if last.summary == nil { last.summary = NSRange(location: ls, length: le - ls) }
                        detailsOpen.append(last)
                    } else if trimmed.contains("</details>"), let o = detailsOpen.popLast() {
                        let span = DetailsSpan(range: NSRange(location: o.line.location, length: le - o.line.location), openLine: o.line,
                                               summaryLine: o.summary, closeLine: NSRange(location: ls, length: le - ls))
                        if detailsOpen.isEmpty { detailsSpans.append(span) }   // nested regions collapse with their outermost parent
                    }
                }
                pos = le; continue
            }
            var end = n, closed = false
            var lastLine = NSRange(location: n, length: 0)
            var p = le
            while p < n {
                var cs = 0, cl = 0, cc = 0
                text.getLineStart(&cs, end: &cl, contentsEnd: &cc, for: NSRange(location: p, length: 0))
                if FenceIndex.closes(open, text, cs, cc) { end = cl; closed = true; lastLine = NSRange(location: cs, length: cl - cs); break }
                p = cl
            }
            let kind: FenceKind = open.isMath ? .math : (open.lang.lowercased() == "mermaid" ? .mermaid : .code(lang: open.lang))
            spans.append(FenceSpan(range: NSRange(location: ls, length: end - ls), kind: kind, closed: closed,
                                   firstLine: NSRange(location: ls, length: le - ls), lastLine: lastLine))
            pos = end
        }
    }

    private func frontMatterSpan(_ t: NSString) -> FenceSpan? {
        var ls = 0, le = 0, ce = 0
        guard t.length >= 3 else { return nil }
        t.getLineStart(&ls, end: &le, contentsEnd: &ce, for: NSRange(location: 0, length: 0))
        guard t.substring(with: NSRange(location: 0, length: ce)).trimmingCharacters(in: .whitespaces) == "---" else { return nil }
        var p = le
        while p < t.length {
            var cs = 0, cl = 0, cc = 0
            t.getLineStart(&cs, end: &cl, contentsEnd: &cc, for: NSRange(location: p, length: 0))
            let l = t.substring(with: NSRange(location: cs, length: cc - cs)).trimmingCharacters(in: .whitespaces)
            if l == "---" || l == "..." {
                return FenceSpan(range: NSRange(location: 0, length: cl), kind: .frontMatter, closed: true,
                                 firstLine: NSRange(location: 0, length: le), lastLine: NSRange(location: cs, length: cl - cs))
            }
            p = cl
        }
        return nil
    }

    struct Open { var char: unichar; var count: Int; var lang: String; var isMath: Bool }

    static func openFence(_ t: NSString, _ ls: Int, _ ce: Int) -> Open? {
        var i = ls
        var spaces = 0
        while i < ce, t.character(at: i) == 0x20, spaces < 4 { i += 1; spaces += 1 }
        guard spaces <= 3, i < ce else { return nil }
        let c = t.character(at: i)
        if c == 0x60 || c == 0x7E {
            var j = i
            while j < ce, t.character(at: j) == c { j += 1 }
            let count = j - i
            guard count >= 3 else { return nil }
            let info = t.substring(with: NSRange(location: j, length: ce - j)).trimmingCharacters(in: .whitespaces)
            if c == 0x60 && info.contains("`") { return nil }
            return Open(char: c, count: count, lang: info.split(separator: " ", maxSplits: 1).first.map(String.init) ?? "", isMath: false)
        }
        if c == 0x24, i + 1 < ce, t.character(at: i + 1) == 0x24 {
            let rest = t.substring(with: NSRange(location: i, length: ce - i)).trimmingCharacters(in: .whitespaces)
            if rest == "$$" || (rest.count > 2 && !rest.hasSuffix("$$")) { return Open(char: 0x24, count: 2, lang: "", isMath: true) }
        }
        return nil
    }

    static func closes(_ o: Open, _ t: NSString, _ ls: Int, _ ce: Int) -> Bool {
        if o.isMath {
            var j = ce
            while j > ls, t.character(at: j - 1) == 0x20 { j -= 1 }
            return j - ls >= 2 && t.character(at: j - 1) == 0x24 && t.character(at: j - 2) == 0x24
        }
        var i = ls
        var spaces = 0
        while i < ce, t.character(at: i) == 0x20, spaces < 4 { i += 1; spaces += 1 }
        guard spaces <= 3 else { return false }
        var j = i
        while j < ce, t.character(at: j) == o.char { j += 1 }
        guard j - i >= o.count else { return false }
        while j < ce { let c = t.character(at: j); if c != 0x20 && c != 0x09 { return false }; j += 1 }
        return true
    }

    // MARK: edits

    private func touch(_ a: NSRange, _ b: NSRange) -> Bool { a.location <= b.end && b.location <= a.end }

    /// Call after the text changed. `oldRange` is the replaced range in pre-edit coordinates.
    public func didEdit(oldRange: NSRange, newLength: Int, text: NSString) {
        let delta = newLength - oldRange.length
        var rescan = spans.contains { touch(oldRange, $0.firstLine) || touch(oldRange, $0.lastLine) }
            || detailsSpans.contains { touch(oldRange, $0.openLine) || touch(oldRange, $0.closeLine) || ($0.summaryLine.map { touch(oldRange, $0) } ?? false) }
        if !rescan {
            let n = text.length
            let loc = min(oldRange.location, n)
            let newRange = NSRange(location: loc, length: min(newLength, n - loc))
            let lines = text.lineRange(for: newRange)
            var p = lines.location
            while p < lines.end {
                var ls = 0, le = 0, ce = 0
                text.getLineStart(&ls, end: &le, contentsEnd: &ce, for: NSRange(location: p, length: 0))
                var i = ls
                while i < ce, text.character(at: i) == 0x20 { i += 1 }
                if i < ce {
                    let c = text.character(at: i)
                    if c == 0x60 || c == 0x7E || c == 0x24 { rescan = true; break }
                    if c == 0x3C { rescan = true; break }   // a tag line may open or close <details>
                    if (c == 0x2D || c == 0x2E) && ls < 8 { rescan = true; break }
                }
                p = le
            }
        }
        if rescan { rebuild(text); return }
        for i in detailsSpans.indices {
            let r = detailsSpans[i].range
            if r.location >= oldRange.end {
                detailsSpans[i].range.location += delta; detailsSpans[i].openLine.location += delta; detailsSpans[i].closeLine.location += delta
                if detailsSpans[i].summaryLine != nil { detailsSpans[i].summaryLine!.location += delta }
            } else if r.location < oldRange.location && r.end > oldRange.end {
                detailsSpans[i].range.length += delta; detailsSpans[i].closeLine.location += delta
            }
        }
        for i in spans.indices {
            let r = spans[i].range
            if r.location >= oldRange.end {
                spans[i].range.location += delta
                spans[i].firstLine.location += delta
                spans[i].lastLine.location += delta
            } else if r.location < oldRange.location && r.end > oldRange.end {
                spans[i].range.length += delta
                spans[i].lastLine.location += delta
            }
        }
    }
}
