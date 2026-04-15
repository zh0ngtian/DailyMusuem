import Foundation

struct WidgetSettingsReader {
    private enum Constants {
        static let manualRefreshStaleTimeout: TimeInterval = 90
    }

    private let defaults: UserDefaults

    init() {
        defaults = UserDefaults(suiteName: SettingsKeys.appGroupID) ?? .standard
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
        guard defaults.bool(forKey: SettingsKeys.widgetManualRefreshInProgress) else {
            return false
        }

        let startedAt = defaults.double(forKey: SettingsKeys.widgetManualRefreshStartedAt)
        guard startedAt > 0 else {
            clearManualRefreshState()
            return false
        }

        if Date().timeIntervalSince1970 - startedAt >= Constants.manualRefreshStaleTimeout {
            clearManualRefreshState()
            return false
        }

        return true
    }

    func categories(for museumID: MuseumID) -> [MuseumCategory] {
        museumID.feedCategories(withStoredValue: defaults.string(forKey: feedCategoryKey(for: museumID)))
    }

    func activeManualRefreshDeliveryState(now: Date = .now) async -> WidgetRefreshDeliveryTracker.State? {
        guard manualRefreshInProgress else {
            return nil
        }

        let nonce = manualRefreshNonceValue
        guard nonce > 0 else {
            return nil
        }

        return await WidgetRefreshDeliveryTracker.shared.activeState(expectedNonce: nonce, now: now)
    }

    func activeManualRefreshTargetRenderID(now: Date = .now) async -> String? {
        guard manualRefreshInProgress else {
            return nil
        }

        let nonce = manualRefreshNonceValue
        guard nonce > 0 else {
            return nil
        }

        return await WidgetRefreshDeliveryTracker.shared.activeTargetRenderID(
            expectedNonce: nonce,
            now: now
        )
    }

    func reusableManualRefreshTargetRenderID(now: Date = .now) async -> String? {
        let nonce = manualRefreshNonceValue
        guard nonce > 0 else {
            return nil
        }

        return await WidgetRefreshDeliveryTracker.shared.reusableTargetRenderID(
            expectedNonce: nonce,
            now: now
        )
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
        defaults.synchronize()
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
