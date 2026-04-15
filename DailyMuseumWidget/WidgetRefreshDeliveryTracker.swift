import Foundation
import WidgetKit

actor WidgetRefreshDeliveryTracker {
    static let shared = WidgetRefreshDeliveryTracker()

    private enum Constants {
        static let directoryName = "WidgetRefresh"
        static let fileName = "delivery-tracker.json"
        static let staleTimeout: TimeInterval = 90
        static let completedResultReuseTimeout: TimeInterval = 15
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
                    return "目标尺寸 \(requestedFamilyKey) 已渲染"
                }
                return "目标尺寸 \(requestedFamilyKey) 待渲染"
            }()

            if familyProgress.isEmpty {
                return "总计 0/0，\(renderProgress)"
            }
            return "总计 \(deliveredTotal)/\(expectedTotal)（\(familyProgress)），\(renderProgress)"
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
        guard var state = loadState(), state.nonce == nonce else {
            return nil
        }

        state.transition(
            to: .completed,
            targetRenderID: targetRenderID,
            at: now.timeIntervalSince1970
        )
        state.renderedFamilyRenderIDs[state.requestedFamilyKey] = targetRenderID
        persist(state)
        return state
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
        guard let state = activeState(expectedNonce: expectedNonce, now: now),
              state.phase == .delivering else {
            return nil
        }
        return state.targetRenderID
    }

    func reusableTargetRenderID(expectedNonce: Int, now: Date = .now) -> String? {
        guard let state = activeState(expectedNonce: expectedNonce, now: now),
              let targetRenderID = state.targetRenderID else {
            return nil
        }

        switch state.phase {
        case .delivering:
            return targetRenderID
        case .completed:
            let age = now.timeIntervalSince1970 - state.lastUpdatedAt
            return age <= Constants.completedResultReuseTimeout ? targetRenderID : nil
        case .generating:
            return nil
        }
    }

    func status(for nonce: Int, now: Date = .now) -> Status {
        guard let state = activeState(expectedNonce: nonce, now: now) else {
            return .missing
        }
        return state.isComplete ? .completed(state) : .pending(state)
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

extension CGSize {
    var widgetLogLabel: String {
        "\(Int(width.rounded()))x\(Int(height.rounded()))"
    }
}
