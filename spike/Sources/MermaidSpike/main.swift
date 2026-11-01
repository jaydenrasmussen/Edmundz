import AppKit
import WebKit

func now() -> Double {
    var t = mach_timebase_info_data_t(); mach_timebase_info(&t)
    return Double(mach_absolute_time()) * Double(t.numer) / Double(t.denom) / 1e6
}

func footprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    _ = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    return Double(info.phys_footprint) / 1_048_576
}

/// Sum of RSS (MB) of all WebKit helper processes on the machine.
func webkitHelpersMB() -> (mb: Double, count: Int) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/ps"); p.arguments = ["-axo", "rss=,comm="]
    let pipe = Pipe(); p.standardOutput = pipe; try? p.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    let out = String(data: data, encoding: .utf8) ?? ""
    var total = 0.0, n = 0
    for line in out.split(separator: "\n") where line.contains("com.apple.WebKit") {
        let parts = line.split(separator: " ", maxSplits: 1)
        if let kb = Double(parts[0]) { total += kb / 1024; n += 1 }
    }
    return (total, n)
}

func helperList() -> String {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/ps"); p.arguments = ["-axo", "pid=,rss=,comm="]
    let pipe = Pipe(); p.standardOutput = pipe; try? p.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    return String(data: data, encoding: .utf8)!.split(separator: "\n").filter { $0.contains("com.apple.WebKit") }
        .map { l -> String in let f = l.split(separator: " ", maxSplits: 2); return "    pid \(f[0]) \(Int(f[1])! / 1024) MB \(f[2].split(separator: "/").last ?? "")" }.joined(separator: "\n")
}

let flow = """
flowchart LR
  A[Start] --> B{Is it?}
  B -- Yes --> C[OK]
  C --> D[Rethink]
  D --> B
  B -- No --> E[End]
  E --> F[Cleanup] --> G[Done]
"""
let seq = """
sequenceDiagram
  Alice->>John: Hello John
  John-->>Alice: Great!
  Alice-)John: See you later
"""

@MainActor
final class App: NSObject, NSApplicationDelegate {
    var page: WebPage?
    var host: NSWindow?

    func applicationDidFinishLaunching(_ n: Notification) {
        Task { await run(); NSApp.terminate(nil) }
    }

    func render(_ page: WebPage, _ name: String, _ src: String) async {
        let t = now()
        do {
            let svg = try await page.callJavaScript("const r = await mermaid.render('d' + Math.random().toString(36).slice(2), src); return r.svg;", arguments: ["src": src]) as? String
            print(String(format: "render %-18@ %.0f ms, svg %d bytes", name as NSString, now() - t, svg?.utf8.count ?? -1))
        } catch { print("render \(name) failed: \(error)") }
    }

    func useMermaid(html: String, label: String, base: Double) async {
        var t = now()
        let page = WebPage()
        do { for try await _ in page.load(html: html) {} } catch { print("load error \(error)") }
        print(String(format: "[%@] start + load: %.0f ms", label as NSString, now() - t))
        var h = webkitHelpersMB()
        print(String(format: "[%@] after start: app %.1f MB, helpers +%.1f MB (%d procs)", label as NSString, footprintMB(), h.mb - base, h.count))
        if label.hasPrefix("mermaid") {
            await render(page, "flowchart", flow); await render(page, "sequence", seq); await render(page, "flowchart again", flow)
            h = webkitHelpersMB()
            print(String(format: "[%@] after renders: helpers +%.1f MB", label as NSString, h.mb - base))
        }
        print(helperList())
        t = now(); _ = t
    }

    func run() async {
        let js = try! String(contentsOfFile: "vendor/mermaid.min.js", encoding: .utf8)
        let mermaidHTML = "<!doctype html><html><body><script>\(js)</script><script>mermaid.initialize({startOnLoad:false, securityLevel:'strict', theme:'neutral'});</script></body></html>"
        do {
            let js = try! String(contentsOfFile: "vendor/mermaid.min.js", encoding: .utf8)
            let html = "<!doctype html><html><body><script>\(js)</script><script>mermaid.initialize({startOnLoad:false, securityLevel:'strict', theme:'neutral', htmlLabels:false, flowchart:{htmlLabels:false}});</script></body></html>"
            let page = WebPage()
            do { for try await _ in page.load(html: html) {} } catch {}
            let html2 = html.replacingOccurrences(of: "htmlLabels:false, flowchart:{htmlLabels:false}", with: "")
            _ = html2
            let dims = try? await page.callJavaScript("""
              const r = await mermaid.render('dpdf', src);
              document.body.style.margin = '0'; document.body.style.background = 'transparent';
              document.body.innerHTML = r.svg;
              const svg = document.body.querySelector('svg'); svg.style.display = 'block';
              return svg.getBoundingClientRect().width + 'x' + svg.getBoundingClientRect().height;
            """, arguments: ["src": flow])
            var t = now()
            var rect = CGRect(x: 0, y: 0, width: 600, height: 300)
            if let d = dims as? String, let w = Double(d.split(separator: "x")[0]), let h = Double(d.split(separator: "x")[1]) { rect = CGRect(x: 0, y: 0, width: ceil(w), height: ceil(h)) }
            print("svg size \(rect)")
            if let data = try? await page.exported(as: .pdf(region: .rect(rect), allowTransparentBackground: true)) {
                print(String(format: "pdf export: %d bytes in %.0f ms", data.count, now() - t))
                if let img = NSImage(data: data) {
                    print("NSImage from pdf: size \(img.size)")
                    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(img.size.width * 2), pixelsHigh: Int(img.size.height * 2), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                    NSColor.white.setFill(); NSRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh).fill()
                    img.draw(in: NSRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh)); NSGraphicsContext.restoreGraphicsState()
                    try? rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHOT_DIR", default: "."] + "/mermaid-pdf.png"))
                }
            }
        }
        for (label, html) in [("empty page", "<!doctype html><html><body>hi</body></html>"), ("mermaid", mermaidHTML)] {
            let base = webkitHelpersMB()
            print(String(format: "\n== %@: baseline app %.1f MB, helpers %.1f MB (%d procs)", label as NSString, footprintMB(), base.mb, base.count))
            await useMermaid(html: html, label: label, base: base.mb)   // page goes out of scope here
            for sec in [2, 10, 20] {
                try? await Task.sleep(for: .seconds(sec == 2 ? 2 : sec == 10 ? 8 : 10))
                let h = webkitHelpersMB()
                print(String(format: "[%@] %d s after release: helpers %+.1f MB vs baseline (%d procs), app %.1f MB", label as NSString, sec, h.mb - base.mb, h.count, footprintMB()))
            }
        }
    }
}

setvbuf(stdout, nil, _IONBF, 0)
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let d = MainActor.assumeIsolated { App() }
app.delegate = d
app.run()
