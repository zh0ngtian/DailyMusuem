import SwiftUI

struct ArtworkDetailLoaderView: View {
    let reference: ArtworkReference

    @State private var artwork: Artwork?
    @State private var errorMessage: String?
    @State private var imageReloadToken = 0

    private let metAPI = MetMuseumAPI()
    private let japanSearchAPI = JapanSearchAPI()

    var body: some View {
        Group {
            if let artwork {
                ArtworkDetailView(
                    artwork: artwork,
                    imageReloadToken: imageReloadToken
                ) {
                    await refresh()
                }
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
                artwork = object.toArtwork()
            case .tnm:
                let item = try await japanSearchAPI.fetchItem(itemID: reference.objectID)
                artwork = item.toArtwork()
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
}
