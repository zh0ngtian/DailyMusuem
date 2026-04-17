import Foundation
import ImageIO
import UIKit

enum WidgetRefreshPhase: String, Codable, Equatable {
    case idle
    case refreshing
    case success
    case failure
}

struct WidgetImageDimensions: Equatable {
    let width: Int
    let height: Int

    var summary: String {
        "\(width)x\(height)"
    }
}

actor WidgetArtworkSnapshotStore {
    static let shared = WidgetArtworkSnapshotStore()

    private enum Constants {
        static let directoryName = "WidgetInstances"
        static let stateFileName = "instances.json"
        static let imagesDirectoryName = "images"
        static let widgetImageMaximumDimension: CGFloat = 1200
        static let legacyPaths = [
            "WidgetCache",
            "WidgetRefresh",
            "WidgetRender",
        ]
    }

    struct ArtworkPayload: Codable, Equatable {
        let museumID: MuseumID
        let museumName: String
        let title: String
        let subtitle: String?
        let imageFileName: String?
        let appURL: URL?
        let updatedAt: TimeInterval

        func withImageFileName(_ imageFileName: String?) -> ArtworkPayload {
            ArtworkPayload(
                museumID: museumID,
                museumName: museumName,
                title: title,
                subtitle: subtitle,
                imageFileName: imageFileName,
                appURL: appURL,
                updatedAt: updatedAt
            )
        }
    }

    struct InstanceState: Codable, Equatable {
        let instanceToken: String
        var scopeRawValue: String
        var nonce: Int
        var phase: WidgetRefreshPhase
        var artwork: ArtworkPayload?
        var failureMessage: String?
        var lastUpdatedAt: TimeInterval
    }

    private struct PersistedState: Codable {
        let instances: [InstanceState]
    }

    private let baseURL: URL
    private let directoryURL: URL
    private let imagesDirectoryURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var didMigrateLegacyArtifacts = false

    init(fileManager: FileManager = .default) {
        let containerURL = fileManager.containerURL(forSecurityApplicationGroupIdentifier: SettingsKeys.appGroupID)
            ?? fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        self.init(baseURL: containerURL)
    }

    init(baseURL: URL) {
        self.baseURL = baseURL
        directoryURL = baseURL.appendingPathComponent(Constants.directoryName, isDirectory: true)
        imagesDirectoryURL = directoryURL.appendingPathComponent(Constants.imagesDirectoryName, isDirectory: true)
    }

    func registerInstance(
        instanceToken: String,
        scopeRawValue: String,
        now: Date = .now
    ) -> InstanceState {
        migrateLegacyArtifactsIfNeeded()

        var instances = loadInstances()
        var state = instances[instanceToken] ?? InstanceState(
            instanceToken: instanceToken,
            scopeRawValue: scopeRawValue,
            nonce: 0,
            phase: .idle,
            artwork: nil,
            failureMessage: nil,
            lastUpdatedAt: now.timeIntervalSince1970
        )
        state.scopeRawValue = scopeRawValue
        state.lastUpdatedAt = now.timeIntervalSince1970
        instances[instanceToken] = state
        persist(instances)
        return state
    }

    func state(for instanceToken: String) -> InstanceState? {
        migrateLegacyArtifactsIfNeeded()
        return loadInstances()[instanceToken]
    }

    func beginRefresh(
        instanceToken: String,
        scopeRawValue: String,
        now: Date = .now
    ) -> InstanceState {
        migrateLegacyArtifactsIfNeeded()

        var instances = loadInstances()
        var state = instances[instanceToken] ?? InstanceState(
            instanceToken: instanceToken,
            scopeRawValue: scopeRawValue,
            nonce: 0,
            phase: .idle,
            artwork: nil,
            failureMessage: nil,
            lastUpdatedAt: now.timeIntervalSince1970
        )
        state.scopeRawValue = scopeRawValue
        state.nonce += 1
        state.phase = .refreshing
        state.failureMessage = nil
        state.lastUpdatedAt = now.timeIntervalSince1970
        instances[instanceToken] = state
        persist(instances)
        return state
    }

    func markSuccess(
        instanceToken: String,
        expectedNonce: Int,
        payload: ArtworkPayload,
        imageData: Data?,
        now: Date = .now
    ) -> InstanceState? {
        migrateLegacyArtifactsIfNeeded()

        var instances = loadInstances()
        guard var state = instances[instanceToken], state.nonce == expectedNonce else {
            return nil
        }

        let previousImageFileName = state.artwork?.imageFileName
        let storedPayload = payload.withImageFileName(
            storeImageData(imageData, instanceToken: instanceToken, nonce: expectedNonce)
        )
        state.phase = .success
        state.artwork = storedPayload
        state.failureMessage = nil
        state.lastUpdatedAt = now.timeIntervalSince1970
        instances[instanceToken] = state
        persist(instances)

        if previousImageFileName != storedPayload.imageFileName {
            deleteImageFile(named: previousImageFileName)
        }
        return state
    }

    func markFailure(
        instanceToken: String,
        expectedNonce: Int,
        message: String,
        now: Date = .now
    ) -> InstanceState? {
        migrateLegacyArtifactsIfNeeded()

        var instances = loadInstances()
        guard var state = instances[instanceToken], state.nonce == expectedNonce else {
            return nil
        }

        let previousImageFileName = state.artwork?.imageFileName
        state.phase = .failure
        state.artwork = nil
        state.failureMessage = message
        state.lastUpdatedAt = now.timeIntervalSince1970
        instances[instanceToken] = state
        persist(instances)
        deleteImageFile(named: previousImageFileName)
        return state
    }

    func knownInstances() -> [InstanceState] {
        migrateLegacyArtifactsIfNeeded()
        return loadInstances().values.sorted { lhs, rhs in
            lhs.instanceToken < rhs.instanceToken
        }
    }

    func mostRecentDisplayableState(scopeRawValue: String) -> InstanceState? {
        migrateLegacyArtifactsIfNeeded()

        let candidates = loadInstances()
            .values
            .filter { $0.scopeRawValue == scopeRawValue }

        if let success = candidates
            .filter({ $0.phase == .success })
            .max(by: { lhs, rhs in lhs.lastUpdatedAt < rhs.lastUpdatedAt }) {
            return success
        }

        return candidates
            .filter { $0.phase == .refreshing }
            .max(by: { lhs, rhs in lhs.lastUpdatedAt < rhs.lastUpdatedAt })
    }

    func migrateLegacyArtifactsIfNeeded() {
        guard !didMigrateLegacyArtifacts else {
            return
        }

        didMigrateLegacyArtifacts = true
        for relativePath in Constants.legacyPaths {
            let legacyURL = baseURL.appendingPathComponent(relativePath, isDirectory: true)
            try? FileManager.default.removeItem(at: legacyURL)
        }
    }

    private func loadInstances() -> [String: InstanceState] {
        guard let data = try? Data(contentsOf: stateFileURL),
              let persisted = try? decoder.decode(PersistedState.self, from: data) else {
            return [:]
        }

        return Dictionary(
            uniqueKeysWithValues: persisted.instances.map { ($0.instanceToken, $0) }
        )
    }

    private func persist(_ instances: [String: InstanceState]) {
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let data = try encoder.encode(
                PersistedState(instances: instances.values.sorted { $0.instanceToken < $1.instanceToken })
            )
            try data.write(to: stateFileURL, options: [.atomic])
        } catch {
            // Ignore persistence failures and let WidgetKit fall back to the in-memory refresh flow.
        }
    }

    private func storeImageData(_ imageData: Data?, instanceToken: String, nonce: Int) -> String? {
        guard let imageData else {
            return nil
        }

        do {
            try FileManager.default.createDirectory(at: imagesDirectoryURL, withIntermediateDirectories: true)
            let fileName = "\(safeFileName(for: instanceToken))-\(nonce).bin"
            let fileURL = imagesDirectoryURL.appendingPathComponent(fileName)
            try imageData.write(to: fileURL, options: [.atomic])
            return fileName
        } catch {
            return nil
        }
    }

    private func deleteImageFile(named fileName: String?) {
        guard let fileName else {
            return
        }
        try? FileManager.default.removeItem(at: imagesDirectoryURL.appendingPathComponent(fileName))
    }

    private func safeFileName(for rawValue: String) -> String {
        rawValue
            .replacingOccurrences(of: "[^A-Za-z0-9_-]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private var stateFileURL: URL {
        directoryURL.appendingPathComponent(Constants.stateFileName)
    }

    static func imageURL(for fileName: String) -> URL? {
        let baseURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SettingsKeys.appGroupID)
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return baseURL
            .appendingPathComponent(Constants.directoryName, isDirectory: true)
            .appendingPathComponent(Constants.imagesDirectoryName, isDirectory: true)
            .appendingPathComponent(fileName)
    }

    static func imageDimensions(for fileName: String) -> WidgetImageDimensions? {
        guard let url = imageURL(for: fileName),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        return imageDimensions(from: data)
    }

    static func widgetImage(
        for fileName: String,
        targetPointSize: CGSize,
        scale: CGFloat
    ) -> UIImage? {
        guard let url = imageURL(for: fileName),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        return widgetImage(from: data, targetPointSize: targetPointSize, scale: scale)
    }

    static func widgetImage(
        from data: Data,
        targetPointSize: CGSize,
        scale: CGFloat
    ) -> UIImage? {
        let targetPixelSize = normalizedWidgetPixelSize(for: targetPointSize, scale: scale)
        guard targetPixelSize.width > 0, targetPixelSize.height > 0 else {
            return UIImage(data: data)
        }

        return autoreleasepool {
            guard let sourceImage = UIImage(data: data),
                  let cgImage = sourceImage.cgImage else {
                return UIImage(data: data)
            }

            let targetAspectRatio = targetPixelSize.width / targetPixelSize.height
            let croppedImage = croppedWidgetImage(cgImage, targetAspectRatio: targetAspectRatio) ?? cgImage

            let format = UIGraphicsImageRendererFormat.default()
            format.scale = 1
            format.opaque = true

            return UIGraphicsImageRenderer(size: targetPixelSize, format: format).image { _ in
                UIImage(cgImage: croppedImage).draw(
                    in: CGRect(origin: .zero, size: targetPixelSize)
                )
            }
        }
    }

    static func imageDimensions(from data: Data) -> WidgetImageDimensions? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            return nil
        }
        return WidgetImageDimensions(width: width, height: height)
    }

    private static func normalizedWidgetPixelSize(
        for pointSize: CGSize,
        scale: CGFloat
    ) -> CGSize {
        let normalizedScale = max(scale, 1)
        let rawPixelSize = CGSize(
            width: max(pointSize.width * normalizedScale, 1),
            height: max(pointSize.height * normalizedScale, 1)
        )
        let maximumDimension = max(rawPixelSize.width, rawPixelSize.height)
        guard maximumDimension > Constants.widgetImageMaximumDimension else {
            return CGSize(
                width: max(rawPixelSize.width.rounded(.down), 1),
                height: max(rawPixelSize.height.rounded(.down), 1)
            )
        }

        let scaleFactor = Constants.widgetImageMaximumDimension / maximumDimension
        return CGSize(
            width: max((rawPixelSize.width * scaleFactor).rounded(.down), 1),
            height: max((rawPixelSize.height * scaleFactor).rounded(.down), 1)
        )
    }

    private static func croppedWidgetImage(
        _ cgImage: CGImage,
        targetAspectRatio: CGFloat
    ) -> CGImage? {
        guard targetAspectRatio > 0 else {
            return cgImage
        }

        let sourceWidth = cgImage.width
        let sourceHeight = cgImage.height
        let sourceAspectRatio = CGFloat(sourceWidth) / CGFloat(sourceHeight)

        if abs(sourceAspectRatio - targetAspectRatio) < 0.001 {
            return cgImage
        }

        if sourceAspectRatio > targetAspectRatio {
            let cropWidth = max(Int((CGFloat(sourceHeight) * targetAspectRatio).rounded(.down)), 1)
            let originX = max((sourceWidth - cropWidth) / 2, 0)
            return cgImage.cropping(to: CGRect(x: originX, y: 0, width: cropWidth, height: sourceHeight))
        }

        let cropHeight = max(Int((CGFloat(sourceWidth) / targetAspectRatio).rounded(.down)), 1)
        let originY = max((sourceHeight - cropHeight) / 2, 0)
        return cgImage.cropping(to: CGRect(x: 0, y: originY, width: sourceWidth, height: cropHeight))
    }
}
