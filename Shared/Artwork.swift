import Foundation

struct Artwork: Identifiable, Hashable, Codable {
    let id: String
    let museumID: MuseumID
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

    var normalizedDescriptionText: String? {
        guard let description = artworkDescription else {
            return nil
        }

        let cleaned = description
            .replacingOccurrences(of: "(?i)<br\\s*/?>", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "(?i)</p>", with: "\n\n", options: .regularExpression)
            .replacingOccurrences(of: "(?i)<p[^>]*>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&#x27;", with: "'")
            .components(separatedBy: .newlines)
            .map(Self.cleanDescriptionLine)
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
        !translationCandidates.isEmpty
    }

    private var translationCandidates: [String] {
        [
            title,
            normalizedDescriptionText,
            medium,
            dimensions,
            department,
            culture,
            country,
            repository
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
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
}
