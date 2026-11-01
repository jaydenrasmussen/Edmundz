import AppKit
import EdmundzCore

/// An image shown inline in the text flow: a picture, a formula or a diagram. The attachment owns its async loading and
/// tells the editor when its size changes (layout) or only its pixels (redraw).
final class MediaAttachment: NSTextAttachment {
    var size: CGSize
    /// Distance from the image bottom to the text baseline.
    var descent: CGFloat = 0
    var rendered: NSImage?
    var load: ((MediaAttachment) -> Void)?
    var onLayout: (() -> Void)?
    var onRedraw: (() -> Void)?
    private var requested = false
    /// Source for "Copy diagram as SVG".
    var svg: String?

    init(size: CGSize) {
        self.size = size
        super.init(data: nil, ofType: nil)
        self.image = MediaAttachment.placeholder   // marks this as an image attachment for TextKit 2
    }
    required init?(coder: NSCoder) { fatalError() }

    static let placeholder: NSImage = {
        NSImage(size: NSSize(width: 4, height: 4), flipped: false) { r in Palette.codeBackground.setFill(); r.fill(); return true }
    }()

    func setRendered(_ image: NSImage, size newSize: CGSize? = nil, descent d: CGFloat? = nil) {
        rendered = image
        var layoutChanged = false
        if let newSize, newSize != size { size = newSize; layoutChanged = true }
        if let d, d != descent { descent = d; layoutChanged = true }
        if layoutChanged { onLayout?() } else { onRedraw?() }
    }

    override func attachmentBounds(for attributes: [NSAttributedString.Key: Any], location: any NSTextLocation,
                                   textContainer: NSTextContainer?, proposedLineFragment: CGRect, position: CGPoint) -> CGRect {
        CGRect(x: 0, y: -descent, width: size.width, height: size.height)
    }

    override func image(for bounds: CGRect, attributes: [NSAttributedString.Key: Any], location: any NSTextLocation,
                        textContainer: NSTextContainer?) -> NSImage? {
        if rendered == nil, !requested { requested = true; load?(self) }
        return rendered ?? MediaAttachment.placeholder
    }

    /// Re-request on next draw (after a failure or appearance change).
    func reset() { rendered = nil; requested = false }
}

/// Builds and caches attachments so a restyled paragraph reuses the already-resolved image, formula or diagram.
final class AttachmentFactory {
    private let cache: NSCache<NSString, MediaAttachment> = { let c = NSCache<NSString, MediaAttachment>(); c.countLimit = 600; return c }()
    var onLayout: (() -> Void)?
    var onRedraw: (() -> Void)?
    var documentURL: URL?
    /// Called once per folder when a sandboxed build needs access to the document's folder to show a relative image.
    var onNeedFolderAccess: ((URL) -> Void)?
    private var askedFolders = Set<String>()

    func purge() { cache.removeAllObjects() }

    private func wire(_ a: MediaAttachment) -> MediaAttachment {
        a.onLayout = { [weak self] in self?.onLayout?() }
        a.onRedraw = { [weak self] in self?.onRedraw?() }
        return a
    }

    private var appearanceKey: String { NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? "dark" : "light" }
    var isDark: Bool { appearanceKey == "dark" }

    // MARK: images

