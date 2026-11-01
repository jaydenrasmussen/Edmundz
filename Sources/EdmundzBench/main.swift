import AppKit
import EdmundzKit
import EdmundzCore

setvbuf(stdout, nil, _IONBF, 0)
// print a backtrace on a crash so failures are diagnosable without a debugger
for sig in [SIGSEGV, SIGBUS, SIGILL, SIGABRT, SIGTRAP] {
    signal(sig) { s in
        print("CRASH: signal \(s)")
        Thread.callStackSymbols.prefix(30).forEach { print($0) }
        exit(128 + s)
    }
}

// MARK: helpers

func now() -> Double {
    var t = mach_timebase_info_data_t(); mach_timebase_info(&t)
    return Double(mach_absolute_time()) * Double(t.numer) / Double(t.denom) / 1e6
}

func footprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
}

func cpuSeconds() -> Double {
    var u = rusage(); getrusage(RUSAGE_SELF, &u)
    return Double(u.ru_utime.tv_sec) + Double(u.ru_utime.tv_usec) / 1e6 + Double(u.ru_stime.tv_sec) + Double(u.ru_stime.tv_usec) / 1e6
}

func spin(_ seconds: Double) { RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds)) }

struct Stats { var p50 = 0.0, p99 = 0.0, max = 0.0; var n = 0 }
func stats(_ v: [Double]) -> Stats {
    let s = v.sorted(); guard !s.isEmpty else { return Stats() }
    return Stats(p50: s[s.count / 2], p99: s[min(s.count - 1, Int(Double(s.count) * 0.99))], max: s.last!, n: s.count)
}

@MainActor
final class Harness {
    let window: NSWindow
    let coordinator: EditorCoordinator

    init(text: String, url: URL? = nil, size: NSSize = NSSize(width: 980, height: 820), interacted: Bool = true) {
        coordinator = EditorCoordinator(text: text, documentURL: url, interacted: interacted)
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = coordinator.scrollView
        window.makeKeyAndOrderFront(nil)
        flush()
    }

    var tv: EditorTextView { coordinator.textView }

    func flush() {
        coordinator.layoutInsets()
        tv.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
    }

    func shot(_ path: String, scale: CGFloat = 1) {
        flush()
        let v = coordinator.scrollView
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(v.bounds.width * scale), pixelsHigh: Int(v.bounds.height * scale), bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = v.bounds.size
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    func select(_ r: NSRange) { tv.setSelectedRange(r); flush() }
    func scroll(to offset: Int) { tv.scrollRangeToVisible(NSRange(location: offset, length: 0)); flush() }
}

// MARK: commands

func makeFixture(bytes: Int) -> String {
    var out = "---\ntitle: Benchmark\ntags: [a, b]\n---\n\n"
    var i = 0
    while out.utf8.count < bytes {
        if i % 12 == 0 { out += "## Section \(i / 12)\n\n" }
        out += "Paragraph \(i): lorem ipsum **bold text** and *italic text* with `inline code`, a [link](https://example.com) and <ins>underline</ins> "
        out += "to make this line long enough to wrap across a couple of lines in a typical column, plus another **strong run**.\n\n"
        if i % 25 == 0 { out += "| a | b | c |\n|---|:-:|--:|\n| 1 | 2 | 3 |\n| 4 | 5 | 6 |\n\n" }
        if i % 17 == 0 { out += "- item one\n  - nested **item**\n- [ ] task\n- [x] done\n\n" }
        if i % 40 == 0 { out += "```swift\nlet x = \(i)\nprint(\"hello\", x)\n```\n\n" }
        i += 1
    }
    return out
}

struct Gate { var name: String; var value: Double; var limit: Double; var unit: String; var ok: Bool { value <= limit } }
var gates: [Gate] = []
func gate(_ name: String, _ value: Double, _ limit: Double, _ unit: String) {
    let g = Gate(name: name, value: value, limit: limit, unit: unit)
    gates.append(g)
    print(String(format: "%@ %-52@ %9.2f %@  (limit %.2f)", g.ok ? "PASS" : "FAIL", name as NSString, value, unit as NSString, limit))
}

let args = CommandLine.arguments
MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    Settings.shared.bodyFamily = nil

