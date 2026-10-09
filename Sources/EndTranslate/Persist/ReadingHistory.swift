import Foundation

/// Recently opened files and where the reader left off in each, so reopening a paper
/// (or relaunching the app) lands on the same paragraph.
enum ReadingHistory {
    struct Position: Codable {
        var page: Int
        /// Viewport top-left in ORIGINAL page coordinates (gaps removed).
        var x: Double
        var y: Double
        /// nil = fit width.
        var scale: Double?
    }

    private static let recentKey = "recentFiles"
    private static let positionsKey = "readingPositions"
    private static let maxRecent = 10
    private static let maxPositions = 200

    static func recent() -> [URL] {
        (UserDefaults.standard.stringArray(forKey: recentKey) ?? [])
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func noteOpened(_ url: URL) {
        var paths = UserDefaults.standard.stringArray(forKey: recentKey) ?? []
        paths.removeAll { $0 == url.path }
        paths.insert(url.path, at: 0)
        UserDefaults.standard.set(Array(paths.prefix(maxRecent)), forKey: recentKey)
    }

    static func clearRecent() {
        UserDefaults.standard.removeObject(forKey: recentKey)
    }

    static func position(for url: URL) -> Position? {
        positions()[url.path]
    }

    static func save(_ position: Position, for url: URL) {
        var all = positions()
        all[url.path] = position
        if all.count > maxPositions {
            let recentPaths = Set(recent().map(\.path))
            for key in all.keys where !recentPaths.contains(key) && key != url.path {
                all[key] = nil
                if all.count <= maxPositions { break }
            }
        }
        guard let data = try? JSONEncoder().encode(all) else { return }
        UserDefaults.standard.set(data, forKey: positionsKey)
    }

    private static func positions() -> [String: Position] {
        guard let data = UserDefaults.standard.data(forKey: positionsKey),
              let decoded = try? JSONDecoder().decode([String: Position].self, from: data) else { return [:] }
        return decoded
    }
}
