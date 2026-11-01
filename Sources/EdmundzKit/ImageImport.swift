import AppKit
import EdmundzCore
import UniformTypeIdentifiers

/// Folder permission for sandboxed (Mac App Store) builds: the document sandbox grants only the file itself, so writing an
/// image next to it, or reading a relative image, needs the folder. Grants are remembered as security-scoped bookmarks.
enum FolderAccess {
    private static let key = "folderBookmarks"
    private static var active: [String: URL] = [:]

    static var isSandboxed: Bool { ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil }

    /// Re-opens access to folders granted in earlier sessions.
    static func restore() {
        guard isSandboxed, let map = UserDefaults.standard.dictionary(forKey: key) as? [String: Data] else { return }
        for (path, data) in map {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale), url.startAccessingSecurityScopedResource() {
                active[path] = url
            }
        }
    }

    static func hasAccess(to folder: URL) -> Bool {
        if !isSandboxed { return true }
        let p = folder.standardizedFileURL.path
        return active.keys.contains { p == $0 || p.hasPrefix($0 + "/") }
    }

    /// Asks the user to grant `folder`; returns true when access is available afterwards.
    @MainActor
    static func request(for folder: URL, message: String) -> Bool {
        if hasAccess(to: folder) { return true }
        let panel = NSOpenPanel()
        panel.message = message
        panel.prompt = "Allow Access"
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.directoryURL = folder
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        guard let data = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) else { return false }
        var map = (UserDefaults.standard.dictionary(forKey: key) as? [String: Data]) ?? [:]
        map[url.standardizedFileURL.path] = data
        UserDefaults.standard.set(map, forKey: key)
        if url.startAccessingSecurityScopedResource() { active[url.standardizedFileURL.path] = url }
        return hasAccess(to: folder)
    }
}

extension EditorCoordinator {
    // MARK: front-matter font override (v1.1)

    /// `font:`, `heading-font:` and `code-font:` in the front-matter override the Settings fonts for this document.
    func updateFrontMatterOverrides() {
        let text = textView.string
        var o: [FontRole: String] = [:]
        if text.hasPrefix("---"), let fm = FrontMatter.parse(text) {
            for (k, v) in fm.entries {
                switch k.lowercased() {
                case "font": o[.body] = v
                case "heading-font", "heading_font": o[.heading] = v
                case "code-font", "code_font": o[.code] = v
                default: break
                }
            }
        }
        o = o.filter { NSFontManager.shared.font(withFamily: $0.value, traits: [], weight: 5, size: 12) != nil }   // ignore uninstalled families
        if o != styler.familyOverrides { styler.familyOverrides = o; reloadStyles() }
    }

    // MARK: paste and drop of images (v1.1)

    /// Handles images on a pasteboard: file URLs of images are copied, raw image data is saved as PNG, into the document's
    /// image folder, and `![](path)` links are inserted. Returns true when the pasteboard was an image paste.
    @discardableResult
    public func importImages(from pb: NSPasteboard, at index: Int? = nil) -> Bool {
        var files: [URL] = []
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            files = urls.filter { (try? $0.resourceValues(forKeys: [.contentTypeKey]).contentType)?.conforms(to: .image) ?? false }
        }
        var data: Data?
        if files.isEmpty, pb.string(forType: .string) == nil, let img = NSImage(pasteboard: pb), let tiff = img.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff) { data = rep.representation(using: .png, properties: [:]) }
        guard !files.isEmpty || data != nil else { return false }

        guard let doc = styler.documentURL else {
            let a = NSAlert()
            a.messageText = "Save the document first"
            a.informativeText = "Images are stored in a folder next to the document, so it needs a location on disk."
            a.runModal()
            return true
        }
        let docFolder = doc.deletingLastPathComponent()
        let assetsName = Settings.shared.imageAssetsFolder.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let folder = assetsName.isEmpty ? docFolder : docFolder.appendingPathComponent(assetsName, isDirectory: true)
        guard MainActor.assumeIsolated({ FolderAccess.request(for: docFolder, message: "Edmundz stores pasted images in a folder next to the document.") }) else { return true }
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) } catch {
            NSAlert(error: error).runModal(); return true
        }
        func exists(_ n: String) -> Bool { FileManager.default.fileExists(atPath: folder.appendingPathComponent(n).path) }
        var links: [String] = []
        do {
            for f in files {
                let ext = f.pathExtension.isEmpty ? "png" : f.pathExtension.lowercased()
                let name = AssetNaming.uniqueName(base: f.deletingPathExtension().lastPathComponent, ext: ext, exists: exists)
                try FileManager.default.copyItem(at: f, to: folder.appendingPathComponent(name))
                links.append(AssetNaming.markdownImage(alt: f.deletingPathExtension().lastPathComponent, folder: assetsName, name: name))
            }
            if let data {
                let name = AssetNaming.uniqueName(base: "pasted-image", ext: "png", exists: exists)
                try data.write(to: folder.appendingPathComponent(name))
                links.append(AssetNaming.markdownImage(alt: "image", folder: assetsName, name: name))
            }
        } catch { NSAlert(error: error).runModal(); return true }

        userInteracted()
        if let index { textView.setSelectedRange(NSRange(location: min(index, (textView.string as NSString).length), length: 0)) }
        let sel = textView.selectedRange()
        let t = textView.string as NSString
        // images get their own paragraph
        let atLineStart = sel.location == 0 || t.character(at: sel.location - 1) == 0x0A
        let text = (atLineStart ? "" : "\n\n") + links.joined(separator: "\n\n") + "\n"
        textView.apply(EditResult(edits: [TextEdit(sel, text)], selection: NSRange(location: sel.location + (text as NSString).length, length: 0)))
        return true
    }
}
