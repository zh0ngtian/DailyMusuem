import Foundation

enum TextPunctuationStyle: String, Hashable, Codable, Sendable {
    case western
    case chinese
}

struct ArtworkTranslationEntry: Equatable {
    let id: String
    let text: String
}

struct ArtworkShareContent: Equatable {
    let plainText: String
    let doubaoShortcutInputText: String
    let shareSheetSubject: String
    let linkMetadataTitle: String
    let officialURL: URL

    init?(artwork: Artwork) {
        guard let officialURL = artwork.objectURL else {
            return nil
        }

        self.officialURL = officialURL
        self.shareSheetSubject = artwork.title
        self.linkMetadataTitle = artwork.title
        self.plainText = "\(artwork.title)｜\(artwork.museumID.displayName)｜\(officialURL.absoluteString)"
        self.doubaoShortcutInputText = "介绍一下这个展品：\(officialURL.absoluteString)"
    }
}

struct Artwork: Identifiable, Hashable, Codable {
    let id: String
    let museumID: MuseumID
    let sourceKey: String?
    let objectID: String

    let title: String
    let artworkDescription: String?
    let artistDisplayName: String?
    let objectDate: String?
    let medium: String?
    let dimensions: String?
    let department: String?
    let culture: String?
    let country: String?
    let repository: String?

    let primaryImageURL: URL?
    let primaryImageSmallURL: URL?
    let objectURL: URL?

    init(
        id: String,
        museumID: MuseumID,
        sourceKey: String? = nil,
        objectID: String,
        title: String,
        artworkDescription: String?,
        artistDisplayName: String?,
        objectDate: String?,
        medium: String?,
        dimensions: String?,
        department: String?,
        culture: String?,
        country: String?,
        repository: String?,
        primaryImageURL: URL?,
        primaryImageSmallURL: URL?,
        objectURL: URL?
    ) {
        self.id = id
        self.museumID = museumID
        self.sourceKey = sourceKey
        self.objectID = objectID
        self.title = title
        self.artworkDescription = artworkDescription
        self.artistDisplayName = artistDisplayName
        self.objectDate = objectDate
        self.medium = medium
        self.dimensions = dimensions
        self.department = department
        self.culture = culture
        self.country = country
        self.repository = repository
        self.primaryImageURL = primaryImageURL
        self.primaryImageSmallURL = primaryImageSmallURL
        self.objectURL = objectURL
    }

    var subtitle: String? {
        let parts = [artistDisplayName, objectDate]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if parts.isEmpty { return nil }
        return parts.joined(separator: " · ")
    }

    func withArtworkDescription(_ description: String?) -> Artwork {
        Artwork(
            id: id,
            museumID: museumID,
            sourceKey: sourceKey,
            objectID: objectID,
            title: title,
            artworkDescription: description,
            artistDisplayName: artistDisplayName,
            objectDate: objectDate,
            medium: medium,
            dimensions: dimensions,
            department: department,
            culture: culture,
            country: country,
            repository: repository,
            primaryImageURL: primaryImageURL,
            primaryImageSmallURL: primaryImageSmallURL,
            objectURL: objectURL
        )
    }

    func withPrimaryImageURLs(
        primaryImageURL: URL?,
        primaryImageSmallURL: URL?
    ) -> Artwork {
        Artwork(
            id: id,
            museumID: museumID,
            sourceKey: sourceKey,
            objectID: objectID,
            title: title,
            artworkDescription: artworkDescription,
            artistDisplayName: artistDisplayName,
            objectDate: objectDate,
            medium: medium,
            dimensions: dimensions,
            department: department,
            culture: culture,
            country: country,
            repository: repository,
            primaryImageURL: primaryImageURL,
            primaryImageSmallURL: primaryImageSmallURL,
            objectURL: objectURL
        )
    }

