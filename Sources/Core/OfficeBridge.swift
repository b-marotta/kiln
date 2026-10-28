import Foundation

/// Optional Java/POI bridge for legacy XLS / PowerPoint — not required for CSV/TSV/XLSX/ODS.
/// Spreadsheet and text-document paths use `SpreadsheetConverter` / `DocumentConverter` instead.
enum OfficeBridge {
    enum Kind {
        case powerpoint
        case spreadsheet
        case pagesOrWord
    }

    static var javaHome: String? {
        ProcessInfo.processInfo.environment["JAVA_HOME"]
            ?? (FileManager.default.fileExists(atPath: "/usr/libexec/java_home")
                ? (try? ProcessRunner.run("/usr/libexec/java_home", arguments: [])).map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                : nil)
    }

    static func isAvailable(for kind: Kind) -> Bool {
        switch kind {
        case .powerpoint:
            return javaHome != nil
                && Bundle.main.url(forResource: "poi", withExtension: "jar", subdirectory: "Tools") != nil
        case .spreadsheet:
            // Native Swift path covers CSV/TSV/XLSX/ODS; Java only for legacy XLS.
            return true
        case .pagesOrWord:
            // TXT/MD/RTF via DocumentConverter; DOCX/Pages still deferred.
            return true
        }
    }

    static func convert(source: URL, kind: Kind, action: FanAction) throws -> URL {
        switch kind {
        case .spreadsheet:
            return try SpreadsheetConverter.convert(source: source, action: action)
        case .pagesOrWord:
            return try DocumentConverter.convert(source: source, action: action)
        case .powerpoint:
            guard isAvailable(for: .powerpoint) else {
                throw ConversionError.toolMissing("JRE+POI")
            }
            throw ConversionError.unsupported
        }
    }
}
