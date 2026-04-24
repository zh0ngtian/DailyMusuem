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
    }

    struct ArtworkPayload: Codable, Equatable {
        let museumID: MuseumID
        let artworkKey: String?
        let museumName: String
        let title: String
        let subtitle: String?
        let imageFileName: String?
        let appURL: URL?
        let updatedAt: TimeInterval

        func withImageFileName(_ imageFileName: String?) -> ArtworkPayload {
            ArtworkPayload(
                museumID: museumID,
                artworkKey: artworkKey,
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
        var instanceToken: String
        var scopeRawValue: String
        var familyToken: String?
        var nonce: Int
        var phase: WidgetRefreshPhase
        var artwork: ArtworkPayload?
        var displayedArtworkKeys: [String]
        var failureMessage: String?
        var lastUpdatedAt: TimeInterval
        var nextAutomaticRefreshAt: TimeInterval?
        var automaticRefreshScheduleSignature: String?

        private enum CodingKeys: String, CodingKey {
            case instanceToken
            case scopeRawValue
            case familyToken
            case nonce
            case phase
            case artwork
            case displayedArtworkKeys
            case failureMessage
            case lastUpdatedAt
            case nextAutomaticRefreshAt
            case automaticRefreshScheduleSignature
        }

        init(
            instanceToken: String,
            scopeRawValue: String,
            familyToken: String?,
            nonce: Int,
            phase: WidgetRefreshPhase,
            artwork: ArtworkPayload?,
            displayedArtworkKeys: [String],
            failureMessage: String?,
            lastUpdatedAt: TimeInterval,
            nextAutomaticRefreshAt: TimeInterval? = nil,
            automaticRefreshScheduleSignature: String? = nil
        ) {
            self.instanceToken = instanceToken
            self.scopeRawValue = scopeRawValue
            self.familyToken = familyToken
            self.nonce = nonce
            self.phase = phase
            self.artwork = artwork
            self.displayedArtworkKeys = displayedArtworkKeys
            self.failureMessage = failureMessage
            self.lastUpdatedAt = lastUpdatedAt
            self.nextAutomaticRefreshAt = nextAutomaticRefreshAt
            self.automaticRefreshScheduleSignature = automaticRefreshScheduleSignature
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            instanceToken = try container.decode(String.self, forKey: .instanceToken)
            scopeRawValue = try container.decode(String.self, forKey: .scopeRawValue)
            familyToken = try container.decodeIfPresent(String.self, forKey: .familyToken)
            nonce = try container.decode(Int.self, forKey: .nonce)
            phase = try container.decode(WidgetRefreshPhase.self, forKey: .phase)
            artwork = try container.decodeIfPresent(ArtworkPayload.self, forKey: .artwork)
            displayedArtworkKeys = try container.decodeIfPresent([String].self, forKey: .displayedArtworkKeys) ?? []
            failureMessage = try container.decodeIfPresent(String.self, forKey: .failureMessage)
            lastUpdatedAt = try container.decode(TimeInterval.self, forKey: .lastUpdatedAt)
            nextAutomaticRefreshAt = try container.decodeIfPresent(TimeInterval.self, forKey: .nextAutomaticRefreshAt)
            automaticRefreshScheduleSignature = try container.decodeIfPresent(
                String.self,
                forKey: .automaticRefreshScheduleSignature
            )
        }
    }

    private struct PersistedState: Codable {
        let instances: [InstanceState]
    }

    private let baseURL: URL
    private let directoryURL: URL
    private let imagesDirectoryURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

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
        familyToken: String? = nil,
        now: Date = .now
    ) -> InstanceState {
        var instances = loadInstances()
        let previousImageFileName = instances[instanceToken]?.artwork?.imageFileName
        var state = instances[instanceToken] ?? makeInitialState(
            instanceToken: instanceToken,
            scopeRawValue: scopeRawValue,
            familyToken: familyToken,
            now: now
        )
        if state.scopeRawValue != scopeRawValue {
            state = resetStateForScopeChange(
                state,
                scopeRawValue: scopeRawValue,
                familyToken: familyToken,
                now: now
            )
        } else {
            if let familyToken {
                state.familyToken = familyToken
            }
            state.lastUpdatedAt = now.timeIntervalSince1970
        }
        instances[instanceToken] = state
        persist(instances)
        if previousImageFileName != state.artwork?.imageFileName {
            deleteImageFile(named: previousImageFileName)
        }
        return state
    }

    func state(for instanceToken: String) -> InstanceState? {
        return loadInstances()[instanceToken]
    }

    func resolveAutomaticRefresh(
        for instanceToken: String,
        scopeRawValue: String,
        familyToken: String? = nil,
        schedule: WidgetAutoRefreshSchedule?,
        now: Date = .now
    ) -> WidgetScheduledRefreshPolicy.Resolution {
        var instances = loadInstances()
        let previousImageFileName = instances[instanceToken]?.artwork?.imageFileName
        var didChangeState = false
        var state = instances[instanceToken] ?? makeInitialState(
            instanceToken: instanceToken,
            scopeRawValue: scopeRawValue,
            familyToken: familyToken,
            now: now
        )

        if instances[instanceToken] == nil {
            didChangeState = true
        } else if state.scopeRawValue != scopeRawValue {
            state = resetStateForScopeChange(
                state,
                scopeRawValue: scopeRawValue,
                familyToken: familyToken,
                now: now
            )
            didChangeState = true
        } else if let familyToken,
                  state.familyToken != familyToken {
            state.familyToken = familyToken
            state.lastUpdatedAt = now.timeIntervalSince1970
            didChangeState = true
        }

        let resolution = WidgetScheduledRefreshPolicy.resolve(
            state: state,
            scopeRawValue: scopeRawValue,
            schedule: schedule,
            now: now
        )
        let nextAutomaticRefreshTimestamp = resolution.nextAutomaticRefreshAt?.timeIntervalSince1970
        if state.nextAutomaticRefreshAt != nextAutomaticRefreshTimestamp ||
            state.automaticRefreshScheduleSignature != resolution.scheduleSignature {
            state.nextAutomaticRefreshAt = nextAutomaticRefreshTimestamp
            state.automaticRefreshScheduleSignature = resolution.scheduleSignature
            didChangeState = true
        }

        if didChangeState {
            instances[instanceToken] = state
            persist(instances)
            if previousImageFileName != state.artwork?.imageFileName {
                deleteImageFile(named: previousImageFileName)
            }
        }

        return resolution
    }

    func renderState(
        for instanceToken: String,
        scopeRawValue: String,
        familyToken: String? = nil,
        now: Date = .now
    ) -> InstanceState {
        var instances = loadInstances()
        if let current = instances[instanceToken] {
            if current.scopeRawValue == scopeRawValue {
                var updatedState = current
                if let familyToken,
                   updatedState.familyToken != familyToken {
                    updatedState.familyToken = familyToken
                    updatedState.lastUpdatedAt = now.timeIntervalSince1970
                    instances[instanceToken] = updatedState
                    persist(instances)
                }
                return presentationState(for: updatedState)
            }

            let previousImageFileName = current.artwork?.imageFileName
            let resetState = resetStateForScopeChange(
                current,
                scopeRawValue: scopeRawValue,
                familyToken: familyToken,
                now: now
            )
            instances[instanceToken] = resetState
            persist(instances)
            if previousImageFileName != resetState.artwork?.imageFileName {
                deleteImageFile(named: previousImageFileName)
            }
            return presentationState(for: resetState)
        }

        let state = makeInitialState(
            instanceToken: instanceToken,
            scopeRawValue: scopeRawValue,
            familyToken: familyToken,
            now: now
        )
        instances[instanceToken] = state
        persist(instances)
        return presentationState(for: state)
    }

    func presentationState(
        for instanceToken: String,
        scopeRawValue: String
    ) -> InstanceState? {
        guard let state = loadInstances()[instanceToken],
              state.scopeRawValue == scopeRawValue else {
            return nil
        }
        return presentationState(for: state)
    }

    func removeInstances(excludingRefreshKeys allowedRefreshKeys: Set<String>) {
        var instances = loadInstances()
        let removedStates = instances.values.filter { !allowedRefreshKeys.contains($0.instanceToken) }
        guard !removedStates.isEmpty else {
            return
        }

        for state in removedStates {
            instances.removeValue(forKey: state.instanceToken)
        }
        persist(instances)
        for state in removedStates {
            deleteImageFile(named: state.artwork?.imageFileName)
        }
    }

    func displayedArtworkKeys(
        for instanceToken: String,
        scopeRawValue: String? = nil
    ) -> Set<String> {
        guard let state = loadInstances()[instanceToken] else {
            return []
        }
        guard scopeRawValue == nil || state.scopeRawValue == scopeRawValue else {
            return []
        }
        return Set(state.displayedArtworkKeys)
    }

    func resetDisplayedArtworkHistory(
        for instanceToken: String,
        scopeRawValue: String,
        now: Date = .now
    ) -> InstanceState? {
        var instances = loadInstances()
        guard var state = instances[instanceToken], state.scopeRawValue == scopeRawValue else {
            return nil
        }

        state.displayedArtworkKeys = []
        state.lastUpdatedAt = now.timeIntervalSince1970
        instances[instanceToken] = state
        persist(instances)
        return state
    }

    func beginRefresh(
        instanceToken: String,
        scopeRawValue: String,
        familyToken: String? = nil,
        now: Date = .now
    ) -> InstanceState {
        var instances = loadInstances()
        let previousImageFileName = instances[instanceToken]?.artwork?.imageFileName
        var state = instances[instanceToken] ?? makeInitialState(
            instanceToken: instanceToken,
            scopeRawValue: scopeRawValue,
            familyToken: familyToken,
            now: now
        )
        if state.scopeRawValue != scopeRawValue {
            state = resetStateForScopeChange(
                state,
                scopeRawValue: scopeRawValue,
                familyToken: familyToken,
                now: now
            )
        }
        if let familyToken {
            state.familyToken = familyToken
        }
        state.nonce += 1
        state.phase = .refreshing
        state.failureMessage = nil
        state.lastUpdatedAt = now.timeIntervalSince1970
        instances[instanceToken] = state
        persist(instances)
        if previousImageFileName != state.artwork?.imageFileName {
            deleteImageFile(named: previousImageFileName)
        }
        return state
    }

    func markSuccess(
        instanceToken: String,
        expectedNonce: Int,
        payload: ArtworkPayload,
        imageData: Data?,
        familyToken: String? = nil,
        now: Date = .now
    ) -> InstanceState? {
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
        if let familyToken {
            state.familyToken = familyToken
        }
        if let artworkKey = storedPayload.artworkKey,
           !state.displayedArtworkKeys.contains(artworkKey) {
            state.displayedArtworkKeys.append(artworkKey)
        }
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
        familyToken: String? = nil,
        now: Date = .now
    ) -> InstanceState? {
        var instances = loadInstances()
        guard var state = instances[instanceToken], state.nonce == expectedNonce else {
            return nil
        }

        let previousImageFileName = state.artwork?.imageFileName
        state.phase = .failure
        state.artwork = nil
        if let familyToken {
            state.familyToken = familyToken
        }
        state.failureMessage = message
        state.lastUpdatedAt = now.timeIntervalSince1970
        instances[instanceToken] = state
        persist(instances)
        deleteImageFile(named: previousImageFileName)
        return state
    }

    func knownInstances() -> [InstanceState] {
        return loadInstances().values.sorted { lhs, rhs in
            lhs.instanceToken < rhs.instanceToken
        }
    }

    private func loadInstances() -> [String: InstanceState] {
        guard let data = try? Data(contentsOf: stateFileURL),
              let persisted = try? decoder.decode(PersistedState.self, from: data) else {
            return [:]
        }

        var normalized: [String: InstanceState] = [:]
        for state in persisted.instances {
            let normalizedState = normalizedState(for: state)
            if let current = normalized[normalizedState.instanceToken] {
                normalized[normalizedState.instanceToken] = mergedState(current, normalizedState)
            } else {
                normalized[normalizedState.instanceToken] = normalizedState
            }
        }
        return normalized
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

    private func makeInitialState(
        instanceToken: String,
        scopeRawValue: String,
        familyToken: String?,
        now: Date
    ) -> InstanceState {
        InstanceState(
            instanceToken: instanceToken,
            scopeRawValue: scopeRawValue,
            familyToken: familyToken,
            nonce: 0,
            phase: .idle,
            artwork: nil,
            displayedArtworkKeys: [],
            failureMessage: nil,
            lastUpdatedAt: now.timeIntervalSince1970,
            nextAutomaticRefreshAt: nil,
            automaticRefreshScheduleSignature: nil
        )
    }

    private func resetStateForScopeChange(
        _ state: InstanceState,
        scopeRawValue: String,
        familyToken: String?,
        now: Date
    ) -> InstanceState {
        InstanceState(
            instanceToken: state.instanceToken,
            scopeRawValue: scopeRawValue,
            familyToken: familyToken ?? state.familyToken,
            nonce: state.nonce,
            phase: .idle,
            artwork: nil,
            displayedArtworkKeys: [],
            failureMessage: nil,
            lastUpdatedAt: now.timeIntervalSince1970,
            nextAutomaticRefreshAt: nil,
            automaticRefreshScheduleSignature: nil
        )
    }

    private func presentationState(for state: InstanceState) -> InstanceState {
        guard state.phase == .refreshing else {
            return state
        }

        var visibleState = state
        visibleState.phase = state.artwork == nil ? .idle : .success
        return visibleState
    }

    private func normalizedState(for state: InstanceState) -> InstanceState {
        var normalized = state
        normalized.familyToken = normalizedFamilyToken(state.familyToken)
        normalized.instanceToken = WidgetRefreshGroupKey.make(
            scopeRawValue: state.scopeRawValue,
            familyToken: normalized.familyToken ?? ""
        )
        return normalized
    }

    private func mergedState(_ lhs: InstanceState, _ rhs: InstanceState) -> InstanceState {
        let orderedStates = [lhs, rhs].sorted { left, right in
            if left.phase == .idle, right.phase != .idle {
                return false
            }
            if left.phase != .idle, right.phase == .idle {
                return true
            }
            return left.lastUpdatedAt > right.lastUpdatedAt
        }
        let primary = orderedStates[0]
        let fallback = orderedStates[1]

        var merged = primary
        merged.instanceToken = primary.instanceToken
        merged.familyToken = primary.familyToken ?? fallback.familyToken
        merged.nonce = max(lhs.nonce, rhs.nonce)
        merged.artwork = primary.artwork ?? fallback.artwork
        merged.displayedArtworkKeys = mergedDisplayedArtworkKeys(from: orderedStates)
        merged.failureMessage = primary.failureMessage ?? fallback.failureMessage
        merged.lastUpdatedAt = max(lhs.lastUpdatedAt, rhs.lastUpdatedAt)
        let latestScheduleState = [lhs, rhs]
            .sorted { $0.lastUpdatedAt > $1.lastUpdatedAt }
            .first { $0.nextAutomaticRefreshAt != nil || $0.automaticRefreshScheduleSignature != nil }
        merged.nextAutomaticRefreshAt = latestScheduleState?.nextAutomaticRefreshAt
        merged.automaticRefreshScheduleSignature = latestScheduleState?.automaticRefreshScheduleSignature
        return merged
    }

    private func mergedDisplayedArtworkKeys(from states: [InstanceState]) -> [String] {
        var seen: Set<String> = []
        var merged: [String] = []

        for state in states {
            for key in state.displayedArtworkKeys where seen.insert(key).inserted {
                merged.append(key)
            }
        }

        return merged
    }

    private func normalizedFamilyToken(_ familyToken: String?) -> String? {
        guard let familyToken = familyToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              !familyToken.isEmpty else {
            return nil
        }
        return familyToken
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
