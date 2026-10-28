import Foundation
import UniformTypeIdentifiers

enum FanMode: Int, Sendable, CaseIterable {
    case convert = 0
    case fileTools = 1
    case fileActions = 2
}

enum FanAction: String, Sendable, CaseIterable, Identifiable {
    case convertToPNG
    case convertToJPEG
    case convertToHEIC
    case convertToWebP
    case convertToTIFF
    case convertToBMP
    case convertToAVIF
    case convertToPDF
    case convertToMP4
    case convertToMOV
    case convertToMKV
    case convertToAVI
    case convertToWMV
    case convertToGIF
    case convertToMP3
    case convertToM4A
    case convertToWAV
    case convertToFLAC
    case convertToOGG
    case convertToOPUS
    case convertToAIFF
    case convertToWMA
    case imagesToPDF
    case pdfToPNG
    case pdfToJPEG
    case pdfToTXT
    case mergePDF, splitPDF, compressPDF, reorderPDF, ocrPDF, signPDF
    case stripMetadata
    case zipArchive
    case tarArchive
    case gzipArchive
    case unzipArchive
    case srtToVTT
    case vttToSRT
    case srtToTXT
    case vttToTXT
    case convertToHTML
    case convertToTXT
    case convertToXLSX
    case convertToODS
    case convertToCSV
    case convertToTSV
    case revealInFinder
    case copyPath
    case copyFiles
    case airDrop
    case openInTerminal
    case floatFiles
    case compressImage
    case cropImage, adjustImage, ocrImage, upscaleImage
    case trimAudio
    case pitchAudio
    case speedAudio
    case reverseAudio
    case volumeAudio

    var id: String { rawValue }

    var title: String {
        switch self {
        case .convertToPNG: return "PNG"
        case .convertToJPEG: return "JPEG"
        case .convertToHEIC: return "HEIC"
        case .convertToWebP: return "WebP"
        case .convertToTIFF: return "TIFF"
        case .convertToBMP: return "BMP"
        case .convertToAVIF: return "AVIF"
        case .convertToPDF: return "PDF"
        case .convertToMP4: return "MP4"
        case .convertToMOV: return "MOV"
        case .convertToMKV: return "MKV"
        case .convertToAVI: return "AVI"
        case .convertToWMV: return "WMV"
        case .convertToGIF: return "GIF"
        case .convertToMP3: return "MP3"
        case .convertToM4A: return "M4A"
        case .convertToWAV: return "WAV"
        case .convertToFLAC: return "FLAC"
        case .convertToOGG: return "OGG"
        case .convertToOPUS: return "OPUS"
        case .convertToAIFF: return "AIFF"
        case .convertToWMA: return "WMA"
        case .imagesToPDF: return "Images → PDF"
        case .pdfToPNG: return "PNG"
        case .pdfToJPEG: return "JPEG"
        case .pdfToTXT: return "TXT"
        case .mergePDF: return "Unisci"
        case .splitPDF: return "Dividi"
        case .compressPDF: return "Comprimi"
        case .reorderPDF: return "Riordina"
        case .ocrPDF: return "Trascrivi"
        case .signPDF: return "Firma"
        case .stripMetadata: return "Strip metadata"
        case .zipArchive: return "ZIP"
        case .tarArchive: return "TAR"
        case .gzipArchive: return "GZIP"
        case .unzipArchive: return "Extract"
        case .srtToVTT: return "SRT → VTT"
        case .vttToSRT: return "VTT → SRT"
        case .srtToTXT: return "SRT → TXT"
        case .vttToTXT: return "VTT → TXT"
        case .convertToHTML: return "HTML"
        case .convertToTXT: return "TXT"
        case .convertToXLSX: return "XLSX"
        case .convertToODS: return "ODS"
        case .convertToCSV: return "CSV"
        case .convertToTSV: return "TSV"
        case .revealInFinder: return "Reveal in Finder"
        case .copyPath: return "Copy path"
        case .copyFiles: return "Copy"
        case .airDrop: return "AirDrop"
        case .openInTerminal: return "Open in Terminal"
        case .floatFiles: return "Float"
        case .compressImage: return "Comprimi"
        case .cropImage: return "Ritaglia"
        case .adjustImage: return "Regola"
        case .ocrImage: return "Trascrivi"
        case .upscaleImage: return "Ingrandisci"
        case .trimAudio: return "Taglia"
        case .pitchAudio: return "Tonalità"
        case .speedAudio: return "Velocità"
        case .reverseAudio: return "Reverse"
        case .volumeAudio: return "Volume"
        }
    }

