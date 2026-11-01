import AppKit
import EdmundzCore

/// One Markdown file. The text lives in the editor's storage while the document is open; saving an untouched document
/// returns the original bytes (front-matter, line endings, trailing newline and BOM all survive).
@objc(EdmundzMarkdownDocument)
public final class MarkdownDocument: NSDocument {
    public private(set) var coordinator: EditorCoordinator?
    private var loadedText = ""
    private var originalData: Data?
    private var originalText: String?
    private var encoding: String.Encoding = .utf8
    private var hasBOM = false
    private var usesCRLF = false

    public override class var autosavesInPlace: Bool { true }
    public override class func canConcurrentlyReadDocuments(ofType typeName: String) -> Bool { true }
    public override var isEntireFileLoaded: Bool { true }

    // MARK: reading and writing

    public override func read(from data: Data, ofType typeName: String) throws {
        originalData = data
        var body = data
        hasBOM = data.starts(with: [0xEF, 0xBB, 0xBF])
        if hasBOM { body = data.dropFirst(3) }
        if let s = String(data: body, encoding: .utf8) { loadedText = s; encoding = .utf8 }
        else if let s = String(data: body, encoding: .windowsCP1252) { loadedText = s; encoding = .windowsCP1252 }
        else if let s = String(data: body, encoding: .isoLatin1) { loadedText = s; encoding = .isoLatin1 }
        else { throw CocoaError(.fileReadInapplicableStringEncoding) }
        usesCRLF = loadedText.contains("\r\n") && !loadedText.replacingOccurrences(of: "\r\n", with: "").contains("\n")
        originalText = loadedText
        coordinator?.setText(loadedText)   // revert while open
    }

    public override func data(ofType typeName: String) throws -> Data {
        let current = coordinator?.string ?? loadedText
        if current == originalText, let d = originalData { return d }
        var s = current
        if usesCRLF { s = s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n") }
        var out = Data()
        if hasBOM { out.append(contentsOf: [0xEF, 0xBB, 0xBF]) }
        out.append(s.data(using: encoding, allowLossyConversion: false) ?? Data(s.utf8))
        originalData = out; originalText = current
        return out
    }

    // MARK: windows

    public override func makeWindowControllers() {
        let c = EditorCoordinator(text: loadedText, documentURL: fileURL, interacted: fileURL == nil)
        c.document = self
        coordinator = c
        addWindowController(EditorWindowController(coordinator: c))
    }

    public override var fileURL: URL? {
        didSet {
            coordinator?.styler.documentURL = fileURL; coordinator?.reloadStyles()
            if fileURL != oldValue { startWatching() }
        }
    }

    // MARK: external changes: reload silently when clean, ask when there are unsaved edits

    private var watcher: FileWatcher?
    private var askedAbout: Data?

    private func startWatching() {
        watcher?.stop(); watcher = nil
        guard let url = fileURL else { return }
        watcher = FileWatcher(url: url) { [weak self] in self?.fileChangedOnDisk() }
    }

    private func fileChangedOnDisk() {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return }
        if data == originalData { return }                 // our own save, or no real change
        if !isDocumentEdited {
            try? read(from: data, ofType: fileType ?? "net.daringfireball.markdown")
            fileModificationDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            updateChangeCount(.changeCleared)
            return
        }
        guard askedAbout != data, let win = windowControllers.first?.window else { return }
        askedAbout = data
        let alert = NSAlert()
        alert.messageText = "“\(displayName)” changed on disk"
        alert.informativeText = "You have unsaved changes. Reloading discards them."
        alert.addButton(withTitle: "Keep My Version")
        alert.addButton(withTitle: "Reload from Disk")
        alert.beginSheetModal(for: win) { [weak self] resp in
            guard resp == .alertSecondButtonReturn, let self else { return }
            try? self.read(from: data, ofType: self.fileType ?? "net.daringfireball.markdown")
            self.fileModificationDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            self.updateChangeCount(.changeCleared)
        }
    }

    // MARK: front-matter title

    public var frontMatterTitle: String? {
        guard let t = coordinator?.string, t.hasPrefix("---") else { return nil }
        return FrontMatter.parse(t)?.title
    }

    // MARK: printing and export

