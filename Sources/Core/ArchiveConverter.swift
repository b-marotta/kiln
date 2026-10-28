import Foundation

enum ArchiveConverter {
    static func zip(sources: [URL]) throws -> URL {
        guard let first = sources.first else { throw ConversionError.unsupported }
        let out: URL
        if sources.count == 1 {
            out = OutputNamer.adjacent(for: first, ext: "zip")
        } else {
            let dir = first.deletingLastPathComponent()
            out = OutputNamer.adjacent(
                for: dir.appendingPathComponent("archive"),
                ext: "zip"
            )
        }

        let zipBin = "/usr/bin/zip"
        guard FileManager.default.isExecutableFile(atPath: zipBin) else {
            throw ConversionError.toolMissing("zip")
        }
        let parent = first.deletingLastPathComponent()
        var args = ["-r", out.path]
        for src in sources {
            if src.deletingLastPathComponent() == parent {
                args.append(src.lastPathComponent)
            } else {
                args.append(src.path)
            }
        }
        try ProcessRunner.run(zipBin, arguments: args, cwd: parent)
        return out
    }

    static func tar(sources: [URL]) throws -> URL {
        guard let first = sources.first else { throw ConversionError.unsupported }
        let out: URL
        if sources.count == 1 {
            out = OutputNamer.adjacent(for: first, ext: "tar")
        } else {
            let dir = first.deletingLastPathComponent()
            out = OutputNamer.adjacent(
                for: dir.appendingPathComponent("archive"),
                ext: "tar"
            )
        }

        let tarBin = "/usr/bin/tar"
        guard FileManager.default.isExecutableFile(atPath: tarBin) else {
            throw ConversionError.toolMissing("tar")
        }
        let parent = first.deletingLastPathComponent()
        var args = ["-cf", out.path]
        for src in sources {
            if src.deletingLastPathComponent() == parent {
                args.append(src.lastPathComponent)
            } else {
                args.append(src.path)
            }
        }
        try ProcessRunner.run(tarBin, arguments: args, cwd: parent)
        return out
    }

    /// Single file → .gz; multiple → .tar.gz beside first parent.
    static func gzip(sources: [URL]) throws -> URL {
        guard let first = sources.first else { throw ConversionError.unsupported }
        let tarBin = "/usr/bin/tar"
        guard FileManager.default.isExecutableFile(atPath: tarBin) else {
            throw ConversionError.toolMissing("tar")
        }

        if sources.count == 1, !isDirectory(first) {
            let out = OutputNamer.adjacent(for: first, ext: "gz")
            // tar czf packs one file; rename conceptually as .gz of that file's tar stream.
            // Prefer gzip(1) for a true single-file gzip.
            if let gzipBin = executable("gzip") {
                let staged = first.deletingLastPathComponent()
                    .appendingPathComponent(first.lastPathComponent + ".kiln-gz-tmp")
                try FileManager.default.copyItem(at: first, to: staged)
                try ProcessRunner.run(gzipBin, arguments: ["-f", staged.path])
                let gzStaged = URL(fileURLWithPath: staged.path + ".gz")
                if FileManager.default.fileExists(atPath: out.path) {
                    try FileManager.default.removeItem(at: out)
                }
                try FileManager.default.moveItem(at: gzStaged, to: out)
                return out
            }
        }

        let out: URL
        if sources.count == 1 {
            out = OutputNamer.adjacent(for: first, ext: "tar.gz")
        } else {
            let dir = first.deletingLastPathComponent()
            out = OutputNamer.adjacent(
                for: dir.appendingPathComponent("archive"),
                ext: "tar.gz"
            )
        }
        let parent = first.deletingLastPathComponent()
        var args = ["-czf", out.path]
        for src in sources {
            if src.deletingLastPathComponent() == parent {
                args.append(src.lastPathComponent)
            } else {
                args.append(src.path)
            }
        }
        try ProcessRunner.run(tarBin, arguments: args, cwd: parent)
        return out
    }

