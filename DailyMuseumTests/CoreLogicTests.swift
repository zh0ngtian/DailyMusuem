import XCTest

final class CoreLogicTests: XCTestCase {
    func testSupportedMuseumsHaveHomepageLogoAssetCatalogEntries() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let assetCatalogURL = projectRoot.appendingPathComponent("DailyMuseum/Assets.xcassets", isDirectory: true)
        let fileManager = FileManager.default

        for museumID in MuseumID.allCases {
            let assetName = museumID.homepageLogoAssetName
            XCTAssertFalse(assetName.isEmpty)

            let imagesetURL = assetCatalogURL.appendingPathComponent("\(assetName).imageset", isDirectory: true)
            var isDirectory: ObjCBool = false
            XCTAssertTrue(
                fileManager.fileExists(atPath: imagesetURL.path, isDirectory: &isDirectory),
                "Missing imageset for \(museumID.rawValue)"
            )
            XCTAssertTrue(isDirectory.boolValue, "Expected imageset directory for \(museumID.rawValue)")

            let contentsURL = imagesetURL.appendingPathComponent("Contents.json")
            XCTAssertTrue(fileManager.fileExists(atPath: contentsURL.path), "Missing Contents.json for \(museumID.rawValue)")

            let images = try fileManager.contentsOfDirectory(at: imagesetURL, includingPropertiesForKeys: nil)
            XCTAssertTrue(
                images.contains(where: { $0.pathExtension.lowercased() == "png" }),
                "Expected PNG logo assets for \(museumID.rawValue)"
            )
        }
    }

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

    func testNaraMuseumDataSourceDefaultsToOfficialWithExpectedDisplayNames() {
        XCTAssertEqual(NaraMuseumDataSource.defaultValue, .official)
        XCTAssertEqual(NaraMuseumDataSource.official.displayName, "馆方数据源")
        XCTAssertEqual(NaraMuseumDataSource.colbase.displayName, "ColBase")
    }

    func testNaraMuseumOfficialCategoriesUseOfficialDepartments() {
        let officialCategories = MuseumID.nnm.selectableFeedCategories(naraDataSource: .official)

        XCTAssertEqual(
            officialCategories.map(\.displayName),
            ["雕刻", "绘画", "书迹", "工艺", "考古", "中国古代青铜器", "其他"]
        )
        XCTAssertEqual(
            officialCategories.map(\.id),
            [
                "official-sculpture",
                "official-painting",
                "official-calligraphy",
                "official-craft",
                "official-archaeology",
                "official-ancient-chinese-bronze",
                "official-other"
            ]
        )
        XCTAssertTrue(officialCategories.allSatisfy { $0.kind == .naraMuseumOfficialDepartment })
        XCTAssertEqual(
            MuseumID.nnm.feedCategoryStorageValue(
                for: officialCategories,
                naraDataSource: .official
            ),
            "all"
        )
    }

    func testNaraMuseumColbaseCategoriesRemainJapanSearchTypes() {
        let colbaseCategories = MuseumID.nnm.selectableFeedCategories(naraDataSource: .colbase)

        XCTAssertEqual(
            colbaseCategories.map(\.id),
            ["archeology", "ancdoc", "paint", "craft", "sculpture", "ceramic", "metal", "lacquer", "weaponry", "daw"]
        )
        XCTAssertTrue(colbaseCategories.allSatisfy { $0.kind == .japanSearchType })
    }

    func testMuseumRepositoryPreferredOrderDeduplicatesAndAppendsMissingMuseums() {
        let museums = MuseumRepository.museums(inPreferredOrder: [.tnm, .tnm, .met])
        let widgetMuseums = MuseumRepository.widgetMuseums(inPreferredOrder: [.tnm, .tnm, .met])

        XCTAssertEqual(museums.map(\.id), [.tnm, .met, .nnm, .nmc, .shm, .guimet])
        XCTAssertEqual(widgetMuseums.map(\.id), [.tnm, .met, .nnm, .nmc, .shm, .guimet])
    }

    func testMuseumRepositoryHomepageCountrySectionsPlaceChinaFirst() {
        let sections = MuseumRepository.homepageCountrySections

        XCTAssertEqual(sections.map(\.country), ["中国", "美国", "日本", "法国"])
        XCTAssertEqual(sections[0].museums.map(\.id), [.nmc, .shm])
        XCTAssertEqual(sections[1].museums.map(\.id), [.met])
        XCTAssertEqual(sections[2].museums.map(\.id), [.tnm, .nnm])
        XCTAssertEqual(sections[3].museums.map(\.id), [.guimet])
        XCTAssertEqual(MuseumRepository.homepageMuseumIDs, [.nmc, .shm, .met, .tnm, .nnm, .guimet])
    }

    func testMuseumRepositoryWidgetMuseumsFollowHomepageOrderWithoutGrouping() {
        let widgetMuseums = MuseumRepository.widgetMuseums(inPreferredOrder: MuseumRepository.homepageMuseumIDs)

        XCTAssertEqual(widgetMuseums.map(\.id), [.nmc, .shm, .met, .tnm, .nnm, .guimet])
    }

    func testMuseumMetadataUsesStableCountryAndCityFieldsForHomepageCopy() {
        XCTAssertEqual(MuseumRepository.museum(for: .met).country, "美国")
        XCTAssertEqual(MuseumRepository.museum(for: .met).city, "纽约")
        XCTAssertEqual(MuseumRepository.museum(for: .met).subtitle, "纽约")
        XCTAssertEqual(MuseumRepository.museum(for: .tnm).country, "日本")
        XCTAssertEqual(MuseumRepository.museum(for: .tnm).city, "东京")
        XCTAssertEqual(MuseumRepository.museum(for: .tnm).subtitle, "东京")
        XCTAssertEqual(MuseumRepository.museum(for: .nnm).country, "日本")
        XCTAssertEqual(MuseumRepository.museum(for: .nnm).city, "奈良")
        XCTAssertEqual(MuseumRepository.museum(for: .nnm).subtitle, "奈良")
        XCTAssertEqual(MuseumRepository.museum(for: .nmc).country, "中国")
        XCTAssertEqual(MuseumRepository.museum(for: .nmc).city, "北京")
        XCTAssertEqual(MuseumRepository.museum(for: .nmc).subtitle, "北京")
        XCTAssertEqual(MuseumRepository.museum(for: .shm).country, "中国")
        XCTAssertEqual(MuseumRepository.museum(for: .shm).city, "上海")
        XCTAssertEqual(MuseumRepository.museum(for: .shm).subtitle, "上海")
        XCTAssertEqual(MuseumRepository.museum(for: .guimet).country, "法国")
        XCTAssertEqual(MuseumRepository.museum(for: .guimet).city, "巴黎")
        XCTAssertEqual(MuseumRepository.museum(for: .guimet).subtitle, "巴黎")
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

    func testShortcutInstallPromptDeepLinkRoundTripPreservesPayload() throws {
        let installURL = try XCTUnwrap(URL(string: "https://www.icloud.com/shortcuts/50a57de8c0884898a895556c3e8b01b5"))
        let appInstallURL = try XCTUnwrap(URL(string: "https://apps.apple.com/cn/app/id6459478672"))
        let callbackURL = try XCTUnwrap(
            AppDeepLink.shortcutInstallPromptURL(
                shortcutName: "DoubaoMuseum",
                installURL: installURL,
                appName: "豆包",
                appInstallURL: appInstallURL
            )
        )
        let callbackWithError = try XCTUnwrap(
            URL(string: "\(callbackURL.absoluteString)&errorMessage=\("missing shortcut".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!)")
        )

        let parsed = AppDeepLink.parseShortcutInstallPrompt(url: callbackWithError)

        XCTAssertEqual(parsed?.shortcutName, "DoubaoMuseum")
        XCTAssertEqual(parsed?.shortcutInstallURL, installURL)
        XCTAssertEqual(parsed?.appName, "豆包")
        XCTAssertEqual(parsed?.appInstallURL, appInstallURL)
        XCTAssertEqual(parsed?.errorMessage, "missing shortcut")
    }

    func testAIAssistantInstallPromptKindResolvesExpectedFailures() {
        XCTAssertEqual(
            AIAssistantInstallPromptKind.resolve(errorMessage: "未找到快捷指令"),
            .shortcut
        )
        XCTAssertEqual(
            AIAssistantInstallPromptKind.resolve(errorMessage: "The app could not be opened."),
            .app
        )
        XCTAssertEqual(
            AIAssistantInstallPromptKind.resolve(errorMessage: "该App无法打开"),
            .app
        )
        XCTAssertEqual(
            AIAssistantInstallPromptKind.resolve(errorMessage: nil),
            .shortcut
        )
    }

    func testWidgetMuseumScopeRawValueRoundTrip() {
        XCTAssertEqual(WidgetMuseumScope(rawValue: WidgetMuseumScope.all.rawValue), .all)
        XCTAssertEqual(WidgetMuseumScope(rawValue: WidgetMuseumScope.single(.tnm).rawValue), .single(.tnm))
        XCTAssertEqual(WidgetMuseumScope(rawValue: WidgetMuseumScope.single(.nnm).rawValue), .single(.nnm))
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

    func testArtworkNormalizedDescriptionTextUsesChinesePunctuationForChineseMuseums() {
        let artwork = makeArtwork(
            museumID: .nmc,
            title: "Test",
            description: """
            <p>&ldquo;引号&rdquo;&nbsp;&mdash;&#8212;&#x2013;&hellip;&lsquo;内嵌&rsquo;</p>
            """
        )

        XCTAssertEqual(
            artwork.normalizedDescriptionText,
            """
            “引号” ——……‘内嵌’
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

    func testArtworkTranslationEntriesIncludeVisibleFieldsOnly() {
        let artwork = makeArtwork(
            museumID: .met,
            title: "Water Lilies",
            description: "A large oil painting.",
            artistDisplayName: "Claude Monet",
            objectDate: "1916",
            medium: "Oil on canvas",
            dimensions: "200 x 180 cm",
            department: "European Paintings",
            culture: "French",
            country: "France"
        )

        XCTAssertEqual(
            artwork.translationEntries,
            [
                ArtworkTranslationEntry(id: "title", text: "Water Lilies"),
                ArtworkTranslationEntry(id: "description", text: "A large oil painting."),
                ArtworkTranslationEntry(id: "artistDisplayName", text: "Claude Monet"),
                ArtworkTranslationEntry(id: "objectDate", text: "1916"),
                ArtworkTranslationEntry(id: "medium", text: "Oil on canvas"),
                ArtworkTranslationEntry(id: "dimensions", text: "200 x 180 cm"),
                ArtworkTranslationEntry(id: "department", text: "European Paintings"),
                ArtworkTranslationEntry(id: "culture", text: "French"),
                ArtworkTranslationEntry(id: "country", text: "France")
            ]
        )
    }

    func testArtworkApplyingTranslationsUpdatesOnlyTranslatedFields() {
        let artwork = makeArtwork(
            museumID: .met,
            title: "Water Lilies",
            description: "A large oil painting.",
            artistDisplayName: "Claude Monet",
            medium: "Oil on canvas"
        )

        let translatedArtwork = artwork.applyingTranslations([
            "title": "睡莲",
            "description": "一幅大型油画。",
            "medium": "布面油画"
        ])

        XCTAssertEqual(translatedArtwork.title, "睡莲")
        XCTAssertEqual(translatedArtwork.normalizedDescriptionText, "一幅大型油画。")
        XCTAssertEqual(translatedArtwork.artistDisplayName, "Claude Monet")
        XCTAssertEqual(translatedArtwork.medium, "布面油画")
    }

    func testMuseumCopyrightNoticeUsesExpectedFormat() {
        XCTAssertEqual(MuseumID.met.copyrightNotice, "©大都会艺术博物馆 版权所有")
        XCTAssertEqual(MuseumID.tnm.copyrightNotice, "©东京国立博物馆 版权所有")
        XCTAssertEqual(MuseumID.nnm.copyrightNotice, "©奈良国立博物馆 版权所有")
        XCTAssertEqual(MuseumID.nmc.copyrightNotice, "©中国国家博物馆 版权所有")
        XCTAssertEqual(MuseumID.shm.copyrightNotice, "©上海博物馆 版权所有")
    }

    func testArtworkShareContentUsesUnifiedShareTextFormat() throws {
        let officialURL = try XCTUnwrap(URL(string: "https://example.com/object/1"))
        let artwork = makeArtwork(
            museumID: .met,
            title: "睡莲",
            description: nil,
            objectURL: officialURL
        )
        let content = try XCTUnwrap(ArtworkShareContent(artwork: artwork))

        XCTAssertEqual(
            content.plainText,
            "睡莲｜大都会艺术博物馆｜https://example.com/object/1"
        )
    }

    func testArtworkShareContentBuildsDoubaoShortcutInputTextFromOfficialURL() throws {
        let officialURL = try XCTUnwrap(URL(string: "https://example.com/object/2"))
        let artwork = makeArtwork(
            museumID: .shm,
            title: "青铜鼎",
            description: nil,
            objectURL: officialURL
        )
        let content = try XCTUnwrap(ArtworkShareContent(artwork: artwork))

        XCTAssertEqual(
            content.doubaoShortcutInputText,
            "介绍一下这个展品：https://example.com/object/2"
        )
    }

    func testArtworkShareContentUsesArtworkTitleAndOfficialURLForMetadata() throws {
        let officialURL = try XCTUnwrap(URL(string: "https://example.com/object/3"))
        let artwork = makeArtwork(
            museumID: .nmc,
            title: "后母戊鼎",
            description: nil,
            objectURL: officialURL
        )
        let content = try XCTUnwrap(ArtworkShareContent(artwork: artwork))

        XCTAssertEqual(content.shareSheetSubject, "后母戊鼎")
        XCTAssertEqual(content.linkMetadataTitle, "后母戊鼎")
        XCTAssertEqual(content.officialURL, officialURL)
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

        let artwork = item.toArtwork(museumID: .tnm)

        XCTAssertEqual(item.sortValue, 20)
        XCTAssertEqual(artwork.objectID, "jpsearch-20")
        XCTAssertEqual(artwork.artistDisplayName, "刀工")
        XCTAssertEqual(artwork.repository, "東京国立博物館")
        XCTAssertEqual(artwork.objectDate, "鎌倉時代")
        XCTAssertEqual(artwork.department, "刀剣")
        XCTAssertEqual(artwork.primaryImageURL?.absoluteString, "https://example.com/slideshow/full.jpg")
        XCTAssertEqual(artwork.primaryImageSmallURL?.absoluteString, "https://example.com/slideshow_s/thumb.jpg")
    }

    func testJapanSearchItemMapsNaraArtworkWithMuseumProfile() throws {
        let item = try decodeJapanSearchItem(
            """
            {
              "id": "cobas-16086",
              "common": {
                "id": "cobas-16086",
                "title": "刺繍釈迦阿弥陀二尊像",
                "linkUrl": "https://colbase.nich.go.jp/collection_items/narahaku/1266-0",
                "thumbnailUrl": ["https://colbase.nich.go.jp/media/narahaku/1266-0/image/slideshow_s/H015391.jpg"],
                "contentsUrl": ["https://colbase.nich.go.jp/media/narahaku/1266-0/image/slideshow_s/H015391.jpg"],
                "contributor": ["奈良国立博物館", "Nara National Museum"],
                "temporal": ["13～14世紀"],
                "provider": "narahaku",
                "database": "cobas"
              },
              "cobas-22-s": "16086",
              "cobas-16-s": "奈良国立博物館",
              "cobas-11-s": "13～14世紀",
              "cobas-12-s": "刺繍",
              "cobas-13-s": "縦127.0　横52.0",
              "cobas-4-s": "工芸"
            }
            """
        )

        let artwork = item.toArtwork(museumID: .nnm)

        XCTAssertEqual(artwork.id, "nnm-cobas-16086")
        XCTAssertEqual(artwork.museumID, .nnm)
        XCTAssertEqual(artwork.repository, "奈良国立博物館")
        XCTAssertEqual(artwork.country, "日本")
        XCTAssertEqual(artwork.primaryImageURL?.absoluteString, "https://colbase.nich.go.jp/media/narahaku/1266-0/image/slideshow/H015391.jpg")
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

    func testRequestLogTimestampIncludesThreeDigitMilliseconds() throws {
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

        XCTAssertEqual(formatted, "04-18 06:20:34.123")
    }

    func testFeedLogTimestampLeftPadsMilliseconds() throws {
        let timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let date = try makeDate(
            year: 2024,
            month: 4,
            day: 18,
            hour: 6,
            minute: 20,
            second: 34,
            nanosecond: 42_000_000,
            timeZone: timeZone
        )

        let formatted = LogTimestampFormatter.feedLogTimestamp(from: date, timeZone: timeZone)

        XCTAssertEqual(formatted, "06:20:34.042")
    }

    func testFeedLogTimestampRoundsMillisecondsIntoNextSecond() throws {
        let timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let date = try makeDate(
            year: 2024,
            month: 4,
            day: 18,
            hour: 6,
            minute: 20,
            second: 34,
            nanosecond: 999_600_000,
            timeZone: timeZone
        )

        let formatted = LogTimestampFormatter.feedLogTimestamp(from: date, timeZone: timeZone)

        XCTAssertEqual(formatted, "06:20:35.000")
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
            "12-31 23:59:01.900"
        )
        XCTAssertEqual(
            LogTimestampFormatter.feedLogTimestamp(from: date, timeZone: timeZone),
            "23:59:01.900"
        )
    }

    func testWeChatShareDiagnosticsDetectsDeclaredSchemeCaseInsensitively() {
        XCTAssertTrue(
            WeChatShareDiagnostics.isSchemeDeclared(
                in: ["LSApplicationQueriesSchemes": ["wechat", "WeiXin"]]
            )
        )
        XCTAssertFalse(
            WeChatShareDiagnostics.isSchemeDeclared(
                in: ["LSApplicationQueriesSchemes": ["wechat", "doubao"]]
            )
        )
        XCTAssertFalse(WeChatShareDiagnostics.isSchemeDeclared(in: nil))
    }

    func testWeChatShareDiagnosticsCanOpenFailureSummaryMentionsMissingSchemeDeclaration() {
        XCTAssertEqual(
            WeChatShareDiagnostics.canOpenFailureSummary(isSchemeDeclared: false),
            "分享失败：canOpenURL(weixin://) 返回 false，且 Info.plist 未声明 LSApplicationQueriesSchemes=weixin，当前无法准确判断是否已安装微信。"
        )
        XCTAssertEqual(
            WeChatShareDiagnostics.canOpenFailureSummary(isSchemeDeclared: true),
            "分享失败：canOpenURL(weixin://) 返回 false，可能未安装微信，或系统当前无法拉起微信。"
        )
    }

    func testWeChatShareDiagnosticsOpenFailureSummaryIncludesDeclarationState() {
        XCTAssertEqual(
            WeChatShareDiagnostics.openFailureSummary(isSchemeDeclared: false),
            "分享失败：UIApplication.open(weixin://) 回调返回 false。Info.plist 未声明 LSApplicationQueriesSchemes=weixin。"
        )
        XCTAssertEqual(
            WeChatShareDiagnostics.openFailureSummary(isSchemeDeclared: true),
            "分享失败：UIApplication.open(weixin://) 回调返回 false。Info.plist 已声明 LSApplicationQueriesSchemes=weixin。"
        )
    }

    func testAppInfoPlistDeclaresWeixinQueryScheme() {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let infoPlistURL = projectRoot.appendingPathComponent("DailyMuseum/Info.plist")
        let plist = NSDictionary(contentsOf: infoPlistURL) as? [String: Any]

        XCTAssertTrue(
            WeChatShareDiagnostics.isSchemeDeclared(in: plist),
            "DailyMuseum/Info.plist must declare LSApplicationQueriesSchemes=weixin for WeChat share detection."
        )
    }

    private func makeArtwork(
        museumID: MuseumID,
        title: String,
        description: String?,
        artistDisplayName: String? = nil,
        objectDate: String? = nil,
        medium: String? = nil,
        dimensions: String? = nil,
        department: String? = nil,
        culture: String? = nil,
        country: String? = nil,
        objectURL: URL? = nil
    ) -> Artwork {
        Artwork(
            id: "\(museumID.rawValue)-1",
            museumID: museumID,
            objectID: "1",
            title: title,
            artworkDescription: description,
            artistDisplayName: artistDisplayName,
            objectDate: objectDate,
            medium: medium,
            dimensions: dimensions,
            department: department,
            culture: culture,
            country: country,
            repository: nil,
            primaryImageURL: nil,
            primaryImageSmallURL: nil,
            objectURL: objectURL
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
