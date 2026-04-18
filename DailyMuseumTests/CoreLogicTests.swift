import XCTest

final class CoreLogicTests: XCTestCase {
    func testFeedCategoriesStoredValueDefaultsToAllSelectableCategories() {
        let categories = MuseumID.met.feedCategories(withStoredValue: nil)

        XCTAssertEqual(categories.count, MuseumID.met.selectableFeedCategories.count)
        XCTAssertFalse(categories.contains(where: { $0.isAll }))
    }

    func testFeedCategoriesStoredValueFallsBackToAllForAllAndUnknownValues() {
        let allFromAll = MuseumID.tnm.feedCategories(withStoredValue: "all")
        let allFromUnknown = MuseumID.tnm.feedCategories(withStoredValue: "unknown")

        XCTAssertEqual(allFromAll, MuseumID.tnm.selectableFeedCategories)
        XCTAssertEqual(allFromUnknown, MuseumID.tnm.selectableFeedCategories)
    }

    func testNormalizedFeedCategoriesIgnoresCrossMuseumSelectionsAndFallsBackToAll() {
        let categories = MuseumID.met.normalizedFeedCategories(MuseumID.tnm.selectableFeedCategories)

        XCTAssertEqual(categories, MuseumID.met.selectableFeedCategories)
    }

    func testFeedCategoryStorageValueNormalizesSubsetOrder() {
        let modernArt = MuseumID.met.feedCategory(withID: "modern-art")
        let americanDecorativeArts = MuseumID.met.feedCategory(withID: "american-decorative-arts")
        let foreignCategory = MuseumID.tnm.feedCategory(withID: "paint")

        let value = MuseumID.met.feedCategoryStorageValue(for: [
            modernArt!,
            foreignCategory!,
            americanDecorativeArts!
        ])

        XCTAssertEqual(value, "american-decorative-arts,modern-art")
    }

    func testMuseumRepositoryPreferredOrderDeduplicatesAndAppendsMissingMuseums() {
        let museums = MuseumRepository.museums(inPreferredOrder: [.tnm, .tnm, .met])
        let widgetMuseums = MuseumRepository.widgetMuseums(inPreferredOrder: [.tnm, .tnm, .met])

        XCTAssertEqual(museums.map(\.id), [.tnm, .met, .nmc, .shm])
        XCTAssertEqual(widgetMuseums.map(\.id), [.tnm, .met, .nmc, .shm])
    }

    func testAppDeepLinkRoundTripPreservesReference() throws {
        let reference = ArtworkReference(
            museumID: .met,
            objectID: "12345",
            imageAspectRatio: 1.75
        )

        let url = try XCTUnwrap(AppDeepLink.artworkURL(reference: reference))
        let parsed = AppDeepLink.parse(url: url)

        XCTAssertEqual(parsed?.museumID, .met)
        XCTAssertEqual(parsed?.objectID, "12345")
        XCTAssertEqual(parsed?.imageAspectRatio, 1.75)
    }

    func testAppDeepLinkRejectsInvalidURLs() {
        XCTAssertNil(AppDeepLink.parse(url: URL(string: "https://example.com/artwork/met/1")!))
        XCTAssertNil(AppDeepLink.parse(url: URL(string: "dailymuseum://museum/met/1")!))
        XCTAssertNil(AppDeepLink.parse(url: URL(string: "dailymuseum://artwork/met")!))
        XCTAssertNil(AppDeepLink.parse(url: URL(string: "dailymuseum://artwork/unknown/1")!))
    }

    func testWidgetMuseumScopeRawValueRoundTrip() {
        XCTAssertEqual(WidgetMuseumScope(rawValue: WidgetMuseumScope.all.rawValue), .all)
        XCTAssertEqual(WidgetMuseumScope(rawValue: WidgetMuseumScope.single(.tnm).rawValue), .single(.tnm))
        XCTAssertNil(WidgetMuseumScope(rawValue: "single:unknown"))
    }

    func testArtworkNormalizedDescriptionTextRemovesHTMLAndNoise() {
        let artwork = makeArtwork(
            museumID: .met,
            title: "Test",
            description: """
            <p> First&nbsp;line </p><br>
            <p>[]</p>
            <p>-> Second line</p>
            <p>&gt; Third line&#39;</p>
            """
        )

        XCTAssertEqual(
            artwork.normalizedDescriptionText,
            """
            First line
            Second line
            > Third line'
            """
        )
    }

    func testArtworkNormalizedDescriptionTextDecodesPunctuationEntities() {
        let artwork = makeArtwork(
            museumID: .met,
            title: "Test",
            description: """
            <p>&ldquo;Quoted&rdquo; text&nbsp;&mdash;&#8212;&#x2013;&rsquo;</p>
            """
        )

        XCTAssertEqual(
            artwork.normalizedDescriptionText,
            """
            "Quoted" text ——–'
            """
        )
    }

    func testArtworkSupportsTranslationRequiresSupportedMuseumAndMeaningfulContent() {
        let translatable = makeArtwork(museumID: .met, title: "Water Lilies", description: nil)
        let unsupportedMuseum = makeArtwork(museumID: .nmc, title: "后母戊鼎", description: nil)
        let blankContent = makeArtwork(museumID: .met, title: "   ", description: nil)

        XCTAssertTrue(translatable.supportsTranslation)
        XCTAssertFalse(unsupportedMuseum.supportsTranslation)
        XCTAssertFalse(blankContent.supportsTranslation)
    }

