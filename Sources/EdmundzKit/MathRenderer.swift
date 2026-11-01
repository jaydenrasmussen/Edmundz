import AppKit
import SwiftMath

struct MathImage {
    var image: NSImage
    /// Distance in points from the image bottom to the text baseline (positive = below baseline).
    var descent: CGFloat
}

/// Native LaTeX rendering with SwiftMath, plus a text preprocessor that maps common commands it lacks onto ones it has.
/// Anything still unsupported is reported so the caller can fall back to KaTeX.
enum MathRenderer {
    private static let cache: NSCache<NSString, Box> = { let c = NSCache<NSString, Box>(); c.totalCostLimit = 16 << 20; return c }()
    private final class Box { let value: MathImage; init(_ v: MathImage) { value = v } }

    static func preprocess(_ latex: String) -> String {
        var s = latex
        let simple: [(String, String)] = [
            ("\\dfrac", "\\frac"), ("\\tfrac", "\\frac"), ("\\lVert", "\\Vert"), ("\\rVert", "\\Vert"), ("\\lvert", "|"), ("\\rvert", "|"),
            ("\\begin{align*}", "\\begin{aligned}"), ("\\end{align*}", "\\end{aligned}"),
            ("\\begin{align}", "\\begin{aligned}"), ("\\end{align}", "\\end{aligned}"),
            ("\\begin{equation*}", ""), ("\\end{equation*}", ""), ("\\begin{equation}", ""), ("\\end{equation}", ""),
            ("\\begin{gather*}", "\\begin{aligned}"), ("\\end{gather*}", "\\end{aligned}"),
            ("\\displaystyle", ""), ("\\textstyle", ""), ("\\bigl", "\\left"), ("\\bigr", "\\right"), ("\\Bigl", "\\left"), ("\\Bigr", "\\right"),
        ]
        for (a, b) in simple { s = s.replacingOccurrences(of: a, with: b) }
        s = regexReplace(s, #"\\operatorname\*?\{([^{}]*)\}"#, #"\\mathrm{$1}"#)
        s = regexReplace(s, #"\\pmod\{([^{}]*)\}"#, #"\\;(\\mathrm{mod}\\,$1)"#)
        s = regexReplace(s, #"\\mathbbm\{"#, #"\\mathbb{"#)
        return s
    }

    private static func regexReplace(_ s: String, _ pattern: String, _ template: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        return re.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: template)
    }

    static func supports(_ latex: String) -> Bool {
        var err: NSError?
        return MTMathListBuilder.build(fromString: preprocess(latex), error: &err) != nil
    }

    /// Nil when SwiftMath cannot parse the input.
    static func render(_ latex: String, display: Bool, fontSize: CGFloat, color: NSColor, appearanceKey: String) -> MathImage? {
        let key = "\(display)|\(fontSize)|\(appearanceKey)|\(latex)" as NSString
        if let hit = cache.object(forKey: key) { return hit.value }
        let tex = preprocess(latex)
        var err: NSError?
        guard MTMathListBuilder.build(fromString: tex, error: &err) != nil else { return nil }

        let resolved = resolvedColor(color)
        let mode: MTMathUILabelMode = display ? .display : .text
        let img = MTMathImage(latex: tex, fontSize: fontSize, textColor: resolved, labelMode: mode, textAlignment: .left)
        let (e, image) = img.asImage()
        guard e == nil, let image else { return nil }

        // descent for baseline alignment
        let label = MTMathUILabel()
        label.latex = tex; label.fontSize = fontSize; label.labelMode = mode; label.textAlignment = .left
        let fit = label.fittingSize
        label.frame = CGRect(origin: .zero, size: fit)
        label.layoutSubtreeIfNeeded()
        let descent = label.displayList?.descent ?? 0

        let result = MathImage(image: image, descent: max(0, descent))
        cache.setObject(Box(result), forKey: key, cost: Int(image.size.width * image.size.height * 4))
        return result
    }

    static func purge() { cache.removeAllObjects() }

    private static func resolvedColor(_ c: NSColor) -> NSColor {
        var out = c
        NSApp?.effectiveAppearance.performAsCurrentDrawingAppearance { out = c.usingColorSpace(.sRGB) ?? c }
        return out
    }
}
