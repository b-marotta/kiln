import AppKit
import CoreImage
import CoreML
import CoreVideo

enum ImageUpscaleFactor: Int, CaseIterable {
    case x2 = 2, x3 = 3, x4 = 4, x5 = 5
    var title: String { "\(rawValue)×" }
    var suffix: String { "\(rawValue)x-pipersr" }
    var passes: Int { self == .x2 ? 1 : self == .x5 ? 3 : 2 }
}

/// Shared with the editor so replacing a job also stops its remaining tiles.
final class ImageUpscaleCancellation {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func check() throws {
        lock.lock(); let value = cancelled; lock.unlock()
        if value { throw CancellationError() }
    }
}

enum ImageUpscaling {
    static let maximumOutputPixels = 40_000_000

    static func upscale(_ image: CGImage, factor: ImageUpscaleFactor = .x2,
                        resourceDirectory: URL? = nil,
                        cancellation: ImageUpscaleCancellation = .init(),
                        progress: (Int, Int) -> Void = { _, _ in }) throws -> CGImage {
        let multiplier = factor.rawValue
        let maximumInput = maximumOutputPixels / (multiplier * multiplier)
        guard image.width > 0, image.height > 0,
              image.width <= maximumInput / image.height else {
            throw ConversionError.processFailed("L’upscaling \(factor.title) supporta fino a 40 megapixel in uscita. Scegli un fattore minore o un’immagine più piccola.")
        }
        try cancellation.check()
        let resources = resourceDirectory ?? Bundle.main.resourceURL?.appendingPathComponent("Upscaling")
        guard let url = resources?.appendingPathComponent("PiperSR_2x.mlmodelc"),
              FileManager.default.fileExists(atPath: url.path) else {
            throw ConversionError.processFailed("Modello PiperSR mancante. Ricompila Kiln.")
        }
        let config = MLModelConfiguration()
        config.computeUnits = .all
        let model = try MLModel(contentsOf: url, configuration: config)
        guard let input = model.modelDescription.inputDescriptionsByName.first,
              let output = model.modelDescription.outputDescriptionsByName.first,
              let constraint = input.value.imageConstraint,
              constraint.pixelsWide == constraint.pixelsHigh, constraint.pixelsWide > 32 else {
            throw ConversionError.processFailed("Modello PiperSR non valido.")
        }
        let tile = constraint.pixelsWide
        let step = tile - 32
        var total = 0, width = image.width, height = image.height
        for _ in 0..<factor.passes {
            total += ((width + step - 1) / step) * ((height + step - 1) / step)
            width *= 2; height *= 2
        }
        var completed = 0
        var current = image
        for pass in 0..<factor.passes {
            try cancellation.check()
            let last = pass == factor.passes - 1
            // The final tiles are resampled directly to 3×/5×. Never allocate a full 8× intermediate.
            current = try renderPass(current, model: model, inputName: input.key, outputName: output.key,
                                     tile: tile, outWidth: last ? image.width * multiplier : current.width * 2,
                                     outHeight: last ? image.height * multiplier : current.height * 2,
                                     cancellation: cancellation) {
                completed += 1
                progress(completed, total)
            }
        }
        return current
    }

