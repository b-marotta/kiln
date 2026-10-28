import AppKit
import Foundation

enum SharingActions {
    static func airDrop(urls: [URL]) throws {
        guard let service = NSSharingService(named: .sendViaAirDrop) else {
            throw ConversionError.writeFailed("AirDrop unavailable")
        }
        guard service.canPerform(withItems: urls) else {
            throw ConversionError.writeFailed("AirDrop cannot share these items")
        }
        DispatchQueue.main.async {
            service.perform(withItems: urls)
        }
    }
}

enum TerminalActions {
    static func open(urls: [URL]) throws {
        guard let first = urls.first else { throw ConversionError.unsupported }
        let dir = first.hasDirectoryPath ? first : first.deletingLastPathComponent()
        let script = """
        tell application "Terminal"
          activate
          do script "cd \(shellEscape(dir.path))"
        end tell
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw ConversionError.processFailed("osascript Terminal failed")
        }
    }

    private static func shellEscape(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
