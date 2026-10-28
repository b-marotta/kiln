import AppKit
import ImageIO

@main
enum UpscaleSmoke {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
        print("PASS \(message)")
    }

    static func pixels(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        bytes.withUnsafeMutableBytes {
            let context = CGContext(data: $0.baseAddress, width: image.width, height: image.height,
                                    bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }

    static func main() throws {
        guard CommandLine.arguments.count == 2 else { fatalError("Pass compiled Upscaling resource directory") }
        let resources = URL(fileURLWithPath: CommandLine.arguments[1])
        // Odd dimensions cross tile boundaries in all factors; asymmetric color tests orientation.
        let width = 475, height = 101
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: 0.8, green: 0.1, blue: 0.1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.clear(CGRect(x: 0, y: 0, width: 40, height: height))
        context.setFillColor(red: 0.1, green: 0.7, blue: 0.2, alpha: 0.5)
        context.setBlendMode(.copy)
        context.fill(CGRect(x: 40, y: 0, width: width - 40, height: 30))
        let source = context.makeImage()!
        let before = pixels(source)
        var outputs: [Data] = []
        for factor in ImageUpscaleFactor.allCases {
            var counts: [Int] = []
            let result = try ImageUpscaling.upscale(source, factor: factor, resourceDirectory: resources) { done, total in
                if done > total { fatalError("Invalid progress") }
                counts.append(done)
                if done == total { print("PASS \(factor.title) progress reaches completion") }
            }
            check(result.width == width * factor.rawValue && result.height == height * factor.rawValue, "\(factor.title) exact requested dimensions")
            check(counts.count > 1 && counts == Array(1...counts.count), "\(factor.title) multiple tiles complete in order")
            let bytes = pixels(result)
            func pixel(_ x: Int, _ y: Int, _ c: Int) -> Int { Int(bytes[(y * result.width + x) * 4 + c]) }
            check(pixel(10, 80, 3) == 0, "\(factor.title) transparent pixels retained")
            check(abs(pixel(100 * factor.rawValue, 10 * factor.rawValue, 3) - 255) <= 1, "\(factor.title) opaque region retained")
            check(abs(pixel(100 * factor.rawValue, 90 * factor.rawValue, 3) - 128) <= 1, "\(factor.title) partial alpha retained")
            check(pixel(100 * factor.rawValue, 10 * factor.rawValue, 0) > pixel(100 * factor.rawValue, 10 * factor.rawValue, 1) + 60, "\(factor.title) red channel and orientation")
            check(pixel(100 * factor.rawValue, 90 * factor.rawValue, 1) > pixel(100 * factor.rawValue, 90 * factor.rawValue, 0) + 20, "\(factor.title) green channel and orientation")
            let seam = 96 * factor.rawValue
            check(abs(pixel(seam - 1, 25 * factor.rawValue, 0) - pixel(seam, 25 * factor.rawValue, 0)) < 25, "\(factor.title) uniform color has no tile seam")
            let encoded = try ImageEditing.encode(result, format: .png, quality: 1)
            let decoded = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(encoded as CFData, nil)!, 0, nil)!
            check(decoded.width == width * factor.rawValue && decoded.height == height * factor.rawValue, "\(factor.title) PNG export dimensions")
            outputs.append(encoded)
            let cancellation = ImageUpscaleCancellation()
            do {
                _ = try ImageUpscaling.upscale(source, factor: factor, resourceDirectory: resources, cancellation: cancellation) { _, _ in cancellation.cancel() }
                fatalError("Cancellation ignored")
            } catch is CancellationError { print("PASS \(factor.title) cancellation between tiles") }
        }
        check(outputs.count == 4, "all four factors tested")
        check(outputs[0] != outputs[1], "factors produce distinct inference results")
        check(pixels(source) == before, "source pixels unchanged")
        // A 1-pixel edge exercises reflection without division by zero at every factor.
        let single = source.cropping(to: CGRect(x: 100, y: 50, width: 1, height: 1))!
        for factor in ImageUpscaleFactor.allCases {
            let result = try ImageUpscaling.upscale(single, factor: factor, resourceDirectory: resources)
            check(result.width == factor.rawValue && result.height == factor.rawValue, "\(factor.title) handles 1×1 input")
        }
        let cancelled = ImageUpscaleCancellation(); cancelled.cancel()
        do {
            _ = try ImageUpscaling.upscale(source, factor: .x2, resourceDirectory: resources, cancellation: cancelled)
            fatalError("Pre-cancellation ignored")
        } catch is CancellationError { print("PASS pre-cancelled work rejected") }
        let large = CGContext(data: nil, width: 4000, height: 2501, bitsPerComponent: 8, bytesPerRow: 16000,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
        do {
            _ = try ImageUpscaling.upscale(large, factor: .x2, resourceDirectory: resources)
            fatalError("Oversized input accepted")
        } catch { check(error.localizedDescription.contains("40 megapixel"), "oversized input rejected before loading model") }
    }
}