    func image(url: String, alt: String, size explicit: ImageSize?, maxWidth: CGFloat, inline: Bool, lineHeight: CGFloat) -> MediaAttachment {
        let key = "img|\(url)|\(explicit?.width ?? 0)x\(explicit?.height ?? 0)|\(Int(maxWidth))|\(inline)|\(Int(lineHeight))|\(documentURL?.path ?? "")" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let store = ImageStore.shared
        let ref = store.resolve(url, base: documentURL)
        if let documentURL, case .file(let f)? = ref, FolderAccess.isSandboxed {
            let folder = documentURL.deletingLastPathComponent()
            if f.path.hasPrefix(folder.path + "/"), !FolderAccess.hasAccess(to: folder), askedFolders.insert(folder.path).inserted {
                DispatchQueue.main.async { [weak self] in self?.onNeedFolderAccess?(folder) }
            }
        }
        var natural = ref.flatMap { store.pixelSize($0) }
        func fit(_ px: CGSize?) -> CGSize {
            guard let px, px.width > 0, px.height > 0 else { return CGSize(width: min(maxWidth, 360), height: 200) }
            var w = explicit?.width.map { CGFloat($0) } ?? px.width
            var h = explicit?.height.map { CGFloat($0) } ?? (w * px.height / px.width)
            if explicit?.width == nil, let eh = explicit?.height { h = CGFloat(eh); w = h * px.width / px.height }
            if inline, h > lineHeight * 1.4 { w *= lineHeight * 1.4 / h; h = lineHeight * 1.4 }
            if w > maxWidth { h *= maxWidth / w; w = maxWidth }
            return CGSize(width: max(w, 1), height: max(h, 1))
        }
        let a = wire(MediaAttachment(size: fit(natural)))
        guard let ref else {
            a.setRendered(Self.errorImage("Image not found: \(alt.isEmpty ? url : alt)", size: a.size))
            cache.setObject(a, forKey: key); return a
        }
        a.load = { att in
            let maxPixel = Int(max(att.size.width, att.size.height) * 2)
            if let img = store.image(ref, maxPixel: max(maxPixel, 64)) {
                att.setRendered(img)
                return
            }
            if store.hasFailed(ref) { att.setRendered(Self.errorImage("Cannot load image: \(alt.isEmpty ? url : alt)", size: att.size)); return }
            // poll via the store's change callback: re-arm and try again
            att.reset()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak att] in
                guard let att, att.rendered == nil else { return }
                if natural == nil, let px = store.pixelSize(ref) { natural = px; att.setRendered(MediaAttachment.placeholder, size: fit(px)); att.reset() }
                if let img = store.image(ref, maxPixel: max(Int(max(att.size.width, att.size.height) * 2), 64)) { att.setRendered(img) }
                else if store.hasFailed(ref) { att.setRendered(Self.errorImage("Cannot load image: \(alt.isEmpty ? url : alt)", size: att.size)) }
                else { att.onRedraw?(); att.reset(); att.onRedraw?() }
            }
        }
        cache.setObject(a, forKey: key)
        return a
    }

    // MARK: math

    func math(latex: String, display: Bool, fontSize: CGFloat) -> MediaAttachment {
        let ap = appearanceKey
        let key = "math|\(display)|\(fontSize)|\(ap)|\(latex)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        if let m = MathRenderer.render(latex, display: display, fontSize: fontSize, color: .labelColor, appearanceKey: ap) {
            let a = wire(MediaAttachment(size: m.image.size))
            a.descent = m.descent
            a.rendered = m.image
            cache.setObject(a, forKey: key)
            return a
        }
        // fall back to KaTeX in the on-demand web view
        let a = wire(MediaAttachment(size: CGSize(width: max(24, CGFloat(latex.count) * fontSize * 0.45), height: fontSize * 1.3)))
        let hex = isDark ? "#f2f2f7" : "#1c1c1e"
        a.load = { att in
            Task { @MainActor in
                let ck = "katex|\(display)|\(fontSize)|\(ap)|\(latex)"
                if let r = await WebRenderer.shared.renderKaTeX(latex, display: display, fontSize: fontSize, colorHex: hex, cacheKey: ck) {
                    att.setRendered(r.image, size: r.image.size, descent: r.descent)
                } else {
                    att.setRendered(Self.errorImage("LaTeX error: \(latex)", size: CGSize(width: min(400, CGFloat(latex.count) * fontSize * 0.55 + 40), height: fontSize * 1.5)), size: CGSize(width: min(400, CGFloat(latex.count) * fontSize * 0.55 + 40), height: fontSize * 1.5), descent: 0)
                }
            }
        }
        cache.setObject(a, forKey: key)
        return a
    }

    // MARK: diagrams

    func mermaid(source: String, maxWidth: CGFloat) -> MediaAttachment {
        let dark = isDark
        let font = Settings.shared.bodyFamily
        let ck = "mm|\(dark)|\(font ?? "")|\(source.hashValue)"
        let key = (ck + "|\(Int(maxWidth))") as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let a = wire(MediaAttachment(size: CGSize(width: maxWidth, height: 120)))
        a.load = { att in
            Task { @MainActor in
                let result = await WebRenderer.shared.renderMermaid(source, dark: dark, fontFamily: font, cacheKey: ck)
                switch result {
                case .image(let img):
                    att.svg = WebRenderer.shared.cachedSVG(ck)
                    var s = img.size
                    if s.width > maxWidth { s = CGSize(width: maxWidth, height: s.height * maxWidth / s.width) }
                    att.setRendered(img, size: s)
                case .error(let msg):
                    let s = CGSize(width: maxWidth, height: 56)
                    att.setRendered(Self.errorImage("Mermaid: \(msg)", size: s), size: s)
                }
            }
        }
        cache.setObject(a, forKey: key)
        return a
    }

    // MARK: error boxes

    static func errorImage(_ message: String, size: CGSize) -> NSImage {
        NSImage(size: size, flipped: false) { r in
            let box = r.insetBy(dx: 0.5, dy: 0.5)
            NSColor.systemRed.withAlphaComponent(0.08).setFill()
            NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).fill()
            NSColor.systemRed.withAlphaComponent(0.5).setStroke()
            NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).stroke()
            let para = NSMutableParagraphStyle(); para.lineBreakMode = .byTruncatingTail
            (message as NSString).draw(in: box.insetBy(dx: 8, dy: 4), withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.systemRed, .paragraphStyle: para])
            return true
        }
    }
}
