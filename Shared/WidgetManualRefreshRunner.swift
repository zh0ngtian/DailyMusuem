import Foundation

struct WidgetManualRefreshRunner {
    let logSource: String

    func perform(
        familyKey: String = "",
        instanceToken: String? = nil,
        scopeRawValue: String? = nil
    ) async {
        if !familyKey.isEmpty {
            await RequestLogger.shared.logEvent(
                source: logSource,
                summary: "旧的按尺寸调试入口已废弃，忽略 familyKey=\(familyKey)，改为刷新全部已登记的小组件实例"
            )
        }

        let normalizedInstanceToken = instanceToken?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedScopeRawValue = scopeRawValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let store = WidgetArtworkSnapshotStore.shared

        if let normalizedInstanceToken, !normalizedInstanceToken.isEmpty {
            let scope = await resolvedScope(
                instanceToken: normalizedInstanceToken,
                explicitScopeRawValue: normalizedScopeRawValue,
                store: store
            )
            guard let scope else {
                await RequestLogger.shared.logEvent(
                    source: logSource,
                    summary: "未找到实例 \(normalizedInstanceToken) 对应的小组件范围，忽略本次调试刷新"
                )
                return
            }

            await WidgetRefreshCoordinator.shared.refresh(
                instanceToken: normalizedInstanceToken,
                scope: scope,
                logSource: logSource
            )
            return
        }

        if let normalizedScopeRawValue, !normalizedScopeRawValue.isEmpty {
            guard let scope = WidgetMuseumScope(rawValue: normalizedScopeRawValue) else {
                await RequestLogger.shared.logEvent(
                    source: logSource,
                    summary: "无法识别 scopeRawValue=\(normalizedScopeRawValue)，忽略本次调试刷新"
                )
                return
            }

            let knownInstances = await store.knownInstances()
            let matchedInstances = knownInstances.filter { $0.scopeRawValue == scope.rawValue }
            guard !matchedInstances.isEmpty else {
                await RequestLogger.shared.logEvent(
                    source: logSource,
                    summary: "当前没有登记 scope=\(scope.rawValue) 的小组件实例"
                )
                return
            }

            for instance in matchedInstances {
                await WidgetRefreshCoordinator.shared.refresh(
                    instanceToken: instance.instanceToken,
                    scope: scope,
                    logSource: logSource
                )
            }
            return
        }

        await WidgetRefreshCoordinator.shared.refreshAllKnownInstances(logSource: logSource)
    }

    private func resolvedScope(
        instanceToken: String,
        explicitScopeRawValue: String?,
        store: WidgetArtworkSnapshotStore
    ) async -> WidgetMuseumScope? {
        if let explicitScopeRawValue,
           !explicitScopeRawValue.isEmpty,
           let explicitScope = WidgetMuseumScope(rawValue: explicitScopeRawValue) {
            return explicitScope
        }

        guard let state = await store.state(for: instanceToken) else {
            return nil
        }
        return WidgetMuseumScope(rawValue: state.scopeRawValue)
    }
}
