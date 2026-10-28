import AppKit
import Foundation

enum PasteboardFileURLs {
    /// Read file URLs only from a pasteboard (same contract shape as the REA-observed path).
    static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true
        ]
        let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: options) ?? []
        return objects.compactMap { ($0 as? URL)?.standardizedFileURL }
    }

    static func arraysEqual(_ a: [URL], _ b: [URL]) -> Bool {
        guard a.count == b.count else { return false }
        return zip(a, b).allSatisfy { $0 == $1 }
    }

    /// Filter URLs allowed for the active fan mode.
    static func filter(_ urls: [URL], for mode: FanMode) -> [URL] {
        urls.filter { url in
            let kind = FileKind.classify(url: url)
            switch mode {
            case .convert, .fileTools:
                return kind.isImage
                    || kind.isVideo
                    || kind.isAudio
                    || kind == .pdf
                    || kind.isArchive
                    || kind == .srt
                    || kind == .vtt
                    || kind.isDocument
                    || kind.isSpreadsheet
                    || kind == .otherFile
                    || kind == .directory
            case .fileActions:
                return kind != .unknown
            }
        }
    }
}
