import Foundation

struct Museum: Identifiable, Hashable, Codable {
    let id: MuseumID
    let displayName: String
    let country: String
    let city: String
    let subtitle: String
    let iconURL: URL?
    let iconAssetName: String?
    let iconBackgroundColor: String?

    init(
        id: MuseumID,
        displayName: String,
        country: String,
        city: String,
        subtitle: String,
        iconURL: URL? = nil,
        iconAssetName: String? = nil,
        iconBackgroundColor: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.country = country
        self.city = city
        self.subtitle = subtitle
        self.iconURL = iconURL
        self.iconAssetName = iconAssetName
        self.iconBackgroundColor = iconBackgroundColor
    }
}

struct MuseumCountrySection: Identifiable, Hashable {
    let country: String
    let museums: [Museum]

    var id: String { country }
}

struct MuseumCategory: Identifiable, Hashable {
    let museumID: MuseumID
    let id: String
    let displayName: String

    var isAll: Bool {
        id == "all"
    }
}

extension MuseumIdentifier {
    var displayName: String {
        if let metadata = MuseumMetadataStore.cachedMuseum(id: self) {
            return metadata.displayName
        }

        return rawValue
    }

    var country: String {
        if let metadata = MuseumMetadataStore.cachedMuseum(id: self) {
            return metadata.country
        }

        return ""
    }

    var city: String {
        if let metadata = MuseumMetadataStore.cachedMuseum(id: self) {
            return metadata.city
        }

        return ""
    }

    var subtitle: String {
        city
    }

    var homepageLogoAssetName: String {
        MuseumMetadataStore.cachedMuseum(id: self)?.icon.assetName ?? "MuseumHomepageLogoPlaceholder"
    }

    var copyrightNotice: String {
        "©\(displayName) 版权所有"
    }

    var supportsTranslation: Bool {
        if let metadata = MuseumMetadataStore.cachedMuseum(id: self) {
            return metadata.capabilities.supportsTranslation
        }

        return false
    }

    var supportsWidgetContent: Bool {
        if let metadata = MuseumMetadataStore.cachedMuseum(id: self) {
            return metadata.capabilities.supportsWidgetContent
        }

        return false
    }

    var punctuationStyle: TextPunctuationStyle {
        MuseumMetadataStore.cachedMuseum(id: self)?.textPunctuationStyle ?? .western
    }

    var defaultSourceKey: String? {
        MuseumMetadataStore.cachedMuseum(id: self)?.defaultSourceKey
    }

    var sources: [MuseumSourceMetadata] {
        MuseumMetadataStore.cachedMuseum(id: self)?.sources ?? []
    }

    var availableFeedCategories: [MuseumCategory] {
        availableFeedCategories(sourceKey: nil)
    }

    func availableFeedCategories(sourceKey: String?) -> [MuseumCategory] {
        metadataFeedCategories(sourceKey: sourceKey) ?? [.all(museumID: self)]
    }

    var defaultFeedCategory: MuseumCategory {
        availableFeedCategories.first ?? .all(museumID: self)
    }

    var selectableFeedCategories: [MuseumCategory] {
        selectableFeedCategories(sourceKey: nil)
    }

    func selectableFeedCategories(sourceKey: String?) -> [MuseumCategory] {
        availableFeedCategories(sourceKey: sourceKey).filter { !$0.isAll }
    }

    var defaultFeedCategories: [MuseumCategory] {
        selectableFeedCategories
    }

    func defaultFeedCategories(sourceKey: String?) -> [MuseumCategory] {
        selectableFeedCategories(sourceKey: sourceKey)
    }

    func feedCategory(withID id: String?, sourceKey: String? = nil) -> MuseumCategory? {
        guard let id else { return availableFeedCategories(sourceKey: sourceKey).first }
        return availableFeedCategories(sourceKey: sourceKey).first(where: { $0.id == id })
            ?? availableFeedCategories(sourceKey: sourceKey).first
    }

    func feedCategories(withStoredValue rawValue: String?, sourceKey: String? = nil) -> [MuseumCategory] {
        let selectable = selectableFeedCategories(sourceKey: sourceKey)
        guard !selectable.isEmpty else { return [] }
        guard let rawValue, !rawValue.isEmpty else { return selectable }

        let storedIDs = rawValue
            .split(separator: ",")
            .map { String($0) }

        if storedIDs.isEmpty || storedIDs.contains("all") {
            return selectable
        }

        let storedIDSet = Set(storedIDs)
        let selected = selectable.filter { storedIDSet.contains($0.id) }
        return selected.isEmpty ? selectable : selected
    }

