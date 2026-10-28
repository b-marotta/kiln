import Foundation

enum ConversionEngine {
    static func perform(action: FanAction, sources: [URL], options: ConversionOptions = .init()) throws -> [URL] {
        guard !sources.isEmpty else { throw ConversionError.unsupported }

        switch action {
        case .convertToPNG:
            return try sources.map { try ImageConverter.convert(source: $0, format: .png, options: options) }
        case .convertToJPEG:
            return try sources.map { try ImageConverter.convert(source: $0, format: .jpeg, options: options) }
        case .convertToHEIC:
            return try sources.map { try ImageConverter.convert(source: $0, format: .heic, options: options) }
        case .convertToWebP:
            return try sources.map { try ImageConverter.convert(source: $0, format: .webp, options: options) }
        case .convertToTIFF:
            return try sources.map { try ImageConverter.convert(source: $0, format: .tiff, options: options) }
        case .convertToBMP:
            return try sources.map { try ImageConverter.convert(source: $0, format: .bmp, options: options) }
        case .convertToAVIF:
            return try sources.map { try ImageConverter.convert(source: $0, format: .avif, options: options) }
        case .convertToPDF:
            if sources.count == 1 {
                let kind = FileKind.classify(url: sources[0])
                if kind.isImage {
                    return [try PDFConverter.imageToSinglePagePDF(source: sources[0])]
                }
                if kind.isDocument && kind != .pdf {
                    return [try DocumentConverter.convert(source: sources[0], action: .convertToPDF)]
                }
                if kind.isSpreadsheet {
                    return [try SpreadsheetConverter.convert(source: sources[0], action: .convertToPDF)]
                }
            }
            if sources.allSatisfy({ FileKind.classify(url: $0).isImage }) {
                return [try PDFConverter.imagesToPDF(sources: sources)]
            }
            if sources.allSatisfy({
                let k = FileKind.classify(url: $0)
                return k.isDocument && k != .pdf
            }) {
                return try sources.map { try DocumentConverter.convert(source: $0, action: .convertToPDF) }
            }
            if sources.allSatisfy({ FileKind.classify(url: $0).isSpreadsheet }) {
                return try sources.map { try SpreadsheetConverter.convert(source: $0, action: .convertToPDF) }
            }
            throw ConversionError.unsupported
        case .imagesToPDF:
            return [try PDFConverter.imagesToPDF(sources: sources)]
        case .pdfToPNG:
            return try PDFConverter.pdfToPNG(source: sources[0])
        case .pdfToJPEG:
            return try PDFConverter.pdfToJPEG(source: sources[0])
        case .pdfToTXT:
            return [try DocumentConverter.pdfToTXT(source: sources[0])]
        case .convertToMP4, .convertToMOV, .convertToMKV, .convertToAVI, .convertToWMV,
             .convertToGIF, .convertToMP3, .convertToM4A, .convertToWAV, .convertToFLAC,
             .convertToOGG, .convertToOPUS, .convertToAIFF, .convertToWMA:
            return try sources.map { try FFmpegConverter.convert(source: $0, action: action) }
        case .stripMetadata:
            return try sources.map { try MetadataScrubber.strip(source: $0) }
        case .zipArchive:
            return [try ArchiveConverter.zip(sources: sources)]
        case .tarArchive:
            return [try ArchiveConverter.tar(sources: sources)]
        case .gzipArchive:
            return [try ArchiveConverter.gzip(sources: sources)]
        case .unzipArchive:
            return try sources.flatMap { try ArchiveConverter.extract(source: $0) }
        case .srtToVTT:
            return try sources.map { try SubtitleConverter.srtToVTT(source: $0) }
        case .vttToSRT:
            return try sources.map { try SubtitleConverter.vttToSRT(source: $0) }
        case .srtToTXT, .vttToTXT:
            return try sources.map { try SubtitleConverter.toTXT(source: $0) }
        case .convertToHTML, .convertToTXT:
            return try sources.map { try DocumentConverter.convert(source: $0, action: action) }
        case .convertToXLSX, .convertToODS, .convertToCSV, .convertToTSV:
            return try sources.map { try SpreadsheetConverter.convert(source: $0, action: action) }
        case .cropImage, .compressImage, .adjustImage, .ocrImage, .upscaleImage,
             .revealInFinder, .copyPath, .copyFiles, .airDrop, .openInTerminal, .floatFiles,
             .trimAudio, .pitchAudio, .speedAudio, .reverseAudio, .volumeAudio,
             .mergePDF, .splitPDF, .compressPDF, .reorderPDF, .ocrPDF, .signPDF:
            throw ConversionError.unsupported
        }
    }
}
