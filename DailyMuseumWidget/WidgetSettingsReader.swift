import Foundation

struct WidgetSettingsReader {
    private enum Constants {
        static let manualRefreshStaleTimeout: TimeInterval = 90
    }

    private let defaults: UserDefaults
    private let refreshTracker: WidgetRefreshDeliveryTracker

    init() {
        self.init(
            defaults: UserDefaults(suiteName: SettingsKeys.appGroupID) ?? .standard,
            refreshTracker: .shared
        )
    }

    init(defaults: UserDefaults, refreshTracker: WidgetRefreshDeliveryTracker = .shared) {
        self.defaults = defaults
        self.refreshTracker = refreshTracker
    }

    var refreshInterval: WidgetRefreshInterval {
        let value = defaults.integer(forKey: SettingsKeys.widgetRefreshIntervalMinutes)
        return WidgetRefreshInterval(rawValue: value) ?? .oneHour
    }

    var museumScope: WidgetMuseumScope {
        let raw = defaults.string(forKey: SettingsKeys.widgetMuseumScope) ?? WidgetMuseumScope.all.rawValue
        let scope = WidgetMuseumScope(rawValue: raw) ?? .all
        if scope.isSupportedForWidget {
            return scope
        }
        persistWidgetMuseumScope(.all)
        return .all
    }

    var preferHasImages: Bool {
        if defaults.object(forKey: SettingsKeys.widgetPreferHasImages) == nil { return true }
        return defaults.bool(forKey: SettingsKeys.widgetPreferHasImages)
    }

    var manualRefreshNonce: TimeInterval {
        defaults.double(forKey: SettingsKeys.widgetManualRefreshNonce)
    }

    var manualRefreshNonceValue: Int {
        Int(manualRefreshNonce.rounded())
    }

    var manualRefreshInProgress: Bool {
        manualRefreshFlagIsActive(now: .now)
    }

    var manualRefreshRequestedFamilyKey: String {
        defaults.string(forKey: SettingsKeys.widgetManualRefreshRequestedFamilyKey) ?? ""
    }

    func manualRefreshInProgress(forFamilyKey familyKey: String, now: Date = .now) -> Bool {
        manualRefreshFlagIsActive(now: now) && manualRefreshApplies(toFamilyKey: familyKey)
    }

    func shouldInterruptManualRefreshExecution(nonce: Int, now: Date = .now) -> Bool {
        WidgetManualRefreshInterruptionDecision.shouldInterrupt(
            executionNonce: nonce,
            isManualRefreshInProgress: manualRefreshFlagIsActive(now: now),
            activeNonce: manualRefreshNonceValue
        )
    }

    func clearManualRefreshStateIfCurrentNonce(_ nonce: Int) {
        guard manualRefreshNonceValue == nonce else {
            return
        }
        clearManualRefreshState()
    }

    func categories(for museumID: MuseumID) -> [MuseumCategory] {
        museumID.feedCategories(withStoredValue: defaults.string(forKey: feedCategoryKey(for: museumID)))
    }

    func activeManualRefreshDeliveryState(
        forFamilyKey familyKey: String? = nil,
        now: Date = .now
    ) async -> WidgetRefreshDeliveryTracker.State? {
        guard manualRefreshFlagIsActive(now: now) else {
            await refreshTracker.clear()
            return nil
        }

        guard manualRefreshApplies(toFamilyKey: familyKey) else {
            return nil
        }

        let nonce = manualRefreshNonceValue
        guard nonce > 0 else {
            return nil
        }

        switch await refreshTracker.activeRefreshStatus(expectedNonce: nonce, now: now) {
        case .active(let state):
            return state
        case .expired, .missing:
            clearManualRefreshState()
            await refreshTracker.clear(nonce: nonce)
            return nil
        }
    }

    func activeManualRefreshTargetRenderID(
        forFamilyKey familyKey: String? = nil,
        now: Date = .now
    ) async -> String? {
        let state = await activeManualRefreshDeliveryState(forFamilyKey: familyKey, now: now)
        guard state?.phase != .generating else {
            return nil
        }
        return state?.targetRenderID
    }

    func reusableManualRefreshTargetRenderID(
        forFamilyKey familyKey: String? = nil,
        now: Date = .now
    ) async -> String? {
        let state = await activeManualRefreshDeliveryState(forFamilyKey: familyKey, now: now)
        guard state?.phase != .generating else {
            return nil
        }
        return state?.targetRenderID
    }

    var categorySelectionKey: String {
        switch museumScope {
        case .all:
            return MuseumRepository.widgetSupportedMuseums.map(\.id)
                .map { "\($0.rawValue):\(categorySelectionKey(for: $0))" }
                .joined(separator: ";")
        case .single(let museumID):
            return "\(museumID.rawValue):\(categorySelectionKey(for: museumID))"
        }
    }

    private func categorySelectionKey(for museumID: MuseumID) -> String {
        museumID.feedCategoryStorageValue(for: categories(for: museumID))
    }

    private func feedCategoryKey(for museumID: MuseumID) -> String {
        SettingsKeys.feedCategoryPrefix + museumID.rawValue
    }

    private func clearManualRefreshState() {
        defaults.set(false, forKey: SettingsKeys.widgetManualRefreshInProgress)
        defaults.removeObject(forKey: SettingsKeys.widgetManualRefreshStartedAt)
        defaults.removeObject(forKey: SettingsKeys.widgetManualRefreshRequestedFamilyKey)
        defaults.synchronize()
    }

    private func manualRefreshFlagIsActive(now: Date, forFamilyKey familyKey: String? = nil) -> Bool {
        guard defaults.bool(forKey: SettingsKeys.widgetManualRefreshInProgress) else {
            return false
        }

        let startedAt = defaults.double(forKey: SettingsKeys.widgetManualRefreshStartedAt)
        guard startedAt > 0 else {
            clearManualRefreshState()
            return false
        }

        if now.timeIntervalSince1970 - startedAt >= Constants.manualRefreshStaleTimeout {
            clearManualRefreshState()
            return false
        }

        return true
    }

    private func manualRefreshApplies(toFamilyKey familyKey: String?) -> Bool {
        guard let familyKey, !familyKey.isEmpty else {
            return true
        }

        let requestedFamilyKey = defaults.string(forKey: SettingsKeys.widgetManualRefreshRequestedFamilyKey) ?? ""
        if requestedFamilyKey.isEmpty {
            return true
        }
        return requestedFamilyKey == familyKey
    }

    private func persistWidgetMuseumScope(_ scope: WidgetMuseumScope) {
        defaults.set(scope.rawValue, forKey: SettingsKeys.widgetMuseumScope)
        defaults.synchronize()
    }
}

private extension WidgetMuseumScope {
    var isSupportedForWidget: Bool {
        switch self {
        case .all:
            return true
        case .single(let museumID):
            return museumID.supportsWidgetContent
        }
    }
}
