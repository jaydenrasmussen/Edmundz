import AppKit
import ImageIO
import UniformTypeIdentifiers

enum ImageRef: Hashable {
    case file(URL)
    case remote(URL)
    case data(Data)

    var key: String {
        switch self {
        case .file(let u): return "f:" + u.path
        case .remote(let u): return "r:" + u.absoluteString
        case .data(let d): return "d:\(d.hashValue)"
        }
    }
}

/// Resolves image references, reads sizes from headers only, and decodes downsampled thumbnails off the main thread
/// into a cost-limited cache.
final class ImageStore {
    static let shared = ImageStore()

    private let cache = NSCache<NSString, NSImage>()
    private var sizes: [String: CGSize] = [:]
    private var inflight = Set<String>()
    private var failed = Set<String>()
    private let queue: OperationQueue = {
        let q = OperationQueue(); q.maxConcurrentOperationCount = 2; q.qualityOfService = .userInitiated; return q
    }()
    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.urlCache = URLCache(memoryCapacity: 8 << 20, diskCapacity: 64 << 20)
        c.requestCachePolicy = .returnCacheDataElseLoad
        return URLSession(configuration: c)
    }()
    var onChange: (() -> Void)?

    init() {
        cache.totalCostLimit = 48 << 20
    }

    func purge() { cache.removeAllObjects() }

    // MARK: resolution

    func resolve(_ ref: String, base: URL?) -> ImageRef? {
        let s = ref.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("data:"), let comma = s.firstIndex(of: ",") {
            let meta = s[s.startIndex..<comma]
            let payload = String(s[s.index(after: comma)...])
            if meta.contains(";base64"), let d = Data(base64Encoded: payload) { return .data(d) }
            if let d = payload.removingPercentEncoding?.data(using: .utf8) { return .data(d) }
            return nil
        }
        if s.hasPrefix("http://") || s.hasPrefix("https://") { return URL(string: s).map { .remote($0) } }
        if s.hasPrefix("file://"), let u = URL(string: s) { return .file(u) }
        let decoded = s.removingPercentEncoding ?? s
        if decoded.hasPrefix("/") { return .file(URL(fileURLWithPath: decoded)) }
        if decoded.hasPrefix("~") { return .file(URL(fileURLWithPath: (decoded as NSString).expandingTildeInPath)) }
        guard let base else { return nil }
        return .file(base.deletingLastPathComponent().appendingPathComponent(decoded).standardizedFileURL)
    }

    /// Pixel size without decoding. Nil when unknown yet (remote not downloaded) or unreadable.
    func pixelSize(_ ref: ImageRef) -> CGSize? {
        if let s = sizes[ref.key] { return s }
        let src: CGImageSource?
        switch ref {
        case .file(let u): src = CGImageSourceCreateWithURL(u as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        case .data(let d): src = CGImageSourceCreateWithData(d as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        case .remote: return nil
        }
        guard let src, let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = (p[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue, let h = (p[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue else {
            // SVG and other types ImageIO cannot size: ask NSImage
            if case .file(let u) = ref, u.pathExtension.lowercased() == "svg", let img = NSImage(contentsOf: u) { sizes[ref.key] = img.size; return img.size }
            return nil
        }
        // honor EXIF orientation
        var size = CGSize(width: w, height: h)
        if let o = (p[kCGImagePropertyOrientation] as? NSNumber)?.intValue, o >= 5 { size = CGSize(width: h, height: w) }
        sizes[ref.key] = size
        return size
    }

    // MARK: decoding

    func cached(_ ref: ImageRef, maxPixel: Int) -> NSImage? { cache.object(forKey: "\(ref.key)@\(maxPixel)" as NSString) }

    func hasFailed(_ ref: ImageRef) -> Bool { failed.contains(ref.key) }

    /// Returns the image if cached; otherwise starts a background decode and returns nil. `onChange` fires when it lands.
    func image(_ ref: ImageRef, maxPixel: Int) -> NSImage? {
        let key = "\(ref.key)@\(maxPixel)"
        if let img = cache.object(forKey: key as NSString) { return img }
        guard !inflight.contains(key), !failed.contains(ref.key) else { return nil }
        if case .remote(let u) = ref, !Settings.shared.allowRemoteImages { failed.insert(ref.key); _ = u; return nil }
        inflight.insert(key)
        switch ref {
        case .remote(let url):
            session.dataTask(with: url) { [weak self] data, _, _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    guard let data, let size = Self.size(of: data) else { self.finish(key, ref, nil); return }
                    self.sizes[ref.key] = size
                    self.decode(data: data, ref: ref, key: key, maxPixel: maxPixel)
                }
            }.resume()
        case .file(let url):
            decode(source: { CGImageSourceCreateWithURL(url as CFURL, nil) }, ref: ref, key: key, maxPixel: maxPixel, svgURL: url)
        case .data(let d):
            decode(source: { CGImageSourceCreateWithData(d as CFData, nil) }, ref: ref, key: key, maxPixel: maxPixel, svgURL: nil)
        }
        return nil
    }

    private static func size(of data: Data) -> CGSize? {
        guard let s = CGImageSourceCreateWithData(data as CFData, nil), let p = CGImageSourceCopyPropertiesAtIndex(s, 0, nil) as? [CFString: Any],
              let w = (p[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue, let h = (p[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue else { return nil }
        return CGSize(width: w, height: h)
    }

    private func decode(data: Data, ref: ImageRef, key: String, maxPixel: Int) {
        decode(source: { CGImageSourceCreateWithData(data as CFData, nil) }, ref: ref, key: key, maxPixel: maxPixel, svgURL: nil)
    }

    private func decode(source: @escaping () -> CGImageSource?, ref: ImageRef, key: String, maxPixel: Int, svgURL: URL?) {
        queue.addOperation { [weak self] in
            autoreleasepool {
                var image: NSImage?
                let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                             kCGImageSourceShouldCacheImmediately: true, kCGImageSourceThumbnailMaxPixelSize: maxPixel]
                if let src = source(), let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) {
                    image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                } else if let svgURL, svgURL.pathExtension.lowercased() == "svg" {
                    image = NSImage(contentsOf: svgURL)
                }
                DispatchQueue.main.async { self?.finish(key, ref, image) }
            }
        }
    }

    private func finish(_ key: String, _ ref: ImageRef, _ image: NSImage?) {
        inflight.remove(key)
        if let image {
            var cost = 0
            if let r = image.representations.first { cost = r.pixelsWide * r.pixelsHigh * 4 }
            cache.setObject(image, forKey: key as NSString, cost: max(cost, 1024))
        } else { failed.insert(ref.key) }
        onChange?()
    }
}
