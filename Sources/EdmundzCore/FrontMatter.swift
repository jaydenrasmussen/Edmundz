import Foundation
import Yams

public struct FrontMatter {
    public var title: String?
    /// Top-level keys in source order with a display string for each value.
    public var entries: [(key: String, value: String)]
    public var tags: [String]
    public var isValid: Bool

    /// Parses the leading `---` block, if any. The source is never modified.
    public static func parse(_ text: String) -> FrontMatter? {
        let ns = text as NSString
        let idx = FenceIndex(text: ns)
        guard let span = idx.spans.first, span.kind == .frontMatter else { return nil }
        let body = ns.substring(with: span.range)
        var lines = body.components(separatedBy: "\n")
        lines.removeFirst()
        if let i = lines.lastIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" || $0.trimmingCharacters(in: .whitespaces) == "..." }) { lines.remove(at: i) }
        let yaml = lines.joined(separator: "\n")
        guard let node = try? Yams.compose(yaml: yaml), case .mapping(let map) = node else {
            return FrontMatter(title: nil, entries: [], tags: [], isValid: yaml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        var entries: [(String, String)] = []
        var title: String?
        var tags: [String] = []
        for (k, v) in map {
            guard let key = k.string else { continue }
            let value = display(v)
            entries.append((key, value))
            if key.lowercased() == "title" { title = value }
            if key.lowercased() == "tags" || key.lowercased() == "tag" {
                if case .sequence(let s) = v { tags = s.map(display) } else { tags = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
            }
        }
        return FrontMatter(title: title, entries: entries, tags: tags, isValid: true)
    }

    private static func display(_ n: Node) -> String {
        switch n {
        case .scalar(let s): return s.string
        case .sequence(let s): return s.map(display).joined(separator: ", ")
        case .mapping(let m): return m.map { "\($0.key.string ?? ""): \(display($0.value))" }.joined(separator: ", ")
        case .alias: return ""
        }
    }
}
