// Screenshots a local HTML page with WebKit (no Chromium needed).
// usage: swift scripts/webshot.swift <file.html> <width> <out.png> [height|full] [--js "<script run after load>"] [--wait seconds] [--dark] [--reduce-motion]
import AppKit
import WebKit

let a = CommandLine.arguments
guard a.count >= 4 else { print("usage: webshot <file.html> <width> <out.png> [height|full] [--js code] [--wait s] [--dark]"); exit(2) }
func opt(_ n: String) -> String? { a.firstIndex(of: n).flatMap { $0 + 1 < a.count ? a[$0 + 1] : nil } }
let file = URL(fileURLWithPath: a[1]), width = Double(a[2])!, out = a[3]
let heightArg = a.count > 4 && !a[4].hasPrefix("--") ? a[4] : "full"
let wait = Double(opt("--wait") ?? "1.5")!

final class Shot: NSObject, WKNavigationDelegate {
    let web: WKWebView
    let win: NSWindow
    init(width: Double) {
        let cfg = WKWebViewConfiguration()
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: 900), configuration: cfg)
        win = NSWindow(contentRect: web.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        win.contentView = web
        if a.contains("--dark") { win.appearance = NSAppearance(named: .darkAqua) }
        win.orderBack(nil)
        super.init()
        web.navigationDelegate = self
    }
    func webView(_ w: WKWebView, didFinish n: WKNavigation!) {
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [self] in
            func go() {
                web.evaluateJavaScript("document.documentElement.scrollHeight") { h, _ in
                    var height = (h as? Double) ?? 900
                    if heightArg != "full", let v = Double(heightArg) { height = v }
                    web.frame = NSRect(x: 0, y: 0, width: width, height: height)
                    win.setContentSize(NSSize(width: width, height: height))
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        let cfg = WKSnapshotConfiguration()
                        let y0 = Double(opt("--y") ?? "0")!, h0 = Double(opt("--h") ?? "\(height)")!
                        cfg.rect = NSRect(x: 0, y: y0, width: width, height: min(h0, height - y0))
                        cfg.snapshotWidth = NSNumber(value: width * 2)
                        web.takeSnapshot(with: cfg) { img, err in
                            guard let img, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                                  let png = rep.representation(using: .png, properties: [:]) else { print("snapshot failed: \(String(describing: err))"); exit(1) }
                            try? png.write(to: URL(fileURLWithPath: out))
                            print("wrote \(out) \(Int(width))x\(Int(height)) page height \(Int(height))")
                            exit(0)
                        }
                    }
                }
            }
            if let js = opt("--js") { web.evaluateJavaScript(js) { r, e in if let e { print("js error: \(e)") } else if let r { print("js result: \(r)") }; DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { go() } } } else { go() }
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let shot = Shot(width: width)
shot.web.loadFileURL(file, allowingReadAccessTo: file.deletingLastPathComponent())
app.run()
