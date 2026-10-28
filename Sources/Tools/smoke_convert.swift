import Foundation
import AppKit

@main
enum Smoke {
    static func main() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("kiln-smoke-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        let jpegURL = tmp.appendingPathComponent("sample.jpg")
        let image = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
            NSColor.systemOrange.setFill()
            rect.fill()
            return true
        }
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
        else {
            fatalError("Could not create sample JPEG")
        }
        try data.write(to: jpegURL)

        let out = try ImageConverter.convert(
            ConversionRequest(source: jpegURL, format: .png)
        )
        guard FileManager.default.fileExists(atPath: out.path) else {
            fatalError("Output missing")
        }
        print("OK \(jpegURL.lastPathComponent) -> \(out.lastPathComponent)")
        try? FileManager.default.removeItem(at: tmp)
    }
}
