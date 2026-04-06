import Foundation

struct WidgetArtworkService {
    let settings: WidgetSettingsReader
    private let metAPI = MetMuseumAPI()
    private let snapshotStore = WidgetArtworkSnapshotStore.shared

    func fetchEntry(date: Date) async throws -> WidgetArtworkEntry {
        let cycleKey = makeCycleKey(date: date)
        if let snapshot = await snapshotStore.load(cycleKey: cycleKey) {
            return WidgetArtworkEntry(
                date: date,
                museumName: snapshot.museumName,
                title: snapshot.title,
                subtitle: snapshot.subtitle,
                imageData: snapshot.imageData,
                appURL: snapshot.appURL
            )
        }

        let museum = pickMuseum()

        switch museum.id {
        case .met:
            let ids = try await metAPI.searchObjectIDs(hasImages: settings.preferHasImages, isOnView: false, query: "a")
            guard let id = ids.randomElement() else {
                throw URLError(.cannotParseResponse)
            }
            let object = try await metAPI.fetchObject(objectID: id)
            let artwork = object.toArtwork()

            let imageURL = artwork.primaryImageSmallURL ?? artwork.primaryImageURL
            let imageData = try await fetchImageData(url: imageURL)
            let reference = ArtworkReference(museumID: museum.id, objectID: artwork.objectID)

            let snapshot = WidgetArtworkSnapshotStore.Snapshot(
                cycleKey: cycleKey,
                museumName: museum.displayName,
                title: artwork.title,
                subtitle: artwork.objectDate,
                imageData: imageData,
                appURL: AppDeepLink.artworkURL(reference: reference)
            )
            await snapshotStore.store(snapshot)

            return WidgetArtworkEntry(
                date: date,
                museumName: snapshot.museumName,
                title: snapshot.title,
                subtitle: snapshot.subtitle,
                imageData: snapshot.imageData,
                appURL: snapshot.appURL
            )
        }
    }

    private func pickMuseum() -> Museum {
        switch settings.museumScope {
        case .all:
            return MuseumRepository.supportedMuseums.randomElement() ?? MuseumRepository.supportedMuseums[0]
        case .single(let id):
            return MuseumRepository.supportedMuseums.first(where: { $0.id == id }) ?? MuseumRepository.supportedMuseums[0]
        }
    }

    private func fetchImageData(url: URL?) async throws -> Data? {
        guard let url else { return nil }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return nil
        }
        return data
    }

    private func makeCycleKey(date: Date) -> String {
        let refreshBucket = Int(date.timeIntervalSince1970 / settings.refreshInterval.seconds)
        return [
            settings.museumScope.rawValue,
            settings.preferHasImages ? "images" : "all",
            String(settings.manualRefreshNonce),
            String(refreshBucket)
        ].joined(separator: "|")
    }
}
