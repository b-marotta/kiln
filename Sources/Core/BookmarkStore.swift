import Foundation

/// Security-scoped bookmark persistence for folder access (sandbox-ready).
enum BookmarkStore {
    private static let defaultsKey = "kiln.folderBookmarks"

    static func save(url: URL) throws {
        let data = try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        var map = loadRaw()
        map[url.path] = data
        UserDefaults.standard.set(map, forKey: defaultsKey)
    }

    static func resolvedURLs() -> [URL] {
        loadRaw().compactMap { _, data in
            var isStale = false
            return try? URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        }
    }

    @discardableResult
    static func startAccessing(_ url: URL) -> Bool {
        url.startAccessingSecurityScopedResource()
    }

    static func stopAccessing(_ url: URL) {
        url.stopAccessingSecurityScopedResource()
    }

    private static func loadRaw() -> [String: Data] {
        (UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Data]) ?? [:]
    }
}
