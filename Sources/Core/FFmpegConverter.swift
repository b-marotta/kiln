import Foundation

enum FFmpegConverter {
    static func convert(source: URL, action: FanAction) throws -> URL {
        guard let ffmpeg = ToolResolver.ffmpeg else { throw ConversionError.toolMissing("ffmpeg") }

        switch action {
        case .convertToMP4:
            return try encodeVideo(ffmpeg: ffmpeg, source: source, ext: "mp4", args: [
                "-c:v", "libx264", "-pix_fmt", "yuv420p",
                "-c:a", "aac", "-movflags", "+faststart"
            ])

        case .convertToMOV:
            return try encodeVideo(ffmpeg: ffmpeg, source: source, ext: "mov", args: [
                "-c:v", "libx264", "-pix_fmt", "yuv420p",
                "-c:a", "aac"
            ])

        case .convertToMKV:
            return try encodeVideo(ffmpeg: ffmpeg, source: source, ext: "mkv", args: [
                "-c:v", "libx264", "-pix_fmt", "yuv420p",
                "-c:a", "aac"
            ])

        case .convertToAVI:
            return try encodeVideo(ffmpeg: ffmpeg, source: source, ext: "avi", args: [
                "-c:v", "libx264", "-pix_fmt", "yuv420p",
                "-c:a", "aac"
            ])

        case .convertToWMV:
            return try encodeVideo(ffmpeg: ffmpeg, source: source, ext: "wmv", args: [
                "-c:v", "wmv2",
                "-c:a", "wmav2"
            ])

        case .convertToGIF:
            let out = OutputNamer.adjacent(for: source, ext: "gif")
            try ProcessRunner.run(ffmpeg, arguments: [
                "-y", "-i", source.path,
                "-vf", "fps=12,scale=640:-1:flags=lanczos",
                "-an", out.path
            ])
            return out

        case .convertToMP3:
            return try encodeAudio(
                ffmpeg: ffmpeg, source: source, ext: "mp3",
                withAudio: ["-vn", "-c:a", "libmp3lame", "-q:a", "2"],
                silent: ["-c:a", "libmp3lame", "-q:a", "2"]
            )

        case .convertToM4A:
            return try encodeAudio(
                ffmpeg: ffmpeg, source: source, ext: "m4a",
                withAudio: ["-vn", "-c:a", "aac", "-b:a", "192k"],
                silent: ["-c:a", "aac", "-b:a", "192k"]
            )

        case .convertToWAV:
            return try encodeAudio(
                ffmpeg: ffmpeg, source: source, ext: "wav",
                withAudio: ["-vn", "-c:a", "pcm_s16le"],
                silent: ["-c:a", "pcm_s16le"]
            )

        case .convertToFLAC:
            return try encodeAudio(
                ffmpeg: ffmpeg, source: source, ext: "flac",
                withAudio: ["-vn", "-c:a", "flac"],
                silent: ["-c:a", "flac"]
            )

        case .convertToOGG:
            // Prefer Vorbis; Homebrew ffmpeg often ships without libvorbis — fall back to Opus-in-Ogg.
            return try encodeAudioTrying(
                ffmpeg: ffmpeg, source: source, ext: "ogg",
                candidates: [
                    (["-vn", "-c:a", "libvorbis", "-q:a", "5"], ["-c:a", "libvorbis", "-q:a", "5"]),
                    (["-vn", "-c:a", "libopus", "-b:a", "128k"], ["-c:a", "libopus", "-b:a", "128k"]),
                    (["-vn", "-c:a", "opus", "-b:a", "128k"], ["-c:a", "opus", "-b:a", "128k"])
                ]
            )

        case .convertToOPUS:
            return try encodeAudioTrying(
                ffmpeg: ffmpeg, source: source, ext: "opus",
                candidates: [
                    (["-vn", "-c:a", "libopus", "-b:a", "128k"], ["-c:a", "libopus", "-b:a", "128k"]),
                    (["-vn", "-c:a", "opus", "-b:a", "128k"], ["-c:a", "opus", "-b:a", "128k"])
                ]
            )

        case .convertToAIFF:
            return try encodeAudio(
                ffmpeg: ffmpeg, source: source, ext: "aiff",
                withAudio: ["-vn", "-c:a", "pcm_s16be"],
                silent: ["-c:a", "pcm_s16be"]
            )

        case .convertToWMA:
            return try encodeAudio(
                ffmpeg: ffmpeg, source: source, ext: "wma",
                withAudio: ["-vn", "-c:a", "wmav2", "-b:a", "192k"],
                silent: ["-c:a", "wmav2", "-b:a", "192k"]
            )

        default:
            throw ConversionError.unsupported
        }
    }

    private static func encodeVideo(
        ffmpeg: String,
        source: URL,
        ext: String,
        args: [String]
    ) throws -> URL {
        let out = OutputNamer.adjacent(for: source, ext: ext)
        var arguments = ["-y", "-i", source.path]
        arguments.append(contentsOf: args)
        arguments.append(out.path)
        try ProcessRunner.run(ffmpeg, arguments: arguments)
        return out
    }

    private static func encodeAudio(
        ffmpeg: String,
        source: URL,
        ext: String,
        withAudio: [String],
        silent: [String]
    ) throws -> URL {
        try encodeAudioTrying(
            ffmpeg: ffmpeg, source: source, ext: ext,
            candidates: [(withAudio, silent)]
        )
    }

    private static func encodeAudioTrying(
        ffmpeg: String,
        source: URL,
        ext: String,
        candidates: [([String], [String])]
    ) throws -> URL {
        let out = OutputNamer.adjacent(for: source, ext: ext)
        var lastError: Error = ConversionError.unsupported
        for (withAudio, silent) in candidates {
            do {
                if hasAudioTrack(source) {
                    var arguments = ["-y", "-i", source.path]
                    arguments.append(contentsOf: withAudio)
                    arguments.append(out.path)
                    try ProcessRunner.run(ffmpeg, arguments: arguments)
                } else {
                    let sec = mediaDurationSeconds(source) ?? 1.0
                    var arguments = [
                        "-y",
                        "-f", "lavfi", "-i", "anullsrc=channel_layout=mono:sample_rate=44100",
                        "-t", String(format: "%.3f", sec)
                    ]
                    arguments.append(contentsOf: silent)
                    arguments.append(out.path)
                    try ProcessRunner.run(ffmpeg, arguments: arguments)
                }
                return out
            } catch {
                lastError = error
                try? FileManager.default.removeItem(at: out)
            }
        }
        throw lastError
    }

    private static func hasAudioTrack(_ source: URL) -> Bool {
        guard let ffprobe = ToolResolver.ffprobe else { return true }
        let out = try? ProcessRunner.run(ffprobe, arguments: [
            "-v", "error",
            "-select_streams", "a",
            "-show_entries", "stream=codec_type",
            "-of", "csv=p=0",
            source.path
        ])
        return !(out ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func mediaDurationSeconds(_ source: URL) -> Double? {
        guard let ffprobe = ToolResolver.ffprobe else { return nil }
        let out = try? ProcessRunner.run(ffprobe, arguments: [
            "-v", "error",
            "-show_entries", "format=duration",
            "-of", "default=nokey=1:noprint_wrappers=1",
            source.path
        ])
        guard let text = out?.trimmingCharacters(in: .whitespacesAndNewlines),
              let value = Double(text), value.isFinite, value > 0
        else { return nil }
        return value
    }
}
