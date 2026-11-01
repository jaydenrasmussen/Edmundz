import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Image bytes are never held by the attachment. Decoded thumbnails live in a cost-limited cache.
final class ImageCache {
    static let shared = ImageCache()
    let cache = NSCache<NSString, NSImage>()
    var inflight = Set<String>()
    var onReady: (() -> Void)?
    var decodes = 0
    private let queue: OperationQueue = { let q = OperationQueue(); q.maxConcurrentOperationCount = 2; q.qualityOfService = .userInitiated; return q }()

    init() { cache.totalCostLimit = 48 * 1024 * 1024 }

    /// Header-only read: pixel size without decoding.
    static func pixelSize(_ url: URL) -> CGSize? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = (p[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue, let h = (p[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue else { return nil }
        return CGSize(width: w, height: h)
    }

    func image(for url: URL, maxPixel: Int) -> NSImage? {
        let key = "\(url.path)@\(maxPixel)" as NSString
        if let img = cache.object(forKey: key) { return img }
        let k = key as String
        guard !inflight.contains(k) else { return nil }
        inflight.insert(k)
        queue.addOperation { [self] in autoreleasepool {
            let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                         kCGImageSourceCreateThumbnailWithTransform: true,
                                         kCGImageSourceShouldCacheImmediately: true,
                                         kCGImageSourceThumbnailMaxPixelSize: maxPixel]
            var result: NSImage?
            if let src = CGImageSourceCreateWithURL(url as CFURL, nil), let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) {
                result = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                DispatchQueue.main.async { self.cache.setObject(result!, forKey: key, cost: cg.width * cg.height * 4) }
            }
            DispatchQueue.main.async { self.inflight.remove(k); self.decodes += 1; self.onReady?() }
        } }
        return nil
    }
}

final class LazyImageAttachment: NSTextAttachment {
    let url: URL
    let displaySize: CGSize
    static let placeholder: NSImage = {
        let i = NSImage(size: NSSize(width: 8, height: 8)); i.lockFocus()
        NSColor.quaternaryLabelColor.setFill(); NSRect(x: 0, y: 0, width: 8, height: 8).fill(); i.unlockFocus(); return i
    }()

    init(url: URL, displaySize: CGSize) {
        self.url = url; self.displaySize = displaySize
        super.init(data: nil, ofType: nil)
        self.image = LazyImageAttachment.placeholder   // marks this as an image attachment for TextKit 2
        self.bounds = CGRect(origin: .zero, size: displaySize)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func attachmentBounds(for attributes: [NSAttributedString.Key: Any], location: any NSTextLocation,
                                   textContainer: NSTextContainer?, proposedLineFragment: CGRect, position: CGPoint) -> CGRect {
        attachBoundsCalls += 1
        return CGRect(origin: .zero, size: displaySize)
    }

    override func image(for bounds: CGRect, attributes: [NSAttributedString.Key: Any], location: any NSTextLocation,
                        textContainer: NSTextContainer?) -> NSImage? {
        imageCalls += 1
        return ImageCache.shared.image(for: url, maxPixel: Int(displaySize.width * 2)) ?? LazyImageAttachment.placeholder
    }
}

/// Writes N synthetic JPEGs (w x h) into dir. Returns elapsed ms.
func generateImages(count: Int, w: Int, h: Int, dir: String) {
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let cs = CGColorSpaceCreateDeviceRGB()
    for i in 0..<count {
        let path = "\(dir)/img-\(i).jpg"
        if FileManager.default.fileExists(atPath: path) { continue }
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let g = CGGradient(colorsSpace: cs, colors: [CGColor(red: CGFloat(i % 7) / 7, green: 0.4, blue: 0.8, alpha: 1), CGColor(red: 0.9, green: CGFloat(i % 5) / 5, blue: 0.2, alpha: 1)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: w, y: h), options: [])
        for k in 0..<60 { ctx.setFillColor(CGColor(red: CGFloat((k * 37 + i) % 100) / 100, green: CGFloat((k * 53) % 100) / 100, blue: 0.5, alpha: 0.7))
            ctx.fillEllipse(in: CGRect(x: (k * 131 + i * 17) % w, y: (k * 97) % h, width: 200 + k * 7, height: 200 + k * 5)) }
        let img = ctx.makeImage()!
        let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        CGImageDestinationFinalize(dest)
    }
}

var attachBoundsCalls = 0
var imageCalls = 0
