import Foundation
import ImageIO
import PDFKit

enum MetadataScrubber {
    /// Rewrite image without EXIF/GPS/XMP when possible. Prefer ExifTool if installed.
    static func strip(source: URL) throws -> URL {
        let kind = FileKind.classify(url: source)
        if kind == .pdf {
            return try stripPDF(source: source)
        }
        // SVG has no EXIF/GPS payload ImageIO can rewrite — adjacent copy is a no-op strip.
        if kind == .svg {
            let out = OutputNamer.adjacent(for: source, ext: "svg")
            try FileManager.default.copyItem(at: source, to: out)
            return out
        }
        guard kind.isImage else { throw ConversionError.unsupported }

        if let exiftool = ToolResolver.exiftool {
            let out = OutputNamer.adjacent(for: source, ext: source.pathExtension)
            try FileManager.default.copyItem(at: source, to: out)
            try ProcessRunner.run(
                exiftool,
                arguments: ["-all=", "-overwrite_original", out.path]
            )
            return out
        }

        return try stripWithImageIO(source: source)
    }

    private static func stripWithImageIO(source: URL) throws -> URL {
        guard let cgSource = CGImageSourceCreateWithURL(source as CFURL, nil),
              let uti = CGImageSourceGetType(cgSource),
              CGImageSourceGetCount(cgSource) > 0,
              let image = CGImageSourceCreateImageAtIndex(cgSource, 0, nil)
        else {
            throw ConversionError.readFailed
        }
        let out = OutputNamer.adjacent(for: source, ext: source.pathExtension)
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, uti, 1, nil) else {
            throw ConversionError.writeFailed("metadata dest")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw ConversionError.writeFailed("metadata finalize")
        }
        return out
    }

    private static func stripPDF(source: URL) throws -> URL {
        guard let doc = PDFDocument(url: source) else { throw ConversionError.readFailed }
        doc.documentAttributes = [:]
        let out = OutputNamer.adjacent(for: source, ext: "pdf")
        guard doc.write(to: out) else { throw ConversionError.writeFailed("pdf metadata") }
        return out
    }
}
