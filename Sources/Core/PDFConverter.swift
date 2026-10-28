import AppKit
import Foundation
import ImageIO
import PDFKit

enum PDFConverter {
    static func imagesToPDF(sources: [URL]) throws -> URL {
        let images: [(cg: CGImage, w: CGFloat, h: CGFloat)] = sources.compactMap { url in
            guard FileKind.classify(url: url).isImage else { return nil }
            guard let cg = loadCGImage(url: url) else { return nil }
            return (cg, CGFloat(cg.width), CGFloat(cg.height))
        }
        guard !images.isEmpty else { throw ConversionError.readFailed }

        let out = OutputNamer.adjacent(for: sources[0], ext: "pdf")
        var mediaBox = CGRect(x: 0, y: 0, width: images[0].w, height: images[0].h)
        guard let consumer = CGDataConsumer(url: out as CFURL),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
        else {
            throw ConversionError.writeFailed("pdf context")
        }

        for (cg, w, h) in images {
            var pageBox = CGRect(x: 0, y: 0, width: w, height: h)
            ctx.beginPage(mediaBox: &pageBox)
            ctx.saveGState()
            // PDF y-up: draw image filling the page.
            ctx.draw(cg, in: pageBox)
            ctx.restoreGState()
            ctx.endPage()
        }
        ctx.closePDF()

        // Verify non-empty content.
        guard let written = try? Data(contentsOf: out), written.count > 100 else {
            throw ConversionError.writeFailed("pdf empty")
        }
        return out
    }

    static func pdfToPNG(source: URL) throws -> [URL] {
        try pdfToRaster(source: source, format: .png)
    }

    static func pdfToJPEG(source: URL) throws -> [URL] {
        try pdfToRaster(source: source, format: .jpeg)
    }

    private static func pdfToRaster(source: URL, format: ConversionFormat) throws -> [URL] {
        guard let doc = PDFDocument(url: source), doc.pageCount > 0 else {
            throw ConversionError.readFailed
        }
        let ext = format.pathExtension
        let fileType: NSBitmapImageRep.FileType = format == .jpeg ? .jpeg : .png
        var outputs: [URL] = []
        let baseName = source.deletingPathExtension().lastPathComponent
        let dir = source.deletingLastPathComponent()
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            let scale: CGFloat = 2
            let pixelW = Int((bounds.width * scale).rounded())
            let pixelH = Int((bounds.height * scale).rounded())
            guard pixelW > 0, pixelH > 0 else { continue }

            guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: pixelW,
                pixelsHigh: pixelH,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ) else { continue }

            NSGraphicsContext.saveGraphicsState()
            if let g = NSGraphicsContext(bitmapImageRep: rep) {
                NSGraphicsContext.current = g
                let ctx = g.cgContext
                ctx.setFillColor(NSColor.white.cgColor)
                ctx.fill(CGRect(x: 0, y: 0, width: pixelW, height: pixelH))
                ctx.saveGState()
                ctx.scaleBy(x: scale, y: scale)
                page.draw(with: .mediaBox, to: ctx)
                ctx.restoreGState()
            }
            NSGraphicsContext.restoreGraphicsState()

            let props: [NSBitmapImageRep.PropertyKey: Any] = format == .jpeg
                ? [.compressionFactor: 0.9]
                : [:]
            guard let data = rep.representation(using: fileType, properties: props) else { continue }
            let out = dir.appendingPathComponent("\(baseName)-p\(i + 1).\(ext)")
            let unique = OutputNamer.adjacent(
                for: out.deletingPathExtension().appendingPathExtension("tmp"),
                ext: ext
            )
            let target = FileManager.default.fileExists(atPath: out.path) ? unique : out
            try data.write(to: target)
            outputs.append(target)
        }
        guard !outputs.isEmpty else { throw ConversionError.writeFailed("pdf pages") }
        return outputs
    }

    static func imageToSinglePagePDF(source: URL) throws -> URL {
        try imagesToPDF(sources: [source])
    }

    private static func loadCGImage(url: URL) -> CGImage? {
        if FileKind.classify(url: url) == .svg, let img = NSImage(contentsOf: url) {
            var rect = NSRect(origin: .zero, size: img.size)
            if rect.width < 1 || rect.height < 1 {
                rect.size = NSSize(width: 1024, height: 1024)
            }
            return img.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: true,
            kCGImageSourceShouldAllowFloat: true
        ]
        return CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary)
    }
}
