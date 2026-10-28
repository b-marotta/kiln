import AVFoundation
import Foundation

enum AudioEditOperation: Int, CaseIterable, Sendable {
    case trim, pitch, speed, reverse, volume

    init?(action: FanAction) {
        switch action {
        case .trimAudio: self = .trim
        case .pitchAudio: self = .pitch
        case .speedAudio: self = .speed
        case .reverseAudio: self = .reverse
        case .volumeAudio: self = .volume
        default: return nil
        }
    }

    var title: String {
        switch self {
        case .trim: return "Taglia"
        case .pitch: return "Tonalità"
        case .speed: return "Velocità"
        case .reverse: return "Reverse"
        case .volume: return "Volume"
        }
    }

    var suffix: String {
        switch self {
        case .trim: return "tagliato"
        case .pitch: return "tonalita"
        case .speed: return "velocita"
        case .reverse: return "reverse"
        case .volume: return "volume"
        }
    }
}

struct AudioVolumePoint: Equatable, Sendable {
    var position: Double
    var gain: Double

    static let initial: [AudioVolumePoint] = [
        .init(position: 0.5, gain: 1)
    ]
}

struct AudioEditSettings: Equatable, Sendable {
    var operation: AudioEditOperation
    var start: Double = 0
    var end: Double = 0
    var semitones: Double = 0
    var speed: Double = 1
    var preservePitch: Bool = true
    var volumePoints: [AudioVolumePoint] = AudioVolumePoint.initial

    var filter: String {
        switch operation {
        case .trim:
            return "atrim=start=\(start):end=\(end),asetpts=PTS-STARTPTS"
        case .pitch:
            // Resample first so this works with any input sample rate. Compensate
            // the changed duration with atempo; ±12 semitones stays in 0.5…2.
            let ratio = pow(2, semitones / 12)
            return "aresample=48000,asetrate=\(48000 * ratio),aresample=48000,atempo=\(1 / ratio)"
        case .speed:
            if !preservePitch { return "aresample=48000,asetrate=\(48000 * speed),aresample=48000" }
            // Each atempo stage must stay at or above 0.5×.
            var remaining = speed
            var stages: [String] = []
            while remaining < 0.5 {
                stages.append("atempo=0.5")
                remaining /= 0.5
            }
            stages.append("atempo=\(remaining)")
            return stages.joined(separator: ",")
        case .reverse: return "areverse"
        case .volume: return "anull" // Applied per sample by renderVolume.
        }
    }
}

enum AudioExportFormat: String, CaseIterable, Sendable {
    case wav, mp3, m4a, flac, aiff

    var codecArguments: [String] {
        switch self {
        case .wav: return ["-c:a", "pcm_s16le"]
        case .mp3: return ["-c:a", "libmp3lame", "-q:a", "2"]
        case .m4a: return ["-c:a", "aac", "-b:a", "192k"]
        case .flac: return ["-c:a", "flac"]
        case .aiff: return ["-c:a", "pcm_s16be"]
        }
    }
}

/// A job owns its child process and scratch files. Closing the editor cancels
/// the process; files live until the background operation releases the job.
final class AudioEditJob: @unchecked Sendable {
    let directory: URL
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("Kiln-audio-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    func cancel() {
        lock.lock()
        cancelled = true
        if let process, process.isRunning { process.terminate() }
        lock.unlock()
    }

    func checkCancellation() throws {
        lock.lock()
        let wasCancelled = cancelled
        lock.unlock()
        if wasCancelled { throw CancellationError() }
    }

    func run(arguments: [String]) throws {
        guard let executable = ToolResolver.ffmpeg else { throw ConversionError.toolMissing("ffmpeg") }
        let log = directory.appendingPathComponent("\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        defer {
            try? handle.close()
            try? FileManager.default.removeItem(at: log)
        }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: executable)
        child.arguments = ["-nostdin", "-hide_banner", "-loglevel", "error"] + arguments
        child.standardOutput = FileHandle.nullDevice
        // A file avoids pipe-buffer deadlock on long or malformed inputs.
        child.standardError = handle
        lock.lock()
        if cancelled { lock.unlock(); throw CancellationError() }
        process = child
        do { try child.run() } catch { process = nil; lock.unlock(); throw error }
        lock.unlock()
        child.waitUntilExit()
        lock.lock()
        process = nil
        let wasCancelled = cancelled
        lock.unlock()
        if wasCancelled { throw CancellationError() }
        guard child.terminationStatus == 0 else {
            let message = (try? String(contentsOf: log, encoding: .utf8)) ?? "Elaborazione audio non riuscita"
            throw ConversionError.processFailed(String(message.suffix(1800)))
        }
    }
}

struct AudioWaveformData: Sendable {
    let duration: Double
    let peaks: [Float]
}

