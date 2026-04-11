import Foundation

actor WidgetArtworkSnapshotStore {
    static let shared = WidgetArtworkSnapshotStore()

    struct Snapshot: Codable {
        let cycleKey: String
        let museumName: String
        let title: String
        let subtitle: String?
        let imageData: Data?
        let appURL: URL?
    }

    private let directoryURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(fileManager: FileManager = .default) {
        let baseURL = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        directoryURL = baseURL
            .appendingPathComponent("DailyMuseumWidget", isDirectory: true)
    }

    func load(cycleKey: String) -> Snapshot? {
        guard let snapshot = loadLatest(),
              snapshot.cycleKey == cycleKey else {
            return nil
        }
        return snapshot
    }

    func loadLatest() -> Snapshot? {
        let fileURL = directoryURL.appendingPathComponent("current-artwork.json")
        guard let data = try? Data(contentsOf: fileURL),
              let snapshot = try? decoder.decode(Snapshot.self, from: data) else {
            return nil
        }
        return snapshot
    }

    func store(_ snapshot: Snapshot) {
        let fileURL = directoryURL.appendingPathComponent("current-artwork.json")
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let data = try encoder.encode(snapshot)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            // Ignore snapshot write failures and fall back to network fetching.
        }
    }
}
