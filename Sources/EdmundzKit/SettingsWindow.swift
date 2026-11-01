import AppKit

/// The Settings window: fonts, appearance, behavior, content.
final class SettingsWindowController: NSWindowController, NSFontChanging {
    private let s = Settings.shared
    private var fontRole: FontRole = .body
    /// True only while the font panel was opened from one of our Choose… buttons.
    private var panelOwned = false
    private var labels: [FontRole: NSTextField] = [:]
    private var sizeField = NSTextField()
    private var sizeStepper = NSStepper()
    private var lineSlider = NSSlider()
    private var measureSlider = NSSlider()
    private var assetsField = NSTextField()

    init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 520), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Settings"; w.isReleasedWhenClosed = false
        super.init(window: w)
        build()
        w.center()
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: Settings.didChange, object: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    private func row(_ title: String, _ control: NSView...) -> NSStackView {
        let l = NSTextField(labelWithString: title); l.alignment = .right
        l.widthAnchor.constraint(equalToConstant: 120).isActive = true
        let st = NSStackView(views: [l] + control); st.orientation = .horizontal; st.spacing = 10; st.alignment = .centerY
        return st
    }

    private func heading(_ t: String) -> NSTextField { let l = NSTextField(labelWithString: t); l.font = .boldSystemFont(ofSize: 12); l.textColor = .secondaryLabelColor; return l }

    private func check(_ title: String, _ key: ReferenceWritableKeyPath<Settings, Bool>) -> NSButton {
        let b = NSButton(checkboxWithTitle: title, target: nil, action: nil)
        b.state = s[keyPath: key] ? .on : .off
        let box = KeyBox(key); box.owner = self
        objc_setAssociatedObject(b, &Self.boxKey, box, .OBJC_ASSOCIATION_RETAIN)
        b.target = box; b.action = #selector(KeyBox.toggled(_:))
        return b
    }
    private static var boxKey = 0

    private final class KeyBox: NSObject {
        let key: ReferenceWritableKeyPath<Settings, Bool>
        weak var owner: SettingsWindowController?
        init(_ k: ReferenceWritableKeyPath<Settings, Bool>) { key = k }
        @objc func toggled(_ b: NSButton) { Settings.shared[keyPath: key] = b.state == .on }
    }

    private func fontRow(_ role: FontRole, _ title: String) -> NSStackView {
        let name = NSTextField(labelWithString: ""); labels[role] = name
        name.lineBreakMode = .byTruncatingTail; name.widthAnchor.constraint(equalToConstant: 190).isActive = true
        let choose = NSButton(title: "Choose…", target: self, action: #selector(chooseFont(_:))); choose.tag = role == .body ? 0 : role == .heading ? 1 : 2
        let reset = NSButton(title: "System", target: self, action: #selector(resetFont(_:))); reset.tag = choose.tag
        return row(title, name, choose, reset)
    }

    private func build() {
        sizeField = NSTextField(string: ""); sizeField.widthAnchor.constraint(equalToConstant: 48).isActive = true
        sizeField.target = self; sizeField.action = #selector(sizeEdited(_:))
        sizeStepper = NSStepper(); sizeStepper.minValue = 9; sizeStepper.maxValue = 48; sizeStepper.increment = 1; sizeStepper.target = self; sizeStepper.action = #selector(sizeStepped(_:))
        lineSlider = NSSlider(value: Double(s.lineHeight), minValue: 1.0, maxValue: 2.4, target: self, action: #selector(lineChanged(_:))); lineSlider.widthAnchor.constraint(equalToConstant: 200).isActive = true
        measureSlider = NSSlider(value: Double(s.measure), minValue: 360, maxValue: 1600, target: self, action: #selector(measureChanged(_:))); measureSlider.widthAnchor.constraint(equalToConstant: 200).isActive = true
        assetsField = NSTextField(string: s.imageAssetsFolder); assetsField.widthAnchor.constraint(equalToConstant: 160).isActive = true
        assetsField.target = self; assetsField.action = #selector(assetsEdited(_:))

        let reset = NSButton(title: "Reset All Settings", target: self, action: #selector(resetAll(_:)))
        let clear = NSButton(title: "Clear Cached Images and Diagrams", target: self, action: #selector(clearCaches(_:)))
        func caption(_ text: String) -> NSTextField {
            let l = NSTextField(wrappingLabelWithString: text)
            l.font = .systemFont(ofSize: 13); l.textColor = .secondaryLabelColor
            l.preferredMaxLayoutWidth = 330
            return l
        }
        func advanced(_ button: NSButton, _ note: String) -> NSStackView {
            let col = NSStackView(views: [button, caption(note)]); col.orientation = .vertical; col.alignment = .leading; col.spacing = 4
            return row("", col)
        }
        let stack = NSStackView(views: [
            heading("FONTS"),
            fontRow(.body, "Body"), fontRow(.heading, "Headings"), fontRow(.code, "Code"),
            row("Size", sizeField, sizeStepper),
            row("Line height", lineSlider), row("Column width", measureSlider),
            heading("BEHAVIOR"),
            row("", check("Continue lists when pressing Return", \.autoContinueLists)),
            row("", check("Smart pairs: wrap selections, close brackets", \.smartPairs)),
            row("", check("Open links with a click (⌘-click always opens)", \.openLinksOnClick)),
            heading("CONTENT"),
            row("", check("Show front-matter", \.showFrontMatter)),
            row("", check("Load remote images", \.allowRemoteImages)),
            row("Image folder", assetsField),
            heading("ADVANCED"),
            advanced(clear, "Frees decoded images, rendered math and diagrams. They load again when a document needs them."),
            advanced(reset, "Puts fonts, sizes and every option on this page back to their defaults."),
        ])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        // The stack lives inside a container with explicit margins: as the content view itself nothing kept it off the window edge.
        let container = NSView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Self.margin),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Self.margin),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -22),
        ])
        window?.contentView = container
        refresh()
        container.layoutSubtreeIfNeeded()
        window?.setContentSize(container.fittingSize)
        window?.makeFirstResponder(nil)                      // do not start with the size field focused
    }

    static let margin: CGFloat = 32

    @objc private func refresh() {
        func name(_ f: String?) -> String { f ?? "System" }
        labels[.body]?.stringValue = name(s.bodyFamily)
        labels[.heading]?.stringValue = s.headingFamily.map { $0 } ?? (s.bodyFamily.map { "\($0) (body)" } ?? "System")
        labels[.code]?.stringValue = name(s.codeFamily)
        sizeField.stringValue = String(format: "%.0f", s.bodySize); sizeStepper.doubleValue = Double(s.bodySize)
        lineSlider.doubleValue = Double(s.lineHeight); measureSlider.doubleValue = Double(s.measure)
    }

    @objc private func chooseFont(_ b: NSButton) {
        fontRole = b.tag == 0 ? .body : b.tag == 1 ? .heading : .code
        let fm = NSFontManager.shared
        fm.target = self
        panelOwned = false                                   // opening the panel and seeding it must not write settings
        fm.setSelectedFont(s.font(fontRole, size: s.bodySize), isMultiple: false)
        NSFontPanel.shared.makeKeyAndOrderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.panelOwned = true }
    }

    func changeFont(_ sender: NSFontManager?) {
        guard let fm = sender, panelOwned else { return }
        let f = fm.convert(s.font(fontRole, size: s.bodySize))
        let family = f.familyName
        switch fontRole {
        case .body: s.bodyFamily = family; s.bodySize = f.pointSize
        case .heading: s.headingFamily = family
        case .code: s.codeFamily = family
        }
    }

    @objc private func resetFont(_ b: NSButton) {
        switch b.tag { case 0: s.bodyFamily = nil; case 1: s.headingFamily = nil; default: s.codeFamily = nil }
    }
    @objc private func sizeEdited(_ f: NSTextField) { s.bodySize = CGFloat(f.doubleValue) }
    @objc private func sizeStepped(_ st: NSStepper) { s.bodySize = CGFloat(st.doubleValue) }
    @objc private func lineChanged(_ sl: NSSlider) { s.lineHeight = CGFloat(sl.doubleValue) }
    @objc private func measureChanged(_ sl: NSSlider) { s.measure = CGFloat(sl.doubleValue) }
    @objc private func assetsEdited(_ f: NSTextField) { s.imageAssetsFolder = f.stringValue }
    @objc private func clearCaches(_ b: NSButton) {
        MemoryPressure.shared.purge()
        let old = b.title
        b.title = "Cleared"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { b.title = old }
    }

    @objc private func resetAll(_ b: NSButton) {
        s.resetAll()
        // checkboxes are rebuilt from the defaults
        build()
    }
}

/// For the layout check in the bench: the Settings window without showing it.
@MainActor
public func makeSettingsWindowForTesting() -> NSWindow { SettingsWindowController().window! }
