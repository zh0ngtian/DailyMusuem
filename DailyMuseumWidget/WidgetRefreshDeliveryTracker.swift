import Foundation
import WidgetKit

actor WidgetRefreshDeliveryTracker {
    static let shared = WidgetRefreshDeliveryTracker()

    private enum Constants {
        static let directoryName = "WidgetRefresh"
        static let fileName = "delivery-tracker.json"
        static let staleTimeout: TimeInterval = 90
        static let completedResultReuseTimeout: TimeInterval = WidgetDesktopSyncSchedule.syncWindowDuration
    }

    enum Phase: String, Codable {
        case generating
        case delivering
        case completed
    }

    enum Status {
        case pending(State)
        case completed(State)
        case missing
    }

    enum ActiveRefreshStatus {
        case active(State)
        case expired
        case missing
    }

    struct State: Codable {
        let nonce: Int
        let startedAt: TimeInterval
        var phase: Phase
        let configurationCount: Int
        let expectedCounts: [String: Int]
        let requestedFamilyKey: String
        var deliveredCounts: [String: Int]
        var deliveredTokens: [String: [String]]
        var targetRenderID: String?
        var renderedFamilyRenderIDs: [String: String]
        var lastUpdatedAt: TimeInterval

        var expectedTotal: Int {
            expectedCounts.values.reduce(0, +)
        }

        var deliveredTotal: Int {
            deliveredCounts.values.reduce(0, +)
        }

        var isComplete: Bool {
            guard let targetRenderID else {
                return false
            }
            return renderedFamilyRenderIDs[requestedFamilyKey] == targetRenderID
        }

        var configurationSummary: String {
            let counts = Self.familyOrder
                .map { familyKey in
                    let expected = expectedCounts[familyKey, default: 0]
                    return expected > 0 ? "\(familyKey)x\(expected)" : nil
                }
                .compactMap { $0 }
            if counts.isEmpty {
                return "0 个"
            }
            return "\(configurationCount) 个（" + counts.joined(separator: "、") + "）"
        }

        var progressSummary: String {
            let phaseSummary: String = switch phase {
            case .generating:
                "阶段=生成中"
            case .delivering:
                "阶段=投递中"
            case .completed:
                "阶段=目标尺寸已收到扩展渲染回执（桌面同步窗口中）"
            }
            let familyProgress = Self.familyOrder
                .map { familyKey in
                    let expected = expectedCounts[familyKey, default: 0]
                    let delivered = deliveredCounts[familyKey, default: 0]
                    guard expected > 0 else { return nil }
                    return "\(familyKey) \(delivered)/\(expected)"
                }
                .compactMap { $0 }
                .joined(separator: "、")
            let renderProgress: String = {
                guard let targetRenderID else {
                    return "目标尺寸 \(requestedFamilyKey) 等待生成 renderID"
                }
                if renderedFamilyRenderIDs[requestedFamilyKey] == targetRenderID {
                    return "目标尺寸 \(requestedFamilyKey) 已收到扩展渲染回执，等待桌面位图同步"
                }
                return "目标尺寸 \(requestedFamilyKey) 待扩展渲染回执"
            }()

            if familyProgress.isEmpty {
                return "\(phaseSummary)，总计 0/0，\(renderProgress)"
            }
            return "\(phaseSummary)，总计 \(deliveredTotal)/\(expectedTotal)（\(familyProgress)），\(renderProgress)"
        }

        mutating func transition(to phase: Phase, targetRenderID: String? = nil, at timestamp: TimeInterval) {
            self.phase = phase
            if let targetRenderID {
                self.targetRenderID = targetRenderID
            }
            lastUpdatedAt = timestamp
        }

        mutating func recordDelivery(familyKey: String, token: String, timestamp: TimeInterval) -> Bool {
            var tokens = deliveredTokens[familyKey] ?? []
            guard !tokens.contains(token) else {
                return false
            }

            tokens.append(token)
            deliveredTokens[familyKey] = tokens

            let expected = expectedCounts[familyKey, default: 0]
            deliveredCounts[familyKey] = min(expected, tokens.count)
            lastUpdatedAt = timestamp
            return true
        }

        mutating func recordRender(familyKey: String, renderID: String, timestamp: TimeInterval) -> Bool {
            guard phase == .delivering,
                  let targetRenderID,
                  familyKey == requestedFamilyKey,
                  renderID == targetRenderID else {
                return false
            }

            guard renderedFamilyRenderIDs[familyKey] != renderID else {
                return false
            }

            renderedFamilyRenderIDs[familyKey] = renderID
            phase = .completed
            lastUpdatedAt = timestamp
            return true
        }

        private static let familyOrder = ["systemLarge", "systemMedium", "systemSmall"]
    }

    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(fileManager: FileManager = .default) {
        let baseURL = fileManager.containerURL(forSecurityApplicationGroupIdentifier: SettingsKeys.appGroupID)
            ?? fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        self.init(baseURL: baseURL)
    }

    init(baseURL: URL) {
        fileURL = baseURL
            .appendingPathComponent(Constants.directoryName, isDirectory: true)
            .appendingPathComponent(Constants.fileName)
    }

    func begin(
        nonce: Int,
        configurationCount: Int,
        expectedCounts providedCounts: [String: Int],
        requestedFamilyKey: String,
        startedAt: Date = .now
    ) -> State {
        var expectedCounts = emptyCounts()
        for (familyKey, count) in providedCounts {
            expectedCounts[familyKey, default: 0] = count
        }

        let timestamp = startedAt.timeIntervalSince1970
        let state = State(
            nonce: nonce,
            startedAt: timestamp,
            phase: .generating,
            configurationCount: configurationCount,
            expectedCounts: expectedCounts,
            requestedFamilyKey: requestedFamilyKey,
            deliveredCounts: emptyCounts(),
            deliveredTokens: [:],
            targetRenderID: nil,
            renderedFamilyRenderIDs: [:],
            lastUpdatedAt: timestamp
        )
        persist(state)
        return state
    }

    func transitionToDelivering(nonce: Int, targetRenderID: String, now: Date = .now) -> State? {
        guard var state = loadState(), state.nonce == nonce else {
            return nil
        }

        state.transition(
            to: .delivering,
            targetRenderID: targetRenderID,
            at: now.timeIntervalSince1970
        )
        persist(state)
        return state
    }

    func completeGeneratedRefresh(nonce: Int, targetRenderID: String, now: Date = .now) -> State? {
        transitionToDelivering(
            nonce: nonce,
            targetRenderID: targetRenderID,
            now: now
        )
    }

    func activeState(expectedNonce: Int, now: Date = .now) -> State? {
        guard let state = loadState(), state.nonce == expectedNonce else {
            return nil
        }

        if now.timeIntervalSince1970 - state.lastUpdatedAt > Constants.staleTimeout {
            removeState()
            return nil
        }

        return state
    }

    func activeTargetRenderID(expectedNonce: Int, now: Date = .now) -> String? {
        guard case .active(let state) = activeRefreshStatus(expectedNonce: expectedNonce, now: now),
              state.phase != .generating else {
            return nil
        }
        return state.targetRenderID
    }

    func reusableTargetRenderID(expectedNonce: Int, now: Date = .now) -> String? {
        guard case .active(let state) = activeRefreshStatus(expectedNonce: expectedNonce, now: now),
              state.phase != .generating else {
            return nil
        }
        return state.targetRenderID
    }

    func status(for nonce: Int, now: Date = .now) -> Status {
        guard case .active(let state) = activeRefreshStatus(expectedNonce: nonce, now: now) else {
            return .missing
        }
        return state.isComplete ? .completed(state) : .pending(state)
    }

    func activeRefreshStatus(expectedNonce: Int, now: Date = .now) -> ActiveRefreshStatus {
        guard let state = activeState(expectedNonce: expectedNonce, now: now) else {
            return .missing
        }

        if state.phase == .completed {
            let age = now.timeIntervalSince1970 - state.lastUpdatedAt
            if age >= Constants.completedResultReuseTimeout {
                return .expired
            }
        }

        return .active(state)
    }

    func recordDelivery(
        nonce: Int,
        family: WidgetFamily,
        displaySize: CGSize,
        deliveryID: String,
        now: Date = .now
    ) -> State? {
        guard var state = activeState(expectedNonce: nonce, now: now),
              state.phase == .delivering else {
            return nil
        }

        let token = "\(deliveryID)|\(displaySize.widgetLogLabel)"
        guard state.recordDelivery(
            familyKey: family.logKey,
            token: token,
            timestamp: now.timeIntervalSince1970
        ) else {
            return nil
        }

        persist(state)
        return state
    }

    func recordRender(
        family: WidgetFamily,
        renderID: String,
        now: Date = .now
    ) -> State? {
        guard var state = loadState(),
              state.recordRender(
                familyKey: family.logKey,
                renderID: renderID,
                timestamp: now.timeIntervalSince1970
              ) else {
            return nil
        }

        persist(state)
        return state
    }

    func clear(nonce: Int? = nil) {
        guard let state = loadState() else {
            return
        }
        guard nonce == nil || state.nonce == nonce else {
            return
        }
        removeState()
    }

    private func emptyCounts() -> [String: Int] {
        [
            "systemLarge": 0,
            "systemMedium": 0,
            "systemSmall": 0,
        ]
    }

    private func loadState() -> State? {
        guard let data = try? Data(contentsOf: fileURL),
              let state = try? decoder.decode(State.self, from: data) else {
            return nil
        }
        return state
    }

    private func persist(_ state: State) {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try encoder.encode(state)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            // Ignore persistence failures to avoid breaking widget refresh.
        }
    }

    private func removeState() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}

