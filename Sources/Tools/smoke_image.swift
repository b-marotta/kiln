import AppKit
import ImageIO
import UniformTypeIdentifiers

@main
enum ImageSmoke {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
        print("PASS \(message)")
    }
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kiln-image-smoke-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bitmap = CGContext(data: nil, width: 400, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                               space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        bitmap.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        bitmap.fill(CGRect(x: 0, y: 100, width: 400, height: 100))
        let image = bitmap.makeImage()!
        let input = directory.appendingPathComponent("source.png")
        let originalData = try ImageEditing.encode(image, jpeg: false, quality: 1)
        try originalData.write(to: input)
        let loaded = try ImageEditing.load(input)
        check(loaded.width == 400 && loaded.height == 200, "load dimensions")
        let cropped = try ImageEditing.render(loaded, crop: CGRect(x: 0.25, y: 0, width: 0.5, height: 0.5))
        check(cropped.width == 200 && cropped.height == 100, "normalized crop dimensions")
        let sample = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                               space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        sample.draw(cropped, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let pixel = sample.data!.assumingMemoryBound(to: UInt8.self)
        check(pixel[0] > 240 && pixel[1] < 60 && pixel[3] > 240, "top-left crop keeps red upper half")
        let scaled = try ImageEditing.render(loaded, scale: 0.5)
        check(scaled.width == 200 && scaled.height == 100, "50 percent pixel resize")
        var adjustments = ImageAdjustments()
        adjustments.brightness = -0.3; adjustments.exposure = -1
        let adjusted = try ImageEditing.render(cropped, adjustments: adjustments)
        sample.draw(adjusted, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        check(pixel[0] < 230, "adjustments change output pixels")
        let png = try ImageEditing.encode(loaded, jpeg: false, quality: 0.5)
        let pngSource = CGImageSourceCreateWithData(png as CFData, nil)!
        let pngImage = CGImageSourceCreateImageAtIndex(pngSource, 0, nil)!
        sample.clear(CGRect(x: 0, y: 0, width: 1, height: 1))
        sample.draw(pngImage.cropping(to: CGRect(x: 0, y: 150, width: 1, height: 1))!, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        check(pixel[3] < 10, "PNG retains transparent lower half")
        let jpg = try ImageEditing.encode(loaded, jpeg: true, quality: 0.9)
        let jpgSource = CGImageSourceCreateWithData(jpg as CFData, nil)!
        let jpgImage = CGImageSourceCreateImageAtIndex(jpgSource, 0, nil)!
        sample.draw(jpgImage.cropping(to: CGRect(x: 0, y: 150, width: 1, height: 1))!, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        check(pixel[0] > 245 && pixel[1] > 245 && pixel[2] > 245 && pixel[3] == 255, "JPEG flattens transparency onto white")
        let gradient = CGContext(data: nil, width: 256, height: 128, bitsPerComponent: 8, bytesPerRow: 1024,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let values = gradient.data!.assumingMemoryBound(to: UInt8.self)
        var noise: UInt32 = 12345
        for y in 0..<128 {
            for x in 0..<256 {
                let i = (y * 256 + x) * 4
                for channel in 0..<3 {
                    noise = noise &* 1664525 &+ 1013904223
                    values[i + channel] = UInt8((noise >> 24) / 2)
                }
                values[i + 3] = 128
            }
        }
        let fixture = gradient.makeImage()!
        for format in ImageEditing.exportFormats {
            let high = try ImageEditing.encode(fixture, format: format, quality: 1, compress: true)
            let low = try ImageEditing.encode(fixture, format: format, quality: 0.1, compress: true)
            check(high != low, "quality changes \(format.pathExtension) output")
            let decodedSource = CGImageSourceCreateWithData(low as CFData, nil)!
            let decoded = CGImageSourceCreateImageAtIndex(decodedSource, 0, nil)!
            check(decoded.width == 256 && decoded.height == 128, "quality preserves \(format.pathExtension) dimensions")
            if format == .png {
                sample.clear(CGRect(x: 0, y: 0, width: 1, height: 1))
                sample.draw(decoded, in: CGRect(x: 0, y: 0, width: 1, height: 1))
                check(abs(Int(pixel[3]) - 128) <= 1, "PNG quality retains partial alpha")
                check(low.count < high.count, "PNG lower quality reduces noisy image size")
            }
        }
        let paletteBitmap = CGContext(data: nil, width: 512, height: 256, bitsPerComponent: 8, bytesPerRow: 2048,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        paletteBitmap.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        paletteBitmap.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
        paletteBitmap.setFillColor(red: 0, green: 1, blue: 0, alpha: 0.5)
        paletteBitmap.fill(CGRect(x: 256, y: 0, width: 256, height: 128))
        let paletteImage = paletteBitmap.makeImage()!
        let nativePNG = try ImageEditing.encode(paletteImage, jpeg: false, quality: 1)
        let optimizedPNG = try ImageEditing.encode(paletteImage, format: .png, quality: 1, compress: true)
        check(optimizedPNG.count < nativePNG.count, "palette PNG improves flat artwork at full quality")
        check(optimizedPNG[25] == 3, "PNG selects indexed representation")
        let paletteSource = CGImageSourceCreateWithData(optimizedPNG as CFData, nil)!
        let paletteDecoded = CGImageSourceCreateImageAtIndex(paletteSource, 0, nil)!
        let decodedBitmap = CGContext(data: nil, width: 512, height: 256, bitsPerComponent: 8, bytesPerRow: 2048,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        decodedBitmap.draw(paletteDecoded, in: CGRect(x: 0, y: 0, width: 512, height: 256))
        let expected = Data(bytes: paletteBitmap.data!, count: 512 * 256 * 4)
        let actual = Data(bytes: decodedBitmap.data!, count: 512 * 256 * 4)
        check(expected == actual, "indexed PNG retains exact rendered pixels and all alpha values")
        for format in ImageEditing.exportFormats {
            let url = directory.appendingPathComponent("optimized." + format.pathExtension)
            let compact = try ImageEditing.encode(fixture, format: format, quality: 0.1, compress: true)
            try compact.write(to: url)
            let decodedInput = try ImageEditing.load(url)
            let result = try ImageEditing.compress(decodedInput, source: url, format: format, quality: 1, preserveOriginal: true)
            check(result.data.count <= compact.count, "\(format.pathExtension) never grows at unchanged dimensions")
            if result.reusedOriginal { check(result.data == compact, "\(format.pathExtension) fallback keeps original bytes") }
            let half = try ImageEditing.render(decodedInput, scale: 0.5)
            let resized = try ImageEditing.compress(half, source: url, format: format, quality: 0.8, preserveOriginal: false)
            check(!resized.reusedOriginal, "\(format.pathExtension) resize cannot silently reuse original")
            let resizedSource = CGImageSourceCreateWithData(resized.data as CFData, nil)!
            let resizedImage = CGImageSourceCreateImageAtIndex(resizedSource, 0, nil)!
            check(resizedImage.width == 128 && resizedImage.height == 64, "\(format.pathExtension) compression honors requested dimensions")
            let unchanged = try Data(contentsOf: url)
            check(unchanged == compact, "\(format.pathExtension) source stays untouched")
        }
        let orientationURL = directory.appendingPathComponent("rotated.jpg")
        let destination = CGImageDestinationCreateWithURL(orientationURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, cropped, [kCGImagePropertyOrientation: 6] as CFDictionary)
        check(CGImageDestinationFinalize(destination), "orientation fixture encoded")
        let upright = try ImageEditing.load(orientationURL)
        check(upright.width == 100 && upright.height == 200, "EXIF orientation normalized")
        let first = try ImageEditing.save(png, source: input, suffix: "ritaglio", ext: "png")
        let second = try ImageEditing.save(png, source: input, suffix: "ritaglio", ext: "png")
        let untouched = try Data(contentsOf: input)
        check(first != second && first != input && untouched == originalData, "exports are unique and source is unchanged")
        check(ActionAvailability.actions(for: [input], mode: .fileActions) == [.cropImage, .compressImage, .adjustImage, .upscaleImage, .ocrImage], "single image exposes five editor actions")
        check(!ActionAvailability.actions(for: [input, input], mode: .fileActions).contains(.cropImage), "multiple images do not enter single-image editor")
        let textImage = NSImage(size: NSSize(width: 1000, height: 180), flipped: false) { rect in
            NSColor.white.setFill(); rect.fill()
            ("KILN TEST 123" as NSString).draw(at: NSPoint(x: 40, y: 60), withAttributes: [.font: NSFont.systemFont(ofSize: 64), .foregroundColor: NSColor.black])
            return true
        }
        var rect = CGRect(x: 0, y: 0, width: 1000, height: 180)
        let textCG = textImage.cgImage(forProposedRect: &rect, context: nil, hints: nil)!
        let recognized = try ImageEditing.recognize(textCG)
        check(recognized.contains("KILN") && recognized.contains("123"), "Vision extracts rendered text")
    }
}
