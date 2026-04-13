import Darwin
import Foundation

actor WidgetArtworkSnapshotStore {
    static let shared = WidgetArtworkSnapshotStore()

    private enum Constants {
        static let directoryName = "WidgetCache"
        static let snapshotFileName = "current-artwork.json"
        static let imageFileExtension = "bin"
        static let lockPollIntervalNanoseconds: UInt64 = 200_000_000
        static let lockWaitTimeout: TimeInterval = 15
        static let staleLockThreshold: TimeInterval = 20
    }

    struct Snapshot: Codable {
        let cycleKey: String
        let museumName: String
        let title: String
        let subtitle: String?
        let imageFileName: String?
        let appURL: URL?

        private let embeddedImageData: Data?

        init(
            cycleKey: String,
            museumName: String,
            title: String,
            subtitle: String?,
            imageFileName: String?,
            appURL: URL?
        ) {
            self.cycleKey = cycleKey
            self.museumName = museumName
            self.title = title
            self.subtitle = subtitle
            self.imageFileName = imageFileName
            self.appURL = appURL
            embeddedImageData = nil
        }

        private enum CodingKeys: String, CodingKey {
            case cycleKey
            case museumName
            case title
            case subtitle
            case imageFileName
            case imageData
            case appURL
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            cycleKey = try container.decode(String.self, forKey: .cycleKey)
            museumName = try container.decode(String.self, forKey: .museumName)
            title = try container.decode(String.self, forKey: .title)
            subtitle = try container.decodeIfPresent(String.self, forKey: .subtitle)
            imageFileName = try container.decodeIfPresent(String.self, forKey: .imageFileName)
            appURL = try container.decodeIfPresent(URL.self, forKey: .appURL)
            embeddedImageData = try container.decodeIfPresent(Data.self, forKey: .imageData)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(cycleKey, forKey: .cycleKey)
            try container.encode(museumName, forKey: .museumName)
            try container.encode(title, forKey: .title)
            try container.encodeIfPresent(subtitle, forKey: .subtitle)
            try container.encodeIfPresent(imageFileName, forKey: .imageFileName)
            try container.encodeIfPresent(appURL, forKey: .appURL)
        }

        func withImageFileName(_ imageFileName: String?) -> Snapshot {
            Snapshot(
                cycleKey: cycleKey,
                museumName: museumName,
                title: title,
                subtitle: subtitle,
                imageFileName: imageFileName,
                appURL: appURL
            )
        }

        var legacyEmbeddedImageData: Data? {
            embeddedImageData
        }
    }

    private let directoryURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(fileManager: FileManager = .default) {
        let baseURL = fileManager.containerURL(forSecurityApplicationGroupIdentifier: SettingsKeys.appGroupID)
            ?? fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        directoryURL = baseURL
            .appendingPathComponent(Constants.directoryName, isDirectory: true)
    }

    func load(cycleKey: String) -> Snapshot? {
        guard let snapshot = loadLatest(),
              snapshot.cycleKey == cycleKey else {
            return nil
        }
        return snapshot
    }

    func loadLatest() -> Snapshot? {
        let fileURL = snapshotFileURL
        guard let data = try? Data(contentsOf: fileURL),
              let snapshot = try? decoder.decode(Snapshot.self, from: data) else {
            return nil
        }
        guard snapshot.imageFileName == nil,
              let embeddedImageData = snapshot.legacyEmbeddedImageData else {
            return snapshot
        }

        let migratedSnapshot = snapshot.withImageFileName(storeImageData(embeddedImageData, cycleKey: snapshot.cycleKey))
        persist(snapshot: migratedSnapshot)
        return migratedSnapshot
    }

    func snapshot(
        for cycleKey: String,
        generate: @Sendable (_ latestSnapshot: Snapshot?) async throws -> Snapshot
    ) async throws -> Snapshot {
        if let snapshot = load(cycleKey: cycleKey) {
            return snapshot
        }

        let lockURL = lockFileURL(for: cycleKey)
        if try acquireGenerationLock(at: lockURL) {
            defer { releaseGenerationLock(at: lockURL) }

            if let snapshot = load(cycleKey: cycleKey) {
                return snapshot
            }

            let snapshot = try await generate(loadLatest())
            return snapshot
        }

        await RequestLogger.shared.logEvent(
            source: "Widget 刷新",
            summary: "检测到同周期快照正在生成，等待复用结果"
        )
        let deadline = Date().addingTimeInterval(Constants.lockWaitTimeout)
        while Date() < deadline {
            if let snapshot = load(cycleKey: cycleKey) {
                return snapshot
            }

            if isStaleLock(at: lockURL) {
                await RequestLogger.shared.logEvent(
                    source: "Widget 刷新",
                    summary: "检测到陈旧快照锁，准备回收并重新生成"
                )
                releaseGenerationLock(at: lockURL)
                break
            }

            try? await Task.sleep(nanoseconds: Constants.lockPollIntervalNanoseconds)
        }

        if let snapshot = load(cycleKey: cycleKey) {
            return snapshot
        }

        if try acquireGenerationLock(at: lockURL) {
            defer { releaseGenerationLock(at: lockURL) }

            if let snapshot = load(cycleKey: cycleKey) {
                return snapshot
            }

            let snapshot = try await generate(loadLatest())
            return snapshot
        }

        throw URLError(.timedOut)
    }

    func store(_ snapshot: Snapshot, imageData: Data?) -> Snapshot {
        let storedSnapshot = snapshot.withImageFileName(storeImageData(imageData, cycleKey: snapshot.cycleKey))
        persist(snapshot: storedSnapshot)
        return storedSnapshot
    }

    private func persist(snapshot: Snapshot) {
        let fileURL = snapshotFileURL
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let data = try encoder.encode(snapshot)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            // Ignore snapshot write failures and fall back to network fetching.
        }
    }

    private var snapshotFileURL: URL {
        directoryURL.appendingPathComponent(Constants.snapshotFileName)
    }

    private func lockFileURL(for cycleKey: String) -> URL {
        directoryURL.appendingPathComponent("snapshot-\(safeFileName(for: cycleKey)).lock")
    }

    private func imageFileURL(for fileName: String) -> URL {
        directoryURL.appendingPathComponent(fileName)
    }

    private func storeImageData(_ imageData: Data?, cycleKey: String) -> String? {
        guard let imageData else {
            return nil
        }

        let fileName = "artwork-\(safeFileName(for: cycleKey)).\(Constants.imageFileExtension)"
        let fileURL = imageFileURL(for: fileName)
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            try imageData.write(to: fileURL, options: [.atomic])
            return fileName
        } catch {
            return nil
        }
    }

    private func safeFileName(for cycleKey: String) -> String {
        Data(cycleKey.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
    }

    private func acquireGenerationLock(at url: URL) throws -> Bool {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let path = url.path
        let fileDescriptor = open(path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard fileDescriptor >= 0 else {
            if errno == EEXIST {
                return false
            }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        close(fileDescriptor)
        return true
    }

    private func releaseGenerationLock(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func isStaleLock(at url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
              let modifiedAt = values.contentModificationDate else {
            return false
        }

        return Date().timeIntervalSince(modifiedAt) >= Constants.staleLockThreshold
    }

    nonisolated static func imageURL(for fileName: String) -> URL? {
        let fileManager = FileManager.default
        let baseURL = fileManager.containerURL(forSecurityApplicationGroupIdentifier: SettingsKeys.appGroupID)
            ?? fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return baseURL
            .appendingPathComponent(Constants.directoryName, isDirectory: true)
            .appendingPathComponent(fileName)
    }
}