enum WidgetRenderFollowUpReloadDecision {
    static func shouldRequestReload(
        deliveryState: WidgetRefreshDeliveryTracker.State?,
        familyKey: String
    ) -> Bool {
        guard let deliveryState else {
            return false
        }

        return deliveryState.phase == .completed
            && deliveryState.requestedFamilyKey == familyKey
    }
}

enum WidgetRenderLoggingDecision {
    static func shouldSuppressRenderLog(
        entryRenderID: String,
        deliveryID: String,
        activeManualRefreshState: WidgetRefreshDeliveryTracker.State?
    ) -> Bool {
        guard deliveryID.contains("-sync-"),
              let activeManualRefreshState,
              activeManualRefreshState.phase == .completed,
              let targetRenderID = activeManualRefreshState.targetRenderID else {
            return false
        }

        return entryRenderID == targetRenderID
    }

    static func renderLogKey(
        entryRenderID: String,
        familyKey: String,
        deliveryID: String,
        activeManualRefreshState: WidgetRefreshDeliveryTracker.State?
    ) -> String {
        guard let activeManualRefreshState,
              activeManualRefreshState.phase == .completed,
              activeManualRefreshState.targetRenderID == entryRenderID else {
            return [entryRenderID, familyKey, deliveryID]
                .filter { !$0.isEmpty }
                .joined(separator: "|")
        }

        return [entryRenderID, familyKey, "sync-window"]
            .filter { !$0.isEmpty }
            .joined(separator: "|")
    }
}

