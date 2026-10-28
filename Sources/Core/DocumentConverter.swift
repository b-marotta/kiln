import AppKit
import Foundation
import PDFKit

/// Clean-room text document conversions (TXT / MD / RTF ↔ PDF / HTML / TXT).
enum DocumentConverter {
    static func convert(source: URL, action: FanAction) throws -> URL {
        let kind = FileKind.classify(url: source)
        switch action {
        case .convertToPDF:
            guard [.txt, .md, .rtf, .html, .doc, .docx].contains(kind) else { throw ConversionError.unsupported }
            return try toPDF(source: source)
        case .convertToHTML:
            guard [.txt, .md, .rtf].contains(kind) else { throw ConversionError.unsupported }
            return try toHTML(source: source)
        case .convertToTXT:
            guard [.md, .rtf, .html, .txt].contains(kind) else { throw ConversionError.unsupported }
            return try toTXT(source: source)
        default:
            throw ConversionError.unsupported
        }
    }

    static func pdfToTXT(source: URL) throws -> URL {
        guard let doc = PDFDocument(url: source) else { throw ConversionError.readFailed }
        var parts: [String] = []
        for i in 0..<doc.pageCount {
            if let page = doc.page(at: i), let s = page.string {
                parts.append(s)
            }
        }
        let out = OutputNamer.adjacent(for: source, ext: "txt")
        try parts.joined(separator: "\n\n").write(to: out, atomically: true, encoding: .utf8)
        return out
    }

    private static func attributedString(from source: URL) throws -> NSAttributedString {
        let kind = FileKind.classify(url: source)
        switch kind {
        case .doc, .docx:
            return try NSAttributedString(
                data: Data(contentsOf: source),
                options: [.documentType: kind == .docx ? NSAttributedString.DocumentType.officeOpenXML : NSAttributedString.DocumentType.docFormat],
                documentAttributes: nil
            )
        case .rtf:
            let data = try Data(contentsOf: source)
            return try NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.rtf],
                documentAttributes: nil
            )
        case .html:
            let data = try Data(contentsOf: source)
            return try NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.html],
                documentAttributes: nil
            )
        case .md:
            let raw = try String(contentsOf: source, encoding: .utf8)
            return NSAttributedString(string: stripMarkdown(raw), attributes: bodyAttrs())
        case .txt:
            let raw = try String(contentsOf: source, encoding: .utf8)
            return NSAttributedString(string: raw, attributes: bodyAttrs())
        default:
            throw ConversionError.unsupported
        }
    }

    /// Temporary rendering for the PDF editor; never leaves intermediate files beside the source.
    static func pdfDocument(source: URL) throws -> PDFDocument {
        if FileKind.classify(url: source) == .pdf { return try PDFActions.load(source) }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        defer { try? FileManager.default.removeItem(at: temporary) }
        _ = try toPDF(source: source, destination: temporary)
        return try PDFActions.load(temporary)
    }

    private static func toPDF(source: URL, destination: URL? = nil) throws -> URL {
        let attr = try attributedString(from: source)
        let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792) // US Letter
        let margin: CGFloat = 54
        let out = destination ?? OutputNamer.adjacent(for: source, ext: "pdf")

        var mediaBox = pageRect
        guard let consumer = CGDataConsumer(url: out as CFURL),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
        else {
            throw ConversionError.writeFailed("pdf context")
        }

        let textStorage = NSTextStorage(attributedString: attr)
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let contentWidth = pageRect.width - margin * 2
        let contentHeight = pageRect.height - margin * 2

        var glyphIndex = 0
        let total = layoutManager.numberOfGlyphs
        while glyphIndex < total || (glyphIndex == 0 && total == 0) {
            let container = NSTextContainer(size: CGSize(width: contentWidth, height: contentHeight))
            container.lineFragmentPadding = 0
            layoutManager.addTextContainer(container)

            ctx.beginPage(mediaBox: &mediaBox)
            ctx.saveGState()
            // Flip to AppKit coords for NSLayoutManager.
            ctx.translateBy(x: 0, y: pageRect.height)
            ctx.scaleBy(x: 1, y: -1)

            let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: true)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = nsCtx
            let range = layoutManager.glyphRange(for: container)
            layoutManager.drawBackground(forGlyphRange: range, at: CGPoint(x: margin, y: margin))
            layoutManager.drawGlyphs(forGlyphRange: range, at: CGPoint(x: margin, y: margin))
            NSGraphicsContext.restoreGraphicsState()

            ctx.restoreGState()
            ctx.endPage()

            let used = range.length
            if used == 0 { break }
            glyphIndex = NSMaxRange(range)
            if glyphIndex >= total { break }
        }
        ctx.closePDF()
        return out
    }

    private static func toHTML(source: URL) throws -> URL {
        let kind = FileKind.classify(url: source)
        let body: String
        switch kind {
        case .txt, .md:
            let raw = try String(contentsOf: source, encoding: .utf8)
            let plain = kind == .md ? stripMarkdown(raw) : raw
            body = escapeHTML(plain).replacingOccurrences(of: "\n", with: "<br>\n")
        case .rtf:
            let attr = try attributedString(from: source)
            body = escapeHTML(attr.string).replacingOccurrences(of: "\n", with: "<br>\n")
        default:
            throw ConversionError.unsupported
        }
        let html = """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8"><title>\(escapeHTML(source.deletingPathExtension().lastPathComponent))</title></head>
        <body style="font-family:-apple-system,Helvetica,sans-serif;line-height:1.45;padding:24px;">
        \(body)
        </body></html>
        """
        let out = OutputNamer.adjacent(for: source, ext: "html")
        try html.write(to: out, atomically: true, encoding: .utf8)
        return out
    }

    private static func toTXT(source: URL) throws -> URL {
        let attr = try attributedString(from: source)
        let out = OutputNamer.adjacent(for: source, ext: "txt")
        try attr.string.write(to: out, atomically: true, encoding: .utf8)
        return out
    }

    private static func bodyAttrs() -> [NSAttributedString.Key: Any] {
        [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.black
        ]
    }

    private static func stripMarkdown(_ text: String) -> String {
        var s = text
        // Very small subset: headings, bold/italic markers, links.
        s = s.replacingOccurrences(of: #"(?m)^#{1,6}\s*"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\*\*(.+?)\*\*"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\*(.+?)\*"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\[(.+?)\]\(.+?\)"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"`([^`]+)`"#, with: "$1", options: .regularExpression)
        return s
    }

    private static func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
