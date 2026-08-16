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
        static let displayedHistoryFileName = "displayed-history.json"
        static let imagesDirectoryName = "images"
        static let widgetImageMaximumDimension: CGFloat = 1024
        static let widgetImageMaximumPixelArea: CGFloat = 1_000_000
        static let storedImageCompressionQuality: CGFloat = 0.85
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

    private struct PersistedDisplayedArtworkHistory: Codable, Equatable {
        var artworkKeysByMuseum: [String: [String]]
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
                prepareStoredImageIfNeeded(named: updatedState.artwork?.imageFileName)
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

    func displayedArtworkKeys(for museumID: MuseumID) -> Set<String> {
        Set(loadDisplayedArtworkHistory().artworkKeysByMuseum[museumID.rawValue] ?? [])
    }

    func resetDisplayedArtworkHistory(
        for museumIDs: [MuseumID],
        now: Date = .now
    ) {
        _ = now
        var history = loadDisplayedArtworkHistory()
        var didChange = false
        for museumID in museumIDs where history.artworkKeysByMuseum[museumID.rawValue] != nil {
            history.artworkKeysByMuseum[museumID.rawValue] = []
            didChange = true
        }
        guard didChange else {
            return
        }
        persistDisplayedArtworkHistory(normalizedDisplayedArtworkHistory(history))
    }

    func exportDisplayedArtworkHistory() -> [String: [String]] {
        loadDisplayedArtworkHistory().artworkKeysByMuseum
    }

    func replaceDisplayedArtworkHistory(_ artworkKeysByMuseum: [String: [String]]) {
        let history = PersistedDisplayedArtworkHistory(artworkKeysByMuseum: artworkKeysByMuseum)
        persistDisplayedArtworkHistory(normalizedDisplayedArtworkHistory(history))
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
           !artworkKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            recordDisplayedArtworkKey(artworkKey, museumID: storedPayload.museumID)
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
        _ = loadDisplayedArtworkHistory()
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
        normalized.displayedArtworkKeys = []
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
        merged.displayedArtworkKeys = []
        merged.failureMessage = primary.failureMessage ?? fallback.failureMessage
        merged.lastUpdatedAt = max(lhs.lastUpdatedAt, rhs.lastUpdatedAt)
        let latestScheduleState = [lhs, rhs]
            .sorted { $0.lastUpdatedAt > $1.lastUpdatedAt }
            .first { $0.nextAutomaticRefreshAt != nil || $0.automaticRefreshScheduleSignature != nil }
        merged.nextAutomaticRefreshAt = latestScheduleState?.nextAutomaticRefreshAt
        merged.automaticRefreshScheduleSignature = latestScheduleState?.automaticRefreshScheduleSignature
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
            let storedData = Self.preparedImageDataForStorage(imageData)
            try storedData.write(to: fileURL, options: [.atomic])
            return fileName
        } catch {
            return nil
        }
    }

    static func preparedImageDataForStorage(_ imageData: Data) -> Data {
        guard let dimensions = imageDimensions(from: imageData) else {
            return imageData
        }

        let sourceWidth = CGFloat(dimensions.width)
        let sourceHeight = CGFloat(dimensions.height)
        let maximumDimension = max(sourceWidth, sourceHeight)
        let pixelArea = sourceWidth * sourceHeight
        let dimensionScale = Constants.widgetImageMaximumDimension / maximumDimension
        let areaScale = sqrt(Constants.widgetImageMaximumPixelArea / pixelArea)
        let scale = min(1, dimensionScale, areaScale)
        guard scale < 1,
              let source = CGImageSourceCreateWithData(
                imageData as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary
              ) else {
            return imageData
        }

        let thumbnailMaximumDimension = max(1, Int(floor(maximumDimension * scale)))

        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailMaximumDimension,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            thumbnailOptions as CFDictionary
        ) else {
            return imageData
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            "public.jpeg" as CFString,
            1,
            nil
        ) else {
            return imageData
        }

        let destinationOptions = [
            kCGImageDestinationLossyCompressionQuality: Constants.storedImageCompressionQuality
        ] as CFDictionary
        CGImageDestinationAddImage(destination, thumbnail, destinationOptions)
        guard CGImageDestinationFinalize(destination) else {
            return imageData
        }
        return output as Data
    }

    private func deleteImageFile(named fileName: String?) {
        guard let fileName else {
            return
        }
        try? FileManager.default.removeItem(at: imagesDirectoryURL.appendingPathComponent(fileName))
    }

    private func prepareStoredImageIfNeeded(named fileName: String?) {
        guard let fileName else {
            return
        }
        let fileURL = imagesDirectoryURL.appendingPathComponent(fileName)
        guard let storedData = try? Data(contentsOf: fileURL) else {
            return
        }
        let preparedData = Self.preparedImageDataForStorage(storedData)
        guard preparedData != storedData else {
            return
        }
        try? preparedData.write(to: fileURL, options: [.atomic])
    }

    private func safeFileName(for rawValue: String) -> String {
        rawValue
            .replacingOccurrences(of: "[^A-Za-z0-9_-]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private var stateFileURL: URL {
        directoryURL.appendingPathComponent(Constants.stateFileName)
    }

    private var displayedHistoryFileURL: URL {
        directoryURL.appendingPathComponent(Constants.displayedHistoryFileName)
    }

    private func loadDisplayedArtworkHistory() -> PersistedDisplayedArtworkHistory {
        if let data = try? Data(contentsOf: displayedHistoryFileURL),
           let persisted = try? decoder.decode(PersistedDisplayedArtworkHistory.self, from: data) {
            return normalizedDisplayedArtworkHistory(persisted)
        }

        let migrated = migratedDisplayedArtworkHistoryFromInstanceState()
        if !migrated.artworkKeysByMuseum.isEmpty {
            persistDisplayedArtworkHistory(migrated)
        }
        return migrated
    }

    private func migratedDisplayedArtworkHistoryFromInstanceState() -> PersistedDisplayedArtworkHistory {
        guard let data = try? Data(contentsOf: stateFileURL),
              let persisted = try? decoder.decode(PersistedState.self, from: data) else {
            return PersistedDisplayedArtworkHistory(artworkKeysByMuseum: [:])
        }

        var history = PersistedDisplayedArtworkHistory(artworkKeysByMuseum: [:])
        for state in persisted.instances {
            for artworkKey in state.displayedArtworkKeys {
                guard let museumID = museumID(forArtworkKey: artworkKey, fallback: state.artwork?.museumID) else {
                    continue
                }
                appendDisplayedArtworkKey(artworkKey, museumID: museumID, to: &history)
            }
        }
        return normalizedDisplayedArtworkHistory(history)
    }

    private func persistDisplayedArtworkHistory(_ history: PersistedDisplayedArtworkHistory) {
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let data = try encoder.encode(history)
            try data.write(to: displayedHistoryFileURL, options: [.atomic])
        } catch {
            // Ignore history persistence failures and allow the refresh flow to keep running.
        }
    }

    private func recordDisplayedArtworkKey(_ artworkKey: String, museumID: MuseumID) {
        var history = loadDisplayedArtworkHistory()
        appendDisplayedArtworkKey(artworkKey, museumID: museumID, to: &history)
        persistDisplayedArtworkHistory(normalizedDisplayedArtworkHistory(history))
    }

    private func appendDisplayedArtworkKey(
        _ artworkKey: String,
        museumID: MuseumID,
        to history: inout PersistedDisplayedArtworkHistory
    ) {
        let trimmedKey = artworkKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            return
        }

        var keys = history.artworkKeysByMuseum[museumID.rawValue] ?? []
        guard !keys.contains(trimmedKey) else {
            return
        }
        keys.append(trimmedKey)
        history.artworkKeysByMuseum[museumID.rawValue] = keys
    }

    private func normalizedDisplayedArtworkHistory(
        _ history: PersistedDisplayedArtworkHistory
    ) -> PersistedDisplayedArtworkHistory {
        var normalized: [String: [String]] = [:]
        for (museumRawValue, artworkKeys) in history.artworkKeysByMuseum {
            guard MuseumID(rawValue: museumRawValue) != nil else {
                continue
            }

            var seen: Set<String> = []
            let keys = artworkKeys.compactMap { key -> String? in
                let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedKey.isEmpty, seen.insert(trimmedKey).inserted else {
                    return nil
                }
                return trimmedKey
            }
            if !keys.isEmpty {
                normalized[museumRawValue] = keys
            }
        }
        return PersistedDisplayedArtworkHistory(artworkKeysByMuseum: normalized)
    }

    private func museumID(forArtworkKey artworkKey: String, fallback: MuseumID?) -> MuseumID? {
        let rawValue = artworkKey.split(separator: "|", maxSplits: 1).first.map(String.init)
        return rawValue.flatMap(MuseumID.init(rawValue:)) ?? fallback
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
        _ = targetPointSize
        _ = scale
        guard let url = imageURL(for: fileName) else { return nil }
        return UIImage(contentsOfFile: url.path)
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
}