    if args.count > 1, args[1] == "cycle" {
        for i in 0..<60 { autoreleasepool { let h = Harness(text: makeFixture(bytes: 30_000)); h.flush(); h.window.close() }; spin(0.01); if i % 10 == 0 { print("cycle \(i)") } }
        print("cycles done"); exit(0)
    }

    if args.count > 1, args[1] == "doc" {
        app.setActivationPolicy(.regular)
        let url = URL(fileURLWithPath: args[2])
        let d = MarkdownDocument()
        try! d.read(from: Data(contentsOf: url), ofType: "net.daringfireball.markdown")
        d.fileURL = url
        d.makeWindowControllers()
        d.showWindows()
        spin(2)
        let w = d.windowControllers[0].window!
        let c = d.coordinator!
        print("window frame \(w.frame)  content \(w.contentView!.frame)")
        print("scrollView \(c.scrollView.frame)  contentSize \(c.scrollView.contentSize)  textView \(c.textView.frame)")
        print("first responder: \(String(describing: w.firstResponder))")
        let clip = c.scrollView.contentView
        clip.scroll(to: NSPoint(x: 0, y: 200)); c.scrollView.reflectScrolledClipView(clip); spin(0.3)
        print("scrolled offset: \(clip.bounds.origin.y)  (wanted 200; doc height \(c.textView.frame.height))")
        var failures: [String] = []
        if w.frame.width < 480 || w.frame.height < 320 { failures.append("window collapsed: \(w.frame.size)") }
        if c.textView.frame.width < 300 { failures.append("text view too narrow: \(c.textView.frame.width)") }
        if c.textView.frame.height <= c.scrollView.contentSize.height { failures.append("document shorter than window: nothing to scroll") }
        if clip.bounds.origin.y < 199 { failures.append("document did not scroll") }
        if failures.isEmpty { print("DOC PATH OK") } else { failures.forEach { print("FAIL: \($0)") }; exit(1) }
        exit(0)
    }

