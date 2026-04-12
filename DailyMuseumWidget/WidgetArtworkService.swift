import Foundation

struct WidgetArtworkService {
    private enum Constants {
        static let imageDownloadMaxAttempts = 3
        static let imageRetryBaseDelayNanoseconds: UInt64 = 400_000_000
    }

    let settings: WidgetSettingsReader
    private let metAPI = MetMuseumAPI()
    private let japanSearchAPI = JapanSearchAPI()
    private let nationalMuseumChinaAPI = NationalMuseumChinaAPI()
    private let snapshotStore = WidgetArtworkSnapshotStore.shared

    func makeLoadingEntry(date: Date) async -> WidgetArtworkEntry {
        if let snapshot = await snapshotStore.loadLatest() {
            return WidgetArtworkEntry(
                date: date,
                museumName: snapshot.museumName,
                title: snapshot.title,
                subtitle: snapshot.subtitle,
                imageData: snapshot.imageData,
                appURL: snapshot.appURL,
                isRefreshing: true
            )
        }

        return WidgetArtworkEntry(
            date: date,
            museumName: "DailyMuseum",
            title: "刷新中",
            subtitle: "正在拉取最新展品",
            imageData: nil,
            appURL: nil,
            isRefreshing: true
        )
    }

    func fetchEntry(date: Date) async throws -> WidgetArtworkEntry {
        let cycleKey = makeCycleKey(date: date)
        if let snapshot = await snapshotStore.load(cycleKey: cycleKey) {
            await RequestLogger.shared.logEvent(
                source: "Widget 刷新",
                summary: "命中当前刷新周期快照缓存，直接复用 \(snapshot.museumName) / \(snapshot.title)"
            )
            return WidgetArtworkEntry(
                date: date,
                museumName: snapshot.museumName,
                title: snapshot.title,
                subtitle: snapshot.subtitle,
                imageData: snapshot.imageData,
                appURL: snapshot.appURL,
                isRefreshing: false
            )
        }

        let previousReference = await snapshotStore
            .loadLatest()?
            .appURL
            .flatMap(AppDeepLink.parse)
        let museum = pickMuseum()
        await RequestLogger.shared.logEvent(
            source: "Widget 刷新",
            summary: "开始生成新条目，博物馆=\(museum.displayName)"
        )

        switch museum.id {
        case .met:
            let ids = try await metAPI.searchObjectIDs(hasImages: settings.preferHasImages, isOnView: false, query: "*")
            guard let id = pickMetObjectID(from: ids, previousReference: previousReference, museum: museum) else {
                throw URLError(.cannotParseResponse)
            }
            let object = try await metAPI.fetchObject(objectID: id)
            let artwork = object.toArtwork()
            return try await makeSnapshotEntry(for: artwork, museum: museum, date: date, cycleKey: cycleKey)
        case .tnm:
            let searchPool = try await japanSearchAPI.searchItemIDs(preferHasImages: settings.preferHasImages)
            guard let id = pickObjectID(from: searchPool.itemIDs, previousReference: previousReference, museum: museum) else {
                throw URLError(.cannotParseResponse)
            }
            let item = try await japanSearchAPI.fetchItem(itemID: id)
            let artwork = item.toArtwork()
            return try await makeSnapshotEntry(for: artwork, museum: museum, date: date, cycleKey: cycleKey)
        case .nmc:
            let ids = try await nationalMuseumChinaAPI.allExhibitIDs()
            guard let id = pickNumericObjectID(from: ids, previousReference: previousReference, museum: museum) else {
                throw URLError(.cannotParseResponse)
            }
            let artwork = try await nationalMuseumChinaAPI.fetchExhibit(exhibitID: id)
            return try await makeSnapshotEntry(for: artwork, museum: museum, date: date, cycleKey: cycleKey)
        }
    }