    var mode: FanMode {
        switch self {
        case .cropImage, .adjustImage, .ocrImage, .compressImage, .upscaleImage,
             .revealInFinder, .copyPath, .copyFiles, .airDrop, .openInTerminal, .floatFiles,
             .trimAudio, .pitchAudio, .speedAudio, .reverseAudio, .volumeAudio,
             .mergePDF, .splitPDF, .compressPDF, .reorderPDF, .ocrPDF, .signPDF:
            return .fileActions
        case .stripMetadata, .zipArchive, .tarArchive, .gzipArchive, .unzipArchive:
            return .fileTools
        default:
            return .convert
        }
    }
}

enum FileKind: Int, Sendable, Hashable, CaseIterable {
    case unknown
    case jpeg, png, heic, tiff, webp, gif, bmp, avif, svg
    case pdf
    case mp4, mov, mkv, webm, avi, wmv
    case mp3, m4a, wav, flac, aiff, ogg, opus, wma
    case zip, tar, gzip, rar
    case srt, vtt
    case txt, md, rtf, html, doc, docx
    case xlsx, xls, ods, csv, tsv
    case directory
    case otherFile

    static func classify(url: URL) -> FileKind {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            return .unknown
        }
        if isDir.boolValue { return .directory }

        let name = url.lastPathComponent.lowercased()
        if name.hasSuffix(".tar.gz") || name.hasSuffix(".tgz") {
            return .gzip
        }

        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": return .jpeg
        case "png": return .png
        case "heic", "heif": return .heic
        case "tif", "tiff": return .tiff
        case "webp": return .webp
        case "gif": return .gif
        case "bmp": return .bmp
        case "avif": return .avif
        case "svg": return .svg
        case "pdf": return .pdf
        case "mp4": return .mp4
        case "mov": return .mov
        case "mkv": return .mkv
        case "webm": return .webm
        case "avi": return .avi
        case "wmv": return .wmv
        case "mp3": return .mp3
        case "m4a": return .m4a
        case "wav": return .wav
        case "flac": return .flac
        case "aiff", "aif": return .aiff
        case "ogg": return .ogg
        case "opus": return .opus
        case "wma": return .wma
        case "zip": return .zip
        case "tar": return .tar
        case "gz": return .gzip
        case "rar": return .rar
        case "srt": return .srt
        case "vtt": return .vtt
        case "doc": return .doc
        case "docx": return .docx
        case "txt": return .txt
        case "md", "markdown": return .md
        case "rtf": return .rtf
        case "html", "htm": return .html
        case "xlsx": return .xlsx
        case "xls": return .xls
        case "ods": return .ods
        case "csv": return .csv
        case "tsv": return .tsv
        default: return .otherFile
        }
    }

    var isImage: Bool {
        [.jpeg, .png, .heic, .tiff, .webp, .gif, .bmp, .avif, .svg].contains(self)
    }

    var isVideo: Bool {
        [.mp4, .mov, .mkv, .webm, .avi, .wmv, .gif].contains(self)
    }

    var isAudio: Bool {
        [.mp3, .m4a, .wav, .flac, .aiff, .ogg, .opus, .wma].contains(self)
    }

    var isArchive: Bool {
        [.zip, .tar, .gzip, .rar].contains(self)
    }

    var isDocument: Bool {
        [.txt, .md, .rtf, .html, .doc, .docx, .pdf].contains(self)
    }

    var isSpreadsheet: Bool {
        [.xlsx, .xls, .ods, .csv, .tsv].contains(self)
    }
}

struct ConversionOptions: Sendable {
    var jpegQuality: Double = 0.9
    var preserveMetadata: Bool = false
}

