import AppKit
import CoreImage
import ImageIO
import Vision
import UniformTypeIdentifiers
import zlib

struct ImageAdjustments {
    var brightness = 0.0
    var contrast = 1.0
    var saturation = 1.0
    var exposure = 0.0
    var temperature = 6500.0
    var sharpness = 0.0
}

enum ImageEditing {
    private static let context = CIContext(options: [.cacheIntermediates: false])

    /// Decode upright pixels once. Reject animated/multipage sources rather than silently discarding frames.
    static func load(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) == 1 else {
            throw ConversionError.processFailed("L’editor supporta immagini statiche a pagina singola.")
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
        guard width > 0, height > 0, Double(width) * Double(height) <= 100_000_000 else {
            throw ConversionError.processFailed("Immagine non valida o superiore a 100 megapixel.")
        }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: max(width, height)]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw ConversionError.readFailed }
        return image
    }

    static func thumbnail(_ image: CGImage, maxEdge: CGFloat = 1200) throws -> CGImage {
        let scale = min(1, maxEdge / CGFloat(max(image.width, image.height)))
        let input = CIImage(cgImage: image).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return try raster(input)
    }

    /// Crop uses normalized coordinates with its origin at the top left, matching the preview.
    static func render(_ image: CGImage, crop: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1),
                       adjustments a: ImageAdjustments = .init(), scale: Double = 1) throws -> CGImage {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let normalized = crop.standardized.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !normalized.isNull, normalized.width * w >= 1, normalized.height * h >= 1,
              scale > 0, scale <= 1 else { throw ConversionError.processFailed("Area di ritaglio non valida.") }
        let rect = CGRect(x: normalized.minX * w, y: (1 - normalized.maxY) * h,
                          width: normalized.width * w, height: normalized.height * h).integral
            .intersection(CGRect(x: 0, y: 0, width: w, height: h))
        var result = CIImage(cgImage: image).cropped(to: rect)
            .transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
        let extent = result.extent
        if a.brightness != 0 || a.contrast != 1 || a.saturation != 1 {
            result = result.applyingFilter("CIColorControls", parameters: ["inputBrightness": a.brightness, "inputContrast": a.contrast, "inputSaturation": a.saturation])
        }
        if a.exposure != 0 { result = result.applyingFilter("CIExposureAdjust", parameters: ["inputEV": a.exposure]) }
        if a.temperature != 6500 {
            result = result.applyingFilter("CITemperatureAndTint", parameters: ["inputNeutral": CIVector(x: 6500, y: 0), "inputTargetNeutral": CIVector(x: a.temperature, y: 0)])
        }
        if a.sharpness != 0 {
            result = result.clampedToExtent().applyingFilter("CISharpenLuminance", parameters: ["inputSharpness": a.sharpness]).cropped(to: extent)
        }
        if scale < 1 {
            let width = max(1, floor(extent.width * scale)), height = max(1, floor(extent.height * scale))
            result = result.applyingFilter("CILanczosScaleTransform", parameters: ["inputScale": height / extent.height, "inputAspectRatio": (width / extent.width) / (height / extent.height)])
                .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return try raster(result)
    }

    private static func raster(_ image: CIImage) throws -> CGImage {
        guard let output = context.createCGImage(image, from: image.extent) else { throw ConversionError.writeFailed("Rendering immagine") }
        return output
    }

    static var exportFormats: [ConversionFormat] {
        let writable = CGImageDestinationCopyTypeIdentifiers() as! [String]
        return [.png, .jpeg, .webp, .heic].filter {
            if $0 == .webp { return ToolResolver.cwebp != nil || writable.contains(UTType.webP.identifier) }
            let type = $0 == .heic ? UTType.heic.identifier : $0 == .jpeg ? UTType.jpeg.identifier : UTType.png.identifier
            return writable.contains(type)
        }
    }

    struct CompressionResult {
        let data: Data
        let reusedOriginal: Bool
    }

    /// The original is a candidate only when format and dimensions are unchanged.
    static func compress(_ image: CGImage, source: URL, format: ConversionFormat,
                         quality: Double, preserveOriginal: Bool) throws -> CompressionResult {
        var originalData: Data?
        if preserveOriginal, let input = CGImageSourceCreateWithURL(source as CFURL, nil),
           CGImageSourceGetCount(input) == 1,
           let type = CGImageSourceGetType(input) as String?, type == typeIdentifier(format) {
            originalData = try? Data(contentsOf: source)
        }
        // The source PNG already is a lossless candidate. Do not encode it again on every slider change.
        let encoded = try encode(image, format: format, quality: quality, compress: true,
                                 pngBaseline: format == .png ? originalData : nil)
        if let originalData, originalData.count <= encoded.count {
            return CompressionResult(data: originalData, reusedOriginal: true)
        }
        return CompressionResult(data: encoded, reusedOriginal: false)
    }

    private static func typeIdentifier(_ format: ConversionFormat) -> String {
        switch format {
        case .png: return UTType.png.identifier
        case .jpeg: return UTType.jpeg.identifier
        case .webp: return UTType.webP.identifier
        case .heic: return UTType.heic.identifier
        default: return ""
        }
    }

    static func encode(_ image: CGImage, format: ConversionFormat, quality: Double, compress: Bool = false, pngBaseline: Data? = nil) throws -> Data {
        let q = max(0, min(1, quality))
        if format == .png {
            let lossless = try pngBaseline ?? encode(image, jpeg: false, quality: 1)
            guard compress else { return lossless }
            var best = lossless
            // Prefer a palette with exact alpha over storing four bytes for every pixel.
            if mayBenefitFromPalette(image), let indexed = try indexedPNG(image), indexed.count < best.count { best = indexed }
            if q < 1 {
                let reduced = try reducedColors(image, quality: q)
                let native = try encode(reduced, jpeg: false, quality: 1)
                if native.count < best.count { best = native }
                if mayBenefitFromPalette(reduced), let indexed = try indexedPNG(reduced), indexed.count < best.count { best = indexed }
            }
            return best
        }
        if format == .jpeg {
            let baseline = try encode(image, jpeg: true, quality: q)
            guard compress else { return baseline }
            // Progressive coding can save bytes without lowering the chosen quality.
            let progressive = try encode(image, jpeg: true, quality: q, progressive: true)
            return progressive.count < baseline.count ? progressive : baseline
        }
        if format == .heic || (format == .webp && ToolResolver.cwebp == nil) {
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, typeIdentifier(format) as CFString, 1, nil) else {
                throw ConversionError.writeFailed("Immagine")
            }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: q] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw ConversionError.writeFailed("Immagine") }
            return data as Data
        }
        guard format == .webp, let tool = ToolResolver.cwebp else { throw ConversionError.unsupported }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("input.png")
        let output = directory.appendingPathComponent("output.webp")
        try encode(image, jpeg: false, quality: 1).write(to: input)
        let settings = ["-quiet", "-mt", "-m", "4", "-q", "\(Int((q * 100).rounded()))", "-alpha_q", "100", "-exact"]
        try ProcessRunner.run(tool, arguments: settings + [input.path, "-o", output.path])
        var best = try Data(contentsOf: output)
        if compress && mayBenefitFromPalette(image) {
            // Flat graphics often compress better losslessly than with a photographic codec.
            try ProcessRunner.run(tool, arguments: ["-quiet", "-mt", "-lossless", "-m", "1", "-exact", input.path, "-o", output.path])
            let lossless = try Data(contentsOf: output)
            if lossless.count < best.count { best = lossless }
        }
        return best
    }

    private static func reducedColors(_ image: CGImage, quality: Double) throws -> CGImage {
        let bitmap = try rgbaBitmap(image)
        let pixels = bitmap.data!.assumingMemoryBound(to: UInt8.self)
        // Power-of-two precision avoids irregular color steps that compress poorly.
        let levels = Double((1 << max(2, min(8, Int((2 + quality * 6).rounded())))) - 1)
        // Precompute the channel mapping once instead of dividing and rounding three times per pixel.
        var lookup = [UInt8](repeating: 0, count: 256 * 256)
        for alpha in 1...255 {
            for channel in 0...alpha {
                let value = Double(channel) / Double(alpha)
                lookup[alpha * 256 + channel] = UInt8(max(0, min(alpha, Int((value * levels).rounded() / levels * Double(alpha)))))
            }
        }
        lookup.withUnsafeBufferPointer { table in
            for offset in stride(from: 0, to: image.width * image.height * 4, by: 4) {
                let row = Int(pixels[offset + 3]) * 256
                pixels[offset] = table[row + Int(pixels[offset])]
                pixels[offset + 1] = table[row + Int(pixels[offset + 1])]
                pixels[offset + 2] = table[row + Int(pixels[offset + 2])]
            }
        }
        guard let reduced = bitmap.makeImage() else { throw ConversionError.writeFailed("PNG") }
        return reduced
    }

    /// Sampling only chooses encoder effort; it never changes pixels or quality.
    private static func mayBenefitFromPalette(_ image: CGImage) -> Bool {
        let width = min(64, image.width), height = min(64, image.height)
        guard let bitmap = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            let bytes = bitmap.data else { return false }
        bitmap.interpolationQuality = .none
        bitmap.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = bytes.assumingMemoryBound(to: UInt32.self)
        var colors = Set<UInt32>()
        for offset in 0..<(width * height) {
            colors.insert(pixels[offset])
            if colors.count > 256 { return false }
        }
        return true
    }

    private static func rgbaBitmap(_ image: CGImage) throws -> CGContext {
        guard let bitmap = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
            throw ConversionError.writeFailed("PNG")
        }
        bitmap.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return bitmap
    }

    /// Standard indexed PNG: PLTE + tRNS retains transparency, including partial alpha.
    private static func indexedPNG(_ image: CGImage) throws -> Data? {
        // Avoid reducing 16-bit or wide-gamut sources just to obtain a smaller palette.
        guard image.bitsPerComponent <= 8, image.colorSpace?.name == CGColorSpace.sRGB else { return nil }
        let bitmap = try rgbaBitmap(image)
        let pixels = bitmap.data!.assumingMemoryBound(to: UInt8.self)
        var palette: [UInt32: UInt8] = [:]
        var colors: [UInt32] = []
        var indices = Data(capacity: (image.width + 1) * image.height)
        for y in 0..<image.height {
            indices.append(0) // PNG filter None, effective for palette indices.
            for x in 0..<image.width {
                let offset = (y * image.width + x) * 4
                let alpha = UInt32(pixels[offset + 3])
                var color = alpha
                for channel in 0..<3 {
                    let value = alpha == 0 ? 0 : min(255, (UInt32(pixels[offset + channel]) * 255 + alpha / 2) / alpha)
                    color |= value << UInt32(24 - channel * 8)
                }
                if let index = palette[color] { indices.append(index) }
                else {
                    guard colors.count < 256 else { return nil }
                    let index = UInt8(colors.count)
                    palette[color] = index; colors.append(color); indices.append(index)
                }
            }
        }
        var compressedLength = compressBound(uLong(indices.count))
        var compressed = Data(count: Int(compressedLength))
        let status = compressed.withUnsafeMutableBytes { destination in
            indices.withUnsafeBytes { input in
                compress2(destination.bindMemory(to: Bytef.self).baseAddress!, &compressedLength,
                          input.bindMemory(to: Bytef.self).baseAddress!, uLong(indices.count), Z_BEST_COMPRESSION)
            }
        }
        guard status == Z_OK else { throw ConversionError.writeFailed("PNG zlib") }
        compressed.count = Int(compressedLength)
        var png = Data([137, 80, 78, 71, 13, 10, 26, 10])
        func integer(_ value: UInt32) -> Data {
            var bigEndian = value.bigEndian
            return withUnsafeBytes(of: &bigEndian) { Data($0) }
        }
        func chunk(_ name: String, _ bytes: Data) {
            let payload = Data(name.utf8) + bytes
            png.append(integer(UInt32(bytes.count)))
            png.append(payload)
            let crc = payload.withUnsafeBytes { crc32(0, $0.bindMemory(to: Bytef.self).baseAddress!, uInt(payload.count)) }
            png.append(integer(UInt32(crc)))
        }
        chunk("IHDR", integer(UInt32(image.width)) + integer(UInt32(image.height)) + Data([8, 3, 0, 0, 0]))
        chunk("sRGB", Data([0]))
        var rgb = Data(), alpha = Data()
        for color in colors {
            rgb.append(contentsOf: [UInt8(color >> 24), UInt8((color >> 16) & 255), UInt8((color >> 8) & 255)])
            alpha.append(UInt8(color & 255))
        }
        chunk("PLTE", rgb)
        if alpha.contains(where: { $0 != 255 }) { chunk("tRNS", alpha) }
        chunk("IDAT", compressed)
        chunk("IEND", Data())
        return png
    }

    static func encode(_ image: CGImage, jpeg: Bool, quality: Double, progressive: Bool = false) throws -> Data {
        var outputImage = image
        if jpeg {
            // JPEG has no alpha: flatten explicitly onto white, never silently onto black.
            guard let bitmap = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw ConversionError.writeFailed("JPEG") }
            bitmap.setFillColor(CGColor(gray: 1, alpha: 1))
            bitmap.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            bitmap.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            guard let flattened = bitmap.makeImage() else { throw ConversionError.writeFailed("JPEG") }
            outputImage = flattened
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, (jpeg ? UTType.jpeg.identifier : UTType.png.identifier) as CFString, 1, nil) else { throw ConversionError.writeFailed("Immagine") }
        var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: max(0, min(1, quality))]
        if jpeg && progressive { properties[kCGImagePropertyJFIFDictionary] = [kCGImagePropertyJFIFIsProgressive: true] }
        CGImageDestinationAddImage(destination, outputImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ConversionError.writeFailed("Immagine") }
        return data as Data
    }

    static func recognize(_ image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["it-IT", "en-US"]
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    static func save(_ data: Data, source: URL, suffix: String, ext: String) throws -> URL {
        let base = source.deletingPathExtension().lastPathComponent
        let proposed = source.deletingLastPathComponent().appendingPathComponent(base + "-" + suffix + "." + ext)
        let url = OutputNamer.adjacent(for: proposed, ext: ext)
        try data.write(to: url, options: .withoutOverwriting)
        return url
    }
}
