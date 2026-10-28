import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ImageConverter {
    /// ImageIO can encode AVIF on recent macOS (UTI `public.avif`).
    static var supportsAVIFEncode: Bool {
        if let cached = _avifEncodeSupported { return cached }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("kiln-avif-probe.avif")
        let ok = CGImageDestinationCreateWithURL(tmp as CFURL, "public.avif" as CFString, 1, nil) != nil
        try? FileManager.default.removeItem(at: tmp)
        _avifEncodeSupported = ok
        return ok
    }
    private static var _avifEncodeSupported: Bool?

    static func convert(source: URL, format: ConversionFormat, options: ConversionOptions) throws -> URL {
        let kind = FileKind.classify(url: source)
        guard kind.isImage else { throw ConversionError.unsupported }

        if format == .webp {
            if kind == .svg {
                let raster = try loadCGImage(from: source)
                return try encodeCGImage(raster, source: source, format: .webp, options: options)
            }
            if ToolResolver.cwebp != nil {
                return try convertViaCWebP(source: source, options: options)
            }
            return try convertViaImageIOWebP(source: source, options: options)
        }

        let image = try loadCGImage(from: source)
        return try encodeCGImage(image, source: source, format: format, options: options)
    }

    private static func loadCGImage(from source: URL) throws -> CGImage {
        if FileKind.classify(url: source) == .svg {
            return try rasterizeSVG(source: source)
        }
        guard let cgSource = CGImageSourceCreateWithURL(source as CFURL, nil),
              CGImageSourceGetCount(cgSource) > 0,
              let image = CGImageSourceCreateImageAtIndex(cgSource, 0, nil)
        else {
            throw ConversionError.readFailed
        }
        return image
    }

    private static func rasterizeSVG(source: URL) throws -> CGImage {
        guard let nsImage = NSImage(contentsOf: source) else {
            throw ConversionError.readFailed
        }
        var rect = NSRect(origin: .zero, size: nsImage.size)
        if rect.width < 1 || rect.height < 1 {
            rect.size = NSSize(width: 1024, height: 1024)
        }
        // Cap huge SVGs.
        let maxEdge: CGFloat = 4096
        if rect.width > maxEdge || rect.height > maxEdge {
            let scale = min(maxEdge / rect.width, maxEdge / rect.height)
            rect.size = NSSize(width: rect.width * scale, height: rect.height * scale)
        }
        guard let cg = nsImage.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            // Fallback: draw into bitmap.
            guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(rect.width.rounded()),
                pixelsHigh: Int(rect.height.rounded()),
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ) else { throw ConversionError.readFailed }
            NSGraphicsContext.saveGraphicsState()
            if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
                NSGraphicsContext.current = ctx
                nsImage.draw(in: NSRect(origin: .zero, size: rect.size))
            }
            NSGraphicsContext.restoreGraphicsState()
            guard let drawn = rep.cgImage else { throw ConversionError.readFailed }
            return drawn
        }
        return cg
    }

    private static func encodeCGImage(
        _ image: CGImage,
        source: URL,
        format: ConversionFormat,
        options: ConversionOptions
    ) throws -> URL {
        if format == .webp {
            // Write PNG temp then cwebp, or ImageIO WebP from CGImage.
            if let cwebp = ToolResolver.cwebp {
                let tmpPNG = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString + ".png")
                defer { try? FileManager.default.removeItem(at: tmpPNG) }
                try writeCGImage(image, to: tmpPNG, typeID: UTType.png.identifier as CFString, options: options)
                let out = OutputNamer.adjacent(for: source, ext: "webp")
                let q = Int((options.jpegQuality * 100).rounded())
                try ProcessRunner.run(cwebp, arguments: ["-q", "\(q)", tmpPNG.path, "-o", out.path])
                return out
            }
            return try writeCGImage(
                image,
                to: OutputNamer.adjacent(for: source, ext: "webp"),
                typeID: UTType.webP.identifier as CFString,
                options: options
            )
        }

        let destinationURL = OutputNamer.adjacent(for: source, ext: format.pathExtension)
        let typeID: CFString
        switch format {
        case .png: typeID = UTType.png.identifier as CFString
        case .jpeg: typeID = UTType.jpeg.identifier as CFString
        case .heic: typeID = UTType.heic.identifier as CFString
        case .tiff: typeID = UTType.tiff.identifier as CFString
        case .bmp: typeID = UTType.bmp.identifier as CFString
        case .avif:
            guard supportsAVIFEncode else { throw ConversionError.unsupported }
            typeID = "public.avif" as CFString
        case .pdf: typeID = UTType.pdf.identifier as CFString
        default: throw ConversionError.unsupported
        }
        return try writeCGImage(image, to: destinationURL, typeID: typeID, options: options)
    }

    @discardableResult
    private static func writeCGImage(
        _ image: CGImage,
        to destinationURL: URL,
        typeID: CFString,
        options: ConversionOptions
    ) throws -> URL {
        guard let destination = CGImageDestinationCreateWithURL(destinationURL as CFURL, typeID, 1, nil) else {
            throw ConversionError.writeFailed("destination")
        }
        var properties: [CFString: Any] = [:]
        let id = typeID as String
        if id == UTType.jpeg.identifier || id == UTType.heic.identifier || id == "public.avif" || id == UTType.webP.identifier {
            properties[kCGImageDestinationLossyCompressionQuality] = options.jpegQuality
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ConversionError.writeFailed("finalize")
        }
        return destinationURL
    }

    private static func convertViaCWebP(source: URL, options: ConversionOptions) throws -> URL {
        guard let cwebp = ToolResolver.cwebp else { throw ConversionError.toolMissing("cwebp") }
        let out = OutputNamer.adjacent(for: source, ext: "webp")
        let q = Int((options.jpegQuality * 100).rounded())
        try ProcessRunner.run(cwebp, arguments: ["-q", "\(q)", source.path, "-o", out.path])
        return out
    }

    private static func convertViaImageIOWebP(source: URL, options: ConversionOptions) throws -> URL {
        guard let cgSource = CGImageSourceCreateWithURL(source as CFURL, nil),
              CGImageSourceGetCount(cgSource) > 0,
              let image = CGImageSourceCreateImageAtIndex(cgSource, 0, nil)
        else {
            throw ConversionError.readFailed
        }
        return try writeCGImage(
            image,
            to: OutputNamer.adjacent(for: source, ext: "webp"),
            typeID: UTType.webP.identifier as CFString,
            options: options
        )
    }
}
