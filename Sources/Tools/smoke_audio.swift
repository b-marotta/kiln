import AVFoundation
import Foundation

/// Compile with ConversionModels, ImageConverter, ToolResolver and AudioEditing.
@main
enum AudioSmoke {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }

    static func samples(_ url: URL) throws -> (Double, [Float]) {
        let file = try AVAudioFile(forReading: url)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        return (file.processingFormat.sampleRate, Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))))
    }

    static func frequency(_ samples: [Float], rate: Double) -> Double {
        let lower = Int(rate * 0.25)
        let upper = min(samples.count - 1, Int(rate * 0.75))
        var crossings = 0
        for i in lower..<upper where samples[i] <= 0 && samples[i + 1] > 0 { crossings += 1 }
        return Double(crossings) * rate / Double(upper - lower)
    }

    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Kiln-audio-smoke-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { if !CommandLine.arguments.contains("--keep") { try? FileManager.default.removeItem(at: directory) } }
        let source = directory.appendingPathComponent("Test audio.wav")
        let audioFormat = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: 44100 * 4)!
        buffer.frameLength = buffer.frameCapacity
        for i in 0..<Int(buffer.frameLength) {
            let amplitude = 0.15 + 0.6 * Double(i) / Double(buffer.frameLength)
            buffer.floatChannelData![0][i] = Float(amplitude * sin(2 * .pi * 440 * Double(i) / 44100))
        }
        do {
            let file = try AVAudioFile(forWriting: source, settings: audioFormat.settings)
            try file.write(from: buffer)
        }
        let original = try Data(contentsOf: source)
        let job = try AudioEditJob()
        let waveform = try AudioEditorMedia.load(source: source, job: job)
        check(abs(waveform.duration - 4) < 0.001, "Source duration")
        check(waveform.peaks.count == 1000 && waveform.peaks.max()! > 0.7, "Decoded waveform")
        check(ActionAvailability.actions(for: [source], mode: .fileActions).count == 5, "Five audio actions")
        check(ActionAvailability.actions(for: [source, source], mode: .fileActions).isEmpty, "No accidental batch editor")
        let text = directory.appendingPathComponent("note.txt")
        try Data("test".utf8).write(to: text)
        check(ActionAvailability.actions(for: [text], mode: .fileActions).isEmpty, "Other file actions stay empty")

        var cases: [(AudioEditSettings, Double, Double)] = [
            (AudioEditSettings(operation: .trim, start: 0.75, end: 2.25), 1.5, 440),
            (AudioEditSettings(operation: .pitch, semitones: 12), 4, 880),
            (AudioEditSettings(operation: .pitch, semitones: -12), 4, 220),
            (AudioEditSettings(operation: .pitch, semitones: 7), 4, 440 * pow(2, 7.0 / 12))
        ]
        for speed in [0.5, 1.5, 2.0] {
            cases.append((AudioEditSettings(operation: .speed, speed: speed), 4 / speed, 440))
        }
        for (settings, expectedDuration, expectedFrequency) in cases {
            let url = try AudioEditorMedia.render(settings: settings, job: job)
            let (rate, pcm) = try samples(url)
            let duration = Double(pcm.count) / rate
            let hz = frequency(pcm, rate: rate)
            check(abs(duration - expectedDuration) < 0.001, "\(settings): wrong duration \(duration)")
            check(abs(hz - expectedFrequency) < 6, "\(settings): wrong frequency \(hz)")
            print("PASS \(settings.operation) · \(String(format: "%.3f", duration)) s · \(String(format: "%.1f", hz)) Hz")
        }
        let reverse = try AudioEditorMedia.render(settings: AudioEditSettings(operation: .reverse), job: job)
        let (_, decoded) = try samples(job.directory.appendingPathComponent("source.wav"))
        let (_, reversed) = try samples(reverse)
        check(decoded.count == reversed.count, "Reverse length")
        let error = zip(decoded.reversed(), reversed).map { abs($0 - $1) }.max()!
        check(error < 0.0001, "Reverse must mirror samples")
        print("PASS reverse · exact reversed PCM")

        for format in AudioExportFormat.allCases {
            let output = try AudioEditorMedia.export(preview: reverse, source: source, operation: .reverse, format: format, job: job)
            let probe = try ProcessRunner.run(ToolResolver.ffprobe!, arguments: ["-v", "error", "-show_entries", "format=duration", "-of", "default=nokey=1:noprint_wrappers=1", output.path])
            check(abs(Double(probe.trimmingCharacters(in: .whitespacesAndNewlines))! - 4) < 0.2, "Export duration \(format)")
            let firstData = try Data(contentsOf: output)
            let second = try AudioEditorMedia.export(preview: reverse, source: source, operation: .reverse, format: format, job: job)
            check(second != output, "Collision must get a unique name")
            let afterCollision = try Data(contentsOf: output)
            check(afterCollision == firstData, "Existing export must stay intact")
            print("PASS export .\(format.rawValue) · collision preserves existing file")
        }
        let sourceAfterExport = try Data(contentsOf: source)
        check(sourceAfterExport == original, "Source must stay intact")
        let cancelled = try AudioEditJob()
        cancelled.cancel()
        do {
            _ = try AudioEditorMedia.load(source: source, job: cancelled)
            preconditionFailure("Cancelled job ran")
        } catch is CancellationError { print("PASS cancellation") }
        do {
            _ = try AudioEditorMedia.load(source: directory.appendingPathComponent("missing.wav"), job: job)
            preconditionFailure("Missing file accepted")
        } catch { print("PASS invalid input reports error") }
        print("PASS source unchanged · fixture: \(source.path)")
    }
}