enum AudioEditorMedia {
    static func load(source: URL, job: AudioEditJob) throws -> AudioWaveformData {
        let decoded = job.directory.appendingPathComponent("source.wav")
        try job.run(arguments: ["-n", "-i", source.path, "-map", "0:a:0", "-vn", "-ar", "48000", "-c:a", "pcm_s16le", decoded.path])
        let file = try AVAudioFile(forReading: decoded)
        let duration = Double(file.length) / file.processingFormat.sampleRate
        guard duration.isFinite, duration > 0, file.length > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8192)
        else { throw ConversionError.readFailed }
        var peaks = [Float](repeating: 0, count: 1000)
        var offset: Int64 = 0
        while offset < file.length {
            try file.read(into: buffer)
            let count = Int(buffer.frameLength)
            guard count > 0, let channels = buffer.floatChannelData else { break }
            for i in 0..<count {
                let bucket = min(peaks.count - 1, Int((offset + Int64(i)) * Int64(peaks.count) / file.length))
                for channel in 0..<Int(buffer.format.channelCount) {
                    peaks[bucket] = max(peaks[bucket], abs(channels[channel][i]))
                }
            }
            offset += Int64(count)
        }
        return AudioWaveformData(duration: duration, peaks: peaks)
    }

    static func render(settings: AudioEditSettings, job: AudioEditJob) throws -> URL {
        let output = job.directory.appendingPathComponent("preview-\(UUID().uuidString).wav")
        if settings.operation == .volume {
            try renderVolume(points: settings.volumePoints, output: output, job: job)
            return output
        }
        var filter = settings.filter
        if settings.operation == .pitch || settings.operation == .speed {
            let input = try AVAudioFile(forReading: job.directory.appendingPathComponent("source.wav"))
            let duration = Double(input.length) / input.processingFormat.sampleRate
            let target = settings.operation == .speed ? duration / settings.speed : duration
            // Flush atempo's final analysis window, including on very short clips,
            // then constrain the result to the requested sample duration.
            filter = "apad=pad_dur=0.25," + filter + ",apad=whole_dur=\(target),atrim=duration=\(target)"
        }
        try job.run(arguments: ["-n", "-i", job.directory.appendingPathComponent("source.wav").path,
                                "-af", filter, "-c:a", "pcm_s16le", "-ar", "48000", output.path])
        return output
    }

    private static func renderVolume(points: [AudioVolumePoint], output: URL, job: AudioEditJob) throws {
        let input = try AVAudioFile(forReading: job.directory.appendingPathComponent("source.wav"))
        guard !points.isEmpty, input.length > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 8192)
        else { throw ConversionError.readFailed }
        let writer = try AVAudioFile(forWriting: output, settings: input.fileFormat.settings)
        var offset: AVAudioFramePosition = 0
        var segment = 0
        let lastFrame = Double(max(1, input.length - 1))
        while offset < input.length {
            try job.checkCancellation()
            try input.read(into: buffer)
            let count = Int(buffer.frameLength)
            guard count > 0, let channels = buffer.floatChannelData else { throw ConversionError.readFailed }
            for frame in 0..<count {
                let position = Double(offset + Int64(frame)) / lastFrame
                while segment < points.count - 2 && position > points[segment + 1].position { segment += 1 }
                let first = points[segment]
                let next = points[min(segment + 1, points.count - 1)]
                let fraction = min(1, max(0, (position - first.position) / max(0.000001, next.position - first.position)))
                let gain = Float(first.gain + (next.gain - first.gain) * fraction)
                for channel in 0..<Int(buffer.format.channelCount) { channels[channel][frame] *= gain }
            }
            try writer.write(from: buffer)
            offset += Int64(count)
        }
    }

    static func export(preview: URL, source: URL, operation: AudioEditOperation, format: AudioExportFormat, job: AudioEditJob) throws -> URL {
        // Encode in scratch space, then copy exclusively beside the source.
        // A concurrent export cannot overwrite either the source or another output.
        let encoded = job.directory.appendingPathComponent("export-\(UUID().uuidString).\(format.rawValue)")
        try job.run(arguments: ["-n", "-i", preview.path, "-map", "0:a:0"] + format.codecArguments + [encoded.path])
        var base = source.deletingPathExtension().lastPathComponent
        var index = 1
        if let separator = base.lastIndex(where: { $0 == "_" || $0 == "-" }),
           let number = Int(base[base.index(after: separator)...]),
           number >= 0, number < Int.max {
            index = number + 1
            base = String(base[..<separator])
        }
        while true {
            let name = "\(base)_\(index).\(format.rawValue)"
            let output = source.deletingLastPathComponent().appendingPathComponent(name)
            do {
                try FileManager.default.copyItem(at: encoded, to: output)
                try? FileManager.default.removeItem(at: encoded)
                return output
            } catch {
                if (error as NSError).code == NSFileWriteFileExistsError { index += 1; continue }
                throw error
            }
        }
    }
}