enum WidgetRenderedArtworkPersistenceDecision {
    static func shouldPersist(
        entryRenderID: String,
        isRefreshing: Bool,
        activeManualRefreshState: WidgetRefreshDeliveryTracker.State?
    ) -> Bool {
        guard !isRefreshing else {
            return false
        }

        guard let activeManualRefreshState else {
            return true
        }

        guard let targetRenderID = activeManualRefreshState.targetRenderID else {
            return false
        }

        return entryRenderID == targetRenderID
    }

    static func ignoreReason(
        entryRenderID: String,
        isRefreshing: Bool,
        activeManualRefreshState: WidgetRefreshDeliveryTracker.State?
    ) -> String {
        if isRefreshing {
            return "加载态不写入最近扩展渲染记录"
        }

        guard let activeManualRefreshState else {
            return "无需忽略"
        }

        guard let targetRenderID = activeManualRefreshState.targetRenderID else {
            return "存在进行中的手动刷新，但目标 renderID 尚未生成"
        }

        return "存在更新中的手动刷新目标 renderID=\(targetRenderID)，忽略过期扩展渲染 renderID=\(entryRenderID)"
    }
}

enum WidgetManualRefreshInterruptionDecision {
    static func shouldInterrupt(
        executionNonce: Int,
        isManualRefreshInProgress: Bool,
        activeNonce: Int
    ) -> Bool {
        !isManualRefreshInProgress || activeNonce != executionNonce
    }
}

struct WidgetManualRefreshInterruptedError: LocalizedError {
    let executionNonce: Int
    let activeNonce: Int

    var errorDescription: String? {
        "手动刷新 nonce=\(executionNonce) 已被 nonce=\(activeNonce) 抢占"
    }
}

enum WidgetDesktopSyncSchedule {
    static let checkpointOffsets: [TimeInterval] = [2, 5, 10, 20, 30]
    static let syncWindowDuration: TimeInterval = checkpointOffsets.last ?? 30

