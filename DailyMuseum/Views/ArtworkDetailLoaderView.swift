import SwiftUI

struct ArtworkDetailLoaderView: View {
    let reference: ArtworkReference

    @StateObject private var favorites = FavoritesStore.shared
    @State private var artwork: Artwork?
    @State private var translatedArtwork: Artwork?
    @State private var showsTranslatedArtwork = false
    @State private var isTranslating = false
    @State private var errorMessage: String?
    @State private var translationAlertMessage: String?
    @State private var imageReloadToken = 0

    private let metAPI = MetMuseumAPI()
    private let japanSearchAPI = JapanSearchAPI()
    private let nationalMuseumChinaAPI = NationalMuseumChinaAPI()
    private let shanghaiMuseumAPI = ShanghaiMuseumAPI()
    private let tencentTranslationClient = TencentTranslationClient()
    private let miniMaxTranslationClient = MiniMaxTranslationClient()

    var body: some View {
        Group {
            if let displayedArtwork {
                ArtworkDetailView(
                    artwork: displayedArtwork,
                    placeholderAspectRatio: detailPlaceholderAspectRatio,
                    imageReloadToken: imageReloadToken,
                    translationToolbarState: artwork?.supportsTranslation == true ? translationToolbarState : nil,
                    isFavorite: isFavorite
                ) {
                    await handleTranslationButtonTap()
                } onFavoriteButtonTap: {
                    toggleFavorite()
                } onRefresh: {
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
        .alert("翻译提示", isPresented: Binding(
            get: { translationAlertMessage != nil },
            set: { if !$0 { translationAlertMessage = nil } }
        )) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(translationAlertMessage ?? "")
        }
    }

    @MainActor
    private func loadArtwork(showLoadingState: Bool = true) async {
        if showLoadingState {
            artwork = nil
        }
        translatedArtwork = nil
        showsTranslatedArtwork = false
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
                    let webDescription = await metAPI.fetchObjectWebDescription(
                        objectID: objectID,
                        objectURL: loadedArtwork.objectURL
                    )
                    loadedArtwork = loadedArtwork.withArtworkDescription(webDescription)
                }
                artwork = loadedArtwork
            case .tnm:
                let item = try await japanSearchAPI.fetchItem(itemID: reference.objectID)
                artwork = item.toArtwork()
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

    @MainActor
    private func handleTranslationButtonTap() async {
        guard !isTranslating else {
            return
        }

        if translatedArtwork != nil {
            showsTranslatedArtwork.toggle()
            return
        }

        guard let artwork else {
            return
        }

        isTranslating = true
        defer { isTranslating = false }

        do {
            translatedArtwork = try await translate(artwork: artwork)
            showsTranslatedArtwork = true
        } catch {
            translationAlertMessage = error.localizedDescription
        }
    }

    private func translate(artwork: Artwork) async throws -> Artwork {
        switch SettingsStore.shared.translationEngine() {
        case .tencent:
            guard let credentials = SettingsStore.shared.tencentTranslationCredentials() else {
                throw TranslationSelectionError.missingTencentCredentials
            }
            return try await tencentTranslationClient.translate(artwork: artwork, credentials: credentials)
        case .miniMax:
            guard let credentials = SettingsStore.shared.miniMaxTranslationCredentials() else {
                throw TranslationSelectionError.missingMiniMaxCredentials
            }
            return try await miniMaxTranslationClient.translate(artwork: artwork, credentials: credentials)
        }
    }

    private var displayedArtwork: Artwork? {
        if showsTranslatedArtwork, let translatedArtwork {
            return translatedArtwork
        }

        return artwork
    }

    private var translationToolbarState: TranslationToolbarState {
        if isTranslating {
            return .translating
        }
        if translatedArtwork != nil {
            return showsTranslatedArtwork ? .translated : .original(hasCachedTranslation: true)
        }
        return .original(hasCachedTranslation: false)
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

private enum TranslationSelectionError: LocalizedError {
    case missingTencentCredentials
    case missingMiniMaxCredentials

    var errorDescription: String? {
        switch self {
        case .missingTencentCredentials:
            return "请先在设置页填写腾讯云翻译的 SecretId 和 SecretKey。"
        case .missingMiniMaxCredentials:
            return "请先在设置页填写 MiniMax API Key。"
        }
    }
}
