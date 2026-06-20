import Foundation

struct MuseumIdentifier: RawRepresentable, Hashable, Codable, Sendable, Identifiable {
    let rawValue: String

    init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    init?(rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        self.rawValue = trimmed
    }

    var id: String { rawValue }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard let value = MuseumIdentifier(rawValue: rawValue) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Museum identifier cannot be empty"
            )
        }
        self = value
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

typealias MuseumID = MuseumIdentifier

struct MuseumMetadataSnapshot: Hashable, Sendable {
    let dataVersion: String
    let museums: [MuseumMetadata]
}

struct MuseumMetadata: Identifiable, Hashable, Codable, Sendable {
    let id: MuseumIdentifier
    let displayName: String
    let subtitle: String
    let country: String
    let city: String
    let address: String?
    let textPunctuationStyle: TextPunctuationStyle
    let icon: MuseumIconMetadata
    let sortOrder: Int
    let capabilities: MuseumCapabilities
    let defaultSourceKey: String
    let sources: [MuseumSourceMetadata]
    let categories: [MuseumCategoryMetadata]
    let waterfallImageFetchPolicy: WaterfallImageFetchPolicy

    enum CodingKeys: String, CodingKey {
        case id = "museumID"
        case displayName
        case subtitle
        case country
        case city
        case address
        case textPunctuationStyle
        case icon
        case sortOrder
        case capabilities
        case defaultSourceKey
        case sources
        case categories
        case waterfallImageFetchPolicy
    }

    func toMuseum() -> Museum {
        Museum(
            id: id,
            displayName: displayName,
            country: country,
            city: city,
            subtitle: subtitle,
            iconURL: icon.url,
            iconAssetName: icon.assetName,
            iconBackgroundColor: icon.backgroundColor
        )
    }
}

struct MuseumIconMetadata: Hashable, Codable, Sendable {
    let url: URL?
    let assetName: String?
    let backgroundColor: String?
}

struct MuseumCapabilities: Hashable, Codable, Sendable {
    let supportsWidgetContent: Bool
    let supportsTranslation: Bool
    let supportsFavorites: Bool
}

struct MuseumSourceMetadata: Identifiable, Hashable, Codable, Sendable {
    let sourceKey: String
    let displayName: String
    let isDefault: Bool
    let translationSourceLanguage: String?
    let preferredImageURLOrder: [ArtworkImageURLRole]
    let imageRequestHeaders: [String: String]

    var id: String { sourceKey }

    init(
        sourceKey: String,
        displayName: String,
        isDefault: Bool,
        translationSourceLanguage: String?,
        preferredImageURLOrder: [ArtworkImageURLRole],
        imageRequestHeaders: [String: String]
    ) {
        self.sourceKey = sourceKey
        self.displayName = displayName
        self.isDefault = isDefault
        self.translationSourceLanguage = translationSourceLanguage
        self.preferredImageURLOrder = preferredImageURLOrder
        self.imageRequestHeaders = imageRequestHeaders
    }

    enum CodingKeys: String, CodingKey {
        case sourceKey
        case displayName
        case isDefault
        case translationSourceLanguage
        case preferredImageURLOrder
        case imageRequestHeaders
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sourceKey = try container.decode(String.self, forKey: .sourceKey)
        displayName = try container.decode(String.self, forKey: .displayName)
        isDefault = try container.decode(Bool.self, forKey: .isDefault)
        translationSourceLanguage = try container.decodeIfPresent(String.self, forKey: .translationSourceLanguage)
        preferredImageURLOrder = try container.decodeIfPresent([ArtworkImageURLRole].self, forKey: .preferredImageURLOrder) ?? []
        imageRequestHeaders = try container.decodeIfPresent([String: String].self, forKey: .imageRequestHeaders) ?? [:]
    }
}

enum ArtworkImageURLRole: String, Codable, Hashable, Sendable {
    case primary
    case thumbnail
}

struct MuseumCategoryMetadata: Identifiable, Hashable, Codable, Sendable {
    let sourceKey: String
    let categoryID: String
    let displayName: String
    let sortOrder: Int

    var id: String { categoryID }

    func toMuseumCategory(museumID: MuseumIdentifier) -> MuseumCategory {
        MuseumCategory(
            museumID: museumID,
            id: categoryID,
            displayName: displayName
        )
    }
}

struct WaterfallImageFetchPolicy: Hashable, Codable, Sendable {
    let qps: Double?

    var isRateLimited: Bool {
        guard let qps else { return false }
        return qps > 0
    }
}

struct MuseumMetadataData: Hashable, Codable, Sendable {
    let museums: [MuseumMetadata]
}
