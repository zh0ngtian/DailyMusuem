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
}