enum ConversionFormat: String, Sendable, CaseIterable {
    case png, jpeg, heic, webp, tiff, bmp, avif, pdf
    case mp4, mov, mkv, avi, wmv, gif
    case mp3, m4a, wav, flac, ogg, opus, aiff, wma
    case zip, tar, gzip
    case vtt, srt, txt, html
    case xlsx, ods, csv, tsv

    var pathExtension: String {
        switch self {
        case .jpeg: return "jpg"
        case .tiff: return "tiff"
        default: return rawValue
        }
    }
}

struct ConversionRequest: Sendable {
    var sources: [URL]
    var action: FanAction
    var options: ConversionOptions = .init()
}

enum ConversionError: LocalizedError {
    case unsupported
    case toolMissing(String)
    case readFailed
    case writeFailed(String)
    case processFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupported: return "Unsupported conversion"
        case .toolMissing(let t): return "Required tool not found: \(t)"
        case .readFailed: return "Could not read input"
        case .writeFailed(let d): return "Write failed: \(d)"
        case .processFailed(let d): return d
        }
    }
}

enum OutputNamer {
    static func adjacent(for source: URL, ext: String) -> URL {
        let dir = source.deletingLastPathComponent()
        let base = source.deletingPathExtension().lastPathComponent
        // file.tar.gz → base "file.tar" is wrong; strip known compound suffix.
        let cleanedBase: String = {
            let lower = source.lastPathComponent.lowercased()
            if lower.hasSuffix(".tar.gz") {
                return String(source.lastPathComponent.dropLast(".tar.gz".count))
            }
            if lower.hasSuffix(".tgz") {
                return String(source.lastPathComponent.dropLast(".tgz".count))
            }
            return base
        }()
        var candidate = dir.appendingPathComponent("\(cleanedBase).\(ext)")
        var n = 1
        let fm = FileManager.default
        while fm.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(cleanedBase)-\(n).\(ext)")
            n += 1
        }
        return candidate
    }
}

