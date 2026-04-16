import Darwin
import Foundation
import ImageIO

actor WidgetArtworkSnapshotStore {
    static let shared = WidgetArtworkSnapshotStore()

    private enum Constants {
        static let directoryName = "WidgetCache"
        static let snapshotFileName = "current-artwork.json"
        static let generationLockFileName = "snapshot-generation.lock"
        static let imageFileExtension = "bin"
        static let lockPollIntervalNanoseconds: UInt64 = 200_000_000
        static let lockHeartbeatIntervalNanoseconds: UInt64 = 1_000_000_000
        static let lockWaitTimeout: TimeInterval = 15
        static let staleLockThreshold: TimeInterval = 20
    }

    private struct GenerationLockMetadata: Codable {
        let ownerNonce: Int?
        let createdAt: TimeInterval
    }

    struct Snapshot: Codable {
        let cycleKey: String
        let museumName: String
        let title: String
        let subtitle: String?
        let imageFileName: String?
        let appURL: URL?
        let generatedAt: TimeInterval
        let manualRefreshNonce: Int

        private let embeddedImageData: Data?

        init(
            cycleKey: String,
            museumName: String,
            title: String,
            subtitle: String?,
            imageFileName: String?,
            appURL: URL?,
            generatedAt: TimeInterval = Date().timeIntervalSince1970,
            manualRefreshNonce: Int = 0
        ) {
            self.cycleKey = cycleKey
            self.museumName = museumName
            self.title = title
            self.subtitle = subtitle
            self.imageFileName = imageFileName
            self.appURL = appURL
            self.generatedAt = generatedAt
            self.manualRefreshNonce = manualRefreshNonce
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
            case generatedAt
            case manualRefreshNonce
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            cycleKey = try container.decode(String.self, forKey: .cycleKey)
            museumName = try container.decode(String.self, forKey: .museumName)
            title = try container.decode(String.self, forKey: .title)
            subtitle = try container.decodeIfPresent(String.self, forKey: .subtitle)
            imageFileName = try container.decodeIfPresent(String.self, forKey: .imageFileName)
            appURL = try container.decodeIfPresent(URL.self, forKey: .appURL)
            generatedAt = try container.decodeIfPresent(TimeInterval.self, forKey: .generatedAt) ?? 0
            manualRefreshNonce = try container.decodeIfPresent(Int.self, forKey: .manualRefreshNonce) ?? 0
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
            try container.encode(generatedAt, forKey: .generatedAt)
            try container.encode(manualRefreshNonce, forKey: .manualRefreshNonce)
        }

        func withImageFileName(_ imageFileName: String?) -> Snapshot {
            Snapshot(
                cycleKey: cycleKey,
                museumName: museumName,
                title: title,
                subtitle: subtitle,
                imageFileName: imageFileName,
                appURL: appURL,
                generatedAt: generatedAt,
                manualRefreshNonce: manualRefreshNonce
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
        self.init(baseURL: baseURL)
    }

    init(baseURL: URL) {
        directoryURL = baseURL
            .appendingPathComponent(Constants.directoryName, isDirectory: true)
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

    func generateSnapshot(
        lockKey: String = "global",
        manualRefreshNonce: Int? = nil,
        shouldAbortWaiting: @escaping @Sendable () -> Bool = { false },
        generate: @Sendable (_ latestSnapshot: Snapshot?) async throws -> Snapshot
    ) async throws -> Snapshot {
        let lockURL = generationLockURL(for: lockKey)
        if try acquireGenerationLock(at: lockURL, ownerNonce: manualRefreshNonce) {
            let heartbeatTask = startGenerationLockHeartbeat(at: lockURL)
            defer {
                heartbeatTask.cancel()
                releaseGenerationLock(at: lockURL)
            }

            let snapshot = try await generate(loadLatest())
            return snapshot
        }

        await RequestLogger.shared.logEvent(
            source: "Widget 刷新",
            summary: "检测到最新快照正在生成，等待复用结果"
        )
        let deadline = Date().addingTimeInterval(Constants.lockWaitTimeout)
        while Date() < deadline {
            if shouldAbortWaiting() {
                throw WidgetManualRefreshInterruptedError(
                    executionNonce: manualRefreshNonce ?? 0,
                    activeNonce: manualRefreshNonce ?? 0
                )
            }

            if !FileManager.default.fileExists(atPath: lockURL.path),
               let snapshot = loadLatest() {
                return snapshot
            }

            if let manualRefreshNonce,
               let lockOwnerNonce = generationLockOwnerNonce(at: lockURL),
               lockOwnerNonce > 0,
               manualRefreshNonce > lockOwnerNonce {
                await RequestLogger.shared.logEvent(
                    source: "Widget 刷新",
                    summary: "检测到较旧 nonce=\(lockOwnerNonce) 持有最新快照锁，当前 nonce=\(manualRefreshNonce) 直接抢占并重新生成"
                )
                releaseGenerationLock(at: lockURL)
                break
            }

            if isStaleLock(at: lockURL) {
                await RequestLogger.shared.logEvent(
                    source: "Widget 刷新",
                    summary: "检测到陈旧最新快照锁，准备回收并重新生成"
                )
                releaseGenerationLock(at: lockURL)
                break
            }

            try? await Task.sleep(nanoseconds: Constants.lockPollIntervalNanoseconds)
        }

        if shouldAbortWaiting() {
            throw WidgetManualRefreshInterruptedError(
                executionNonce: manualRefreshNonce ?? 0,
                activeNonce: manualRefreshNonce ?? 0
            )
        }

        if try acquireGenerationLock(at: lockURL, ownerNonce: manualRefreshNonce) {
            let heartbeatTask = startGenerationLockHeartbeat(at: lockURL)
            defer {
                heartbeatTask.cancel()
                releaseGenerationLock(at: lockURL)
            }

            let snapshot = try await generate(loadLatest())
            return snapshot
        }

        throw URLError(.timedOut)
    }

    func store(_ snapshot: Snapshot, imageData: Data?) -> Snapshot {
        if let latestSnapshot = loadLatest(),
           shouldKeepExistingSnapshot(latestSnapshot, over: snapshot) {
            return latestSnapshot
        }

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

    private func generationLockURL(for lockKey: String) -> URL {
        let suffix = safeFileName(for: lockKey)
        return directoryURL.appendingPathComponent("\(suffix)-\(Constants.generationLockFileName)")
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

    private func acquireGenerationLock(at url: URL, ownerNonce: Int?) throws -> Bool {
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
        persistGenerationLockMetadata(ownerNonce: ownerNonce, at: url)
        return true
    }

    private func releaseGenerationLock(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func startGenerationLockHeartbeat(at url: URL) -> Task<Void, Never> {
        Task.detached(priority: .utility) {
            while !Task.isCancelled {
                try? FileManager.default.setAttributes(
                    [.modificationDate: Date()],
                    ofItemAtPath: url.path
                )
                try? await Task.sleep(nanoseconds: Constants.lockHeartbeatIntervalNanoseconds)
            }
        }
    }

    private func isStaleLock(at url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
              let modifiedAt = values.contentModificationDate else {
            return false
        }

        return Date().timeIntervalSince(modifiedAt) >= Constants.staleLockThreshold
    }

    private func generationLockOwnerNonce(at url: URL) -> Int? {
        guard let data = try? Data(contentsOf: url),
              let metadata = try? decoder.decode(GenerationLockMetadata.self, from: data) else {
            return nil
        }
        return metadata.ownerNonce
    }

    private func persistGenerationLockMetadata(ownerNonce: Int?, at url: URL) {
        let metadata = GenerationLockMetadata(
            ownerNonce: ownerNonce,
            createdAt: Date().timeIntervalSince1970
        )
        guard let data = try? encoder.encode(metadata) else {
            return
        }
        try? data.write(to: url)
    }

    private func shouldKeepExistingSnapshot(_ existing: Snapshot, over incoming: Snapshot) -> Bool {
        if existing.manualRefreshNonce != incoming.manualRefreshNonce {
            return existing.manualRefreshNonce > incoming.manualRefreshNonce
        }

        if existing.generatedAt != incoming.generatedAt {
            return existing.generatedAt >= incoming.generatedAt
        }

        return existing.cycleKey == incoming.cycleKey
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

    nonisolated static func imageDimensions(for fileName: String) -> WidgetImageDimensions? {
        guard let url = imageURL(for: fileName),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            return nil
        }
        return WidgetImageDimensions(width: width, height: height)
    }

    nonisolated static func imageDimensions(from imageData: Data) -> WidgetImageDimensions? {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            return nil
        }
        return WidgetImageDimensions(width: width, height: height)
    }
}

struct WidgetImageDimensions {
    let width: Int
    let height: Int

    var summary: String {
        "\(width)x\(height)"
    }
}