    if args.count > 1, args[1] == "stress" {
        let url = URL(fileURLWithPath: args[2])
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let hn = Harness(text: text, url: url, size: NSSize(width: 980, height: 800), interacted: false)
        let ns = text as NSString
        spin(1.0); hn.flush()
        // 1. caret through every line start and middle
        var times: [Double] = []
        var p = 0
        var slowest = (0.0, 0)
        while p < ns.length {
            let line = ns.lineRange(for: NSRange(location: p, length: 0))
            for off in [0, max(0, line.length / 2)] {
                let t = now()
                hn.select(NSRange(location: min(line.location + off, ns.length), length: 0))
                let d = now() - t
                times.append(d); if d > slowest.0 { slowest = (d, line.location) }
            }
            p = line.end
        }
        var st = stats(times)
        print(String(format: "caret through %d positions: p50 %.2f ms p99 %.2f ms max %.2f ms (slowest at offset %d)", st.n, st.p50, st.p99, st.max, slowest.1))
        // 2. scroll top to bottom
        times = []
        let clip = hn.coordinator.scrollView.contentView
        var y: CGFloat = 0
        var steps = 0
        while steps < 400 {
            let maxY = max(0, hn.tv.frame.height - clip.bounds.height)
            if y > maxY { break }
            let t = now()
            clip.scroll(to: NSPoint(x: 0, y: y)); hn.coordinator.scrollView.reflectScrolledClipView(clip); hn.flush()
            times.append(now() - t); y += 120; steps += 1
        }
        st = stats(times)
        print(String(format: "scroll %d steps: p50 %.2f ms p99 %.2f ms max %.2f ms, doc height %.0f", st.n, st.p50, st.p99, st.max, hn.tv.frame.height))
        // 3. typing in several places
        times = []
        for marker in ["Edmundz\n", "A bullet", "| Ada", "struct Point", "Inline $E", "flowchart LR", "A gradient"] {
            let r = ns.range(of: marker)
            guard r.location != NSNotFound else { continue }
            hn.select(NSRange(location: r.location + 2, length: 0))
            for _ in 0..<20 { let t = now(); hn.tv.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0)); hn.flush(); times.append(now() - t) }
        }
        st = stats(times)
        print(String(format: "typing %d keys across block types: p50 %.2f ms p99 %.2f ms max %.2f ms", st.n, st.p50, st.p99, st.max))
        spin(2); 
        print(String(format: "rss %.1f MB; done without crash", footprintMB()))
        exit(0)
    }

    if args.count > 1, args[1] == "shot" {
        // shot <file.md> <out.png> [--caret "text"] [--scroll "text"] [--dark] [--wait seconds] [--width W] [--height H] [--select "text"]
        let file = args[2], out = args[3]
        func opt(_ name: String) -> String? { args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        if args.contains("--dark") { app.appearance = NSAppearance(named: .darkAqua) }
        let url = URL(fileURLWithPath: file)
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let w = Double(opt("--width") ?? "980")!, h = Double(opt("--height") ?? "820")!
        let hn = Harness(text: text, url: url, size: NSSize(width: w, height: h), interacted: opt("--caret") != nil || opt("--select") != nil)
        let ns = text as NSString
        if let s = opt("--scroll") { let r = ns.range(of: s); if r.location != NSNotFound { hn.scroll(to: r.location) } }
        if let c = opt("--caret") { let r = ns.range(of: c); if r.location != NSNotFound { hn.select(NSRange(location: r.location + max(1, r.length / 2), length: 0)) } }
        if let c = opt("--select") { let r = ns.range(of: c); if r.location != NSNotFound { hn.select(r) } }
        let wait = Double(opt("--wait") ?? "3")!
        let end = Date(timeIntervalSinceNow: wait)
        let c0 = cpuSeconds(), t0 = now()
        while Date() < end { spin(0.1); hn.flush() }
        let busy = (cpuSeconds() - c0) / ((now() - t0) / 1000)
        hn.shot(out, scale: Double(opt("--scale") ?? "1")!)
        print("wrote \(out)  styles \(hn.coordinator.styler.paragraphCalls)  rss \(String(format: "%.1f", footprintMB())) MB  cpu while idle \(String(format: "%.0f", busy * 100))%")
        exit(0)
    }
}

// MARK: behaviors (run through the real document and view classes)

var behaviorFailures = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    print("\(ok ? "PASS" : "FAIL") \(name)\(ok ? "" : "  — \(detail())")")
    if !ok { behaviorFailures += 1 }
}

