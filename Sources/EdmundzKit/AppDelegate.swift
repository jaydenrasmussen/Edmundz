import AppKit
#if DIRECT
import Sparkle
#endif

public final class AppDelegate: NSObject, NSApplicationDelegate {
    private var settingsController: SettingsWindowController?
    private var helpPanels: [String: NSPanel] = [:]
    #if DIRECT
    // Not started automatically: it starts only once a real feed URL and EdDSA key are configured in Info.plist.
    private let updater = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
    private var updaterStarted = false
    private var updatesConfigured: Bool {
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? ""
        return !key.isEmpty && !key.hasPrefix("REPLACE") && !feed.isEmpty && !feed.contains("example.com")
    }
    #endif

    public func applicationDidFinishLaunching(_ notification: Notification) {
        MenuBuilder.install(appName: "Edmundz", delegate: self)
        MemoryPressure.shared.start()
        FolderAccess.restore()
        UserDefaults.standard.removeObject(forKey: "NSWindow Frame EdmundzEditor")   // frame saved by an earlier build
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.noticeMissingFonts() }
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    public func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    private func noticeMissingFonts() {
        let missing = Settings.shared.missingFamilies
        guard !missing.isEmpty, !UserDefaults.standard.bool(forKey: "missingFontNoticeShown") else { return }
        UserDefaults.standard.set(true, forKey: "missingFontNoticeShown")
        let a = NSAlert()
        a.messageText = "A saved font is not installed"
        a.informativeText = "\(missing.sorted().joined(separator: ", ")) is not available on this Mac, so the system font is used instead. You can choose another in Settings."
        a.addButton(withTitle: "Open Settings"); a.addButton(withTitle: "OK")
        if a.runModal() == .alertFirstButtonReturn { showSettings(nil) }
    }

    // MARK: actions

    @objc func showAbout(_ sender: Any?) {
        var credits = "Edmundz renders Markdown while you edit it.\n\nThird-party software:\n\n"
        credits += Resources.string("licenses/THIRD-PARTY.txt") ?? ""
        let style = NSMutableParagraphStyle(); style.lineSpacing = 2
        let att = NSAttributedString(string: credits, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor, .paragraphStyle: style])
        NSApp.orderFrontStandardAboutPanel(options: [.credits: att, .applicationName: "Edmundz"])
    }

    @objc func showSettings(_ sender: Any?) {
        if settingsController == nil { settingsController = SettingsWindowController() }
        settingsController?.showWindow(nil)
        settingsController?.window?.makeKeyAndOrderFront(nil)
    }

    @objc func increaseFontSize(_ sender: Any?) { Settings.shared.bodySize += 1 }
    @objc func decreaseFontSize(_ sender: Any?) { Settings.shared.bodySize -= 1 }
    @objc func resetFontSize(_ sender: Any?) { Settings.shared.bodySize = 16 }

    @objc func showShortcuts(_ sender: Any?) { showHelp("Keyboard Shortcuts", ShortcutTable.helpText()) }

    @objc func showLatexHelp(_ sender: Any?) {
        showHelp("Supported LaTeX", """
        Inline math: $a^2 + b^2 = c^2$   Display math: $$ \\int_0^1 x\\,dx $$ or a block fenced by $$ lines.

        Edmundz draws most LaTeX natively: fractions, roots, sums, integrals, limits, Greek letters, matrices (pmatrix, bmatrix,
        vmatrix, cases), aligned, \\left \\right, accents, \\mathbb \\mathcal \\mathbf, \\text, \\binom and more.
        \\dfrac, align*, \\operatorname, \\pmod and a few others are translated automatically.

        Anything else (for example \\underbrace, \\substack, \\cancel, \\xrightarrow, array, \\tag, \\newcommand, \\ce)
        is drawn with KaTeX, which starts in the background only when needed.

        Not supported: full LaTeX documents, TikZ, and packages. An expression that cannot be drawn shows a red error box
        with its source. Currency such as $5 and $10 is not treated as math.
        """)
    }

    #if DIRECT
    @objc func checkForUpdates(_ sender: Any?) {
        guard updatesConfigured else {
            let a = NSAlert()
            a.messageText = "Updates are not configured in this build"
            a.informativeText = "Set SUFeedURL and SUPublicEDKey in Info.plist (see scripts/bundle.sh) to enable updates."
            a.runModal(); return
        }
        if !updaterStarted { updater.startUpdater(); updaterStarted = true }
        updater.checkForUpdates(sender)
    }
    #endif

    private func showHelp(_ title: String, _ text: String) {
        if let p = helpPanels[title] { p.makeKeyAndOrderFront(nil); return }
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 520), styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
        p.title = title; p.isReleasedWhenClosed = false
        let sv = NSScrollView(frame: p.contentView!.bounds); sv.autoresizingMask = [.width, .height]; sv.hasVerticalScroller = true
        let tv = NSTextView(frame: sv.bounds); tv.isEditable = false; tv.autoresizingMask = [.width]; tv.textContainerInset = NSSize(width: 16, height: 14)
        tv.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular); tv.string = text
        sv.documentView = tv; p.contentView?.addSubview(sv)
        p.center(); p.makeKeyAndOrderFront(nil)
        helpPanels[title] = p
    }
}

/// Entry point used by the executable target.
@MainActor
public func runEdmundz() {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    _ = NSDocumentController.shared
    app.run()
}
