import Foundation

struct Museum: Identifiable, Hashable, Codable {
    let id: MuseumID
    let displayName: String
    let country: String
    let city: String
    let subtitle: String
}

struct MuseumCountrySection: Identifiable, Hashable {
    let country: String
    let museums: [Museum]

    var id: String { country }
}

struct MuseumCategory: Identifiable, Hashable {
    enum Kind: String {
        case all
        case metDepartment
        case japanSearchType
        case nationalMuseumChinaBucket
        case shanghaiMuseumSubtype
    }

    let museumID: MuseumID
    let id: String
    let displayName: String
    let kind: Kind
    let remoteValue: String?

    var metDepartmentID: Int? {
        guard kind == .metDepartment else { return nil }
        return remoteValue.flatMap(Int.init)
    }

    var japanSearchTypeCode: String? {
        guard kind == .japanSearchType else { return nil }
        return remoteValue
    }

    var nationalMuseumChinaBucketKey: String? {
        guard kind == .nationalMuseumChinaBucket else { return nil }
        return remoteValue
    }

    var nationalMuseumChinaCategoryID: Int? {
        guard kind == .nationalMuseumChinaBucket else { return nil }
        return remoteValue.flatMap(Int.init)
    }

    var shanghaiMuseumSubtype: String? {
        guard kind == .shanghaiMuseumSubtype else { return nil }
        return remoteValue
    }

    var isAll: Bool {
        kind == .all
    }
}