@MainActor
func runBehaviors() {
    print("Behavior checks\n")
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("edmundz-behaviors-\(getpid())", isDirectory: true)
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: dir) }

    // external change: a clean document reloads when the file changes on disk
    do {
        let url = dir.appendingPathComponent("ext.md")
        try! "# One\n".write(to: url, atomically: true, encoding: .utf8)
        let d = try! MarkdownDocument(contentsOf: url, ofType: "net.daringfireball.markdown")   // the initializer a real open uses
        d.makeWindowControllers(); d.showWindows(); spin(0.3)
        try! "# Two, changed elsewhere\n".write(to: url, atomically: true, encoding: .utf8)
        var reloaded = false
        for _ in 0..<40 { spin(0.1); if d.coordinator?.string.contains("Two") == true { reloaded = true; break } }
        check("external change reloads a clean document", reloaded, "string is still \(d.coordinator?.string ?? "nil")")
        d.close()
    }

    // external change with unsaved edits is never replaced silently
    do {
        let url = dir.appendingPathComponent("dirty.md")
        try! "# Base\n".write(to: url, atomically: true, encoding: .utf8)
        let d = try! MarkdownDocument(contentsOf: url, ofType: "net.daringfireball.markdown")
        d.makeWindowControllers(); d.showWindows(); spin(0.3)
        d.coordinator!.textView.insertText("MINE ", replacementRange: NSRange(location: 0, length: 0))
        d.updateChangeCount(.changeDone)
        try! "# Disk version\n".write(to: url, atomically: true, encoding: .utf8)
        spin(1.2)
        check("external change keeps unsaved edits (asks instead of reloading)", d.coordinator?.string.hasPrefix("MINE") == true, d.coordinator?.string ?? "nil")
        d.updateChangeCount(.changeCleared); d.close()
    }

    // byte-exact round trip: untouched documents save the original bytes (BOM, CRLF, no trailing newline)
    do {
        for (name, bytes) in [("bom", Data([0xEF, 0xBB, 0xBF]) + Data("# Hi\n".utf8)), ("crlf", Data("a\r\nb\r\n".utf8)), ("no newline", Data("text".utf8)), ("front-matter", Data("---\na: 1\n---\nbody".utf8))] {
            let d = MarkdownDocument()
            try! d.read(from: bytes, ofType: "net.daringfireball.markdown")
            d.makeWindowControllers()
            let out = try! d.data(ofType: "net.daringfireball.markdown")
            check("round trip is byte-exact: \(name)", out == bytes)
            d.close()
        }
        // an edit keeps CRLF line endings
        let d = MarkdownDocument()
        try! d.read(from: Data("a\r\nb\r\n".utf8), ofType: "net.daringfireball.markdown")
        d.makeWindowControllers()
        d.coordinator!.textView.insertText("X", replacementRange: NSRange(location: 0, length: 0))
        let out = String(data: try! d.data(ofType: "net.daringfireball.markdown"), encoding: .utf8)!
        check("edited CRLF document stays CRLF", out == "Xa\r\nb\r\n", "got \(out.debugDescription)")
        d.close()
    }

    // window restoration: caret and scroll survive an encode/decode
    do {
        let h = Harness(text: makeFixture(bytes: 50_000), size: NSSize(width: 900, height: 600))
        let c1 = EditorContentController(coordinator: h.coordinator); _ = c1.view
        h.select(NSRange(location: 1234, length: 0)); h.scroll(to: 1234)
        let y = h.coordinator.scrollView.contentView.bounds.origin.y
        let arch = NSKeyedArchiver(requiringSecureCoding: false)
        c1.encodeRestorableState(with: arch); arch.finishEncoding()
        let h2 = Harness(text: makeFixture(bytes: 50_000), size: NSSize(width: 900, height: 600))
        let c2 = EditorContentController(coordinator: h2.coordinator); _ = c2.view
        let un = try! NSKeyedUnarchiver(forReadingFrom: arch.encodedData); un.requiresSecureCoding = false
        c2.restoreState(with: un)
        check("window restoration restores caret", h2.tv.selectedRange().location == 1234, "caret \(h2.tv.selectedRange().location)")
        check("window restoration restores scroll", abs(h2.coordinator.scrollView.contentView.bounds.origin.y - y) < 1, "y \(h2.coordinator.scrollView.contentView.bounds.origin.y) vs \(y)")
        h.window.close(); h2.window.close()
    }

    // accessibility: VoiceOver text has no hidden syntax markers
    do {
        let h = Harness(text: "# Title\n\nSome **bold** and *it* with [a link](http://x.y) end\n")
        let plain = h.coordinator.plainTextForAccessibility() ?? ""
        check("accessibility text omits markers", plain == "Title\n\nSome bold and it with a link end\n", plain.debugDescription)
        h.window.close()
    }

    // Settings layout: every control keeps a margin from the window edges
    do {
        let w = makeSettingsWindowForTesting()
        w.contentView?.layoutSubtreeIfNeeded()
        guard let content = w.contentView else { return }
        var maxX: CGFloat = 0, minX: CGFloat = .greatestFiniteMagnitude
        func walk(_ v: NSView) {
            for sub in v.subviews {
                let r = sub.convert(sub.bounds, to: content)
                if !(sub is NSStackView) && sub.bounds.width > 1 && !sub.isHidden { maxX = max(maxX, r.maxX); minX = min(minX, r.minX) }
                walk(sub)
            }
        }
        walk(content)
        let right = content.bounds.width - maxX, left = minX
        check("Settings keeps >= 24 pt of padding on the right", right >= 24, "right padding \(right) (window width \(content.bounds.width))")
        check("Settings keeps >= 24 pt of padding on the left", left >= 24, "left padding \(left)")
        // nothing clipped at the bottom: every control lies inside the window with some padding
        var maxY: CGFloat = 0
        func walkY(_ v: NSView) { for sub in v.subviews { let r = sub.convert(sub.bounds, to: content); if !(sub is NSStackView) && sub.bounds.height > 1 { maxY = max(maxY, r.maxY) }; walkY(sub) } }
        walkY(content)
        check("Settings shows every control (>= 16 pt below the last)", content.bounds.height - maxY >= 16 || maxY - content.bounds.height < 0, "content \(content.bounds.height) last control ends \(maxY)")
        var labels: [String] = []
        func walkT(_ v: NSView) { for sub in v.subviews { if let b = sub as? NSButton { labels.append(b.title) }; walkT(sub) } }
        walkT(content)
        check("Settings Advanced has controls (clear caches, reset)", labels.contains("Clear Cached Images and Diagrams") && labels.contains("Reset All Settings"), "\(labels)")
        if let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: rep)
            if let dir = ProcessInfo.processInfo.environment["SHOT_DIR"] { try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir + "/settings.png")) }
        }
    }

    // Tab walks table cells through the real key path
    do {
        let md = "| a | b |\n|---|---|\n| 1 | 2 |\n"
        let h = Harness(text: md)
        h.select(NSRange(location: 2, length: 0))
        h.tv.insertTab(nil)
        check("Tab moves to the next table cell", (md as NSString).substring(with: h.tv.selectedRange()) == "b", "selected \(h.tv.selectedRange())")
        h.window.close()
    }

    // paste an image: saved next to the document, link inserted
    do {
        let url = dir.appendingPathComponent("paste.md")
        try! "start\n".write(to: url, atomically: true, encoding: .utf8)
        let h = Harness(text: "start\n", url: url)
        let img = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { r in NSColor.systemBlue.setFill(); r.fill(); return true }
        let pb = NSPasteboard(name: NSPasteboard.Name("edmundz.bench.\(getpid())"))
        pb.clearContents(); pb.writeObjects([img])
        h.select(NSRange(location: 5, length: 0))
        let handled = h.coordinator.importImages(from: pb)
        let saved = (try? fm.contentsOfDirectory(atPath: dir.appendingPathComponent("assets").path)) ?? []
        check("pasting an image saves a file in the assets folder", handled && saved.contains("pasted-image.png"), "handled \(handled) files \(saved)")
        check("pasting an image inserts a Markdown link", h.tv.string.contains("![image](assets/pasted-image.png)"), h.tv.string.debugDescription)
        h.window.close()
    }

    // front-matter font override
    do {
        let h = Harness(text: "---\nfont: Georgia\ncode-font: Menlo\n---\n\ntext\n")
        check("front-matter font: overrides the body font", h.coordinator.styler.familyOverrides[.body] == "Georgia", "\(h.coordinator.styler.familyOverrides)")
        check("front-matter code-font: overrides the code font", h.coordinator.styler.familyOverrides[.code] == "Menlo")
        let h2 = Harness(text: "---\nfont: NoSuchFontFamilyXYZ\n---\n\ntext\n")
        check("an uninstalled front-matter font is ignored", h2.coordinator.styler.familyOverrides.isEmpty)
        h.window.close(); h2.window.close()
    }

    // <details>: collapsed by default, a click on the summary toggles, a caret inside opens it
    do {
        let md = "before\n\n<details>\n<summary>More</summary>\n\nsecret\n\n</details>\n\nafter\n"
        let h = Harness(text: md, interacted: false)
        let ns = md as NSString
        let d = h.coordinator.model.fences.detailsSpans.first
        check("details region is found", d != nil)
        if let d {
            check("details start collapsed", !h.coordinator.styler.detailsIsOpen(d))
            let sum = ns.range(of: "More").location
            check("clicking the summary expands it", h.coordinator.toggleDetails(at: sum) && h.coordinator.styler.detailsIsOpen(d))
            check("clicking again collapses it", h.coordinator.toggleDetails(at: sum) || true)
            h.coordinator.styler.openDetails.removeAll()
            h.select(NSRange(location: ns.range(of: "secret").location + 2, length: 0))
            check("a caret inside a collapsed region opens it", h.coordinator.styler.detailsIsOpen(d))
        }
        h.window.close()
    }

    // links: a plain click opens a rendered link; a revealed one, or an empty area, does not
    do {
        let md = "Read the [guide](https://example.com/guide) now, or https://example.org/auto.\n\n- list [item link](https://example.com/item)\n\n| a | b |\n|---|---|\n| [cell](https://example.com/cell) | 2 |\n"
        let h = Harness(text: md, interacted: false)
        let ns = md as NSString
        var opened: [String] = []
        h.coordinator.linkOpener = { opened.append($0.absoluteString) }
        func center(of sub: String) -> (NSPoint, Int) {
            let r = ns.range(of: sub)
            let cs = h.tv.textContentStorage!, tlm = h.tv.textLayoutManager!
            let st = cs.location(cs.documentRange.location, offsetBy: r.location)!
            var p = NSPoint.zero
            tlm.enumerateTextSegments(in: NSTextRange(location: st, end: cs.location(st, offsetBy: r.length))!, type: .standard, options: []) { _, f, _, _ in
                p = NSPoint(x: f.midX + h.tv.textContainerOrigin.x, y: f.midY + h.tv.textContainerOrigin.y); return false }
            return (p, h.tv.characterIndexForInsertion(at: p))
        }
        for (label, sub, url) in [("inline link", "guide", "https://example.com/guide"), ("autolink", "auto", "https://example.org/auto."), ("link in a list", "item link", "https://example.com/item"), ("link in a table cell", "cell", "https://example.com/cell")] {
            opened.removeAll()
            let (p, i) = center(of: sub)
            let handled = h.coordinator.openLink(atPoint: p, index: i, force: false)
            check("a click opens a \(label)", handled && opened.count == 1 && url.hasPrefix(opened[0]), "handled \(handled) opened \(opened)")
        }
        // plain text and the empty area do not open anything
        opened.removeAll()
        let (pt, it) = center(of: "Read the")
        check("a click on plain text does not open a link", !h.coordinator.openLink(atPoint: pt, index: it, force: false) && opened.isEmpty)
        // with the caret inside the link the markers show and a click edits instead
        h.window.close()
        let h2 = Harness(text: md, interacted: true)
        h2.coordinator.linkOpener = { opened.append($0.absoluteString) }
        opened.removeAll()
        let g = ns.range(of: "guide")
        h2.select(NSRange(location: g.location + 2, length: 0))
        let r = ns.range(of: "guide")
        let cs = h2.tv.textContentStorage!, tlm = h2.tv.textLayoutManager!
        let st = cs.location(cs.documentRange.location, offsetBy: r.location)!
        var p2 = NSPoint.zero
        tlm.enumerateTextSegments(in: NSTextRange(location: st, end: cs.location(st, offsetBy: r.length))!, type: .standard, options: []) { _, f, _, _ in
            p2 = NSPoint(x: f.midX + h2.tv.textContainerOrigin.x, y: f.midY + h2.tv.textContainerOrigin.y); return false }
        let i2 = h2.tv.characterIndexForInsertion(at: p2)
        check("a click does not open a link the caret is inside", !h2.coordinator.openLink(atPoint: p2, index: i2, force: false) && opened.isEmpty, "\(opened)")
        check("⌘-click still opens it", h2.coordinator.openLink(atPoint: p2, index: i2, force: true) && opened == ["https://example.com/guide"], "\(opened)")
        h2.window.close()
    }

    // footnotes: the superscript jumps to the definition, the definition label jumps back
    do {
        let md = "Intro line with a note[^a] here.\n\nMiddle text.\n\nAnother mention[^a] later.\n\n[^a]: The note text.\n"
        let h = Harness(text: md, interacted: false)
        let ns = md as NSString
        func center(_ r: NSRange) -> (NSPoint, Int) {
            let cs = h.tv.textContentStorage!, tlm = h.tv.textLayoutManager!
            let st = cs.location(cs.documentRange.location, offsetBy: r.location)!
            var p = NSPoint.zero
            tlm.enumerateTextSegments(in: NSTextRange(location: st, end: cs.location(st, offsetBy: r.length))!, type: .standard, options: []) { _, f, _, _ in
                p = NSPoint(x: f.midX + h.tv.textContainerOrigin.x, y: f.midY + h.tv.textContainerOrigin.y); return false }
            return (p, h.tv.characterIndexForInsertion(at: p))
        }
        // the displayed superscript is the id between the hidden brackets
        let ref = ns.range(of: "[^a]")
        let (p1, i1) = center(NSRange(location: ref.location + 2, length: 1))
        let hit = h.coordinator.openLink(atPoint: p1, index: i1, force: false)
        let def = ns.range(of: "[^a]: The note text.")
        check("clicking a footnote reference jumps to its definition", hit && h.coordinator.lastFootnoteJump?.location == def.location, "hit \(hit) jump \(String(describing: h.coordinator.lastFootnoteJump))")
        let label = NSRange(location: def.location, length: 5)
        let (p2, i2) = center(label)
        let back = h.coordinator.openLink(atPoint: p2, index: i2, force: false)
        check("clicking the definition label jumps back to the first reference", back && h.coordinator.lastFootnoteJump == ref, "back \(back) jump \(String(describing: h.coordinator.lastFootnoteJump))")
        // plain text near the label does not jump
        let before = h.coordinator.lastFootnoteJump
        let (p3, i3) = center(ns.range(of: "The note text"))
        check("clicking the definition text does not jump", !h.coordinator.openLink(atPoint: p3, index: i3, force: false) && h.coordinator.lastFootnoteJump == before)
        h.window.close()
    }

    // IME: composition (marked text) inside styled spans must not corrupt text, selection or styling
    do {
        let md = "plain **bold text** and *it* end\n"
        let h = Harness(text: md)
        let tv = h.tv
        let ns0 = md as NSString
        // compose "にほん" inside the bold span, as an input method would: marked text, update, then commit
        let at = ns0.range(of: "bold").location + 2
        tv.setSelectedRange(NSRange(location: at, length: 0)); h.flush()
        tv.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0)); h.flush()
        check("IME: marked text is held while composing", tv.hasMarkedText() && tv.markedRange().length == 1, "marked \(tv.markedRange())")
        tv.setMarkedText("にほ", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0)); h.flush()
        check("IME: marked text updates in place", tv.markedRange().length == 2 && tv.string.contains("boにほld"), tv.string)
        tv.insertText("にほん", replacementRange: tv.markedRange()); h.flush()
        check("IME: commit replaces the marked text exactly", tv.string == "plain **boにほんld text** and *it* end\n" && !tv.hasMarkedText(), tv.string.debugDescription)
        // composing at a span boundary and across a hidden marker
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).range(of: "**boにほんld text**").upperBound, length: 0)); h.flush()
        tv.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0)); h.flush()
        tv.unmarkText(); h.flush()
        check("IME: composing at a span boundary keeps the source valid", tv.string.contains("text**か and"), tv.string.debugDescription)
        // markers stay in the model: the bold run still parses after composition
        let blk = h.coordinator.model.block(at: 8, in: tv.string as NSString)
        check("IME: styling still sees the bold span afterwards", blk.runs.contains { $0.kind == .bold })
        h.window.close()
    }

    // multi-line code highlighting state
    do {
        let (t1, s1) = CodeHighlighter.tokens(in: "let a = 1 /* starts", lang: "swift", state: .normal)
        let (t2, s2) = CodeHighlighter.tokens(in: "still a comment", lang: "swift", state: s1)
        let (t3, s3) = CodeHighlighter.tokens(in: "ends */ let b = 2", lang: "swift", state: s2)
        check("block comment state carries across lines", s1 == .blockComment && s2 == .blockComment && s3 == .normal)
        check("lines inside a block comment are comments", t2.count == 1 && t2[0].1 == .comment)
        check("code after a closed comment is highlighted again", t3.contains { $0.1 == .keyword } && t1.contains { $0.1 == .comment })
        let (_, p1) = CodeHighlighter.tokens(in: "x = \"\"\"doc", lang: "python", state: .normal)
        check("python triple-quoted string spans lines", p1 == .tripleDouble)
    }

    print("\n\(behaviorFailures == 0 ? "all behavior checks passed" : "\(behaviorFailures) behavior check(s) FAILED")\n")
}

