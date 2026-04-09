import SwiftUI

struct ArtworkDetailLoaderView: View {
    let reference: ArtworkReference

    @State private var artwork: Artwork?
    @State private var errorMessage: String?

    private let metAPI = MetMuseumAPI()
    private let japanSearchAPI = JapanSearchAPI()

    var body: some View {
        Group {
            if let artwork {
                ArtworkDetailView(artwork: artwork)
            } else if let errorMessage {
                ContentUnavailableView(
                    "加载失败",
                    systemImage: "wifi.exclamationmark",
                    description: Text(errorMessage)
                )
            } else {
                ProgressView("正在打开展品...")
            }
        }
        .task(id: reference) {
            await loadArtwork()
        }
    }

    @MainActor
    private func loadArtwork() async {
        artwork = nil
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
            errorMessage = error.localizedDescription
        }
    }
}
