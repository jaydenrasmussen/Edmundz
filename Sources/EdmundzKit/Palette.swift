import AppKit
import EdmundzCore

enum Palette {
    static var text: NSColor { .labelColor }
    static var secondary: NSColor { .secondaryLabelColor }
    static var marker: NSColor { .tertiaryLabelColor }
    static var link: NSColor { .controlAccentColor }
    static var codeBackground: NSColor { NSColor(name: nil) { a in a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.09) : NSColor(white: 0, alpha: 0.055) } }
    static var quoteBar: NSColor { NSColor.tertiaryLabelColor }
    static var rule: NSColor { .separatorColor }
    static var error: NSColor { .systemRed }
    static var mark: NSColor { NSColor.systemYellow.withAlphaComponent(0.35) }

    static func alert(_ k: AlertKind) -> NSColor {
        switch k {
        case .note: return .systemBlue
        case .tip: return .systemGreen
        case .important: return .systemPurple
        case .warning: return .systemOrange
        case .caution: return .systemRed
        }
    }
}
