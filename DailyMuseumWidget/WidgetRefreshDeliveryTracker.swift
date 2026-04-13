import Foundation
import WidgetKit

actor WidgetRefreshDeliveryTracker {
    static let shared = WidgetRefreshDeliveryTracker()

    private enum Constants {
        static let directoryName = "WidgetRefresh"
        static let fileName = "delivery-tracker.json"
        static let staleTimeout: TimeInterval = 20
    }

    enum Phase: String, Codable {
        case generating
        case delivering
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
        var deliveredCounts: [String: Int]
        var deliveredTokens: [String: [String]]
        var lastUpdatedAt: TimeInterval

        var expectedTotal: Int {
            expectedCounts.values.reduce(0, +)
        }

        var deliveredTotal: Int {
            deliveredCounts.values.reduce(0, +)
        }

        var isComplete: Bool {
            Self.familyOrder.allSatisfy { familyKey in
                deliveredCounts[familyKey, default: 0] >= expectedCounts[familyKey, default: 0]
            }
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
            if familyProgress.isEmpty {
                return "总计 0/0"
            }
            return "总计 \(deliveredTotal)/\(expectedTotal)（\(familyProgress)）"
        }

        mutating func transition(to phase: Phase, at timestamp: TimeInterval) {
            self.phase = phase
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
            deliveredCounts: emptyCounts(),
            deliveredTokens: [:],
            lastUpdatedAt: timestamp
        )
        persist(state)
        return state
    }

    func transitionToDelivering(nonce: Int, now: Date = .now) -> State? {
        guard var state = loadState(), state.nonce == nonce else {
            return nil
        }
        state.transition(to: .delivering, at: now.timeIntervalSince1970)
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
