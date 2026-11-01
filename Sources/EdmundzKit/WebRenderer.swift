import AppKit
import WebKit

/// Serves bundled scripts to the off-screen renderer page over a private scheme; nothing else is loadable.
struct ResourceSchemeHandler: URLSchemeHandler {
    func reply(for request: URLRequest) -> AsyncThrowingStream<URLSchemeTaskResult, any Error> {
        AsyncThrowingStream { c in
            guard let url = request.url else { c.finish(throwing: URLError(.badURL)); return }
            var path = url.path
            if path.hasPrefix("/") { path.removeFirst() }
            guard let file = Resources.url(path), let data = try? Data(contentsOf: file) else { c.finish(throwing: URLError(.fileDoesNotExist)); return }
            let ext = file.pathExtension.lowercased()
            let mime = ext == "js" ? "text/javascript" : ext == "css" ? "text/css" : ext == "woff2" ? "font/woff2" : "application/octet-stream"
            c.yield(.response(URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: ext == "woff2" ? nil : "utf-8")))
            c.yield(.data(data))
            c.finish()
        }
    }
}

enum DiagramResult {
    case image(NSImage)
    case error(String)
}

struct KaTeXResult { var image: NSImage; var descent: CGFloat }

/// One shared, lazily created, off-screen web view that renders Mermaid diagrams and KaTeX formulas to vector PDF images.
/// It is created on first use and released shortly after the queue drains, so documents without diagrams never start WebKit
/// and finished work frees the helper processes (M0: about 100 MB while alive).
@MainActor
final class WebRenderer {
    static let shared = WebRenderer()

    private var page: WebPage?
    private var loadedScripts = Set<String>()
    private var teardown: Task<Void, Never>?
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var pageCreations = 0

    private let cache: NSCache<NSString, CacheEntry> = { let c = NSCache<NSString, CacheEntry>(); c.totalCostLimit = 24 << 20; return c }()
    private final class CacheEntry { let image: NSImage; let descent: CGFloat; let error: String?; var svg: String?; init(_ i: NSImage, _ d: CGFloat, _ e: String?) { image = i; descent = d; error = e } }

    var isAlive: Bool { page != nil }
    var idleSeconds: Double = 2

    // MARK: cache

    func cachedDiagram(_ key: String) -> DiagramResult? {
        guard let e = cache.object(forKey: key as NSString) else { return nil }
        if let err = e.error { return .error(err) }
        return .image(e.image)
    }

    func cachedSVG(_ key: String) -> String? { cache.object(forKey: key as NSString)?.svg }

    func cachedMath(_ key: String) -> KaTeXResult? {
        guard let e = cache.object(forKey: key as NSString), e.error == nil else { return nil }
        return KaTeXResult(image: e.image, descent: e.descent)
    }

    func purge() { cache.removeAllObjects(); releasePage() }

    // MARK: serialization

    private func acquire() async {
        teardown?.cancel(); teardown = nil
        if busy { await withCheckedContinuation { waiters.append($0) } } else { busy = true }
    }

