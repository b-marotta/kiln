import Foundation

enum ToolResolver {
    private static let searchPaths: [String] = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        // Bundled tools inside Kiln.app (optional; never depend on Tangerine.app)
        Bundle.main.resourceURL?.appendingPathComponent("Tools").path
    ].compactMap { $0 }

    static var ffmpeg: String? { find("ffmpeg") }
    static var ffprobe: String? { find("ffprobe") }
    static var cwebp: String? { find("cwebp") }
    static var dwebp: String? { find("dwebp") }
    static var exiftool: String? { find("exiftool") }
    static var perl: String? { find("perl") }

    static func find(_ name: String) -> String? {
        if let env = ProcessInfo.processInfo.environment["PATH"] {
            for dir in env.split(separator: ":") {
                let path = "\(dir)/\(name)"
                if FileManager.default.isExecutableFile(atPath: path) { return path }
            }
        }
        for dir in searchPaths {
            let path = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }
}

enum ProcessRunner {
    @discardableResult
    static func run(_ executable: String, arguments: [String], cwd: URL? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let cwd { process.currentDirectoryURL = cwd }

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err

        try process.run()
        process.waitUntilExit()

        let errData = err.fileHandleForReading.readDataToEndOfFile()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errText = String(data: errData, encoding: .utf8) ?? ""
        let outText = String(data: outData, encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            let message = errText.isEmpty ? outText : errText
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            let tail = trimmed.split(separator: "\n").suffix(6).joined(separator: "\n")
            throw ConversionError.processFailed(tail.isEmpty ? "exit \(process.terminationStatus)" : tail)
        }
        return outText
    }
}