enum MuseumID: String, Codable, CaseIterable, Identifiable, Sendable {
    case met
    case tnm
    case nmc
    case shm

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .met:
            return "大都会艺术博物馆"
        case .tnm:
            return "东京国立博物馆"
        case .nmc:
            return "中国国家博物馆"
        case .shm:
            return "上海博物馆"
        }
    }

    var country: String {
        switch self {
        case .met:
            return "美国"
        case .tnm:
            return "日本"
        case .nmc, .shm:
            return "中国"
        }
    }

    var city: String {
        switch self {
        case .met:
            return "纽约"
        case .tnm:
            return "东京"
        case .nmc:
            return "北京"
        case .shm:
            return "上海"
        }
    }

    var subtitle: String {
        city
    }

    var homepageLogoAssetName: String {
        switch self {
        case .met:
            return "MetHomepageLogo"
        case .tnm:
            return "TnmHomepageLogo"
        case .nmc:
            return "NmcHomepageLogo"
        case .shm:
            return "ShmHomepageLogo"
        }
    }

    var copyrightNotice: String {
        "©\(displayName) 版权所有"
    }

    var supportsTranslation: Bool {
        switch self {
        case .met, .tnm:
            return true
        case .nmc, .shm:
            return false
        }
    }

    var supportsWidgetContent: Bool {
        switch self {
        case .met, .tnm, .nmc, .shm:
            return true
        }
    }

    var usesChinesePunctuation: Bool {
        switch self {
        case .nmc, .shm:
            return true
        case .met, .tnm:
            return false
        }
    }

    var availableFeedCategories: [MuseumCategory] {
        switch self {
        case .met:
            return [
                .all(museumID: self),
                .metDepartment(museumID: self, id: "american-decorative-arts", displayName: "美国装饰艺术", departmentID: 1),
                .metDepartment(museumID: self, id: "ancient-west-asian-art", displayName: "古代西亚艺术", departmentID: 3),
                .metDepartment(museumID: self, id: "arms-and-armor", displayName: "武器与盔甲", departmentID: 4),
                .metDepartment(museumID: self, id: "africa-oceania-americas", displayName: "非洲、大洋洲与美洲艺术", departmentID: 5),
                .metDepartment(museumID: self, id: "asian-art", displayName: "亚洲艺术", departmentID: 6),
                .metDepartment(museumID: self, id: "the-cloisters", displayName: "修道院分馆", departmentID: 7),
                .metDepartment(museumID: self, id: "costume-institute", displayName: "服装学院", departmentID: 8),
                .metDepartment(museumID: self, id: "drawings-and-prints", displayName: "素描与版画", departmentID: 9),
                .metDepartment(museumID: self, id: "egyptian-art", displayName: "古埃及艺术", departmentID: 10),
                .metDepartment(museumID: self, id: "european-paintings", displayName: "欧洲绘画", departmentID: 11),
                .metDepartment(museumID: self, id: "european-sculpture-and-decorative-arts", displayName: "欧洲雕塑与装饰艺术", departmentID: 12),
                .metDepartment(museumID: self, id: "greek-and-roman-art", displayName: "古希腊与古罗马艺术", departmentID: 13),
                .metDepartment(museumID: self, id: "islamic-art", displayName: "伊斯兰艺术", departmentID: 14),
                .metDepartment(museumID: self, id: "robert-lehman-collection", displayName: "罗伯特·雷曼收藏", departmentID: 15),
                .metDepartment(museumID: self, id: "libraries", displayName: "图书馆藏", departmentID: 16),
                .metDepartment(museumID: self, id: "medieval-art", displayName: "中世纪艺术", departmentID: 17),
                .metDepartment(museumID: self, id: "musical-instruments", displayName: "乐器", departmentID: 18),
                .metDepartment(museumID: self, id: "photographs", displayName: "摄影", departmentID: 19),
                .metDepartment(museumID: self, id: "modern-art", displayName: "现代艺术", departmentID: 21)
            ]
        case .tnm:
            return [
                .all(museumID: self),
                .japanSearchType(museumID: self, id: "archeology", displayName: "考古与历史资料", typeCode: "archeology"),
                .japanSearchType(museumID: self, id: "paint", displayName: "绘画", typeCode: "paint"),
                .japanSearchType(museumID: self, id: "ancdoc", displayName: "书迹与古文书", typeCode: "ancdoc"),
                .japanSearchType(museumID: self, id: "metal", displayName: "金属工艺", typeCode: "metal"),
                .japanSearchType(museumID: self, id: "ceramic", displayName: "陶瓷", typeCode: "ceramic"),
                .japanSearchType(museumID: self, id: "lacquer", displayName: "漆器", typeCode: "lacquer"),
                .japanSearchType(museumID: self, id: "daw", displayName: "染织", typeCode: "daw"),
                .japanSearchType(museumID: self, id: "weaponry", displayName: "刀剑与兵器", typeCode: "weaponry"),
                .japanSearchType(museumID: self, id: "sculpture", displayName: "雕刻", typeCode: "sculpture"),
                .japanSearchType(museumID: self, id: "arts", displayName: "艺术与美术", typeCode: "arts"),
                .japanSearchType(museumID: self, id: "architecture", displayName: "建筑", typeCode: "architecture")
            ]
        case .nmc:
            return [
                .all(museumID: self),
                .nationalMuseumChinaBucket(museumID: self, id: "archaeology", displayName: "考古发掘品", categoryID: 1),
                .nationalMuseumChinaBucket(museumID: self, id: "revolutionary", displayName: "革命文物", categoryID: 2),
                .nationalMuseumChinaBucket(museumID: self, id: "national-history", displayName: "国史文物", categoryID: 3),
                .nationalMuseumChinaBucket(museumID: self, id: "heirloom", displayName: "传世文物", categoryID: 4),
                .nationalMuseumChinaBucket(museumID: self, id: "currency", displayName: "货币", categoryID: 22),
                .nationalMuseumChinaBucket(museumID: self, id: "rubbings", displayName: "文献拓本", categoryID: 24),
                .nationalMuseumChinaBucket(museumID: self, id: "arts", displayName: "艺术品", categoryID: 26)
            ]
        case .shm:
            return [.all(museumID: self)] + [
                "礼器", "明器", "法器", "道具", "模具/模版", "丧葬用具", "陈设/观赏品", "日用品", "文具", "农具",
                "工具", "兵器", "饪食器", "酒器", "水器", "车马器", "度量衡", "古钱", "铸币", "打制币",
                "机制币", "纸币", "金银锭", "非法定钱币", "雕塑", "造像", "碑刻/墓志", "俑像", "画像石", "画像砖",
                "封泥", "符节（牌）", "印玺", "建筑配件", "器物配件", "织物", "绣品", "服装", "饰品", "文献",
                "书籍图谱", "拓本", "玩具", "乐器"
            ].map { .shanghaiMuseumSubtype(museumID: self, name: $0) }
        }
    }

    var defaultFeedCategory: MuseumCategory {
        availableFeedCategories[0]
    }

    var selectableFeedCategories: [MuseumCategory] {
        availableFeedCategories.filter { !$0.isAll }
    }

    var defaultFeedCategories: [MuseumCategory] {
        selectableFeedCategories
    }

    func feedCategory(withID id: String?) -> MuseumCategory? {
        guard let id else { return defaultFeedCategory }
        return availableFeedCategories.first(where: { $0.id == id }) ?? defaultFeedCategory
    }

    func feedCategories(withStoredValue rawValue: String?) -> [MuseumCategory] {
        let selectable = selectableFeedCategories
        guard !selectable.isEmpty else { return [] }
        guard let rawValue, !rawValue.isEmpty else { return selectable }

        let storedIDs = rawValue
            .split(separator: ",")
            .map { String($0) }

        if storedIDs.isEmpty || storedIDs.contains("all") {
            return selectable
        }

        let storedIDSet = Set(storedIDs)
        let selected = selectable.filter { storedIDSet.contains($0.id) }
        return selected.isEmpty ? selectable : selected
    }

    func normalizedFeedCategories(_ categories: [MuseumCategory]) -> [MuseumCategory] {
        let selectable = selectableFeedCategories
        guard !selectable.isEmpty else { return [] }

        let selectedIDSet = Set(
            categories
                .filter { $0.museumID == self && !$0.isAll }
                .map(\.id)
        )

        let normalized = selectable.filter { selectedIDSet.contains($0.id) }
        return normalized.isEmpty ? selectable : normalized
    }

    func areAllFeedCategoriesSelected(_ categories: [MuseumCategory]) -> Bool {
        normalizedFeedCategories(categories).count == selectableFeedCategories.count
    }

    func feedCategoryStorageValue(for categories: [MuseumCategory]) -> String {
        let normalized = normalizedFeedCategories(categories)
        if normalized.count == selectableFeedCategories.count {
            return "all"
        }
        return normalized.map(\.id).joined(separator: ",")
    }
}

