import Foundation

struct JapanSearchSearchResponse: Decodable {
    let list: [JapanSearchItem]
    let hit: Int
    let from: Int?
}

struct JapanSearchItem: Decodable {
    struct Common: Decodable {
        let id: String
        let title: String
        let titleEn: String?
        let titleYomi: String?
        let linkURL: URL?
        let thumbnailURLs: [URL]
        let contentURLs: [URL]
        let contributor: [String]
        let temporal: [String]
        let description: String?
        let provider: String?
        let database: String?

        enum CodingKeys: String, CodingKey {
            case id
            case title
            case titleEn
            case titleYomi
            case linkURL = "linkUrl"
            case thumbnailURLs = "thumbnailUrl"
            case contentURLs = "contentsUrl"
            case contributor
            case temporal
            case description
            case provider
            case database
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            title = try container.decode(String.self, forKey: .title)
            titleEn = try container.decodeIfPresent(String.self, forKey: .titleEn)
            titleYomi = try container.decodeIfPresent(String.self, forKey: .titleYomi)
            linkURL = try container.decodeIfPresent(URL.self, forKey: .linkURL)
            thumbnailURLs = try container.decodeIfPresent([URL].self, forKey: .thumbnailURLs) ?? []
            contentURLs = try container.decodeIfPresent([URL].self, forKey: .contentURLs) ?? []
            contributor = try container.decodeIfPresent([String].self, forKey: .contributor) ?? []
            temporal = try container.decodeIfPresent([String].self, forKey: .temporal) ?? []
            description = try container.decodeIfPresent(String.self, forKey: .description)
            provider = try container.decodeIfPresent(String.self, forKey: .provider)
            database = try container.decodeIfPresent(String.self, forKey: .database)
        }
    }

    let id: String
    let common: Common
    let fields: [String: String]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        id = try container.decode(String.self, forKey: DynamicCodingKey("id"))
        common = try container.decode(Common.self, forKey: DynamicCodingKey("common"))

        var extracted: [String: String] = [:]
        for key in container.allKeys where key.stringValue.hasPrefix("cobas-") {
            if let value = try? container.decode(String.self, forKey: key) {
                extracted[key.stringValue] = value
            }
        }
        fields = extracted
    }

    var sortValue: Int {
        if let explicit = fields["cobas-22-s"].flatMap(Int.init) {
            return explicit
        }
        if let fallback = id.split(separator: "-").last.flatMap({ Int($0) }) {
            return fallback
        }
        return .max
    }

    func toArtwork() -> Artwork {
        let imageURL = common.contentURLs.first ?? common.thumbnailURLs.first
        let thumbnailURL = common.thumbnailURLs.first ?? common.contentURLs.first
        let contributors = common.contributor.filter { !$0.contains("Tokyo National Museum") }
        let artist = contributors.first(where: { $0 != "東京国立博物館" })
        let repository = fields["cobas-16-s"] ?? common.contributor.first
        let date = fields["cobas-11-s"] ?? common.temporal.first

        return Artwork(
            id: "tnm-\(id)",
            museumID: .tnm,
            objectID: id,
            title: common.title,
            artistDisplayName: artist,
            objectDate: date,
            medium: fields["cobas-12-s"],
            dimensions: fields["cobas-13-s"],
            department: fields["cobas-4-s"],
            culture: nil,
            country: "日本",
            repository: repository,
            primaryImageURL: imageURL,
            primaryImageSmallURL: thumbnailURL,
            objectURL: common.linkURL
        )
    }
}

private struct DynamicCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init(_ stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(stringValue: String) {
        self.init(stringValue)
    }

    init?(intValue: Int) {
        self.stringValue = "\(intValue)"
        self.intValue = intValue
    }
}
