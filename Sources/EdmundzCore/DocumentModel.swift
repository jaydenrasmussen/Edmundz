import Foundation

/// Owns the derived structure of one document: the fence index and a cache of parsed blocks.
/// The text itself stays in the caller's storage; every call is given the current text.
public final class DocumentModel {
    public private(set) var fences: FenceIndex
    private var cache: [Int: ParsedBlock] = [:]
    public private(set) var generation = 0
    public var parseCount = 0
    /// The text the model last saw. Set by `reset` / `didEdit`; lets collaborators read source ranges without holding storage.
    public private(set) var sourceText: NSString?
    /// True when the last edit forced a full fence rescan (callers may need to restyle more than the edited block).
    public private(set) var lastEditRebuilt = false

    public init(text: NSString) { fences = FenceIndex(text: text); sourceText = text }

    public func reset(text: NSString) {
        fences = FenceIndex(text: text)
        sourceText = text
        cache.removeAll()
        generation += 1
    }

    public func didEdit(oldRange: NSRange, newLength: Int, text: NSString) {
        let before = fences.rebuildCount
        fences.didEdit(oldRange: oldRange, newLength: newLength, text: text)
        lastEditRebuilt = fences.rebuildCount != before
        sourceText = text
        cache.removeAll(keepingCapacity: true)
        generation += 1
    }

    public func block(at offset: Int, in text: NSString) -> ParsedBlock {
        let result = BlockSplitter.block(containing: offset, in: text, fences: fences)
        let range: NSRange
        switch result {
        case .fence(let s): range = s.range
        case .chunk(let r): range = r
        }
        if let hit = cache[range.location], hit.range == range { return hit }
        parseCount += 1
        let parsed: ParsedBlock
        switch result {
        case .fence(let s): parsed = BlockParser.parseFence(s, in: text)
        case .chunk(let r): parsed = BlockParser.parse(chunk: r, in: text)
        }
        if cache.count > 512 { cache.removeAll(keepingCapacity: true) }
        cache[range.location] = parsed
        return parsed
    }

    /// The block and the index of the line that contains `offset`.
    public func line(at offset: Int, in text: NSString) -> (block: ParsedBlock, index: Int)? {
        let b = block(at: offset, in: text)
        guard let i = b.lineIndex(containing: offset) else { return nil }
        return (b, i)
    }
}
