import XCTest

final class CoreLogicTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try seedTestMuseumMetadata()
    }

    func testSupportedMuseumsHaveHomepageLogoAssetCatalogEntries() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let assetCatalogURL = projectRoot.appendingPathComponent("DailyMuseum/Assets.xcassets", isDirectory: true)
        let fileManager = FileManager.default

        for museumID in testMuseumMetadata().map(\.id) {
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
        let categories = MuseumIdentifier("met").feedCategories(withStoredValue: nil)

        XCTAssertEqual(categories.count, MuseumIdentifier("met").selectableFeedCategories.count)
        XCTAssertFalse(categories.contains(where: { $0.isAll }))
    }

    func testFeedCategoriesStoredValueFallsBackToAllForAllAndUnknownValues() {
        let allFromAll = MuseumIdentifier("tnm").feedCategories(withStoredValue: "all")
        let allFromUnknown = MuseumIdentifier("tnm").feedCategories(withStoredValue: "unknown")

        XCTAssertEqual(allFromAll, MuseumIdentifier("tnm").selectableFeedCategories)
        XCTAssertEqual(allFromUnknown, MuseumIdentifier("tnm").selectableFeedCategories)
    }

    func testNormalizedFeedCategoriesIgnoresCrossMuseumSelectionsAndFallsBackToAll() {
        let categories = MuseumIdentifier("met").normalizedFeedCategories(MuseumIdentifier("tnm").selectableFeedCategories)

        XCTAssertEqual(categories, MuseumIdentifier("met").selectableFeedCategories)
    }

    func testFeedCategoryStorageValueNormalizesSubsetOrder() {
        let modernArt = MuseumIdentifier("met").feedCategory(withID: "modern-art")
        let americanDecorativeArts = MuseumIdentifier("met").feedCategory(withID: "american-decorative-arts")
        let foreignCategory = MuseumIdentifier("tnm").feedCategory(withID: "paint")

        let value = MuseumIdentifier("met").feedCategoryStorageValue(for: [
            modernArt!,
            foreignCategory!,
            americanDecorativeArts!
        ])

        XCTAssertEqual(value, "american-decorative-arts,modern-art")
    }

    func testNaraMuseumSourcesComeFromMetadata() {
        XCTAssertEqual(MuseumIdentifier("nnm").defaultSourceKey, "official")
        XCTAssertEqual(MuseumIdentifier("nnm").sources.map(\.sourceKey), ["official", "colbase"])
        XCTAssertEqual(MuseumIdentifier("nnm").sources.map(\.displayName), ["馆方数据源", "ColBase"])
    }

    func testNaraMuseumOfficialCategoriesUseOfficialDepartments() {
        let officialCategories = MuseumIdentifier("nnm").selectableFeedCategories(sourceKey: "official")

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
        XCTAssertEqual(
            MuseumIdentifier("nnm").feedCategoryStorageValue(
                for: officialCategories,
                sourceKey: "official"
            ),
            "all"
        )
    }

    func testNaraMuseumColbaseCategoriesRemainJapanSearchTypes() {
        let colbaseCategories = MuseumIdentifier("nnm").selectableFeedCategories(sourceKey: "colbase")

        XCTAssertEqual(
            colbaseCategories.map(\.id),
            ["archeology", "ancdoc", "paint", "craft", "sculpture", "ceramic", "metal", "lacquer", "weaponry", "daw"]
        )
    }

    func testMuseumRepositoryPreferredOrderDeduplicatesAndAppendsMissingMuseums() {
        let museums = MuseumRepository.museums(inPreferredOrder: [MuseumIdentifier("tnm"), MuseumIdentifier("tnm"), MuseumIdentifier("met")])
        let widgetMuseums = MuseumRepository.widgetMuseums(inPreferredOrder: [MuseumIdentifier("tnm"), MuseumIdentifier("tnm"), MuseumIdentifier("met")])

        XCTAssertEqual(museums.map(\.id), [MuseumIdentifier("tnm"), MuseumIdentifier("met"), MuseumIdentifier("nmc"), MuseumIdentifier("shm"), MuseumIdentifier("nnm"), MuseumIdentifier("guimet")])
        XCTAssertEqual(widgetMuseums.map(\.id), [MuseumIdentifier("tnm"), MuseumIdentifier("met"), MuseumIdentifier("nmc"), MuseumIdentifier("shm"), MuseumIdentifier("nnm"), MuseumIdentifier("guimet")])
    }

    func testMuseumRepositoryHomepageCountrySectionsPlaceChinaFirst() {
        let sections = MuseumRepository.homepageCountrySections

        XCTAssertEqual(sections.map(\.country), ["中国", "美国", "日本", "法国"])
        XCTAssertEqual(sections[0].museums.map(\.id), [MuseumIdentifier("nmc"), MuseumIdentifier("shm")])
        XCTAssertEqual(sections[1].museums.map(\.id), [MuseumIdentifier("met")])
        XCTAssertEqual(sections[2].museums.map(\.id), [MuseumIdentifier("tnm"), MuseumIdentifier("nnm")])
        XCTAssertEqual(sections[3].museums.map(\.id), [MuseumIdentifier("guimet")])
        XCTAssertEqual(MuseumRepository.homepageMuseumIDs, [MuseumIdentifier("nmc"), MuseumIdentifier("shm"), MuseumIdentifier("met"), MuseumIdentifier("tnm"), MuseumIdentifier("nnm"), MuseumIdentifier("guimet")])
    }

    func testMuseumRepositoryWidgetMuseumsFollowHomepageOrderWithoutGrouping() {
        let widgetMuseums = MuseumRepository.widgetMuseums(inPreferredOrder: MuseumRepository.homepageMuseumIDs)

        XCTAssertEqual(widgetMuseums.map(\.id), [MuseumIdentifier("nmc"), MuseumIdentifier("shm"), MuseumIdentifier("met"), MuseumIdentifier("tnm"), MuseumIdentifier("nnm"), MuseumIdentifier("guimet")])
    }

    func testMuseumMetadataUsesStableCountryAndCityFieldsForHomepageCopy() {
        XCTAssertEqual(MuseumRepository.museum(for: MuseumIdentifier("met")).country, "美国")
        XCTAssertEqual(MuseumRepository.museum(for: MuseumIdentifier("met")).city, "纽约")
        XCTAssertEqual(MuseumRepository.museum(for: MuseumIdentifier("met")).subtitle, "纽约")
        XCTAssertEqual(MuseumRepository.museum(for: MuseumIdentifier("tnm")).country, "日本")
        XCTAssertEqual(MuseumRepository.museum(for: MuseumIdentifier("tnm")).city, "东京")
        XCTAssertEqual(MuseumRepository.museum(for: MuseumIdentifier("tnm")).subtitle, "东京")
        XCTAssertEqual(MuseumRepository.museum(for: MuseumIdentifier("nnm")).country, "日本")
        XCTAssertEqual(MuseumRepository.museum(for: MuseumIdentifier("nnm")).city, "奈良")
        XCTAssertEqual(MuseumRepository.museum(for: MuseumIdentifier("nnm")).subtitle, "奈良")
        XCTAssertEqual(MuseumRepository.museum(for: MuseumIdentifier("nmc")).country, "中国")
        XCTAssertEqual(MuseumRepository.museum(for: MuseumIdentifier("nmc")).city, "北京")
        XCTAssertEqual(MuseumRepository.museum(for: MuseumIdentifier("nmc")).subtitle, "北京")
        XCTAssertEqual(MuseumRepository.museum(for: MuseumIdentifier("shm")).country, "中国")
        XCTAssertEqual(MuseumRepository.museum(for: MuseumIdentifier("shm")).city, "上海")
        XCTAssertEqual(MuseumRepository.museum(for: MuseumIdentifier("shm")).subtitle, "上海")
        XCTAssertEqual(MuseumRepository.museum(for: MuseumIdentifier("guimet")).country, "法国")
        XCTAssertEqual(MuseumRepository.museum(for: MuseumIdentifier("guimet")).city, "巴黎")
        XCTAssertEqual(MuseumRepository.museum(for: MuseumIdentifier("guimet")).subtitle, "巴黎")
    }

    func testAppDeepLinkRoundTripPreservesReference() throws {
        let reference = ArtworkReference(
            museumID: MuseumIdentifier("met"),
            objectID: "12345",
            imageAspectRatio: 1.75
        )

        let url = try XCTUnwrap(AppDeepLink.artworkURL(reference: reference))
        let parsed = AppDeepLink.parse(url: url)

        XCTAssertEqual(parsed?.museumID, MuseumIdentifier("met"))
        XCTAssertEqual(parsed?.objectID, "12345")
        XCTAssertEqual(parsed?.imageAspectRatio, 1.75)
    }

    func testAppDeepLinkRejectsInvalidURLs() {
        XCTAssertNil(AppDeepLink.parse(url: URL(string: "https://example.com/artwork/met/1")!))
        XCTAssertNil(AppDeepLink.parse(url: URL(string: "dailymuseum://museum/met/1")!))
        XCTAssertNil(AppDeepLink.parse(url: URL(string: "dailymuseum://artwork/met")!))
        XCTAssertNil(AppDeepLink.parse(url: URL(string: "dailymuseum://artwork//1")!))
        XCTAssertEqual(AppDeepLink.parse(url: URL(string: "dailymuseum://artwork/unknown/1")!)?.museumID.rawValue, "unknown")
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
        XCTAssertEqual(WidgetMuseumScope(rawValue: WidgetMuseumScope.single(MuseumIdentifier("tnm")).rawValue), .single(MuseumIdentifier("tnm")))
        XCTAssertEqual(WidgetMuseumScope(rawValue: WidgetMuseumScope.single(MuseumIdentifier("nnm")).rawValue), .single(MuseumIdentifier("nnm")))
        XCTAssertEqual(WidgetMuseumScope(rawValue: "single:unknown"), .single(MuseumIdentifier("unknown")))
    }

    func testArtworkNormalizedDescriptionTextRemovesHTMLAndNoise() {
        let artwork = makeArtwork(
            museumID: MuseumIdentifier("met"),
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
            museumID: MuseumIdentifier("met"),
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
            museumID: MuseumIdentifier("nmc"),
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
        let translatable = makeArtwork(museumID: MuseumIdentifier("met"), title: "Water Lilies", description: nil)
        let unsupportedMuseum = makeArtwork(museumID: MuseumIdentifier("nmc"), title: "后母戊鼎", description: nil)
        let blankContent = makeArtwork(museumID: MuseumIdentifier("met"), title: "   ", description: nil)

        XCTAssertTrue(translatable.supportsTranslation)
        XCTAssertFalse(unsupportedMuseum.supportsTranslation)
        XCTAssertFalse(blankContent.supportsTranslation)
    }

    func testArtworkTranslationEntriesIncludeVisibleFieldsOnly() {
        let artwork = makeArtwork(
            museumID: MuseumIdentifier("met"),
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
            museumID: MuseumIdentifier("met"),
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
        XCTAssertEqual(MuseumIdentifier("met").copyrightNotice, "©大都会艺术博物馆 版权所有")
        XCTAssertEqual(MuseumIdentifier("tnm").copyrightNotice, "©东京国立博物馆 版权所有")
        XCTAssertEqual(MuseumIdentifier("nnm").copyrightNotice, "©奈良国立博物馆 版权所有")
        XCTAssertEqual(MuseumIdentifier("nmc").copyrightNotice, "©中国国家博物馆 版权所有")
        XCTAssertEqual(MuseumIdentifier("shm").copyrightNotice, "©上海博物馆 版权所有")
    }

    func testArtworkShareContentUsesUnifiedShareTextFormat() throws {
        let officialURL = try XCTUnwrap(URL(string: "https://example.com/object/1"))
        let artwork = makeArtwork(
            museumID: MuseumIdentifier("met"),
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
            museumID: MuseumIdentifier("shm"),
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
            museumID: MuseumIdentifier("nmc"),
            title: "后母戊鼎",
            description: nil,
            objectURL: officialURL
        )
        let content = try XCTUnwrap(ArtworkShareContent(artwork: artwork))

        XCTAssertEqual(content.shareSheetSubject, "后母戊鼎")
        XCTAssertEqual(content.linkMetadataTitle, "后母戊鼎")
        XCTAssertEqual(content.officialURL, officialURL)
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

struct TestMuseumMetadataSeed: Codable {
    let dataVersion: String
    let updatedAt: Date
    let museums: [MuseumMetadata]
}

func seedTestMuseumMetadata(
    defaults: UserDefaults = UserDefaults(suiteName: SettingsKeys.appGroupID) ?? .standard
) throws {
    let seed = TestMuseumMetadataSeed(
        dataVersion: "test-metadata",
        updatedAt: Date(timeIntervalSince1970: 1),
        museums: testMuseumMetadata()
    )
    let data = try JSONEncoder().encode(seed)
    defaults.set(data, forKey: "museum.metadata.snapshot.v1")
    defaults.synchronize()
}

func testMuseumMetadata() -> [MuseumMetadata] {
    [
        testMuseum(
            id: MuseumIdentifier("nmc"),
            name: "中国国家博物馆",
            country: "中国",
            city: "北京",
            iconAssetName: "NmcHomepageLogo",
            sortOrder: 10,
            textPunctuationStyle: .chinese,
            supportsTranslation: false,
            source: MuseumSourceMetadata(
                sourceKey: "nmc_api",
                displayName: "中国国家博物馆 App API",
                isDefault: true,
                translationSourceLanguage: nil,
                preferredImageURLOrder: [.primary, .thumbnail],
                imageRequestHeaders: [:]
            ),
            categories: [
                MuseumCategoryMetadata(sourceKey: "nmc_api", categoryID: "archaeology", displayName: "考古发掘品", sortOrder: 10)
            ],
            waterfallQPS: 1
        ),
        testMuseum(
            id: MuseumIdentifier("shm"),
            name: "上海博物馆",
            country: "中国",
            city: "上海",
            iconAssetName: "ShmHomepageLogo",
            sortOrder: 20,
            textPunctuationStyle: .chinese,
            supportsTranslation: false,
            source: MuseumSourceMetadata(
                sourceKey: "shm_web",
                displayName: "上海博物馆官网",
                isDefault: true,
                translationSourceLanguage: nil,
                preferredImageURLOrder: [.primary, .thumbnail],
                imageRequestHeaders: [:]
            ),
            categories: [
                MuseumCategoryMetadata(sourceKey: "shm_web", categoryID: "礼器", displayName: "礼器", sortOrder: 10)
            ]
        ),
        MuseumMetadata(
            id: MuseumIdentifier("met"),
            displayName: "大都会艺术博物馆",
            subtitle: "纽约",
            country: "美国",
            city: "纽约",
            address: nil,
            textPunctuationStyle: .western,
            icon: MuseumIconMetadata(url: nil, assetName: "MetHomepageLogo", backgroundColor: nil),
            sortOrder: 30,
            capabilities: MuseumCapabilities(supportsWidgetContent: true, supportsTranslation: true, supportsFavorites: true),
            defaultSourceKey: "met_all",
            sources: [
                MuseumSourceMetadata(
                    sourceKey: "met_all",
                    displayName: "全部展品",
                    isDefault: true,
                    translationSourceLanguage: "en",
                    preferredImageURLOrder: [.primary, .thumbnail],
                    imageRequestHeaders: [:]
                ),
                MuseumSourceMetadata(
                    sourceKey: "met_on_view",
                    displayName: "在展展品",
                    isDefault: false,
                    translationSourceLanguage: "en",
                    preferredImageURLOrder: [.primary, .thumbnail],
                    imageRequestHeaders: [:]
                )
            ],
            categories: [
                MuseumCategoryMetadata(sourceKey: "met_all", categoryID: "american-decorative-arts", displayName: "美国装饰艺术", sortOrder: 10),
                MuseumCategoryMetadata(sourceKey: "met_all", categoryID: "modern-art", displayName: "现代艺术", sortOrder: 20),
                MuseumCategoryMetadata(sourceKey: "met_all", categoryID: "asian-art", displayName: "亚洲艺术", sortOrder: 30),
                MuseumCategoryMetadata(sourceKey: "met_on_view", categoryID: "american-decorative-arts", displayName: "美国装饰艺术", sortOrder: 10),
                MuseumCategoryMetadata(sourceKey: "met_on_view", categoryID: "modern-art", displayName: "现代艺术", sortOrder: 20),
                MuseumCategoryMetadata(sourceKey: "met_on_view", categoryID: "asian-art", displayName: "亚洲艺术", sortOrder: 30)
            ],
            waterfallImageFetchPolicy: WaterfallImageFetchPolicy(qps: nil)
        ),
        testMuseum(
            id: MuseumIdentifier("tnm"),
            name: "东京国立博物馆",
            country: "日本",
            city: "东京",
            iconAssetName: "TnmHomepageLogo",
            sortOrder: 40,
            supportsTranslation: true,
            source: MuseumSourceMetadata(
                sourceKey: "japan_search",
                displayName: "Japan Search",
                isDefault: true,
                translationSourceLanguage: "ja",
                preferredImageURLOrder: [.thumbnail, .primary],
                imageRequestHeaders: testImageRequestHeaders(referer: "https://colbase.nich.go.jp/")
            ),
            categories: [
                MuseumCategoryMetadata(sourceKey: "japan_search", categoryID: "paint", displayName: "绘画", sortOrder: 10)
            ]
        ),
        MuseumMetadata(
            id: MuseumIdentifier("nnm"),
            displayName: "奈良国立博物馆",
            subtitle: "奈良",
            country: "日本",
            city: "奈良",
            address: nil,
            textPunctuationStyle: .western,
            icon: MuseumIconMetadata(url: nil, assetName: "NnmHomepageLogo", backgroundColor: nil),
            sortOrder: 50,
            capabilities: MuseumCapabilities(supportsWidgetContent: true, supportsTranslation: true, supportsFavorites: true),
            defaultSourceKey: "official",
            sources: [
                MuseumSourceMetadata(sourceKey: "official", displayName: "馆方数据源", isDefault: true, translationSourceLanguage: "zh-Hans", preferredImageURLOrder: [.primary, .thumbnail], imageRequestHeaders: testImageRequestHeaders(referer: "https://www.narahaku.go.jp/chinese/collection/")),
                MuseumSourceMetadata(sourceKey: "colbase", displayName: "ColBase", isDefault: false, translationSourceLanguage: "ja", preferredImageURLOrder: [.thumbnail, .primary], imageRequestHeaders: testImageRequestHeaders(referer: "https://colbase.nich.go.jp/"))
            ],
            categories: [
                MuseumCategoryMetadata(sourceKey: "official", categoryID: "official-sculpture", displayName: "雕刻", sortOrder: 10),
                MuseumCategoryMetadata(sourceKey: "official", categoryID: "official-painting", displayName: "绘画", sortOrder: 20),
                MuseumCategoryMetadata(sourceKey: "official", categoryID: "official-calligraphy", displayName: "书迹", sortOrder: 30),
                MuseumCategoryMetadata(sourceKey: "official", categoryID: "official-craft", displayName: "工艺", sortOrder: 40),
                MuseumCategoryMetadata(sourceKey: "official", categoryID: "official-archaeology", displayName: "考古", sortOrder: 50),
                MuseumCategoryMetadata(sourceKey: "official", categoryID: "official-ancient-chinese-bronze", displayName: "中国古代青铜器", sortOrder: 60),
                MuseumCategoryMetadata(sourceKey: "official", categoryID: "official-other", displayName: "其他", sortOrder: 70),
                MuseumCategoryMetadata(sourceKey: "colbase", categoryID: "archeology", displayName: "考古与历史资料", sortOrder: 10),
                MuseumCategoryMetadata(sourceKey: "colbase", categoryID: "ancdoc", displayName: "书迹与古文书", sortOrder: 20),
                MuseumCategoryMetadata(sourceKey: "colbase", categoryID: "paint", displayName: "绘画", sortOrder: 30),
                MuseumCategoryMetadata(sourceKey: "colbase", categoryID: "craft", displayName: "工艺", sortOrder: 40),
                MuseumCategoryMetadata(sourceKey: "colbase", categoryID: "sculpture", displayName: "雕刻", sortOrder: 50),
                MuseumCategoryMetadata(sourceKey: "colbase", categoryID: "ceramic", displayName: "陶瓷", sortOrder: 60),
                MuseumCategoryMetadata(sourceKey: "colbase", categoryID: "metal", displayName: "金属工艺", sortOrder: 70),
                MuseumCategoryMetadata(sourceKey: "colbase", categoryID: "lacquer", displayName: "漆器", sortOrder: 80),
                MuseumCategoryMetadata(sourceKey: "colbase", categoryID: "weaponry", displayName: "刀剑与兵器", sortOrder: 90),
                MuseumCategoryMetadata(sourceKey: "colbase", categoryID: "daw", displayName: "染织", sortOrder: 100)
            ],
            waterfallImageFetchPolicy: WaterfallImageFetchPolicy(qps: nil)
        ),
        testMuseum(
            id: MuseumIdentifier("guimet"),
            name: "吉美国立亚洲艺术博物馆",
            country: "法国",
            city: "巴黎",
            iconAssetName: "GuimetHomepageLogo",
            sortOrder: 60,
            supportsTranslation: true,
            source: MuseumSourceMetadata(
                sourceKey: "guimet_web",
                displayName: "吉美官网中文藏品页",
                isDefault: true,
                translationSourceLanguage: nil,
                preferredImageURLOrder: [.primary, .thumbnail],
                imageRequestHeaders: [:]
            ),
            categories: [
                MuseumCategoryMetadata(sourceKey: "guimet_web", categoryID: "china", displayName: "中国", sortOrder: 10)
            ]
        )
    ]
}

private func testMuseum(
    id: MuseumID,
    name: String,
    country: String,
    city: String,
    iconAssetName: String,
    sortOrder: Int,
    textPunctuationStyle: TextPunctuationStyle = .western,
    supportsTranslation: Bool,
    source: MuseumSourceMetadata,
    categories: [MuseumCategoryMetadata],
    waterfallQPS: Double? = nil
) -> MuseumMetadata {
    MuseumMetadata(
        id: id,
        displayName: name,
        subtitle: city,
        country: country,
        city: city,
        address: nil,
        textPunctuationStyle: textPunctuationStyle,
        icon: MuseumIconMetadata(url: nil, assetName: iconAssetName, backgroundColor: nil),
        sortOrder: sortOrder,
        capabilities: MuseumCapabilities(supportsWidgetContent: true, supportsTranslation: supportsTranslation, supportsFavorites: true),
        defaultSourceKey: source.sourceKey,
        sources: [source],
        categories: categories,
        waterfallImageFetchPolicy: WaterfallImageFetchPolicy(qps: waterfallQPS)
    )
}

private func testImageRequestHeaders(referer: String) -> [String: String] {
    [
        "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
        "Accept": "image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8",
        "Accept-Language": "ja-JP,ja;q=0.9,en-US;q=0.8,zh-CN;q=0.7",
        "Cache-Control": "no-cache",
        "Pragma": "no-cache",
        "Referer": referer
    ]
}
