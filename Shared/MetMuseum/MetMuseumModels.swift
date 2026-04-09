import Foundation

struct MetMuseumSearchResponse: Decodable {
    let total: Int
    let objectIDs: [Int]?
}

struct MetMuseumObject: Decodable {
    let objectID: Int
    let title: String
    let artistDisplayName: String?
    let objectDate: String?
    let medium: String?
    let dimensions: String?
    let department: String?
    let culture: String?
    let country: String?
    let repository: String?
    let primaryImage: String?
    let primaryImageSmall: String?
    let objectURL: String?
}

extension MetMuseumObject {
    func toArtwork() -> Artwork {
        Artwork(
            id: "met-\(objectID)",
            museumID: .met,
            objectID: "\(objectID)",
            title: title,
            artistDisplayName: artistDisplayName,
            objectDate: objectDate,
            medium: medium,
            dimensions: dimensions,
            department: department,
            culture: culture,
            country: country,
            repository: repository,
            primaryImageURL: URL(string: primaryImage ?? ""),
            primaryImageSmallURL: URL(string: primaryImageSmall ?? ""),
            objectURL: URL(string: objectURL ?? "")
        )
    }
}