    public override func printOperation(withSettings printSettings: [NSPrintInfo.AttributeKey: Any]) throws -> NSPrintOperation {
        guard let tv = coordinator?.textView else { throw CocoaError(.fileWriteUnknown) }
        let info = (printInfo.copy() as! NSPrintInfo)
        info.dictionary().addEntries(from: printSettings.reduce(into: [:]) { $0[$1.key.rawValue] = $1.value })
        info.horizontalPagination = .fit
        info.isVerticallyCentered = false
        let op = NSPrintOperation(view: tv, printInfo: info)
        op.showsPrintPanel = true
        return op
    }

    @objc public func exportPDF(_ sender: Any?) {
        guard let tv = coordinator?.textView, let win = windowControllers.first?.window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = (displayName as NSString).deletingPathExtension + ".pdf"
        panel.beginSheetModal(for: win) { [weak self] resp in
            guard resp == .OK, let url = panel.url, let self else { return }
            let info = self.printInfo.copy() as! NSPrintInfo
            info.horizontalPagination = .fit
            info.jobDisposition = .save
            info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
            let op = NSPrintOperation(view: tv, printInfo: info)
            op.showsPrintPanel = false; op.showsProgressPanel = true
            op.run()
        }
    }

    @objc public func exportHTML(_ sender: Any?) {
        guard let win = windowControllers.first?.window, let md = coordinator?.string else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.html]
        panel.nameFieldStringValue = (displayName as NSString).deletingPathExtension + ".html"
        panel.beginSheetModal(for: win) { resp in
            guard resp == .OK, let url = panel.url else { return }
            let html = HTMLExport.page(markdown: md, title: self.frontMatterTitle ?? (self.displayName as NSString).deletingPathExtension)
            try? html.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

// MARK: window

public final class EditorContentController: NSViewController {
    let coordinator: EditorCoordinator
    public init(coordinator: EditorCoordinator) { self.coordinator = coordinator; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }
    static let defaultSize = NSSize(width: 980, height: 820)
    public override func loadView() {
        // an explicit size: the window takes its content size from this view when the controller is installed
        coordinator.scrollView.frame = NSRect(origin: .zero, size: Self.defaultSize)
        view = coordinator.scrollView
        preferredContentSize = Self.defaultSize
    }
    public override func viewDidAppear() { super.viewDidAppear(); view.window?.makeFirstResponder(coordinator.textView) }

    public override func encodeRestorableState(with coder: NSCoder) {
        super.encodeRestorableState(with: coder)
        coder.encode(coordinator.textView.selectedRange().location, forKey: "caret")
        coder.encode(Double(coordinator.scrollView.contentView.bounds.origin.y), forKey: "scrollY")
    }

    public override func restoreState(with coder: NSCoder) {
        super.restoreState(with: coder)
        let caret = coder.decodeInteger(forKey: "caret")
        let y = coder.decodeDouble(forKey: "scrollY")
        let len = (coordinator.textView.string as NSString).length
        coordinator.textView.setSelectedRange(NSRange(location: min(max(caret, 0), len), length: 0))
        coordinator.scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
        coordinator.scrollView.reflectScrolledClipView(coordinator.scrollView.contentView)
    }
}

public final class EditorWindowController: NSWindowController {
    init(coordinator: EditorCoordinator) {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 820),
                           styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false   // ARC owns the window; the AppKit default (true) double-releases it on close
        win.tabbingMode = .preferred
        win.tabbingIdentifier = "edmundz"
        win.isRestorable = true
        win.minSize = NSSize(width: 480, height: 320)
        win.contentViewController = EditorContentController(coordinator: coordinator)
        win.setContentSize(EditorContentController.defaultSize)
        if !win.setFrameUsingName("EdmundzEditorFrame") { win.center() }
        // never reuse a collapsed frame saved by an older build
        if win.frame.width < 480 || win.frame.height < 320 { win.setContentSize(EditorContentController.defaultSize); win.center() }
        win.setFrameAutosaveName("EdmundzEditorFrame")
        super.init(window: win)
        shouldCascadeWindows = true
    }
    required init?(coder: NSCoder) { fatalError() }

    public override func windowTitle(forDocumentDisplayName displayName: String) -> String {
        (document as? MarkdownDocument)?.frontMatterTitle ?? displayName
    }
}
