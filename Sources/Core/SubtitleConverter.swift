import Foundation

enum SubtitleConverter {
    static func srtToVTT(source: URL) throws -> URL {
        let text = try String(contentsOf: source, encoding: .utf8)
        var body = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: ",", with: ".")
        if !body.hasPrefix("WEBVTT") {
            body = "WEBVTT\n\n" + body
        }
        let out = OutputNamer.adjacent(for: source, ext: "vtt")
        try body.write(to: out, atomically: true, encoding: .utf8)
        return out
    }

    static func vttToSRT(source: URL) throws -> URL {
        var text = try String(contentsOf: source, encoding: .utf8)
            .replacingOccurrences(of: "\r\n", with: "\n")
        if text.hasPrefix("WEBVTT") {
            if let range = text.range(of: "\n\n") {
                text = String(text[range.upperBound...])
            } else {
                text = text.replacingOccurrences(of: "WEBVTT", with: "")
            }
        }
        // VTT uses '.' as millisecond separator; SRT uses ','.
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let s = String(line)
            if s.contains("-->") {
                return s.replacingOccurrences(of: ".", with: ",")
            }
            return s
        }
        let out = OutputNamer.adjacent(for: source, ext: "srt")
        try lines.joined(separator: "\n").write(to: out, atomically: true, encoding: .utf8)
        return out
    }

    static func toTXT(source: URL) throws -> URL {
        let text = try String(contentsOf: source, encoding: .utf8)
            .replacingOccurrences(of: "\r\n", with: "\n")
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var cues: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed == "WEBVTT" { continue }
            if trimmed.hasPrefix("NOTE") { continue }
            if trimmed.allSatisfy(\.isNumber) { continue } // cue index
            if trimmed.contains("-->") { continue }
            cues.append(trimmed)
        }
        let out = OutputNamer.adjacent(for: source, ext: "txt")
        try cues.joined(separator: "\n").write(to: out, atomically: true, encoding: .utf8)
        return out
    }
}
