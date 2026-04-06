import Foundation

actor MetMuseumPersistentCache {
    static let shared = MetMuseumPersistentCache()

    private struct CachedObjectIDs: Codable {
        let objectIDs: [Int]
        let createdAt: Date
    }

    private let directoryURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(fileManager: FileManager = .default) {
        let baseURL = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        directoryURL = baseURL
            .appendingPathComponent("DailyMuseum", isDirectory: true)
            .appendingPathComponent("MetMuseum", isDirectory: true)
    }

    func objectIDs(forKey key: String) -> [Int]? {
        let fileURL = fileURL(forKey: key)
        guard let data = try? Data(contentsOf: fileURL),
              let cached = try? decoder.decode(CachedObjectIDs.self, from: data) else {
            return nil
        }
        return cached.objectIDs
    }

    func setObjectIDs(_ objectIDs: [Int], forKey key: String) {
        let fileURL = fileURL(forKey: key)
        let cached = CachedObjectIDs(objectIDs: objectIDs, createdAt: Date())

        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let data = try encoder.encode(cached)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            // Ignore cache write failures and keep network path as fallback.
        }
    }

    private func fileURL(forKey key: String) -> URL {
        let sanitized = key.unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : "_"
        }
        return directoryURL.appendingPathComponent(String(sanitized) + ".json")
    }
}
