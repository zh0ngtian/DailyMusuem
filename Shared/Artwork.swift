import Foundation

struct Artwork: Identifiable, Hashable, Codable {
    let id: String
    let museumID: MuseumID
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
}
