import SwiftUI

struct ArtworkDetailLoaderView: View {
    let reference: ArtworkReference

    @ObservedObject private var favorites = FavoritesStore.shared
    @State private var artwork: Artwork?
    @State private var errorMessage: String?
    @State private var imageReloadToken = 0

    private let metAPI = MetMuseumAPI()
    private let japanSearchAPI = JapanSearchAPI()
    private let nationalMuseumChinaAPI = NationalMuseumChinaAPI()
    private let shanghaiMuseumAPI = ShanghaiMuseumAPI()

    var body: some View {
        Group {
            if let artwork {
                ArtworkDetailView(
                    artwork: artwork,
                    placeholderAspectRatio: detailPlaceholderAspectRatio,
                    imageReloadToken: imageReloadToken,
                    isFavorite: isFavorite,
                    onFavoriteButtonTap: {
                        toggleFavorite()
                    },
                    onRefresh: {
                        await refresh()
                    }
                )
            } else if let errorMessage {
                ScrollView {
                    ContentUnavailableView(
                        "加载失败",
                        systemImage: "wifi.exclamationmark",
                        description: Text(errorMessage)
                    )
                    .frame(maxWidth: .infinity, minHeight: 320)
                }
                .refreshable {
                    await refresh()
                }
            } else {
                ScrollView {
                    ProgressView("正在打开展品...")
                        .frame(maxWidth: .infinity, minHeight: 320)
                }
                .refreshable {
                    await refresh()
                }
            }
        }
        .task(id: reference) {
            await loadArtwork()
        }
    }

    @MainActor
    private func loadArtwork(showLoadingState: Bool = true) async {
        if showLoadingState {
            artwork = nil
        }
        errorMessage = nil

        do {
            switch reference.museumID {
            case .met:
                guard let objectID = Int(reference.objectID) else {
                    throw URLError(.badURL)
                }
                let object = try await metAPI.fetchObject(objectID: objectID)
                var loadedArtwork = object.toArtwork()
                if loadedArtwork.artworkDescription == nil {
                    var webDescription = await metAPI.fetchObjectWebDescription(
                        objectID: objectID,
                        objectURL: loadedArtwork.objectURL
                    )
                    if webDescription == nil, let objectURL = loadedArtwork.objectURL {
                        await RequestLogger.shared.logEvent(
                            source: "Met 官网",
                            summary: "URLSession 未拿到官网概述，尝试浏览器渲染兜底，objectID=\(objectID)"
                        )
                        webDescription = await MetMuseumWebDescriptionBrowserFetcher.shared.fetchDescription(from: objectURL)
                    }
                    loadedArtwork = loadedArtwork.withArtworkDescription(webDescription)
                }
                artwork = loadedArtwork
            case .tnm, .nnm:
                let item = try await japanSearchAPI.fetchItem(
                    museumID: reference.museumID,
                    itemID: reference.objectID
                )
                artwork = item.toArtwork(museumID: reference.museumID)
            case .nmc:
                guard let exhibitID = Int(reference.objectID) else {
                    throw URLError(.badURL)
                }
                artwork = try await nationalMuseumChinaAPI.fetchExhibit(exhibitID: exhibitID)
            case .shm:
                artwork = try await shanghaiMuseumAPI.fetchArtwork(objectCode: reference.objectID)
            }
        } catch {
            if artwork == nil {
                errorMessage = error.localizedDescription
            }
        }
    }

    @MainActor
    private func refresh() async {
        if let url = artwork?.primaryImageURL ?? artwork?.primaryImageSmallURL {
            await ImageMemoryCache.shared.removeImage(for: url)
        }
        if let url = artwork?.primaryImageSmallURL {
            await ImageMemoryCache.shared.removeImage(for: url)
        }
        imageReloadToken += 1
        await loadArtwork(showLoadingState: false)
    }

    private var detailPlaceholderAspectRatio: CGFloat {
        guard let imageAspectRatio = reference.imageAspectRatio,
              imageAspectRatio.isFinite,
              imageAspectRatio > 0 else {
            return 0.8
        }
        return CGFloat(imageAspectRatio)
    }

    private var isFavorite: Bool {
        guard let artwork else {
            return false
        }
        return favorites.isFavorite(museumID: artwork.museumID, objectID: artwork.objectID)
    }

    private func toggleFavorite() {
        guard let artwork else {
            return
        }

        favorites.toggleFavorite(
            artwork: artwork,
            imageAspectRatio: reference.imageAspectRatio
        )
    }
}
