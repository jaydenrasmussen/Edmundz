import AppKit

func footprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
}

func now() -> Double {
    var t = mach_timebase_info_data_t(); mach_timebase_info(&t)
    return Double(mach_absolute_time()) * Double(t.numer) / Double(t.denom) / 1e6 // ms
}

func report(_ name: String, _ samples: [Double]) {
    let s = samples.sorted()
    func p(_ q: Double) -> Double { s[min(s.count - 1, Int(Double(s.count) * q))] }
    print(String(format: "%-34@ n=%4d  p50 %6.2f ms  p99 %6.2f ms  max %6.2f ms", name as NSString, s.count, p(0.5), p(0.99), s.last ?? 0))
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSTextViewDelegate {
    var window: NSWindow!
    var textView: NSTextView!
    let styler = Styler()
    var lastCaret = 0

    func applicationDidFinishLaunching(_ n: Notification) {
        let args = CommandLine.arguments
        let sizeKB = args.firstIndex(of: "--kb").flatMap { Int(args[$0 + 1]) } ?? 1024
        let bench = args.contains("--bench")

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        scroll.hasVerticalScroller = true
        textView = NSTextView(usingTextLayoutManager: true)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.textContainerInset = NSSize(width: 60, height: 40)
        textView.delegate = self
        textView.isRichText = false
        textView.allowsUndo = true
        scroll.documentView = textView
        window = NSWindow(contentRect: scroll.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.contentView = scroll
        window.title = "Edmundz spike"
        window.makeKeyAndOrderFront(nil)

        textView.textContentStorage!.delegate = styler
        textView.textLayoutManager!.delegate = styler

        let mem0 = footprintMB()
        var doc = makeFixture(bytes: sizeKB * 1024)
        if args.contains("--blocks") {
            doc = "# Blocks\n\nText before the table.\n\n| Name | Role | Score |\n|---|:---:|---:|\n| Ada | Engineer | 10 |\n| Grace Hopper | Admiral | 9000 |\n| Linus | Maintainer | 7 |\n\nText between.\n\n---\n\nText after the rule, with **bold**.\n"
        }
        if let i = args.firstIndex(of: "--images") {
            let count = Int(args[i + 1])!, dir = args[i + 2]
            var t = now(); generateImages(count: count, w: 2400, h: 1600, dir: dir)
            print(String(format: "generated/checked %d images in %.0f ms", count, now() - t))
            t = now(); for k in 0..<count { _ = ImageCache.pixelSize(URL(fileURLWithPath: "\(dir)/img-\(k).jpg")) }
            print(String(format: "header-only size read: %.3f ms per image", (now() - t) / Double(count)))
            doc = (0..<count).map { "Paragraph before image \($0) with some **bold** text.\n\n![image \($0)](\(dir)/img-\($0).jpg)\n\n" }.joined()
            ImageCache.shared.onReady = { [unowned self] in self.textView.needsDisplay = true }
        }
        let t0 = now()
        textView.string = doc
        textView.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let tOpen = now() - t0
        print(String(format: "doc %d KB, open-to-first-paint %.1f ms, paragraph styles computed: %d", sizeKB, tOpen, styler.paragraphCalls))
        print(String(format: "memory: before %.1f MB, after open %.1f MB", mem0, footprintMB()))

        if args.contains("--images") && !args.contains("--shot") {
            let clip = (textView.enclosingScrollView!).contentView
            var maxY = textView.frame.height - clip.bounds.height
            var heightAtStart = textView.frame.height
            var steps: [Double] = []; var y: CGFloat = 0; var peak = 0.0
            var k = 0
            while y < maxY {
                maxY = textView.frame.height - clip.bounds.height
                autoreleasepool {
                    let t = now()
                    clip.scroll(to: NSPoint(x: 0, y: y)); textView.enclosingScrollView!.reflectScrolledClipView(clip)
                    flush()
                    steps.append(now() - t)
                }
                // let async decodes land, as in a real run loop
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.004))
                peak = max(peak, footprintMB()); y += 500; k += 1
                if k % 40 == 0 { print(String(format: "  scrolled to %.0f/%.0f: %.1f MB, decodes %d", y, maxY, footprintMB(), ImageCache.shared.decodes)) }
            }
            report("scroll step (500 pt) w/ images", steps)
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 1.0))
            print("attachmentBounds calls \(attachBoundsCalls), image(for:) calls \(imageCalls)")
            print(String(format: "peak %.1f MB, final %.1f MB, decodes %d, doc height %.0f pt (estimated at open: %.0f)", peak, footprintMB(), ImageCache.shared.decodes, textView.frame.height, heightAtStart))
            NSApp.terminate(nil)
        }
        if args.contains("--check") {
            let ns = textView.string as NSString
            // copy: select text spanning hidden markers and an image paragraph; the pasteboard must hold the exact source
            let from = ns.range(of: "lorem ipsum **bold").location
            let sel = NSRange(location: from, length: 60)
            textView.setSelectedRange(sel); flush()
            let pb = NSPasteboard(name: NSPasteboard.Name("edmundz.spike"))
            pb.clearContents()
            let ok = textView.writeSelection(to: pb, types: textView.writablePasteboardTypes)
            let copied = pb.string(forType: .string) ?? ""
            print("COPY as source: wrote=\(ok) identical=\(copied == ns.substring(with: sel)) -> \"\(copied)\"")
            // undo: three edits, three undos, text identical to the original
            let original = textView.string
            textView.setSelectedRange(NSRange(location: from + 3, length: 0))
            for ch in ["a", "b", "c"] { textView.insertText(ch, replacementRange: NSRange(location: NSNotFound, length: 0)); textView.undoManager?.endUndoGrouping(); textView.undoManager?.beginUndoGrouping() }
            let edited = textView.string
            var n = 0
            while textView.string != original && (textView.undoManager?.canUndo ?? false) && n < 10 { textView.undoManager?.undo(); n += 1 }
            print("UNDO: undos needed to restore original: \(n); restored=\(textView.string == original)")
            print("UNDO: edited differs=\(edited != original), after 3 undos identical=\(textView.string == original), canUndo=\(textView.undoManager?.canUndo ?? false)")
            NSApp.terminate(nil); return
        }
        if args.contains("--shot") {
            func shot(_ name: String) {
                flush()
                let v = textView.enclosingScrollView!
                let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds)!
                v.cacheDisplay(in: v.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: name))
            }
            let ns = textView.string as NSString
            if args.contains("--blocks") {
                let d = ProcessInfo.processInfo.environment["SHOT_DIR", default: "."]
                textView.setSelectedRange(NSRange(location: ns.length - 2, length: 0)); shot(d + "/shot-blocks.png")
                let tr = ns.range(of: "Grace Hopper")
                textView.setSelectedRange(NSRange(location: tr.location + 2, length: 0)); shot(d + "/shot-blocks-reveal.png")
                NSApp.terminate(nil); return
            }
            if args.contains("--images") {
                let d = ProcessInfo.processInfo.environment["SHOT_DIR", default: "."]
                textView.setSelectedRange(NSRange(location: 0, length: 0)); flush(); RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5)); shot(d + "/shot-img-hidden.png")
                let ir = ns.range(of: "![image 0]")
                textView.setSelectedRange(NSRange(location: ir.location + 3, length: 0)); flush(); RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5)); shot(d + "/shot-img-reveal.png")
                NSApp.terminate(nil); return
            }
            textView.setSelectedRange(NSRange(location: ns.length - 1, length: 0)); flush()
            if let tlm = textView.textLayoutManager, let cs = textView.textContentStorage {
                var from = 0
                for k in 0..<5 {
                    let r = ns.range(of: "**", range: NSRange(location: from, length: ns.length - from)); from = r.upperBound + 20
                    let st = cs.location(cs.documentRange.location, offsetBy: r.location)!
                    let tr = NSTextRange(location: st, end: cs.location(st, offsetBy: 2)!)!
                    tlm.enumerateTextSegments(in: tr, type: .standard, options: []) { _, f, _, _ in print("  para-ish #\(k) '**' at \(r.location): x=\(f.minX) w=\(f.width)"); return false }
                }
            }
            shot(ProcessInfo.processInfo.environment["SHOT_DIR", default: "."] + "/shot-hidden.png")
            let r = ns.range(of: "**bold text**")
            textView.setSelectedRange(NSRange(location: r.location + 4, length: 0)); shot(ProcessInfo.processInfo.environment["SHOT_DIR", default: "."] + "/shot-reveal.png")
            NSApp.terminate(nil)
        }
        if bench { runBench(doc: doc); NSApp.terminate(nil) }
    }

    func paragraph(_ loc: Int) -> NSRange {
        let ns = textView.string as NSString
        return ns.paragraphRange(for: NSRange(location: min(max(loc, 0), max(0, ns.length - 1)), length: 0))
    }

    /// One transaction per range: TextKit coalesces ranges edited in one transaction into a single
    /// span, which forces layout of everything between a far-apart old and new caret paragraph.
    func invalidate(_ r: NSRange) {
        guard let ts = textView.textStorage else { return }
        ts.beginEditing(); ts.edited(.editedAttributes, range: r, changeInLength: 0); ts.endEditing()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        let loc = textView.selectedRange().location
        guard loc != styler.caret else { return }
        let oldCaret = styler.caret
        styler.caret = loc
        let newPara = paragraph(loc)
        invalidate(newPara)
        if oldCaret >= 0 {
            let oldPara = paragraph(oldCaret)
            if oldPara != newPara { invalidate(oldPara) }
        }
    }

    func flush() {
        textView.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
    }

    func runBench(doc: String) {
        let ns = doc as NSString
        // Move to a spot, return a location inside a paragraph near it.
        func spot(_ frac: Double) -> Int {
            let target = Int(Double(ns.length) * frac)
            let p = ns.paragraphRange(for: NSRange(location: target, length: 0))
            var c = styler.paragraphCalls; var t = now()
            textView.scrollRangeToVisible(NSRange(location: p.location, length: 0))
            print(String(format: "    scrollRangeToVisible: %.1f ms, styles +%d", now() - t, styler.paragraphCalls - c))
            c = styler.paragraphCalls; t = now()
            flush()
            print(String(format: "    flush after scroll: %.1f ms, styles +%d", now() - t, styler.paragraphCalls - c))
            return p.location
        }

        for (label, frac) in [("top", 0.01), ("middle", 0.5), ("end", 0.98)] {
            let base = spot(frac)
            print(String(format: "  [%@] after scroll: %.1f MB, styles %d", label as NSString, footprintMB(), styler.paragraphCalls))
            var c = styler.paragraphCalls; var t = now()
            textView.setSelectedRange(NSRange(location: base + 20, length: 0))
            print(String(format: "    setSelectedRange: %.1f ms, styles +%d", now() - t, styler.paragraphCalls - c))
            c = styler.paragraphCalls; t = now()
            flush()
            print(String(format: "    flush after select: %.1f ms, styles +%d, %.1f MB", now() - t, styler.paragraphCalls - c, footprintMB()))
            // typing
            var typing: [Double] = []
            for i in 0..<300 {
                autoreleasepool {
                    let c0 = styler.paragraphCalls
                    defer { if label == "end" && (i < 6 || i % 50 == 0) { print("  end key \(i): styles +\(styler.paragraphCalls - c0), \(String(format: "%.1f", footprintMB())) MB") } }
                    let t = now()
                    textView.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
                    flush()
                    typing.append(now() - t)
                }
                _ = i
            }
            report("typing @\(label)", typing)
            print(String(format: "  [%@] after typing: %.1f MB, styles %d", label as NSString, footprintMB(), styler.paragraphCalls))

            // caret moves across a paragraph with markers (right arrow)
            textView.setSelectedRange(NSRange(location: base, length: 0))
            flush()
            var moves: [Double] = []
            for _ in 0..<300 {
                autoreleasepool {
                    let t = now()
                    textView.moveRight(nil)
                    flush()
                    moves.append(now() - t)
                }
            }
            report("caret move (right arrow) @\(label)", moves)
            print(String(format: "  [%@] after moves: %.1f MB, styles %d", label as NSString, footprintMB(), styler.paragraphCalls))
        }

        // Hidden-marker geometry check: width of a hidden "**" must be ~0.
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        let s = textView.string as NSString
        let r = s.range(of: "**bold text**")
        // park caret far from it so markers are hidden
        textView.setSelectedRange(NSRange(location: s.length - 1, length: 0)); flush()
        textView.scrollRangeToVisible(r); flush()
        if let tlm = textView.textLayoutManager, let cs = textView.textContentStorage {
            let start = cs.location(cs.documentRange.location, offsetBy: r.location)!
            let end = cs.location(start, offsetBy: 2)!
            let tr = NSTextRange(location: start, end: end)!
            tlm.enumerateTextSegments(in: tr, type: .standard, options: []) { _, frame, _, _ in
                print(String(format: "hidden \"**\" segment width: %.3f pt (visible char would be ~18 pt)", frame.width)); return false
            }
        }

        // Far-jump test: caret in the middle, then click at the end, then scroll back to the middle.
        let midP = spot(0.5); textView.setSelectedRange(NSRange(location: midP + 10, length: 0)); flush()
        _ = spot(0.98)
        var c = styler.paragraphCalls; var t = now()
        textView.setSelectedRange(NSRange(location: ns.length - 50, length: 0)); flush()
        print(String(format: "FAR JUMP middle->end: %.1f ms, styles +%d", now() - t, styler.paragraphCalls - c))
        c = styler.paragraphCalls; t = now()
        let midVisible = spot(0.5)
        flush()
        print(String(format: "SCROLL BACK to middle: %.1f ms, styles +%d", now() - t, styler.paragraphCalls - c))
        // Caret stops: walk right through one paragraph, record caret x per press.
        let pr = paragraph(ns.length / 3)
        textView.setSelectedRange(NSRange(location: pr.location, length: 0)); flush()
        var xs: [(Int, CGFloat)] = []
        for _ in 0..<min(pr.length, 400) {
            let loc = textView.selectedRange().location
            xs.append((loc, textView.firstRect(forCharacterRange: NSRange(location: loc, length: 0), actualRange: nil).minX))
            textView.moveRight(nil); flush()
        }
        var same = 0, back = 0
        for i in 1..<xs.count { if xs[i].1 == xs[i-1].1 && xs[i].0 != xs[i-1].0 { same += 1 }; if xs[i].1 < xs[i-1].1 - 0.5 && xs[i].0 > xs[i-1].0 { back += 1 } }
        print("CARET WALK: \(xs.count) presses, \(same) presses that did not move the caret visually, \(back) x-decreases (line wraps expected)")
        print(String(format: "memory after bench: %.1f MB, paragraph styles computed: %d", footprintMB(), styler.paragraphCalls))
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
