import AppKit

public enum FontRole: Hashable { case body, heading, code }

/// User preferences. Backed by UserDefaults; changes post `Settings.didChange`.
public final class Settings {
    public static let shared = Settings()
    public static let didChange = Notification.Name("EdmundzSettingsDidChange")

    private let d: UserDefaults
    public init(defaults: UserDefaults = .standard) {
        d = defaults
        d.register(defaults: [
            "bodySize": 16.0, "lineHeight": 1.55, "measure": 720.0,
            "autoContinueLists": true, "smartPairs": true, "showFrontMatter": true,
            "allowRemoteImages": true, "imageAssetsFolder": "assets", "openLinksOnClick": true,
        ])
        migrateSystemFamilies()
    }

    /// Family names the system fonts resolve to. Saving one of these would pin the font instead of following the system.
    static var systemFamilies: Set<String> {
        var s: Set<String> = []
        for f in [NSFont.systemFont(ofSize: 13), NSFont.systemFont(ofSize: 40), NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)] { if let n = f.familyName { s.insert(n) } }
        s.formUnion(["SF Pro", "SF Pro Text", "SF Pro Display", "SF Mono", ".AppleSystemUIFont", ".SF NS", ".SF NS Mono"])
        return s
    }

    /// Normalizes saved system-font families back to "System" (nil).
    private func migrateSystemFamilies() {
        for key in ["font.body", "font.heading", "font.code"] {
            if let v = d.string(forKey: key), Settings.systemFamilies.contains(v) { d.removeObject(forKey: key) }
        }
    }

    private func set(_ v: Any?, _ key: String) {
        if let name = v as? String, ["font.body", "font.heading", "font.code"].contains(key), Settings.systemFamilies.contains(name) {
            d.removeObject(forKey: key)
            fontCache.removeAll()
            NotificationCenter.default.post(name: Settings.didChange, object: self)
            return
        }
        d.set(v, forKey: key)
        fontCache.removeAll()
        NotificationCenter.default.post(name: Settings.didChange, object: self)
    }

    // fonts: nil family means the system font for that role
    public var bodyFamily: String? { get { d.string(forKey: "font.body") } set { set(newValue, "font.body") } }
    public var headingFamily: String? { get { d.string(forKey: "font.heading") } set { set(newValue, "font.heading") } }
    public var codeFamily: String? { get { d.string(forKey: "font.code") } set { set(newValue, "font.code") } }
    public var bodySize: CGFloat { get { CGFloat(d.double(forKey: "bodySize")) } set { set(Double(min(max(newValue, 9), 48)), "bodySize") } }
    public var lineHeight: CGFloat { get { CGFloat(d.double(forKey: "lineHeight")) } set { set(Double(min(max(newValue, 1.0), 2.4)), "lineHeight") } }
    /// Column width in points.
    public var measure: CGFloat { get { CGFloat(d.double(forKey: "measure")) } set { set(Double(min(max(newValue, 360), 1600)), "measure") } }

    public var autoContinueLists: Bool { get { d.bool(forKey: "autoContinueLists") } set { set(newValue, "autoContinueLists") } }
    /// A plain click opens a rendered link (otherwise only ⌘-click does).
    public var openLinksOnClick: Bool { get { d.bool(forKey: "openLinksOnClick") } set { set(newValue, "openLinksOnClick") } }
    public var smartPairs: Bool { get { d.bool(forKey: "smartPairs") } set { set(newValue, "smartPairs") } }
    public var showFrontMatter: Bool { get { d.bool(forKey: "showFrontMatter") } set { set(newValue, "showFrontMatter") } }
    public var allowRemoteImages: Bool { get { d.bool(forKey: "allowRemoteImages") } set { set(newValue, "allowRemoteImages") } }
    public var imageAssetsFolder: String { get { d.string(forKey: "imageAssetsFolder") ?? "assets" } set { set(newValue, "imageAssetsFolder") } }

    public func resetAll() {
        for k in ["font.body", "font.heading", "font.code", "bodySize", "lineHeight", "measure", "autoContinueLists", "smartPairs",
                  "showFrontMatter", "allowRemoteImages", "imageAssetsFolder", "openLinksOnClick"] { d.removeObject(forKey: k) }
        set(nil, "reset")
    }

    // MARK: font resolution

    private struct FontKey: Hashable { var role: FontRole; var size: CGFloat; var bold: Bool; var italic: Bool; var family: String? }
    private var fontCache: [FontKey: NSFont] = [:]
    /// Set when a saved family is not installed; the UI shows a one-time notice and the system font is used.
    public private(set) var missingFamilies: Set<String> = []

    public func font(_ role: FontRole, size: CGFloat, bold: Bool = false, italic: Bool = false, override: String? = nil) -> NSFont {
        let key = FontKey(role: role, size: (size * 100).rounded() / 100, bold: bold, italic: italic, family: override)
        if let f = fontCache[key] { return f }
        let family: String?
        if let override { family = override }
        else { switch role { case .body: family = bodyFamily; case .heading: family = headingFamily ?? bodyFamily; case .code: family = codeFamily } }
        var font: NSFont?
        if let family {
            var traits: NSFontTraitMask = []
            if bold { traits.insert(.boldFontMask) }
            if italic { traits.insert(.italicFontMask) }
            font = NSFontManager.shared.font(withFamily: family, traits: traits, weight: bold ? 9 : 5, size: size)
            if font == nil, override == nil { missingFamilies.insert(family) }
        }
        if font == nil {
            switch role {
            case .code:
                font = NSFont.monospacedSystemFont(ofSize: size, weight: bold ? .bold : .regular)
                if italic { font = NSFontManager.shared.convert(font!, toHaveTrait: .italicFontMask) }
            default:
                font = NSFont.systemFont(ofSize: size, weight: bold ? .bold : .regular)
                if italic { font = NSFontManager.shared.convert(font!, toHaveTrait: .italicFontMask) }
            }
        }
        fontCache[key] = font!
        return font!
    }
}