enum ActionAvailability {
    static func actions(for urls: [URL], mode: FanMode) -> [FanAction] {
        let kinds = Set(urls.map(FileKind.classify))
        guard !urls.isEmpty else { return [] }

        switch mode {
        case .fileActions:
            if urls.count == 1, kinds.allSatisfy({ $0.isImage && $0 != .gif && $0 != .svg }) {
                return [.cropImage, .compressImage, .adjustImage, .upscaleImage, .ocrImage]
            }
            if kinds == [.pdf] {
                return urls.count > 1 ? [.mergePDF] : [.splitPDF, .compressPDF, .reorderPDF, .ocrPDF, .signPDF]
            }
            if kinds.allSatisfy(\.isDocument) {
                return urls.count > 1 ? [.mergePDF] : [.splitPDF, .reorderPDF, .signPDF]
            }
            return urls.count == 1 && kinds.allSatisfy(\.isAudio)
                ? [.trimAudio, .pitchAudio, .speedAudio, .reverseAudio, .volumeAudio] : []

        case .fileTools:
            var tools: [FanAction] = []
            let allImage = kinds.allSatisfy(\.isImage)
            let allExtractable = kinds.allSatisfy { [.zip, .tar, .gzip, .rar].contains($0) }
            if allImage {
                tools.append(.stripMetadata)
            }
            if kinds.contains(.pdf) || allImage {
                if !tools.contains(.stripMetadata) { tools.append(.stripMetadata) }
            }
            if allExtractable {
                tools.append(.unzipArchive)
            } else {
                tools.append(contentsOf: [.zipArchive, .tarArchive, .gzipArchive])
            }
            return tools

        case .convert:
            var result: [FanAction] = []
            let allImage = kinds.allSatisfy(\.isImage)
            let allVideo = kinds.allSatisfy { $0.isVideo && $0 != .gif }
            let allAudio = kinds.allSatisfy(\.isAudio)
            let allPDF = kinds == [.pdf]
            let allSRT = kinds == [.srt]
            let allVTT = kinds == [.vtt]
            let allTextDoc = kinds.allSatisfy { [.txt, .md, .rtf].contains($0) }
            let allSheet = kinds.allSatisfy(\.isSpreadsheet)

            if allImage {
                result.append(contentsOf: [
                    .convertToPDF, .convertToPNG, .convertToWebP, .convertToHEIC,
                    .convertToTIFF, .convertToJPEG, .convertToBMP
                ])
                if ImageConverter.supportsAVIFEncode {
                    result.append(.convertToAVIF)
                }
                if urls.count > 1 { result.append(.imagesToPDF) }
            }
            if allVideo || (kinds.count == 1 && kinds.contains(.gif)) {
                result.append(contentsOf: [
                    .convertToMP4, .convertToMOV, .convertToMKV, .convertToAVI,
                    .convertToWMV, .convertToGIF, .convertToMP3, .convertToWAV
                ])
            }
            if allAudio {
                result.append(contentsOf: [
                    .convertToMP3, .convertToM4A, .convertToWAV, .convertToFLAC,
                    .convertToOGG, .convertToOPUS, .convertToAIFF, .convertToWMA,
                    .convertToMP4
                ])
            }
            if allPDF {
                result.append(contentsOf: [.pdfToPNG, .pdfToJPEG, .pdfToTXT, .convertToXLSX])
            }
            if allSRT {
                result.append(contentsOf: [.srtToVTT, .srtToTXT])
            }
            if allVTT {
                result.append(contentsOf: [.vttToSRT, .vttToTXT])
            }
            if allTextDoc {
                result.append(contentsOf: [.convertToPDF, .convertToHTML, .convertToTXT])
            }
            if kinds.allSatisfy({ [.html, .doc, .docx, .txt, .md, .rtf].contains($0) }), !allTextDoc {
                result.append(.convertToPDF)
            }
            if allSheet {
                result.append(contentsOf: [
                    .convertToXLSX, .convertToODS, .convertToCSV, .convertToTSV, .convertToPDF
                ])
            }

            // Same format as source never appears on the wheel (Tangerine behavior).
            return result.filter { action in
                guard let target = action.outputKind else { return true }
                return !kinds.allSatisfy { $0 == target }
            }
        }
    }
}

private extension FanAction {
    /// Format produced by this convert action, if any.
    var outputKind: FileKind? {
        switch self {
        case .convertToPNG, .pdfToPNG: return .png
        case .convertToJPEG, .pdfToJPEG: return .jpeg
        case .convertToHEIC: return .heic
        case .convertToWebP: return .webp
        case .convertToTIFF: return .tiff
        case .convertToBMP: return .bmp
        case .convertToAVIF: return .avif
        case .convertToPDF, .imagesToPDF: return .pdf
        case .convertToMP4: return .mp4
        case .convertToMOV: return .mov
        case .convertToMKV: return .mkv
        case .convertToAVI: return .avi
        case .convertToWMV: return .wmv
        case .convertToGIF: return .gif
        case .convertToMP3: return .mp3
        case .convertToM4A: return .m4a
        case .convertToWAV: return .wav
        case .convertToFLAC: return .flac
        case .convertToOGG: return .ogg
        case .convertToOPUS: return .opus
        case .convertToAIFF: return .aiff
        case .convertToWMA: return .wma
        case .srtToVTT: return .vtt
        case .vttToSRT: return .srt
        case .srtToTXT, .vttToTXT, .pdfToTXT, .convertToTXT: return .txt
        case .convertToHTML: return .html
        case .convertToXLSX: return .xlsx
        case .convertToODS: return .ods
        case .convertToCSV: return .csv
        case .convertToTSV: return .tsv
        case .zipArchive: return .zip
        case .tarArchive: return .tar
        case .gzipArchive: return .gzip
        default: return nil
        }
    }
}

extension FanAction {
    var isImageAction: Bool { [.cropImage, .compressImage, .adjustImage, .upscaleImage, .ocrImage].contains(self) }
    var isPDFAction: Bool { [.mergePDF, .splitPDF, .compressPDF, .reorderPDF, .ocrPDF, .signPDF].contains(self) }
}
