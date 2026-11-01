import AppKit

/// The single source for the Format and View menus and for Help > Keyboard Shortcuts.
public struct Shortcut {
    public let title: String
    public let key: String
    public let modifiers: NSEvent.ModifierFlags
    public let action: Selector
    public let tag: Int
    public let group: String
    public let markdown: String

    var display: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        return s + key.uppercased()
    }
}

public enum ShortcutTable {
    static let cmd: NSEvent.ModifierFlags = [.command]

    public static let format: [Shortcut] = [
        Shortcut(title: "Bold", key: "b", modifiers: cmd, action: #selector(EditorTextView.toggleBold(_:)), tag: 0, group: "Inline", markdown: "**text**"),
        Shortcut(title: "Italic", key: "i", modifiers: cmd, action: #selector(EditorTextView.toggleItalic(_:)), tag: 0, group: "Inline", markdown: "*text*"),
        Shortcut(title: "Underline", key: "u", modifiers: cmd, action: #selector(EditorTextView.toggleUnderline(_:)), tag: 0, group: "Inline", markdown: "<ins>text</ins>"),
        Shortcut(title: "Strikethrough", key: "x", modifiers: [.command, .shift], action: #selector(EditorTextView.toggleStrikethrough(_:)), tag: 0, group: "Inline", markdown: "~~text~~"),
        Shortcut(title: "Code", key: "c", modifiers: [.command, .option], action: #selector(EditorTextView.toggleInlineCode(_:)), tag: 0, group: "Inline", markdown: "`text`"),
        Shortcut(title: "Link…", key: "k", modifiers: cmd, action: #selector(EditorTextView.editLink(_:)), tag: 0, group: "Inline", markdown: "[text](url)"),
        Shortcut(title: "Heading 1", key: "1", modifiers: cmd, action: #selector(EditorTextView.setHeadingLevel(_:)), tag: 1, group: "Blocks", markdown: "# "),
        Shortcut(title: "Heading 2", key: "2", modifiers: cmd, action: #selector(EditorTextView.setHeadingLevel(_:)), tag: 2, group: "Blocks", markdown: "## "),
        Shortcut(title: "Heading 3", key: "3", modifiers: cmd, action: #selector(EditorTextView.setHeadingLevel(_:)), tag: 3, group: "Blocks", markdown: "### "),
        Shortcut(title: "Heading 4", key: "4", modifiers: cmd, action: #selector(EditorTextView.setHeadingLevel(_:)), tag: 4, group: "Blocks", markdown: "#### "),
        Shortcut(title: "Heading 5", key: "5", modifiers: cmd, action: #selector(EditorTextView.setHeadingLevel(_:)), tag: 5, group: "Blocks", markdown: "##### "),
        Shortcut(title: "Heading 6", key: "6", modifiers: cmd, action: #selector(EditorTextView.setHeadingLevel(_:)), tag: 6, group: "Blocks", markdown: "###### "),
        Shortcut(title: "Paragraph", key: "0", modifiers: cmd, action: #selector(EditorTextView.setHeadingLevel(_:)), tag: 0, group: "Blocks", markdown: "removes #"),
        Shortcut(title: "Bulleted List", key: "8", modifiers: [.command, .shift], action: #selector(EditorTextView.toggleBulletList(_:)), tag: 0, group: "Blocks", markdown: "- "),
        Shortcut(title: "Numbered List", key: "7", modifiers: [.command, .shift], action: #selector(EditorTextView.toggleNumberedList(_:)), tag: 0, group: "Blocks", markdown: "1. "),
        Shortcut(title: "Task List", key: "9", modifiers: [.command, .shift], action: #selector(EditorTextView.toggleTaskList(_:)), tag: 0, group: "Blocks", markdown: "- [ ] "),
        Shortcut(title: "Indent Item", key: "]", modifiers: cmd, action: #selector(EditorTextView.indentItem(_:)), tag: 0, group: "Blocks", markdown: ""),
        Shortcut(title: "Outdent Item", key: "[", modifiers: cmd, action: #selector(EditorTextView.outdentItem(_:)), tag: 0, group: "Blocks", markdown: ""),
    ]

    /// Shortcuts that live in other menus, listed so Help is complete.
    public static let other: [(String, String, String)] = [
        ("Find", "⌘F", "Edit"), ("Find Next", "⌘G", "Edit"), ("Find Previous", "⇧⌘G", "Edit"),
        ("Larger Text", "⌘+", "View"), ("Smaller Text", "⌘−", "View"), ("Actual Size", "⌥⌘0", "View"),
        ("Next Tab", "⌃⇥ or ⇧⌘]", "Window"), ("Previous Tab", "⇧⌃⇥ or ⇧⌘[", "Window"),
        ("Settings", "⌘,", "App"), ("Export as PDF", "⇧⌘E", "File"),
    ]

    public static func helpText() -> String {
        var out = ""
        for group in ["Inline", "Blocks"] {
            out += "\(group)\n"
            for s in format where s.group == group { out += "  \(s.display.padding(toLength: 8, withPad: " ", startingAt: 0))  \(s.title.padding(toLength: 16, withPad: " ", startingAt: 0))  \(s.markdown)\n" }
            out += "\n"
        }
        out += "Other\n"
        for (t, k, _) in other { out += "  \(k.padding(toLength: 12, withPad: " ", startingAt: 0))  \(t)\n" }
        return out
    }
}
