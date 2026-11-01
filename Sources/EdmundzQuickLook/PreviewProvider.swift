import Foundation
import QuickLookUI
import UniformTypeIdentifiers
import EdmundzCore

/// Finder / Spotlight preview for Markdown: GFM rendered to a standalone HTML page by the same parser the editor uses.
@objc(PreviewProvider)
public final class PreviewProvider: QLPreviewProvider, QLPreviewingController {
    public func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let data = try Data(contentsOf: request.fileURL)
        let markdown = String(decoding: data, as: UTF8.self)
        let title = FrontMatter.parse(markdown)?.title ?? request.fileURL.deletingPathExtension().lastPathComponent
        let html = HTMLExport.page(markdown: markdown, title: title)
        let reply = QLPreviewReply(dataOfContentType: .html, contentSize: CGSize(width: 800, height: 900)) { reply in
            reply.stringEncoding = .utf8
            return Data(html.utf8)
        }
        reply.title = title
        return reply
    }
}