    static func syncStartedAt(for state: WidgetRefreshDeliveryTracker.State) -> Date? {
        guard state.phase == .completed else {
            return nil
        }
        return Date(timeIntervalSince1970: state.lastUpdatedAt)
    }

    static func nextReloadDate(
        for state: WidgetRefreshDeliveryTracker.State,
        now: Date
    ) -> Date? {
        guard let syncStartedAt = syncStartedAt(for: state) else {
            return nil
        }
        return nextReloadDate(syncStartedAt: syncStartedAt, now: now)
    }

    static func nextReloadDate(syncStartedAt: Date, now: Date) -> Date? {
        for offset in checkpointOffsets {
            let candidate = syncStartedAt.addingTimeInterval(offset)
            if candidate > now {
                return candidate
            }
        }
        return nil
    }

    static func remainingCheckpointDates(
        syncStartedAt: Date,
        now: Date
    ) -> [Date] {
        checkpointOffsets
            .map { syncStartedAt.addingTimeInterval($0) }
            .filter { $0 > now }
    }

    static func syncWindowEnd(for state: WidgetRefreshDeliveryTracker.State) -> Date? {
        guard let syncStartedAt = syncStartedAt(for: state) else {
            return nil
        }
        return syncStartedAt.addingTimeInterval(syncWindowDuration)
    }
}

enum WidgetImageFetchPolicy {
    private enum Constants {
        static let regularRequestTimeout: TimeInterval = 8
        static let regularMaxAttempts = 3
        static let manualRefreshRequestTimeout: TimeInterval = 3
        static let manualRefreshMaxAttempts = 1
    }

    static func requestTimeout(manualRefreshInProgress: Bool) -> TimeInterval {
        manualRefreshInProgress ? Constants.manualRefreshRequestTimeout : Constants.regularRequestTimeout
    }

    static func maxAttempts(manualRefreshInProgress: Bool) -> Int {
        manualRefreshInProgress ? Constants.manualRefreshMaxAttempts : Constants.regularMaxAttempts
    }
}

enum WidgetManualRefreshFallbackDecision {
    private enum Constants {
        static let maxImageFetchFailuresBeforeFallback = 2
        static let maxElapsedBeforeFallback: TimeInterval = 12
    }

    static func shouldFallbackToTextOnly(
        manualRefreshInProgress: Bool,
        imageFetchFailureCount: Int,
        elapsed: TimeInterval
    ) -> Bool {
        guard manualRefreshInProgress else {
            return false
        }

        return imageFetchFailureCount >= Constants.maxImageFetchFailuresBeforeFallback
            || elapsed >= Constants.maxElapsedBeforeFallback
    }
}

enum WidgetValidatedSnapshotResult {
    case ready(WidgetArtworkSnapshotStore.Snapshot)
    case missingImage
    case imageFetchFailed
    case invalidImageData
}

enum WidgetPreferredImageURLDecision {
    static func resolve(for artwork: Artwork, museumID: MuseumID) -> URL? {
        resolveCandidates(for: artwork, museumID: museumID).first
    }

    static func resolveCandidates(for artwork: Artwork, museumID: MuseumID) -> [URL] {
        switch museumID {
        case .tnm:
            return uniqueURLs([artwork.primaryImageSmallURL, artwork.primaryImageURL])
        case .met, .nmc, .shm:
            return uniqueURLs([artwork.primaryImageSmallURL, artwork.primaryImageURL])
        }
    }

    private static func uniqueURLs(_ candidates: [URL?]) -> [URL] {
        var seen: Set<String> = []
        return candidates.compactMap { url in
            guard let url else { return nil }
            let key = url.absoluteString
            guard seen.insert(key).inserted else { return nil }
            return url
        }
    }
}

enum WidgetImageSuitabilityDecision {
    private enum Constants {
        static let minimumShortSide = 60
        static let maximumAspectRatio = 4.5
    }

    static func isAcceptableForWidget(dimensions: WidgetImageDimensions) -> Bool {
        let shortSide = min(dimensions.width, dimensions.height)
        let longSide = max(dimensions.width, dimensions.height)
        guard shortSide >= Constants.minimumShortSide else {
            return false
        }
        return Double(longSide) / Double(shortSide) <= Constants.maximumAspectRatio
    }
}

extension CGSize {
    var widgetLogLabel: String {
        "\(Int(width.rounded()))x\(Int(height.rounded()))"
    }
}