    private static func renderPass(_ image: CGImage, model: MLModel, inputName: String, outputName: String,
                                   tile: Int, outWidth: Int, outHeight: Int,
                                   cancellation: ImageUpscaleCancellation, tileCompleted: () -> Void) throws -> CGImage {
        let halo = 16, step = tile - halo * 2
        let width = image.width, height = image.height
        let ratioX = Double(outWidth) / Double(width), ratioY = Double(outHeight) / Double(height)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        var source = [UInt8](repeating: 0, count: width * height * 4)
        try source.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: colorSpace, bitmapInfo: bitmapInfo) else { throw ConversionError.readFailed }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var destination = [UInt8](repeating: 0, count: outWidth * outHeight * 4)
        let context = CIContext(options: [.cacheIntermediates: false])
        for y in stride(from: 0, to: height, by: step) {
            for x in stride(from: 0, to: width, by: step) {
                try cancellation.check()
                try autoreleasepool {
                    var buffer: CVPixelBuffer?
                    let status = CVPixelBufferCreate(kCFAllocatorDefault, tile, tile, kCVPixelFormatType_32BGRA,
                                                    [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
                    guard status == kCVReturnSuccess, let buffer else { throw ConversionError.writeFailed("Buffer upscaling") }
                    CVPixelBufferLockBaseAddress(buffer, [])
                    let pointer = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
                    let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
                    for ty in 0..<tile { for tx in 0..<tile {
                        let sx = reflected(x + tx - halo, count: width)
                        let sy = reflected(y + ty - halo, count: height)
                        let index = (sy * width + sx) * 4, i = ty * rowBytes + tx * 4
                        let alpha = source[index + 3]
                        for c in 0..<3 {
                            let straight = alpha == 0 ? 0 : min(255, (Float(source[index + c]) * 255 / Float(alpha)).rounded())
                            pointer[i + 2 - c] = UInt8(straight)
                        }
                        pointer[i + 3] = 255
                    } }
                    CVPixelBufferUnlockBaseAddress(buffer, [])
                    let provider = try MLDictionaryFeatureProvider(dictionary: [inputName: MLFeatureValue(pixelBuffer: buffer)])
                    let prediction = try model.prediction(from: provider)
                    try cancellation.check()
                    guard let output = prediction.featureValue(for: outputName)?.imageBufferValue,
                          CVPixelBufferGetWidth(output) == tile * 2, CVPixelBufferGetHeight(output) == tile * 2 else {
                        throw ConversionError.writeFailed("Output PiperSR non valido")
                    }
                    let left = x * outWidth / width, top = y * outHeight / height
                    let right = min(x + step, width) * outWidth / width
                    let bottom = min(y + step, height) * outHeight / height
                    let pieceWidth = right - left, pieceHeight = bottom - top
                    var rendered = CIImage(cvPixelBuffer: output)
                    if ratioX != 2 || ratioY != 2 {
                        rendered = rendered.applyingFilter("CILanczosScaleTransform", parameters: [
                            "inputScale": ratioY / 2, "inputAspectRatio": ratioX / ratioY])
                    }
                    // Keep a common global sampling grid across overlapping tiles, including odd dimensions.
                    rendered = rendered.transformed(by: CGAffineTransform(translationX: Double(x - halo) * ratioX,
                                                                           y: Double(y - halo) * ratioY))
                    var rgba = [UInt8](repeating: 0, count: pieceWidth * pieceHeight * 4)
                    rgba.withUnsafeMutableBytes {
                        context.render(rendered, toBitmap: $0.baseAddress!, rowBytes: pieceWidth * 4,
                                       bounds: CGRect(x: left, y: top, width: pieceWidth, height: pieceHeight),
                                       format: .RGBA8, colorSpace: colorSpace)
                    }
                    for oy in 0..<pieceHeight { for ox in 0..<pieceWidth {
                        let dx = left + ox, dy = top + oy
                        let alpha = interpolatedAlpha(source, width: width, height: height,
                                                      x: (Double(dx) + 0.5) / ratioX - 0.5,
                                                      y: (Double(dy) + 0.5) / ratioY - 0.5)
                        let i = (dy * outWidth + dx) * 4, sample = (oy * pieceWidth + ox) * 4
                        for c in 0..<3 { destination[i + c] = UInt8((Float(rgba[sample + c]) * alpha / 255).rounded()) }
                        destination[i + 3] = UInt8(alpha.rounded())
                    } }
                }
                tileCompleted()
            }
        }
        try cancellation.check()
        guard let provider = CGDataProvider(data: Data(destination) as CFData),
              let result = CGImage(width: outWidth, height: outHeight, bitsPerComponent: 8, bitsPerPixel: 32,
                                   bytesPerRow: outWidth * 4, space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
                                   provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else {
            throw ConversionError.writeFailed("Immagine ingrandita")
        }
        return result
    }

    private static func reflected(_ coordinate: Int, count: Int) -> Int {
        guard count > 1 else { return 0 }
        let period = (count - 1) * 2
        let value = ((coordinate % period) + period) % period
        return value < count ? value : period - value
    }

    private static func interpolatedAlpha(_ pixels: [UInt8], width: Int, height: Int, x: Double, y: Double) -> Float {
        let sx = max(0, min(Double(width - 1), x)), sy = max(0, min(Double(height - 1), y))
        let x0 = Int(sx), y0 = Int(sy), fx = Float(sx - Double(x0)), fy = Float(sy - Double(y0))
        func a(_ px: Int, _ py: Int) -> Float { Float(pixels[(py * width + px) * 4 + 3]) }
        let top = a(x0, y0) * (1 - fx) + a(min(x0 + 1, width - 1), y0) * fx
        let bottom = a(x0, min(y0 + 1, height - 1)) * (1 - fx) + a(min(x0 + 1, width - 1), min(y0 + 1, height - 1)) * fx
        return top * (1 - fy) + bottom * fy
    }
}
