import Foundation

public struct ImageSize: Equatable {
    public var width: Double?
    public var height: Double?
    public init(width: Double? = nil, height: Double? = nil) { self.width = width; self.height = height }
}

/// Inline construct found in a block. Ranges are absolute UTF-16 offsets in the document.
public enum RunKind: Equatable {
    case bold, italic, underline, strike, code
    case link(url: String)
    case image(url: String, alt: String, size: ImageSize?)
    case math(display: Bool)
    case footnoteRef
    case autolink
    case kbd, sub, sup, mark
    case lineBreak          // <br>
    case htmlComment
    case htmlOther          // unsupported inline html: shown dimmed
    case emoji(String)
}

public struct Run: Equatable {
    public var kind: RunKind
    /// Whole construct, markers included.
    public var range: NSRange
    /// Leading marker (e.g. "**", "[", "<ins>"). Length 0 when there is none.
    public var open: NSRange
    /// Trailing marker (e.g. "**", "](url)", "</ins>").
    public var close: NSRange
    public var content: NSRange {
        NSRange(location: open.upperBound, length: max(0, close.location - open.upperBound))
    }
}

public enum AlertKind: String, CaseIterable {
    case note, tip, important, warning, caution
}

public enum LineKind: Equatable {
    case blank
    case paragraph
    case heading(Int)
    case setextUnderline
    case fenceOpen(lang: String)
    case code(lang: String)
    case fenceClose
    case indentedCode
    case mathFence, mathLine
    case mermaidFence, mermaidLine
    case frontMatterFence, frontMatter
    case rule
    case htmlBlock
    case htmlComment
    case tableHeader, tableDelimiter, tableRow
    case footnoteDef
}

public struct TaskBox: Equatable {
    public var range: NSRange   // the "[ ]" / "[x]"
    public var checked: Bool
}

public struct TableLine: Equatable {
    public var alignments: [TableAlignment]
    /// Cell content ranges (trimmed), absolute. Empty for the delimiter line.
    public var cells: [NSRange]
    /// Every "|" in the line (absolute).
    public var pipes: [NSRange]
}

public enum TableAlignment: Equatable { case none, left, center, right }

public struct LineModel {
    /// Absolute range including the trailing newline.
    public var range: NSRange
    public var kind: LineKind = .paragraph
    public var quoteDepth = 0
    public var alert: AlertKind?
    /// First line of an alert block (shows the title).
    public var alertTitle = false
    /// Block-level markers hidden unless the caret is on the line: "#", ">", fences, setext underline, closing "#".
    public var markers: [NSRange] = []
    /// A list bullet to draw as a dot (one character).
    public var bullet: NSRange?
    /// Ordered list number like "1." (kept visible, styled).
    public var number: NSRange?
    public var task: TaskBox?
    /// Characters from line start to where the item/quote content starts (for hanging indents).
    public var contentStart: Int = 0
    public var listDepth = 0
    public var table: TableLine?
    /// Block-relative index of this line inside a multi-line widget block (mermaid, math).
    public var widgetIndex = 0
}

public enum WidgetKind: Equatable { case mermaid, mathBlock }

public struct ParsedBlock {
    public var range: NSRange
    public var lines: [LineModel]
    public var runs: [Run]
    /// Set for mermaid and display-math fences: the whole block renders as one image on its first line.
    public var widget: WidgetKind?
    /// Source of the widget (fence content without fence lines).
    public var widgetSource: String = ""
    public var contentRange: NSRange = NSRange(location: 0, length: 0)

    public func lineIndex(containing offset: Int) -> Int? {
        var lo = 0, hi = lines.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let r = lines[mid].range
            if offset < r.location { hi = mid - 1 }
            else if offset >= r.upperBound && !(offset == r.upperBound && mid == lines.count - 1) { lo = mid + 1 }
            else { return mid }
        }
        return nil
    }
}

extension NSRange {
    public var end: Int { location + length }
    func intersects(_ o: NSRange) -> Bool { NSIntersectionRange(self, o).length > 0 }
    func clipped(to o: NSRange) -> NSRange { NSIntersectionRange(self, o) }
}