enum MuseumLatencyQuality: Equatable, Sendable {
    case good
    case warning
    case poor
}

struct MuseumLatencyMeasurement: Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case measured(milliseconds: Int)
        case timeout
    }

    let museumID: MuseumID
    let status: Status

    var displayText: String {
        switch status {
        case .measured(let milliseconds):
            return "\(milliseconds) ms"
        case .timeout:
            return "超时"
        }
    }

    var quality: MuseumLatencyQuality {
        switch status {
        case .measured(let milliseconds):
            return Self.quality(forMilliseconds: milliseconds)
        case .timeout:
            return .poor
        }
    }

    static func measured(museumID: MuseumID, milliseconds: Int) -> MuseumLatencyMeasurement {
        MuseumLatencyMeasurement(
            museumID: museumID,
            status: .measured(milliseconds: max(0, milliseconds))
        )
    }

    static func timeout(museumID: MuseumID) -> MuseumLatencyMeasurement {
        MuseumLatencyMeasurement(museumID: museumID, status: .timeout)
    }

    static func quality(forMilliseconds milliseconds: Int) -> MuseumLatencyQuality {
        if milliseconds <= 500 {
            return .good
        }
        if milliseconds <= 1_500 {
            return .warning
        }
        return .poor
    }
}

final class MuseumLatencyService: @unchecked Sendable {
    private enum Constants {
        static let timeoutInterval: TimeInterval = 5
    }

    private let session: URLSession
    private let now: @Sendable () -> Date
    private let timeoutInterval: TimeInterval

    init(
        session: URLSession = .shared,
        timeoutInterval: TimeInterval = Constants.timeoutInterval,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.session = session
        self.timeoutInterval = timeoutInterval
        self.now = now
    }