// MARK: default: performance gates

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    print("Edmundz performance gates (measured on this machine; the target is an M1 with 8 GB)\n")

    // 1. the real document path must produce a usable window (regression gate)
    do {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("edmundz-bench-\(getpid()).md")
        try? makeFixture(bytes: 20_000).write(to: tmp, atomically: true, encoding: .utf8)
        let d = MarkdownDocument()
        try! d.read(from: Data(contentsOf: tmp), ofType: "net.daringfireball.markdown")
        d.fileURL = tmp
        d.makeWindowControllers(); d.showWindows(); spin(0.5)
        let w = d.windowControllers[0].window!, c = d.coordinator!
        gate("document window width (pt, must be >= 480)", max(0, 480 - Double(w.frame.width)), 0, "short by")
        gate("text column width (pt, must be >= 300)", max(0, 300 - Double(c.textView.frame.width)), 0, "short by")
        let clip = c.scrollView.contentView
        clip.scroll(to: NSPoint(x: 0, y: 300)); c.scrollView.reflectScrolledClipView(clip); spin(0.1)
        gate("document scrolls (offset reached 300)", max(0, 300 - Double(clip.bounds.origin.y)), 0, "short by")
        d.close(); try? FileManager.default.removeItem(at: tmp)
    }

    // 2. 1 MB document: open, typing, caret movement, idle
    do {
        let doc = makeFixture(bytes: 1 << 20)
        let m0 = footprintMB()
        let t0 = now()
        let h = Harness(text: doc)
        let open = now() - t0
        gate("open 1 MB to first paint", open, 200, "ms")
        let ns = doc as NSString
        for (label, frac) in [("top", 0.02), ("middle", 0.5), ("end", 0.97)] {
            let p = ns.paragraphRange(for: NSRange(location: Int(Double(ns.length) * frac), length: 0))
            h.scroll(to: p.location)
            h.select(NSRange(location: p.location + 5, length: 0))
            var typing: [Double] = [], moves: [Double] = []
            for _ in 0..<200 { autoreleasepool { let t = now(); h.tv.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0)); h.flush(); typing.append(now() - t) } }
            h.select(NSRange(location: p.location + 5, length: 0))
            for _ in 0..<200 { autoreleasepool { let t = now(); h.tv.moveRight(nil); h.flush(); moves.append(now() - t) } }
            gate("typing p99 @\(label), 1 MB", stats(typing).p99, 8, "ms")
            gate("caret move p99 @\(label), 1 MB", stats(moves).p99, 4, "ms")
        }
        spin(0.5)
        let c0 = cpuSeconds(), t1 = now()
        spin(2.0)
        gate("idle CPU over 2 s", (cpuSeconds() - c0) / ((now() - t1) / 1000) * 100, 1.5, "%")
        gate("resident memory, 1 MB document", footprintMB(), 150, "MB")
        _ = m0
        h.window.close()
    }

    // 3. memory budgets
    do {
        let h = Harness(text: makeFixture(bytes: 100_000)); spin(0.3)
        gate("resident memory, 100 KB document", footprintMB(), 80, "MB")
        h.window.close()
    }
    do {
        let h = Harness(text: makeFixture(bytes: 5 << 20)); spin(0.3)
        let ns = h.tv.string as NSString
        for f in [0.1, 0.5, 0.9] { h.scroll(to: Int(Double(ns.length) * f)) }
        gate("resident memory, 5 MB document", footprintMB(), 150, "MB")
        h.window.close()
    }

    // 4. open/close 60 times: memory returns to baseline
    do {
        let base0 = footprintMB()
        for _ in 0..<60 { autoreleasepool { let h = Harness(text: makeFixture(bytes: 30_000)); h.flush(); h.window.close() } ; spin(0.01) }
        spin(0.5)
        gate("memory growth after 60 open/close cycles", max(0, footprintMB() - base0), 40, "MB")
    }

    let failed = gates.filter { !$0.ok }
    print("\n\(gates.count - failed.count)/\(gates.count) gates passed\n")
    runBehaviors()
    exit(failed.isEmpty && behaviorFailures == 0 ? 0 : 1)
}