    private func release() {
        if !waiters.isEmpty { waiters.removeFirst().resume(); return }
        busy = false
        teardown = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(self.idleSeconds))
            if !Task.isCancelled { self.releasePage() }
        }
    }

    private func releasePage() {
        page = nil
        loadedScripts.removeAll()
    }

    // MARK: page

    private func ensurePage() async throws -> WebPage {
        if let page { return page }
        var config = WebPage.Configuration()
        config.websiteDataStore = .nonPersistent()
        config.urlSchemeHandlers[URLScheme("edmundz-res")!] = ResourceSchemeHandler()
        let p = WebPage(configuration: config)
        let html = """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src edmundz-res: 'unsafe-eval'; style-src edmundz-res: 'unsafe-inline'; font-src edmundz-res:; img-src data:">
        <style>html,body{margin:0;padding:0;background:transparent}</style></head><body></body></html>
        """
        for try await _ in p.load(html: html, baseURL: URL(string: "edmundz-res://app/")!) {}
        page = p
        pageCreations += 1
        return p
    }

    private func loadScript(_ name: String, on p: WebPage) async throws {
        guard !loadedScripts.contains(name) else { return }
        _ = try await p.callJavaScript("""
        await new Promise((res, rej) => { const s = document.createElement('script'); s.src = 'edmundz-res://app/' + name;
          s.onload = res; s.onerror = () => rej(new Error('cannot load ' + name)); document.head.appendChild(s); });
        """, arguments: ["name": name])
        loadedScripts.insert(name)
    }

    private func loadStyle(_ name: String, on p: WebPage) async throws {
        guard !loadedScripts.contains(name) else { return }
        _ = try await p.callJavaScript("""
        await new Promise((res, rej) => { const l = document.createElement('link'); l.rel = 'stylesheet'; l.href = 'edmundz-res://app/' + name;
          l.onload = res; l.onerror = () => rej(new Error('cannot load ' + name)); document.head.appendChild(l); });
        """, arguments: ["name": name])
        loadedScripts.insert(name)
    }

    // MARK: mermaid

    func renderMermaid(_ source: String, dark: Bool, fontFamily: String?, cacheKey: String) async -> DiagramResult {
        if let hit = cachedDiagram(cacheKey) { return hit }
        await acquire()
        defer { release() }
        do {
            let p = try await ensurePage()
            try await loadScript("mermaid.min.js", on: p)
            let font = fontFamily ?? "-apple-system, system-ui, sans-serif"
            let dims = try await p.callJavaScript("""
            mermaid.initialize({ startOnLoad: false, securityLevel: 'strict', theme: dark ? 'dark' : 'neutral',
                                 themeVariables: { fontFamily: font }, fontFamily: font });
            document.body.innerHTML = '';
            try {
              const r = await mermaid.render('m' + Math.random().toString(36).slice(2), src);
              document.body.innerHTML = r.svg; window.__svg = r.svg;
            } catch (e) { document.body.innerHTML = ''; return { error: String(e && e.message ? e.message : e).split('\\n')[0] }; }
            const svg = document.body.querySelector('svg');
            svg.style.display = 'block'; svg.style.maxWidth = 'none';
            const b = svg.getBoundingClientRect();
            return { w: Math.ceil(b.width), h: Math.ceil(b.height), svg: window.__svg };
            """, arguments: ["src": source, "dark": dark, "font": font]) as? [String: Any]
            if let err = dims?["error"] as? String {
                cache.setObject(CacheEntry(NSImage(), 0, err), forKey: cacheKey as NSString, cost: 1024)
                return .error(err)
            }
            guard let w = (dims?["w"] as? NSNumber)?.doubleValue, let h = (dims?["h"] as? NSNumber)?.doubleValue, w > 0, h > 0 else { return .error("empty diagram") }
            let data = try await p.exported(as: .pdf(region: .rect(CGRect(x: 0, y: 0, width: w, height: h)), allowTransparentBackground: true))
            guard let image = NSImage(data: data) else { return .error("could not draw diagram") }
            let entry = CacheEntry(image, 0, nil); entry.svg = dims?["svg"] as? String
            cache.setObject(entry, forKey: cacheKey as NSString, cost: data.count + (entry.svg?.utf8.count ?? 0))
            return .image(image)
        } catch {
            return .error("diagram renderer failed: \(error.localizedDescription)")
        }
    }

    // MARK: katex fallback

    func renderKaTeX(_ latex: String, display: Bool, fontSize: CGFloat, colorHex: String, cacheKey: String) async -> KaTeXResult? {
        if let hit = cachedMath(cacheKey) { return hit }
        await acquire()
        defer { release() }
        do {
            let p = try await ensurePage()
            try await loadStyle("katex.min.css", on: p)
            try await loadScript("katex.min.js", on: p)
            let res = try await p.callJavaScript("""
            document.body.innerHTML = '';
            const el = document.createElement('div');
            el.style.cssText = 'display:inline-block;font-size:' + size + 'px;color:' + color + ';padding:1px';
            try { katex.render(tex, el, { displayMode: display, throwOnError: true, strict: 'ignore', trust: false }); }
            catch (e) { return { error: String(e.message || e) }; }
            document.body.appendChild(el);
            const probe = document.createElement('span');
            probe.style.cssText = 'display:inline-block;width:0;height:0;vertical-align:baseline';
            el.appendChild(probe);
            el.offsetWidth;                                   // force layout so the fonts in use are requested
            await Promise.all(Array.from(document.fonts).map(f => f.load().catch(() => null)));
            await document.fonts.ready;
            el.offsetWidth;
            const r = el.getBoundingClientRect();
            return { w: Math.ceil(r.width), h: Math.ceil(r.height), descent: r.bottom - probe.getBoundingClientRect().bottom };
            """, arguments: ["tex": latex, "display": display, "size": Double(fontSize), "color": colorHex]) as? [String: Any]
            guard res?["error"] == nil, let w = (res?["w"] as? NSNumber)?.doubleValue, let h = (res?["h"] as? NSNumber)?.doubleValue, w > 0, h > 0 else { return nil }
            let descent = CGFloat((res?["descent"] as? NSNumber)?.doubleValue ?? 0)
            let data = try await p.exported(as: .pdf(region: .rect(CGRect(x: 0, y: 0, width: w, height: h)), allowTransparentBackground: true))
            guard let image = NSImage(data: data) else { return nil }
            cache.setObject(CacheEntry(image, descent, nil), forKey: cacheKey as NSString, cost: data.count)
            return KaTeXResult(image: image, descent: descent)
        } catch { return nil }
    }
}