    func measureLatencies(for museumIDs: [MuseumID]) async -> [MuseumID: MuseumLatencyMeasurement] {
        await withTaskGroup(of: MuseumLatencyMeasurement.self) { group in
            for museumID in museumIDs {
                group.addTask {
                    await self.measureLatency(for: museumID)
                }
            }

            var measurements: [MuseumID: MuseumLatencyMeasurement] = [:]
            for await measurement in group {
                measurements[measurement.museumID] = measurement
            }
            return measurements
        }
    }

    func measureLatency(for museumID: MuseumID) async -> MuseumLatencyMeasurement {
        do {
            let request = try makeRequest(for: museumID)
            let start = now()
            let (_, response) = try await session.data(for: request)
            try validate(response: response)
            let milliseconds = Int((now().timeIntervalSince(start) * 1_000).rounded())
            return .measured(museumID: museumID, milliseconds: milliseconds)
        } catch {
            return .timeout(museumID: museumID)
        }
    }

    private func makeRequest(for museumID: MuseumID) throws -> URLRequest {
        switch museumID {
        case .met:
            return try makeGETRequest(
                urlString: "https://collectionapi.metmuseum.org/public/collection/v1/departments"
            )
        case .tnm:
            var components = URLComponents(string: "https://jpsearch.go.jp/api/item/search/jps-cross")
            components?.queryItems = [
                URLQueryItem(name: "f-db", value: "cobas"),
                URLQueryItem(name: "q-contributor", value: "東京国立博物館"),
                URLQueryItem(name: "f-contents", value: "image"),
                URLQueryItem(name: "from", value: "0"),
                URLQueryItem(name: "size", value: "1")
            ]
            guard let url = components?.url else {
                throw URLError(.badURL)
            }

            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = timeoutInterval
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("curl/8.7.1", forHTTPHeaderField: "User-Agent")
            request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
            request.setValue("ja-JP,ja;q=0.9,en-US;q=0.8,zh-CN;q=0.7", forHTTPHeaderField: "Accept-Language")
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            request.setValue("no-cache", forHTTPHeaderField: "Pragma")
            return request
        case .nmc:
            var components = URLComponents(string: "https://appapi.chnmuseum.cn/api/exhibit_list")
            components?.queryItems = [
                URLQueryItem(name: "cate_id", value: "0"),
                URLQueryItem(name: "limit", value: "1"),
                URLQueryItem(name: "page", value: "1"),
                URLQueryItem(name: "p", value: "i"),
                URLQueryItem(name: "son_cate_id", value: "0")
            ]
            guard let url = components?.url else {
                throw URLError(.badURL)
            }

            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = timeoutInterval
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue(Self.mobileUserAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
            request.setValue("zh-CN,zh-Hans;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
            request.setValue("gzip, deflate, br", forHTTPHeaderField: "Accept-Encoding")
            return request
        case .shm:
            let url = URL(string: "https://www.shanghaimuseum.net/mu/frontend/pg/collection/search-antique")!
            let collectionURL = "https://www.shanghaimuseum.net/mu/frontend/pg/collection/antique"
            let body = try JSONSerialization.data(withJSONObject: shanghaiMuseumLatencyPayload(), options: [])

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.httpBody = body
            request.timeoutInterval = timeoutInterval
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
            request.setValue("zh-CN,zh-Hans;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
            request.setValue(Self.mobileUserAgent, forHTTPHeaderField: "User-Agent")
            request.setValue(collectionURL, forHTTPHeaderField: "Referer")
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            request.setValue("no-cache", forHTTPHeaderField: "Pragma")
            return request
        }
    }

    private func makeGETRequest(urlString: String) throws -> URLRequest {
        guard let url = URL(string: urlString) else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeoutInterval
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return request
    }

    private func validate(response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }

    private static let mobileUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    private func shanghaiMuseumLatencyPayload() -> [String: Any] {
        [
            "params": [
                "langCode": "CHINESE",
                "antiqueSourceCode": "ANTIQUE_SOURCE_1",
                "esFlag": true,
                "ai0": "1",
                "ai1": "1",
                "keywords": NSNull(),
                "types": NSNull(),
                "ages": NSNull(),
                "year": NSNull(),
                "place": NSNull(),
                "author": NSNull(),
                "matter": NSNull(),
                "shape": NSNull(),
                "style": NSNull(),
                "subject": NSNull(),
                "subtype": NSNull(),
                "tech": NSNull(),
                "objectFlag": NSNull(),
                "videoFlag": NSNull(),
                "stampFlag": NSNull(),
                "prefaceFlag": NSNull(),
                "donateFlag": NSNull(),
                "unearthFlag": NSNull()
            ],
            "page": 1,
            "limit": 1
        ]
    }
}

enum MuseumRepository {
    static let supportedMuseums: [Museum] = MuseumID.allCases.map {
        Museum(id: $0, displayName: $0.displayName, country: $0.country, city: $0.city, subtitle: $0.subtitle)
    }

    static let widgetSupportedMuseums: [Museum] = supportedMuseums.filter { $0.id.supportsWidgetContent }

    static let homepageCountrySections: [MuseumCountrySection] = {
        homepageCountryOrder.compactMap { country in
            let museums = supportedMuseums.filter { $0.country == country }
            guard !museums.isEmpty else { return nil }
            return MuseumCountrySection(country: country, museums: museums)
        }
    }()

    static let homepageMuseumIDs: [MuseumID] = homepageCountrySections.flatMap { section in
        section.museums.map(\.id)
    }

    static func museum(for id: MuseumID) -> Museum {
        supportedMuseums.first(where: { $0.id == id }) ?? Museum(id: id, displayName: id.displayName, country: id.country, city: id.city, subtitle: id.subtitle)
    }

    static func museums(inPreferredOrder ids: [MuseumID]) -> [Museum] {
        var seen: Set<MuseumID> = []
        var ordered: [Museum] = []

        for id in ids where seen.insert(id).inserted {
            ordered.append(museum(for: id))
        }

        for museum in supportedMuseums where seen.insert(museum.id).inserted {
            ordered.append(museum)
        }

        return ordered
    }

    static func widgetMuseums(inPreferredOrder ids: [MuseumID]) -> [Museum] {
        var seen: Set<MuseumID> = []
        var ordered: [Museum] = []

        for id in ids where id.supportsWidgetContent && seen.insert(id).inserted {
            ordered.append(museum(for: id))
        }

        for museum in widgetSupportedMuseums where seen.insert(museum.id).inserted {
            ordered.append(museum)
        }

        return ordered
    }

    private static let homepageCountryOrder: [String] = {
        var countries: [String] = []
        var seen: Set<String> = []

        if supportedMuseums.contains(where: { $0.country == "中国" }) {
            countries.append("中国")
            seen.insert("中国")
        }

        for museum in supportedMuseums where seen.insert(museum.country).inserted {
            countries.append(museum.country)
        }

        return countries
    }()
}

private extension MuseumCategory {
    static func all(museumID: MuseumID) -> MuseumCategory {
        MuseumCategory(
            museumID: museumID,
            id: "all",
            displayName: "全部",
            kind: .all,
            remoteValue: nil
        )
    }

    static func metDepartment(museumID: MuseumID, id: String, displayName: String, departmentID: Int) -> MuseumCategory {
        MuseumCategory(
            museumID: museumID,
            id: id,
            displayName: displayName,
            kind: .metDepartment,
            remoteValue: String(departmentID)
        )
    }

    static func japanSearchType(museumID: MuseumID, id: String, displayName: String, typeCode: String) -> MuseumCategory {
        MuseumCategory(
            museumID: museumID,
            id: id,
            displayName: displayName,
            kind: .japanSearchType,
            remoteValue: typeCode
        )
    }

    static func nationalMuseumChinaBucket(museumID: MuseumID, id: String, displayName: String, categoryID: Int) -> MuseumCategory {
        MuseumCategory(
            museumID: museumID,
            id: id,
            displayName: displayName,
            kind: .nationalMuseumChinaBucket,
            remoteValue: String(categoryID)
        )
    }

    static func shanghaiMuseumSubtype(museumID: MuseumID, name: String) -> MuseumCategory {
        MuseumCategory(
            museumID: museumID,
            id: name,
            displayName: name,
            kind: .shanghaiMuseumSubtype,
            remoteValue: name
        )
    }
}
