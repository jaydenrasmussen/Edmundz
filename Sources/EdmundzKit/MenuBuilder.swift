import AppKit

enum MenuBuilder {
    @MainActor
    static func install(appName: String, delegate: AppDelegate) {
        let main = NSMenu()
        NSApp.mainMenu = main

        func item(_ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = [.command], target: AnyObject? = nil, tag: Int = 0) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = key.isEmpty ? [] : mods
            i.target = target; i.tag = tag
            return i
        }
        func add(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
            let m = NSMenu(title: title)
            items.forEach { m.addItem($0) }
            let top = NSMenuItem(title: title, action: nil, keyEquivalent: ""); top.submenu = m
            main.addItem(top)
            return m
        }

        // App
        let services = NSMenu(title: "Services"); NSApp.servicesMenu = services
        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: ""); servicesItem.submenu = services
        var appItems: [NSMenuItem] = [
            item("About \(appName)", #selector(AppDelegate.showAbout(_:)), target: delegate),
        ]
        #if DIRECT
        appItems.append(item("Check for Updates…", #selector(AppDelegate.checkForUpdates(_:)), target: delegate))
        #endif
        appItems += [.separator(),
            item("Settings…", #selector(AppDelegate.showSettings(_:)), ",", target: delegate), .separator(),
            servicesItem, .separator(),
            item("Hide \(appName)", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:))), .separator(),
            item("Quit \(appName)", #selector(NSApplication.terminate(_:)), "q"),
        ]
        _ = add(appName, appItems)

        // File
        let recent = NSMenu(title: "Open Recent")
        recent.addItem(item("Clear Menu", #selector(NSDocumentController.clearRecentDocuments(_:))))
        let recentItem = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: ""); recentItem.submenu = recent
        _ = add("File", [
            item("New", #selector(NSDocumentController.newDocument(_:)), "n"),
            item("Open…", #selector(NSDocumentController.openDocument(_:)), "o"),
            recentItem, .separator(),
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
            item("Save", #selector(NSDocument.save(_:)), "s"),
            item("Save As…", #selector(NSDocument.saveAs(_:)), "s", [.command, .shift]),
            item("Revert to Saved", #selector(NSDocument.revertToSaved(_:))), .separator(),
            item("Export as PDF…", #selector(MarkdownDocument.exportPDF(_:)), "e", [.command, .shift]),
            item("Export as HTML…", #selector(MarkdownDocument.exportHTML(_:))), .separator(),
            item("Page Setup…", #selector(NSDocument.runPageLayout(_:)), "p", [.command, .shift]),
            item("Print…", #selector(NSDocument.printDocument(_:)), "p"),
        ])

        // Edit
        let find = NSMenu(title: "Find")
        for (t, k, m, tag) in [("Find…", "f", NSEvent.ModifierFlags.command, 1), ("Find and Replace…", "f", [.command, .option], 12), ("Find Next", "g", .command, 2),
                               ("Find Previous", "g", [.command, .shift], 3), ("Use Selection for Find", "e", .command, 7)] as [(String, String, NSEvent.ModifierFlags, Int)] {
            find.addItem(item(t, #selector(NSResponder.performTextFinderAction(_:)), k, m, tag: tag))
        }
        let findItem = NSMenuItem(title: "Find", action: nil, keyEquivalent: ""); findItem.submenu = find
        let spelling = NSMenu(title: "Spelling")
        spelling.addItem(item("Check Spelling While Typing", #selector(NSTextView.toggleContinuousSpellChecking(_:))))
        spelling.addItem(item("Show Spelling and Grammar", #selector(NSText.showGuessPanel(_:)), ":"))
        let spellItem = NSMenuItem(title: "Spelling", action: nil, keyEquivalent: ""); spellItem.submenu = spelling
        _ = add("Edit", [
            item("Undo", Selector(("undo:")), "z"), item("Redo", Selector(("redo:")), "z", [.command, .shift]), .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"), item("Copy", #selector(NSText.copy(_:)), "c"), item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"), .separator(), findItem, spellItem,
        ])

        // Format: generated from the shortcut table
        var fmt: [NSMenuItem] = []
        var last = ""
        for s in ShortcutTable.format {
            if s.group != last, !last.isEmpty { fmt.append(.separator()) }
            last = s.group
            let it = NSMenuItem(title: s.title, action: s.action, keyEquivalent: s.key)
            it.keyEquivalentModifierMask = s.modifiers; it.tag = s.tag
            fmt.append(it)
        }
        _ = add("Format", fmt)

        // View
        _ = add("View", [
            item("Larger Text", #selector(AppDelegate.increaseFontSize(_:)), "+", target: delegate),
            item("Smaller Text", #selector(AppDelegate.decreaseFontSize(_:)), "-", target: delegate),
            item("Actual Size", #selector(AppDelegate.resetFontSize(_:)), "0", [.command, .option], target: delegate), .separator(),
            item("Show Tab Bar", #selector(NSWindow.toggleTabBar(_:))), item("Show All Tabs", #selector(NSWindow.toggleTabOverview(_:))), .separator(),
            item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ])

        // Window
        let win = add("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:))), .separator(),
            item("Show Previous Tab", #selector(NSWindow.selectPreviousTab(_:)), "[", [.command, .shift]),
            item("Show Next Tab", #selector(NSWindow.selectNextTab(_:)), "]", [.command, .shift]),
            item("Move Tab to New Window", #selector(NSWindow.moveTabToNewWindow(_:))),
            item("Merge All Windows", #selector(NSWindow.mergeAllWindows(_:))), .separator(),
            item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))),
        ])
        NSApp.windowsMenu = win

        // Help
        let help = add("Help", [
            item("Keyboard Shortcuts", #selector(AppDelegate.showShortcuts(_:)), "?", [.command], target: delegate),
            item("Supported LaTeX", #selector(AppDelegate.showLatexHelp(_:)), target: delegate),
        ])
        NSApp.helpMenu = help
    }
}
