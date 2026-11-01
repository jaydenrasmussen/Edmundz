import AppKit
import EdmundzCore

/// Per-paragraph drawing that plain attributes cannot express: rules, quote bars, code and metadata backgrounds, table borders.
final class Deco: NSObject {
    enum Role { case top, middle, bottom, single }
    enum Kind {
        case rule
        case quote(depth: Int, color: NSColor?, role: Role)
        case code(Role)
        case frontMatter(Role)
        /// `edges`: x of every column boundary from the container's left edge (including both outer edges).
        /// `gridOnly`: the collapsed delimiter row, which only continues the vertical lines.
        case tableRow(header: Bool, last: Bool, totalWidth: CGFloat, edges: [CGFloat], gridOnly: Bool)
    }
    let kind: Kind
    init(_ kind: Kind) { self.kind = kind }
}

extension NSAttributedString.Key {
    static let deco = NSAttributedString.Key("edmundz.deco")
    static let heading = NSAttributedString.Key("edmundz.heading")
}

final class DecoratedFragment: NSTextLayoutFragment {
    let deco: Deco

    init(element: NSTextElement, range: NSTextRange?, deco: Deco) {
        self.deco = deco
        super.init(textElement: element, range: range)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// A translucent tint composited over the page background, so abutting fragments can overlap without a darker seam.
    private func opaque(_ c: NSColor) -> CGColor {
        var out = c.cgColor
        let appearance = textLayoutManager?.textContainer?.textView?.effectiveAppearance ?? NSApp.effectiveAppearance
        appearance.performAsCurrentDrawingAppearance {
            let resolved = c.usingColorSpace(.sRGB) ?? c
            out = (NSColor.textBackgroundColor.usingColorSpace(.sRGB)?.blended(withFraction: resolved.alphaComponent, of: resolved.withAlphaComponent(1)) ?? resolved).cgColor
        }
        return out
    }

    private func resolved(_ c: NSColor) -> CGColor {
        var out = c.cgColor
        let appearance = textLayoutManager?.textContainer?.textView?.effectiveAppearance ?? NSApp.effectiveAppearance
        appearance.performAsCurrentDrawingAppearance { out = c.cgColor }
        return out
    }

    /// Fragments that continue into the next one reach 1 pt further, hiding the anti-aliased join.
    private func joined(_ role: Deco.Role, _ r: CGRect) -> CGRect {
        (role == .top || role == .middle) ? CGRect(x: r.minX, y: r.minY, width: r.width, height: r.height + 1) : r
    }

    private var containerWidth: CGFloat { textLayoutManager?.textContainer?.size.width ?? 600 }

    override var renderingSurfaceBounds: CGRect {
        var r = super.renderingSurfaceBounds
        let w = containerWidth
        // decorations are laid out from the container edge, which is `indent` to the left of this fragment's origin
        r = r.union(CGRect(x: -layoutFragmentFrame.origin.x - 8, y: 0, width: w + 16, height: layoutFragmentFrame.height))
        return r
    }

    override func draw(at origin: CGPoint, in ctx: CGContext) {
        // `origin` is in the fragment's own space; the container's left edge lies `frame.origin.x` to the left of it. (The frame sits at the
        // leftmost line fragment, so it is not always the paragraph indent: a one-line "TIP" title and a longer body line differ.)
        let point = CGPoint(x: origin.x - layoutFragmentFrame.origin.x, y: origin.y)
        let h = layoutFragmentFrame.height
        let w = containerWidth
        ctx.saveGState()
        switch deco.kind {
        case .rule:
            ctx.setStrokeColor(Palette.rule.cgColor); ctx.setLineWidth(1)
            ctx.move(to: CGPoint(x: point.x + 4, y: point.y + h / 2)); ctx.addLine(to: CGPoint(x: point.x + w - 4, y: point.y + h / 2)); ctx.strokePath()
        case .quote(let depth, let color, let role):
            if let color {
                // one rounded block across the callout's lines; the side bar is clipped to the same shape so it follows the corners
                let rect = joined(role, CGRect(x: point.x, y: point.y, width: w, height: h))
                ctx.saveGState()
                ctx.addPath(roundedPath(role, rect)); ctx.clip()
                ctx.setFillColor(opaque(color.withAlphaComponent(0.07))); ctx.fill(rect)
                ctx.setFillColor(color.cgColor)
                for d in 0..<depth { ctx.fill(CGRect(x: point.x + CGFloat(d) * 14, y: point.y, width: 3, height: rect.height)) }
                ctx.restoreGState()
            } else {
                ctx.setFillColor(Palette.quoteBar.cgColor)
                for d in 0..<depth { ctx.fill(CGRect(x: point.x + 2 + CGFloat(d) * 14, y: point.y, width: 3, height: h)) }
            }
        case .code(let role):
            fillBlock(ctx, role, joined(role, CGRect(x: point.x - 6, y: point.y, width: w + 12, height: h)), opaque(Palette.codeBackground))
        case .frontMatter(let role):
            fillBlock(ctx, role, joined(role, CGRect(x: point.x - 6, y: point.y, width: w + 12, height: h)), opaque(Palette.codeBackground))
        case .tableRow(let header, let last, let total, let edges, let gridOnly):
            let right = point.x + min(total, w)
            let band = CGRect(x: point.x, y: point.y, width: right - point.x, height: h)
            if !gridOnly {
                if header {
                    // the header band has rounded top corners
                    ctx.setFillColor(opaque(Palette.codeBackground))
                    ctx.addPath(roundedPath(.top, band)); ctx.fillPath()
                    ctx.setStrokeColor(NSColor.secondaryLabelColor.cgColor); ctx.setLineWidth(1.2)
                } else {
                    ctx.setStrokeColor((last ? NSColor.secondaryLabelColor : NSColor.separatorColor).cgColor); ctx.setLineWidth(last ? 1.0 : 0.5)
                }
                ctx.move(to: CGPoint(x: point.x, y: point.y + h - 0.5)); ctx.addLine(to: CGPoint(x: right, y: point.y + h - 0.5)); ctx.strokePath()
            }
            // vertical column lines: light grey on white, subdued white on black (the label colour at low alpha adapts to both)
            ctx.saveGState()
            if header && !gridOnly { ctx.addPath(roundedPath(.top, band)); ctx.clip() }
            ctx.setStrokeColor(resolved(NSColor.labelColor.withAlphaComponent(0.16))); ctx.setLineWidth(0.5)
            for x in edges {
                let px = point.x + x
                ctx.move(to: CGPoint(x: px, y: point.y)); ctx.addLine(to: CGPoint(x: px, y: point.y + h + (gridOnly ? 0 : 0))); ctx.strokePath()
            }
            ctx.restoreGState()
        }
        ctx.restoreGState()
        super.draw(at: origin, in: ctx)
    }

    private func fillBlock(_ ctx: CGContext, _ role: Deco.Role, _ rect: CGRect, _ color: CGColor) {
        ctx.setFillColor(color)
        ctx.addPath(roundedPath(role, rect)); ctx.fillPath()
    }

    /// A rectangle with the 7 pt corner radius on the top and/or bottom corners the role calls for.
    private func roundedPath(_ role: Deco.Role, _ rect: CGRect) -> CGPath {
        let r: CGFloat = 7
        let path = CGMutablePath()
        let top = (role == .top || role == .single), bottom = (role == .bottom || role == .single)
        // the text view is flipped here: minY is the top
        let tl = top ? r : 0, bl = bottom ? r : 0
        path.move(to: CGPoint(x: rect.minX + tl, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - tl, y: rect.minY))
        if tl > 0 { path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY), tangent2End: CGPoint(x: rect.maxX, y: rect.minY + tl), radius: tl) } else { path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY)) }
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - bl))
        if bl > 0 { path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY), tangent2End: CGPoint(x: rect.maxX - bl, y: rect.maxY), radius: bl) } else { path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY)) }
        path.addLine(to: CGPoint(x: rect.minX + bl, y: rect.maxY))
        if bl > 0 { path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: rect.maxY - bl), radius: bl) } else { path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY)) }
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + tl))
        if tl > 0 { path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY), tangent2End: CGPoint(x: rect.minX + tl, y: rect.minY), radius: tl) }
        path.closeSubpath()
        return path
    }
}