    static func extract(source: URL) throws -> [URL] {
        let kind = FileKind.classify(url: source)
        switch kind {
        case .zip:
            return try unzipZIP(source: source)
        case .tar:
            return try extractTar(source: source, gzipped: false)
        case .gzip:
            return try extractGzipFamily(source: source)
        case .rar:
            return try extractRAR(source: source)
        default:
            throw ConversionError.unsupported
        }
    }

    /// Back-compat name used by ConversionEngine.
    static func unzip(source: URL) throws -> [URL] {
        try extract(source: source)
    }

    private static func unzipZIP(source: URL) throws -> [URL] {
        let dest = try makeExtractDir(beside: source)
        let unzipBin = "/usr/bin/unzip"
        guard FileManager.default.isExecutableFile(atPath: unzipBin) else {
            throw ConversionError.toolMissing("unzip")
        }
        try ProcessRunner.run(unzipBin, arguments: ["-o", source.path, "-d", dest.path])
        return try listContents(of: dest)
    }

    private static func extractTar(source: URL, gzipped: Bool) throws -> [URL] {
        let dest = try makeExtractDir(beside: source)
        let tarBin = "/usr/bin/tar"
        guard FileManager.default.isExecutableFile(atPath: tarBin) else {
            throw ConversionError.toolMissing("tar")
        }
        let args = [gzipped ? "-xzf" : "-xf", source.path, "-C", dest.path]
        try ProcessRunner.run(tarBin, arguments: args)
        return try listContents(of: dest)
    }

    private static func extractGzipFamily(source: URL) throws -> [URL] {
        let name = source.lastPathComponent.lowercased()
        if name.hasSuffix(".tar.gz") || name.hasSuffix(".tgz") {
            return try extractTar(source: source, gzipped: true)
        }
        // Plain .gz — gunzip to adjacent file, return that file.
        guard let gunzip = executable("gunzip") ?? executable("gzip") else {
            throw ConversionError.toolMissing("gunzip")
        }
        let dest = try makeExtractDir(beside: source)
        let staged = dest.appendingPathComponent(source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: staged)
        if gunzip.hasSuffix("gzip") {
            try ProcessRunner.run(gunzip, arguments: ["-df", staged.path])
        } else {
            try ProcessRunner.run(gunzip, arguments: ["-f", staged.path])
        }
        // gunzip removes .gz → file without .gz inside dest
        return try listContents(of: dest)
    }

    private static func extractRAR(source: URL) throws -> [URL] {
        let dest = try makeExtractDir(beside: source)
        if let unrar = executable("unrar") {
            try ProcessRunner.run(unrar, arguments: ["x", "-o+", source.path, dest.path + "/"])
            return try listContents(of: dest)
        }
        // bsdtar (libarchive) can read many RAR volumes on recent macOS.
        let tarBin = "/usr/bin/tar"
        if FileManager.default.isExecutableFile(atPath: tarBin) {
            do {
                try ProcessRunner.run(tarBin, arguments: ["-xf", source.path, "-C", dest.path])
                return try listContents(of: dest)
            } catch {
                throw ConversionError.toolMissing("unrar")
            }
        }
        throw ConversionError.toolMissing("unrar")
    }

    private static func makeExtractDir(beside source: URL) throws -> URL {
        let destDir = source.deletingPathExtension()
        // .tar.gz → deletingPathExtension leaves .tar; strip again if needed.
        var base = destDir
        if base.pathExtension.lowercased() == "tar" {
            base = base.deletingPathExtension()
        }
        var unique = base
        var n = 1
        while FileManager.default.fileExists(atPath: unique.path) {
            unique = URL(fileURLWithPath: base.path + "-\(n)")
            n += 1
        }
        try FileManager.default.createDirectory(at: unique, withIntermediateDirectories: true)
        return unique
    }

    private static func listContents(of dir: URL) throws -> [URL] {
        let contents = try FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil
        )
        return contents.isEmpty ? [dir] : contents
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        return isDir.boolValue
    }

    private static func executable(_ name: String) -> String? {
        ToolResolver.find(name)
    }
}