    var normalizedDescriptionText: String? {
        guard let description = artworkDescription else {
            return nil
        }

        let cleaned = description
            .replacingOccurrences(of: "(?i)<br\\s*/?>", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "(?i)</p>", with: "\n\n", options: .regularExpression)
            .replacingOccurrences(of: "(?i)<p[^>]*>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .components(separatedBy: .newlines)
            .map(Self.cleanDescriptionLine)
            .map { $0.decodingCommonHTMLEntities(punctuationStyle: museumID.punctuationStyle) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
            .replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleaned.isEmpty else {
            return nil
        }

        return cleaned
    }

    var supportsTranslation: Bool {
        museumID.supportsTranslation && !translationEntries.isEmpty
    }

    var translationEntries: [ArtworkTranslationEntry] {
        [
            translationEntry(id: "title", value: title),
            translationEntry(id: "description", value: normalizedDescriptionText),
            translationEntry(id: "artistDisplayName", value: artistDisplayName),
            translationEntry(id: "objectDate", value: objectDate),
            translationEntry(id: "medium", value: medium),
            translationEntry(id: "dimensions", value: dimensions),
            translationEntry(id: "department", value: department),
            translationEntry(id: "culture", value: culture),
            translationEntry(id: "country", value: country)
        ]
        .compactMap { $0 }
    }

    func applyingTranslations(_ translationsByID: [String: String]) -> Artwork {
        Artwork(
            id: id,
            museumID: museumID,
            sourceKey: sourceKey,
            objectID: objectID,
            title: translationsByID["title"] ?? title,
            artworkDescription: translationsByID["description"] ?? normalizedDescriptionText,
            artistDisplayName: translationsByID["artistDisplayName"] ?? artistDisplayName,
            objectDate: translationsByID["objectDate"] ?? objectDate,
            medium: translationsByID["medium"] ?? medium,
            dimensions: translationsByID["dimensions"] ?? dimensions,
            department: translationsByID["department"] ?? department,
            culture: translationsByID["culture"] ?? culture,
            country: translationsByID["country"] ?? country,
            repository: repository,
            primaryImageURL: primaryImageURL,
            primaryImageSmallURL: primaryImageSmallURL,
            objectURL: objectURL
        )
    }

    private static func cleanDescriptionLine(_ line: String) -> String {
        var cleaned = line.trimmingCharacters(in: .whitespacesAndNewlines)

        cleaned = cleaned.replacingOccurrences(
            of: #"^\[\s*"?\s*"#,
            with: "",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: #"\s*"?\s*\]$"#,
            with: "",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: #"^[\[\]",\s]+$"#,
            with: "",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: #"^->\s*"#,
            with: "",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: #"^>+\s*"#,
            with: "",
            options: .regularExpression
        )

        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func translationEntry(id: String, value: String?) -> ArtworkTranslationEntry? {
        let trimmedValue = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedValue.isEmpty else {
            return nil
        }
        return ArtworkTranslationEntry(id: id, text: trimmedValue)
    }
}

extension String {
    func decodingCommonHTMLEntities(punctuationStyle: TextPunctuationStyle = .western) -> String {
        let namedEntities: [(String, String)] = [
            ("&nbsp;", " "),
            ("&amp;", "&"),
            ("&lt;", "<"),
            ("&gt;", ">"),
            ("&quot;", punctuationStyle == .chinese ? "\"" : "\""),
            ("&apos;", punctuationStyle == .chinese ? "'" : "'"),
            ("&#39;", punctuationStyle == .chinese ? "'" : "'"),
            ("&#x27;", punctuationStyle == .chinese ? "'" : "'"),
            ("&ldquo;", punctuationStyle == .chinese ? "“" : "\""),
            ("&rdquo;", punctuationStyle == .chinese ? "”" : "\""),
            ("&lsquo;", punctuationStyle == .chinese ? "‘" : "'"),
            ("&rsquo;", punctuationStyle == .chinese ? "’" : "'"),
            ("&ndash;", punctuationStyle == .chinese ? "——" : "–"),
            ("&mdash;", punctuationStyle == .chinese ? "——" : "—"),
            ("&hellip;", punctuationStyle == .chinese ? "……" : "…"),
            ("&middot;", "·")
        ]

        let replacedNamedEntities = namedEntities.reduce(self) { partialResult, entity in
            partialResult.replacingOccurrences(of: entity.0, with: entity.1)
        }

        guard let regex = try? NSRegularExpression(pattern: #"&#(x?[0-9A-Fa-f]+);"#) else {
            return replacedNamedEntities
        }

        let fullRange = NSRange(replacedNamedEntities.startIndex..., in: replacedNamedEntities)
        let matches = regex.matches(in: replacedNamedEntities, options: [], range: fullRange)

        guard !matches.isEmpty else {
            return replacedNamedEntities
        }

        var decoded = replacedNamedEntities
        for match in matches.reversed() {
            guard let entityRange = Range(match.range(at: 0), in: decoded),
                  let valueRange = Range(match.range(at: 1), in: decoded) else {
                continue
            }

            let rawValue = String(decoded[valueRange])
            let scalarValue: UInt32?
            if rawValue.lowercased().hasPrefix("x") {
                scalarValue = UInt32(rawValue.dropFirst(), radix: 16)
            } else {
                scalarValue = UInt32(rawValue, radix: 10)
            }

            guard let scalarValue,
                  let scalar = UnicodeScalar(scalarValue) else {
                continue
            }

            decoded.replaceSubrange(entityRange, with: String(scalar))
        }

        guard punctuationStyle == .chinese else {
            return decoded
        }

        return decoded.applyingChinesePunctuationConventions()
    }

    private func applyingChinesePunctuationConventions() -> String {
        var result = self
        result = result.replacingOccurrences(of: "…+", with: "……", options: .regularExpression)
        result = result.replacingOccurrences(of: "[—–]+", with: "——", options: .regularExpression)
        result = result.replacingOccurrences(of: "\"", withPairedQuotesOpen: "“", close: "”")
        result = result.replacingOccurrences(of: "'", withPairedQuotesOpen: "‘", close: "’")
        return result
    }

    private func replacingOccurrences(
        of target: Character,
        withPairedQuotesOpen openQuote: Character,
        close closeQuote: Character
    ) -> String {
        var shouldUseOpenQuote = true
        var transformed = String()
        transformed.reserveCapacity(count)

        for character in self {
            if character == target {
                transformed.append(shouldUseOpenQuote ? openQuote : closeQuote)
                shouldUseOpenQuote.toggle()
            } else {
                transformed.append(character)
            }
        }

        return transformed
    }
}
