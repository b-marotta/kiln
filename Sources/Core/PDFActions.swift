import AppKit
import PDFKit
import Vision
import CoreText
import ImageIO

/// PDF operations always produce a new adjacent file. Page indices are zero based internally.
enum PDFActions {
    static func load(_ url: URL) throws -> PDFDocument {
        guard let doc = PDFDocument(url: url), !doc.isLocked, doc.pageCount > 0 else {
            throw ConversionError.processFailed("PDF vuoto, protetto da password o non leggibile: \(url.lastPathComponent)")
        }
        guard doc.allowsCopying, doc.allowsPrinting else {
            throw ConversionError.processFailed("Il PDF non consente copia o stampa.")
        }
        return doc
    }

    static func indices(_ expression: String, count: Int) throws -> [Int] {
        try groups(expression, count: count).flatMap { $0 }
    }

    static func groups(_ expression: String, count: Int) throws -> [[Int]] {
        let parts = expression.split(separator: ",", omittingEmptySubsequences: false)
        var result: [[Int]] = []
        for part in parts {
            let limits = part.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "-", omittingEmptySubsequences: false)
            guard (1...2).contains(limits.count),
                  let start = Int(limits[0].trimmingCharacters(in: .whitespaces)), start >= 1, start <= count else {
                throw ConversionError.processFailed("Pagine non valide. Usa per esempio 1-2, 5-7 (da 1 a \(count)).")
            }
            let end: Int
            if limits.count == 2 {
                guard let value = Int(limits[1].trimmingCharacters(in: .whitespaces)), value >= start, value <= count else {
                    throw ConversionError.processFailed("Intervallo non valido: \(part).")
                }
                end = value
            } else { end = start }
            result.append((start...end).map { $0 - 1 })
        }
        guard !result.isEmpty else { throw ConversionError.processFailed("Seleziona almeno una pagina.") }
        return result
    }

    static func extract(_ doc: PDFDocument, indices: [Int]) throws -> PDFDocument {
        let output = PDFDocument()
        for index in indices {
            guard let page = doc.page(at: index)?.copy() as? PDFPage else { throw ConversionError.readFailed }
            output.insert(page, at: output.pageCount)
        }
        guard output.pageCount > 0 else { throw ConversionError.processFailed("Il PDF deve contenere almeno una pagina.") }
        return output
    }

    static func merge(_ sources: [URL]) throws -> PDFDocument {
        guard sources.count > 1 else { throw ConversionError.processFailed("Carica almeno due PDF.") }
        let output = PDFDocument()
        for source in sources {
            let doc = try load(source)
            for i in 0..<doc.pageCount {
                guard let page = doc.page(at: i)?.copy() as? PDFPage else { throw ConversionError.readFailed }
                output.insert(page, at: output.pageCount)
            }
        }
        return output
    }

    static func save(_ doc: PDFDocument, source: URL, suffix: String) throws -> URL {
        guard doc.pageCount > 0, let data = doc.dataRepresentation() else { throw ConversionError.writeFailed("PDF vuoto") }
        return try save(data, source: source, suffix: suffix)
    }

    private static func save(_ data: Data, source: URL, suffix: String) throws -> URL {
        let stem = source.deletingPathExtension().appendingPathExtension("pdf")
        let named = stem.deletingLastPathComponent().appendingPathComponent(stem.deletingPathExtension().lastPathComponent + "-" + suffix + ".pdf")
        let target = OutputNamer.adjacent(for: named, ext: "pdf")
        try data.write(to: target, options: .atomic)
        return target
    }

    /// Compression flattens annotations and text.
    static func compress(source: URL, quality: Double, snapshot: Data? = nil) throws -> URL {
        let data = try compressedData(source: source, quality: quality, snapshot: snapshot)
        let original = try Data(contentsOf: source)
        guard data.count < original.count else { throw ConversionError.processFailed("Questo PDF è già compatto: la compressione scelta non riduce le dimensioni. Nessun file creato.") }
        return try save(data, source: source, suffix: "compresso")
    }

    static func compressedData(source: URL, quality: Double, snapshot: Data? = nil) throws -> Data {
        let doc = try snapshot.flatMap(PDFDocument.init(data:)) ?? load(source)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data), let ctx = CGContext(consumer: consumer, mediaBox: nil, nil) else { throw ConversionError.writeFailed("PDF") }
        for i in 0..<doc.pageCount {
            try autoreleasepool {
                guard let page = doc.page(at: i) else { throw ConversionError.readFailed }
                let bounds = page.bounds(for: .mediaBox)
                let rotated = page.rotation % 180 != 0
                let size = rotated ? NSSize(width: bounds.height, height: bounds.width) : bounds.size
                let scale = min(1.5, 2400 / max(size.width, size.height))
                let image = page.thumbnail(of: NSSize(width: size.width * scale, height: size.height * scale), for: .mediaBox)
                guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                      let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: quality]),
                      let jpegSource = CGImageSourceCreateWithData(jpeg as CFData, nil), let cg = CGImageSourceCreateImageAtIndex(jpegSource, 0, nil) else { throw ConversionError.readFailed }
                var rect = CGRect(origin: .zero, size: size)
                let boxData = Data(bytes: &rect, count: MemoryLayout<CGRect>.size)
                ctx.beginPDFPage([kCGPDFContextMediaBox: boxData] as CFDictionary)
                ctx.draw(cg, in: rect)
                ctx.endPDFPage()
            }
        }
        ctx.closePDF()
        return data as Data
    }

    static func recognizedText(snapshot: Data) throws -> String {
        guard let doc = PDFDocument(data: snapshot) else { throw ConversionError.readFailed }
        var pages: [String] = []
        for i in 0..<doc.pageCount {
            let text: String = try autoreleasepool {
                guard let page = doc.page(at: i) else { throw ConversionError.readFailed }
                if let existing = page.string, !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return existing }
                let bounds = page.bounds(for: .mediaBox)
                let scale = min(3, 3000 / max(bounds.width, bounds.height))
                let image = page.thumbnail(of: NSSize(width: bounds.width * scale, height: bounds.height * scale), for: .mediaBox)
                var rect = CGRect(origin: .zero, size: image.size)
                guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { throw ConversionError.readFailed }
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.recognitionLanguages = ["it-IT", "en-US"]
                request.usesLanguageCorrection = true
                try VNImageRequestHandler(cgImage: cg).perform([request])
                return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
            }
            pages.append(text)
        }
        return pages.joined(separator: "\n\n")
    }

    static func saveText(_ text: String, source: URL, page: Int? = nil) throws -> URL {
        let suffix = page.map { "-ocr-pagina-\($0 + 1).txt" } ?? "-ocr.txt"
        let named = source.deletingLastPathComponent().appendingPathComponent(source.deletingPathExtension().lastPathComponent + suffix)
        let output = OutputNamer.adjacent(for: named, ext: "txt")
        try text.write(to: output, atomically: true, encoding: .utf8)
        return output
    }

    /// Bake the signature into a copy of one page; custom annotation appearances are not reliably serialized by PDFKit.
    static func signedPageDocument(_ page: PDFPage, image: CGImage, rect: CGRect) throws -> PDFDocument {
        guard let pageRef = page.pageRef else { throw ConversionError.readFailed }
        let bounds = page.bounds(for: .mediaBox)
        let size = page.rotation % 180 == 0 ? bounds.size : NSSize(width: bounds.height, height: bounds.width)
        var box = CGRect(origin: .zero, size: size)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data), let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { throw ConversionError.writeFailed("Firma") }
        let transform = page.transform(for: .mediaBox)
        ctx.beginPDFPage(nil)
        // Draw the underlying page without PDFKit's tagged-content/accessibility rendering path.
        ctx.saveGState()
        ctx.concatenate(transform)
        ctx.drawPDFPage(pageRef)
        for annotation in page.annotations where annotation.shouldDisplay {
            annotation.draw(with: .mediaBox, in: ctx)
        }
        ctx.restoreGState()
        ctx.draw(image, in: rect.applying(transform))
        ctx.endPDFPage()
        ctx.closePDF()
        // PDFPage.document is weak. Keep the owning document alive through insertion/serialization.
        guard let result = PDFDocument(data: data as Data), let signedPage = result.page(at: 0) else { throw ConversionError.writeFailed("Firma") }
        signedPage.setBounds(page.bounds(for: .cropBox).applying(transform), for: .cropBox)
        return result
    }

    /// Keep the original page artwork and add an invisible searchable text layer.
    static func ocr(source: URL, snapshot: Data? = nil) throws -> URL {
        let doc = try snapshot.flatMap(PDFDocument.init(data:)) ?? load(source)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data), let ctx = CGContext(consumer: consumer, mediaBox: nil, nil) else { throw ConversionError.writeFailed("OCR") }
        var recognized = 0
        for i in 0..<doc.pageCount {
            try autoreleasepool {
                guard let page = doc.page(at: i) else { throw ConversionError.readFailed }
                let bounds = page.bounds(for: .mediaBox)
                // PDFKit's thumbnail applies rotation; recognition uses the same upright geometry.
                let rotated = page.rotation % 180 != 0
                let size = rotated ? NSSize(width: bounds.height, height: bounds.width) : bounds.size
                let image = page.thumbnail(of: NSSize(width: size.width * 2, height: size.height * 2), for: .mediaBox)
                var imageRect = CGRect(origin: .zero, size: image.size)
                guard let cg = image.cgImage(forProposedRect: &imageRect, context: nil, hints: nil) else { throw ConversionError.readFailed }
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.recognitionLanguages = ["it-IT", "en-US"]
                request.usesLanguageCorrection = true
                try VNImageRequestHandler(cgImage: cg).perform([request])
                var rect = CGRect(origin: .zero, size: size)
                let boxData = Data(bytes: &rect, count: MemoryLayout<CGRect>.size)
                ctx.beginPDFPage([kCGPDFContextMediaBox: boxData] as CFDictionary)
                // Use PDFKit's transform, which includes rotation and nonzero media-box origins.
                ctx.saveGState()
                page.draw(with: .mediaBox, to: ctx)
                ctx.restoreGState()
                // Existing selectable text already supplies the search layer.
                if page.string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                    for observation in request.results ?? [] {
                        guard let text = observation.topCandidates(1).first?.string else { continue }
                        let box = observation.boundingBox
                        let font = CTFontCreateWithName("Helvetica" as CFString, max(4, box.height * size.height * 0.8), nil)
                        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
                        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
                        ctx.saveGState()
                        ctx.textMatrix = .identity
                        ctx.translateBy(x: box.minX * size.width, y: box.minY * size.height)
                        if width > 0 { ctx.scaleBy(x: box.width * size.width / width, y: 1) }
                        ctx.textPosition = .zero
                        ctx.setTextDrawingMode(.invisible)
                        CTLineDraw(line, ctx)
                        ctx.restoreGState()
                        recognized += 1
                    }
                } else { recognized += 1 }
                ctx.endPDFPage()
            }
        }
        ctx.closePDF()
        guard recognized > 0 else { throw ConversionError.processFailed("Nessun testo riconosciuto nel PDF.") }
        return try save(data as Data, source: source, suffix: "ocr")
    }
}