    private func makeSnapshotEntry(for artwork: Artwork, museum: Museum, date: Date, cycleKey: String) async throws -> WidgetArtworkEntry {
        let imageURL = preferredWidgetImageURL(for: artwork, museum: museum)
        let imageData = try await fetchImageData(url: imageURL)
        let reference = ArtworkReference(
            museumID: museum.id,
            objectID: artwork.objectID,
            imageAspectRatio: nil
        )

        let snapshot = WidgetArtworkSnapshotStore.Snapshot(
            cycleKey: cycleKey,
            museumName: museum.displayName,
            title: artwork.title,
            subtitle: artwork.objectDate,
            imageData: imageData,
            appURL: AppDeepLink.artworkURL(reference: reference)
        )
        await snapshotStore.store(snapshot)
        await RequestLogger.shared.logEvent(
            source: "Widget 刷新",
            summary: "刷新完成，已缓存 \(museum.displayName) / \(artwork.title)"
        )

        return WidgetArtworkEntry(
            date: date,
            museumName: snapshot.museumName,
            title: snapshot.title,
            subtitle: snapshot.subtitle,
            imageData: snapshot.imageData,
            appURL: snapshot.appURL,
            isRefreshing: false
        )
    }

    private func preferredWidgetImageURL(for artwork: Artwork, museum: Museum) -> URL? {
        switch museum.id {
        case .tnm:
            return artwork.primaryImageURL ?? artwork.primaryImageSmallURL
        case .met, .nmc:
            return artwork.primaryImageSmallURL ?? artwork.primaryImageURL
        }
    }

    private func pickMetObjectID(from ids: [Int], previousReference: ArtworkReference?, museum: Museum) -> Int? {
        pickNumericObjectID(from: ids, previousReference: previousReference, museum: museum)
    }

    private func pickNumericObjectID(from ids: [Int], previousReference: ArtworkReference?, museum: Museum) -> Int? {
        let stringIDs = ids.map(String.init)
        guard let objectID = pickObjectID(from: stringIDs, previousReference: previousReference, museum: museum) else {
            return nil
        }
        return Int(objectID)
    }

    private func pickObjectID(from ids: [String], previousReference: ArtworkReference?, museum: Museum) -> String? {
        guard !ids.isEmpty else { return nil }

        let excludedObjectID = previousReference?.museumID == museum.id ? previousReference?.objectID : nil
        guard let excludedObjectID else {
            return ids.randomElement()
        }

        let filtered = ids.filter { $0 != excludedObjectID }
        return filtered.randomElement() ?? ids.randomElement()
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
        for attempt in 1...Constants.imageDownloadMaxAttempts {
            let start = Date()
            await RequestLogger.shared.logRequestStart(source: "Widget 图片", url: url)

            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    throw URLError(.badServerResponse)
                }
                await RequestLogger.shared.logRequestSuccess(
                    source: "Widget 图片",
                    url: url,
                    statusCode: http.statusCode,
                    duration: Date().timeIntervalSince(start),
                    responseBytes: data.count
                )
                if attempt > 1 {
                    await RequestLogger.shared.logEvent(
                        source: "Widget 图片",
                        summary: "第 \(attempt) 次尝试成功，结束重试"
                    )
                }
                return data
            } catch {
                await RequestLogger.shared.logRequestFailure(
                    source: "Widget 图片",
                    url: url,
                    duration: Date().timeIntervalSince(start),
                    error: error
                )

                guard attempt < Constants.imageDownloadMaxAttempts else {
                    await RequestLogger.shared.logEvent(
                        source: "Widget 图片",
                        summary: "图片请求已达到最大重试次数 \(Constants.imageDownloadMaxAttempts)"
                    )
                    return nil
                }

                let nextAttempt = attempt + 1
                await RequestLogger.shared.logEvent(
                    source: "Widget 图片",
                    summary: "准备第 \(nextAttempt) 次重试"
                )
                let delay = Constants.imageRetryBaseDelayNanoseconds * UInt64(attempt)
                try? await Task.sleep(nanoseconds: delay)
            }
        }

        return nil
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