    func testTranslationToolbarStateUsesExpectedOriginalIcon() {
        let state = TranslationToolbarState.original(hasCachedTranslation: false)

        XCTAssertEqual(state.systemImageName, "globe")
        XCTAssertFalse(state.isDisabled)
    }

    func testTranslationToolbarStateUsesExpectedTranslatingIconAndDisablesButton() {
        let state = TranslationToolbarState.translating

        XCTAssertEqual(state.systemImageName, "globe.badge.clock")
        XCTAssertTrue(state.isDisabled)
    }

    func testTranslationToolbarStateUsesExpectedTranslatedIcon() {
        let state = TranslationToolbarState.translated

        XCTAssertEqual(state.systemImageName, "globe.badge.chevron.backward")
        XCTAssertFalse(state.isDisabled)
    }

    func testJapanSearchItemSortValueAndArtworkMapping() throws {
        let item = try decodeJapanSearchItem(
            """
            {
              "id": "jpsearch-20",
              "common": {
                "id": "jpsearch-20",
                "title": "国宝 太刀",
                "linkUrl": "https://example.com/object",
                "thumbnailUrl": ["https://example.com/slideshow_s/thumb.jpg"],
                "contentsUrl": ["https://example.com/slideshow_s/full.jpg"],
                "contributor": ["Tokyo National Museum", "東京国立博物館", "刀工"],
                "temporal": ["鎌倉時代"],
                "description": "sample description",
                "provider": "tnm",
                "database": "cobas"
              },
              "cobas-22-s": "20",
              "cobas-16-s": "東京国立博物館",
              "cobas-11-s": "鎌倉時代",
              "cobas-12-s": "鉄",
              "cobas-13-s": "長さ70cm",
              "cobas-4-s": "刀剣"
            }
            """
        )

        let artwork = item.toArtwork()

        XCTAssertEqual(item.sortValue, 20)
        XCTAssertEqual(artwork.objectID, "jpsearch-20")
        XCTAssertEqual(artwork.artistDisplayName, "刀工")
        XCTAssertEqual(artwork.repository, "東京国立博物館")
        XCTAssertEqual(artwork.objectDate, "鎌倉時代")
        XCTAssertEqual(artwork.department, "刀剣")
        XCTAssertEqual(artwork.primaryImageURL?.absoluteString, "https://example.com/slideshow/full.jpg")
        XCTAssertEqual(artwork.primaryImageSmallURL?.absoluteString, "https://example.com/slideshow_s/thumb.jpg")
    }

    func testJapanSearchItemSortValueFallsBackToItemIDSuffix() throws {
        let item = try decodeJapanSearchItem(
            """
            {
              "id": "jpsearch-314",
              "common": {
                "id": "jpsearch-314",
                "title": "Test",
                "thumbnailUrl": [],
                "contentsUrl": [],
                "contributor": [],
                "temporal": []
              }
            }
            """
        )

        XCTAssertEqual(item.sortValue, 314)
    }

    func testRequestLogTimestampIncludesSixDigitMicroseconds() throws {
        let timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let date = try makeDate(
            year: 2024,
            month: 4,
            day: 18,
            hour: 6,
            minute: 20,
            second: 34,
            nanosecond: 123_456_000,
            timeZone: timeZone
        )

        let formatted = LogTimestampFormatter.requestLogTimestamp(from: date, timeZone: timeZone)

        XCTAssertEqual(formatted, "04-18 06:20:34.123456")
    }

    func testFeedLogTimestampLeftPadsMicroseconds() throws {
        let timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let date = try makeDate(
            year: 2024,
            month: 4,
            day: 18,
            hour: 6,
            minute: 20,
            second: 34,
            nanosecond: 42_000,
            timeZone: timeZone
        )

        let formatted = LogTimestampFormatter.feedLogTimestamp(from: date, timeZone: timeZone)

        XCTAssertEqual(formatted, "06:20:34.000042")
    }

    func testRequestAndFeedLogTimestampsKeepExpectedLayout() throws {
        let timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let date = try makeDate(
            year: 2024,
            month: 12,
            day: 31,
            hour: 23,
            minute: 59,
            second: 1,
            nanosecond: 900_001_000,
            timeZone: timeZone
        )

        XCTAssertEqual(
            LogTimestampFormatter.requestLogTimestamp(from: date, timeZone: timeZone),
            "12-31 23:59:01.900001"
        )
        XCTAssertEqual(
            LogTimestampFormatter.feedLogTimestamp(from: date, timeZone: timeZone),
            "23:59:01.900001"
        )
    }

    private func makeArtwork(museumID: MuseumID, title: String, description: String?) -> Artwork {
        Artwork(
            id: "\(museumID.rawValue)-1",
            museumID: museumID,
            objectID: "1",
            title: title,
            artworkDescription: description,
            artistDisplayName: nil,
            objectDate: nil,
            medium: nil,
            dimensions: nil,
            department: nil,
            culture: nil,
            country: nil,
            repository: nil,
            primaryImageURL: nil,
            primaryImageSmallURL: nil,
            objectURL: nil
        )
    }

    private func decodeJapanSearchItem(_ json: String) throws -> JapanSearchItem {
        try JSONDecoder().decode(JapanSearchItem.self, from: Data(json.utf8))
    }

    private func makeDate(
        year: Int,
        month: Int,
        day: Int,
        hour: Int,
        minute: Int,
        second: Int,
        nanosecond: Int,
        timeZone: TimeZone
    ) throws -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = DateComponents(
            timeZone: timeZone,
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute,
            second: second,
            nanosecond: nanosecond
        )
        return try XCTUnwrap(calendar.date(from: components))
    }
}