    func normalizedFeedCategories(_ categories: [MuseumCategory], sourceKey: String? = nil) -> [MuseumCategory] {
        let selectable = selectableFeedCategories(sourceKey: sourceKey)
        guard !selectable.isEmpty else { return [] }

        let selectedIDSet = Set(
            categories
                .filter { $0.museumID == self && !$0.isAll }
                .map(\.id)
        )

        let normalized = selectable.filter { selectedIDSet.contains($0.id) }
        return normalized.isEmpty ? selectable : normalized
    }

    func areAllFeedCategoriesSelected(_ categories: [MuseumCategory], sourceKey: String? = nil) -> Bool {
        normalizedFeedCategories(categories, sourceKey: sourceKey).count == selectableFeedCategories(sourceKey: sourceKey).count
    }

    func feedCategoryStorageValue(for categories: [MuseumCategory], sourceKey: String? = nil) -> String {
        let normalized = normalizedFeedCategories(categories, sourceKey: sourceKey)
        if normalized.count == selectableFeedCategories(sourceKey: sourceKey).count {
            return "all"
        }
        return normalized.map(\.id).joined(separator: ",")
    }

    private func metadataFeedCategories(sourceKey: String? = nil) -> [MuseumCategory]? {
        guard let metadata = MuseumMetadataStore.cachedMuseum(id: self) else {
            return nil
        }
        let effectiveSourceKey = sourceKey ?? metadata.defaultSourceKey
        let categories = metadata.categories
            .filter { $0.sourceKey == effectiveSourceKey }
            .sorted { lhs, rhs in
                if lhs.sortOrder != rhs.sortOrder {
                    return lhs.sortOrder < rhs.sortOrder
                }
                return lhs.categoryID < rhs.categoryID
            }
            .map { $0.toMuseumCategory(museumID: self) }
        guard !categories.isEmpty else {
            return nil
        }
        return [.all(museumID: self)] + categories
    }
}

enum MuseumRepository {
    static var supportedMuseums: [Museum] {
        let metadataMuseums = MuseumMetadataStore.cachedSnapshot()?.museums
            .sorted { lhs, rhs in
                if lhs.sortOrder != rhs.sortOrder {
                    return lhs.sortOrder < rhs.sortOrder
                }
                return lhs.id.rawValue < rhs.id.rawValue
            }
            .map { $0.toMuseum() } ?? []
        return metadataMuseums
    }

    static var widgetSupportedMuseums: [Museum] {
        supportedMuseums.filter { $0.id.supportsWidgetContent }
    }

    static var homepageCountrySections: [MuseumCountrySection] {
        homepageCountryOrder.compactMap { country in
            let museums = supportedMuseums.filter { $0.country == country }
            guard !museums.isEmpty else { return nil }
            return MuseumCountrySection(country: country, museums: museums)
        }
    }

    static var homepageMuseumIDs: [MuseumID] {
        homepageCountrySections.flatMap { section in
            section.museums.map(\.id)
        }
    }

    static func museum(for id: MuseumID) -> Museum {
        supportedMuseums.first(where: { $0.id == id }) ?? Museum(id: id, displayName: id.displayName, country: id.country, city: id.city, subtitle: id.subtitle)
    }

    static func museums(inPreferredOrder ids: [MuseumID]) -> [Museum] {
        var seen: Set<MuseumID> = []
        var ordered: [Museum] = []

        for id in ids where seen.insert(id).inserted {
            ordered.append(museum(for: id))
        }

        for museum in supportedMuseums where seen.insert(museum.id).inserted {
            ordered.append(museum)
        }

        return ordered
    }

    static func widgetMuseums(inPreferredOrder ids: [MuseumID]) -> [Museum] {
        var seen: Set<MuseumID> = []
        var ordered: [Museum] = []

        for id in ids where id.supportsWidgetContent && seen.insert(id).inserted {
            ordered.append(museum(for: id))
        }

        for museum in widgetSupportedMuseums where seen.insert(museum.id).inserted {
            ordered.append(museum)
        }

        return ordered
    }

    private static var homepageCountryOrder: [String] {
        var countries: [String] = []
        var seen: Set<String> = []

        for museum in supportedMuseums where seen.insert(museum.country).inserted {
            countries.append(museum.country)
        }

        return countries
    }
}

private extension MuseumCategory {
    static func all(museumID: MuseumID) -> MuseumCategory {
        MuseumCategory(
            museumID: museumID,
            id: "all",
            displayName: "全部"
        )
    }
}
