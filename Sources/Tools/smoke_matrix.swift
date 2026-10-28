import Foundation

/// Standalone matrix: compile with Core sources (see build.sh notes / README).
@main
struct SmokeMatrix {
    static func main() throws {
        let tmp = URL(fileURLWithPath: CommandLine.arguments[1])
        let png = tmp.appendingPathComponent("a.png")

        func check(_ name: String, _ block: () throws -> [URL]) {
            do {
                let outs = try block()
                print("OK \(name): \(outs.map(\.lastPathComponent).joined(separator: ", "))")
            } catch {
                print("FAIL \(name): \(error)")
            }
        }

        check("png->jpeg") { try ConversionEngine.perform(action: .convertToJPEG, sources: [png]) }
        check("png->pdf") { try ConversionEngine.perform(action: .convertToPDF, sources: [png]) }
        check("strip") { try ConversionEngine.perform(action: .stripMetadata, sources: [png]) }
        check("zip") { try ConversionEngine.perform(action: .zipArchive, sources: [png]) }
        check("tar") { try ConversionEngine.perform(action: .tarArchive, sources: [png]) }
        check("png->webp") { try ConversionEngine.perform(action: .convertToWebP, sources: [png]) }

        let srt = tmp.appendingPathComponent("t.srt")
        try "1\n00:00:00,000 --> 00:00:01,000\nHi\n".write(to: srt, atomically: true, encoding: .utf8)
        check("srt->vtt") { try ConversionEngine.perform(action: .srtToVTT, sources: [srt]) }
        check("srt->txt") { try ConversionEngine.perform(action: .srtToTXT, sources: [srt]) }
        if let vtt = try? ConversionEngine.perform(action: .srtToVTT, sources: [srt]).first {
            check("vtt->srt") { try ConversionEngine.perform(action: .vttToSRT, sources: [vtt]) }
        }

        let txt = tmp.appendingPathComponent("note.txt")
        try "Hello Kiln\nLine two".write(to: txt, atomically: true, encoding: .utf8)
        check("txt->pdf") { try ConversionEngine.perform(action: .convertToPDF, sources: [txt]) }
        check("txt->html") { try ConversionEngine.perform(action: .convertToHTML, sources: [txt]) }

        let csv = tmp.appendingPathComponent("t.csv")
        try "a,b\n1,2\n".write(to: csv, atomically: true, encoding: .utf8)
        check("csv->xlsx") { try ConversionEngine.perform(action: .convertToXLSX, sources: [csv]) }
        if let xlsx = try? ConversionEngine.perform(action: .convertToXLSX, sources: [csv]).first {
            check("xlsx->tsv") { try ConversionEngine.perform(action: .convertToTSV, sources: [xlsx]) }
            check("xlsx->pdf") { try ConversionEngine.perform(action: .convertToPDF, sources: [xlsx]) }
        }

        let svg = tmp.appendingPathComponent("t.svg")
        try """
        <svg xmlns="http://www.w3.org/2000/svg" width="64" height="64">
          <rect width="64" height="64" fill="#f90"/>
        </svg>
        """.write(to: svg, atomically: true, encoding: .utf8)
        check("svg->png") { try ConversionEngine.perform(action: .convertToPNG, sources: [svg]) }

        if let ffmpeg = ToolResolver.ffmpeg {
            let wav = tmp.appendingPathComponent("t.wav")
            try ProcessRunner.run(ffmpeg, arguments: [
                "-y", "-f", "lavfi", "-i", "sine=frequency=440:duration=0.2", wav.path
            ])
            check("wav->mp3") { try ConversionEngine.perform(action: .convertToMP3, sources: [wav]) }
            check("wav->m4a") { try ConversionEngine.perform(action: .convertToM4A, sources: [wav]) }
            check("wav->flac") { try ConversionEngine.perform(action: .convertToFLAC, sources: [wav]) }
            check("mp3->ogg") {
                let mp3 = try ConversionEngine.perform(action: .convertToMP3, sources: [wav])[0]
                return try ConversionEngine.perform(action: .convertToOGG, sources: [mp3])
            }

            let mp4 = tmp.appendingPathComponent("t.mp4")
            try ProcessRunner.run(ffmpeg, arguments: [
                "-y", "-f", "lavfi", "-i", "color=c=orange:s=160x120:d=0.3",
                "-f", "lavfi", "-i", "sine=frequency=440:duration=0.3",
                "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest",
                mp4.path
            ])
            check("mp4->mov") { try ConversionEngine.perform(action: .convertToMOV, sources: [mp4]) }
            check("mp4->mkv") { try ConversionEngine.perform(action: .convertToMKV, sources: [mp4]) }
            check("mp4->gif") { try ConversionEngine.perform(action: .convertToGIF, sources: [mp4]) }
        } else {
            print("SKIP ffmpeg")
        }

        if let pdf = try? ConversionEngine.perform(action: .convertToPDF, sources: [png]).first {
            check("pdf->png") { try ConversionEngine.perform(action: .pdfToPNG, sources: [pdf]) }
            check("pdf->jpeg") { try ConversionEngine.perform(action: .pdfToJPEG, sources: [pdf]) }
            check("pdf->txt") { try ConversionEngine.perform(action: .pdfToTXT, sources: [pdf]) }
            check("pdf->xlsx") { try ConversionEngine.perform(action: .convertToXLSX, sources: [pdf]) }
        }

        // tar extract round-trip
        if let tar = try? ConversionEngine.perform(action: .tarArchive, sources: [png]).first {
            check("tar extract") { try ConversionEngine.perform(action: .unzipArchive, sources: [tar]) }
        }

        print("tools ffmpeg=\(ToolResolver.ffmpeg != nil) cwebp=\(ToolResolver.cwebp != nil) exiftool=\(ToolResolver.exiftool != nil)")
    }
}
