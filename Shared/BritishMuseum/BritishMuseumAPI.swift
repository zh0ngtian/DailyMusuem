import Foundation

struct BritishMuseumDepartmentIndex: Sendable {
    struct Manifest: Decodable, Sendable {
        struct Department: Decodable, Sendable {
            let departmentID: String
            let departmentRaw: String
            let departmentDisplayName: String
            let count: Int
            let file: String
        }

        let partial: Bool?
        let reportedTotalResults: Int?
        let fetchedPages: Int?
        let departments: [Department]
    }

    struct DepartmentFile: Decodable, Sendable {
        let departmentID: String
        let departmentRaw: String
        let departmentDisplayName: String
        let count: Int
        let objectIDs: [String]
    }

    let manifest: Manifest
    private let departmentFilesByID: [String: DepartmentFile]
    private let departmentIDByObjectID: [String: String]

    static func loadFromBundle(_ bundle: Bundle = .main) throws -> BritishMuseumDepartmentIndex {
        let directoryCandidates = [
            "department_index_partial",
            "british_museum/department_index_partial",
            "data/british_museum/department_index_partial"
        ]

        for subdirectory in directoryCandidates {
            if let manifestURL = bundle.url(
                forResource: "british_museum_department_manifest",
                withExtension: "json",
                subdirectory: subdirectory
            ) {
                let directoryURL = manifestURL.deletingLastPathComponent()
                return try load(
                    manifestURL: manifestURL,
                    departmentFileURL: { file in
                        directoryURL.appendingPathComponent(file)
                    }
                )
            }
        }

        if let manifestURL = bundle.url(forResource: "british_museum_department_manifest", withExtension: "json") {
            return try load(
                manifestURL: manifestURL,
                departmentFileURL: { file in
                    let fileName = (file as NSString).lastPathComponent as NSString
                    return bundle.url(
                        forResource: fileName.deletingPathExtension,
                        withExtension: fileName.pathExtension
                    )
                }
            )
        }

        throw URLError(.fileDoesNotExist)
    }

    static func load(fromDirectory directoryURL: URL) throws -> BritishMuseumDepartmentIndex {
        let manifestURL = directoryURL.appendingPathComponent("british_museum_department_manifest.json")
        return try load(
            manifestURL: manifestURL,
            departmentFileURL: { file in
                directoryURL.appendingPathComponent(file)
            }
        )
    }

    func objectIDs(for categories: [MuseumCategory]) -> [String] {
        let normalized = MuseumID.bm.normalizedFeedCategories(categories)
        let departmentIDs: [String]
        if MuseumID.bm.areAllFeedCategoriesSelected(normalized) {
            departmentIDs = manifest.departments.map(\.departmentID)
        } else {
            departmentIDs = normalized.compactMap(\.britishMuseumDepartmentID)
        }

        var seen: Set<String> = []
        var output: [String] = []
        for departmentID in departmentIDs {
            guard let file = departmentFilesByID[departmentID] else { continue }
            for objectID in file.objectIDs where seen.insert(objectID).inserted {
                output.append(objectID)
            }
        }
        return output
    }

    func departmentDisplayName(for objectID: String) -> String? {
        guard let departmentID = departmentIDByObjectID[objectID] else {
            return nil
        }
        return departmentFilesByID[departmentID]?.departmentDisplayName
    }

    private static func load(
        manifestURL: URL,
        departmentFileURL: (String) -> URL?
    ) throws -> BritishMuseumDepartmentIndex {
        let decoder = JSONDecoder()
        let manifest = try decoder.decode(Manifest.self, from: Data(contentsOf: manifestURL))

        var departmentFilesByID: [String: DepartmentFile] = [:]
        var departmentIDByObjectID: [String: String] = [:]

        for department in manifest.departments {
            guard let fileURL = departmentFileURL(department.file) else {
                throw URLError(.fileDoesNotExist)
            }
            let departmentFile = try decoder.decode(DepartmentFile.self, from: Data(contentsOf: fileURL))
            departmentFilesByID[departmentFile.departmentID] = departmentFile

            for objectID in departmentFile.objectIDs where departmentIDByObjectID[objectID] == nil {
                departmentIDByObjectID[objectID] = departmentFile.departmentID
            }
        }

        return BritishMuseumDepartmentIndex(
            manifest: manifest,
            departmentFilesByID: departmentFilesByID,
            departmentIDByObjectID: departmentIDByObjectID
        )
    }
}

final class BritishMuseumAPI {
    private enum Constants {
        static let baseURL = URL(string: "https://www.britishmuseum.org")!
        static let repositoryName = "大英博物馆"
        static let countryName = "英国"
        static let requestTimeout: TimeInterval = 20
        static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
    }

    private let session: URLSession
    private let responseCache = BritishMuseumResponseCache.shared
    private let indexLoader: @Sendable () throws -> BritishMuseumDepartmentIndex

    init(
        session: URLSession = .shared,
        indexLoader: @escaping @Sendable () throws -> BritishMuseumDepartmentIndex = {
            try BritishMuseumDepartmentIndex.loadFromBundle()
        }
    ) {
        self.session = session
        self.indexLoader = indexLoader
    }

    func objectIDs(
        categories: [MuseumCategory],
        onLog: (@Sendable (String) async -> Void)? = nil
    ) async throws -> [String] {
        await onLog?("检查大英博物馆 Department 离线索引...")
        let index = try await departmentIndex()
        let ids = index.objectIDs(for: categories)
        await onLog?("大英博物馆离线索引已读取，当前类别可用 \(ids.count) 条 objectID。")
        return ids
    }

    func indexedArtwork(objectID: String) async -> Artwork {
        let index = try? await departmentIndex()
        let department = index?.departmentDisplayName(for: objectID)
        return placeholderArtwork(objectID: objectID, department: department)
    }

    func fetchArtwork(
        objectID: String,
        cachePolicy: MuseumRequestCachePolicy = .useCaches
    ) async throws -> Artwork {
        let logger = RequestLogger.shared
        if cachePolicy.usesCaches,
           let cached = await responseCache.artwork(forObjectID: objectID) {
            await logger.logEvent(source: "大英博物馆详情", summary: "命中内存缓存，objectID=\(objectID)")
            return cached
        }

        let objectURL = Self.objectURL(for: objectID)
        let start = Date()
        await logger.logRequestStart(source: "大英博物馆详情", url: objectURL)

        do {
            let (data, response) = try await session.data(for: makeObjectRequest(url: objectURL))
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            try validate(response: response)
            let html = String(decoding: data, as: UTF8.self)
            guard !Self.isCloudflareChallenge(html) else {
                throw URLError(.cannotParseResponse)
            }

            let index = try? await departmentIndex()
            let departmentFallback = index?.departmentDisplayName(for: objectID)
            let artwork = try BritishMuseumObjectPageParser.parse(
                html: html,
                objectID: objectID,
                objectURL: objectURL,
                departmentFallback: departmentFallback
            )
            await logger.logRequestSuccess(
                source: "大英博物馆详情",
                url: objectURL,
                statusCode: statusCode,
                duration: Date().timeIntervalSince(start),
                responseBytes: data.count
            )

            if cachePolicy.usesCaches {
                await responseCache.setArtwork(artwork, forObjectID: objectID)
            }
            return artwork
        } catch {
            await logger.logRequestFailure(
                source: "大英博物馆详情",
                url: objectURL,
                duration: Date().timeIntervalSince(start),
                error: error
            )
            return await indexedArtwork(objectID: objectID)
        }
    }

    static func objectURL(for objectID: String) -> URL {
        Constants.baseURL
            .appendingPathComponent("collection")
            .appendingPathComponent("object")
            .appendingPathComponent(objectID)
    }

    private func departmentIndex() async throws -> BritishMuseumDepartmentIndex {
        if let cached = await responseCache.departmentIndex {
            return cached
        }

        let index = try indexLoader()
        await responseCache.setDepartmentIndex(index)
        return index
    }

    private func placeholderArtwork(objectID: String, department: String?) -> Artwork {
        Artwork(
            id: "bm-\(objectID)",
            museumID: .bm,
            objectID: objectID,
            title: objectID,
            artworkDescription: nil,
            artistDisplayName: nil,
            objectDate: nil,
            medium: nil,
            dimensions: nil,
            department: department,
            culture: nil,
            country: Constants.countryName,
            repository: Constants.repositoryName,
            primaryImageURL: nil,
            primaryImageSmallURL: nil,
            objectURL: Self.objectURL(for: objectID)
        )
    }

    private func makeObjectRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = Constants.requestTimeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(Constants.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("en-GB,en;q=0.9,zh-CN;q=0.8", forHTTPHeaderField: "Accept-Language")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        return request
    }

    private func validate(response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }

    private static func isCloudflareChallenge(_ html: String) -> Bool {
        html.localizedCaseInsensitiveContains("Just a moment")
            && html.localizedCaseInsensitiveContains("challenge-platform")
    }
}

enum BritishMuseumObjectPageParser {
    private static let fieldLabels: Set<String> = [
        "Object Type",
        "Museum number",
        "Title",
        "Description",
        "Cultures/periods",
        "Production date",
        "Artist/maker",
        "Maker",
        "Materials",
        "Technique",
        "Dimensions",
        "Curator's comments",
        "Location",
        "Subjects",
        "Findspot",
        "Made in",
        "Department",
        "Registration number",
        "Acquisition name",
        "Acquisition date",
        "Acquisition notes",
        "Bibliographic references",
        "Conservation"
    ]

    static func parse(
        html: String,
        objectID: String,
        objectURL: URL,
        departmentFallback: String?
    ) throws -> Artwork {
        let lines = normalizedTextLines(from: html)
        let objectType = firstValue(after: "Object Type", in: lines)
        let rawTitle = firstValue(after: "Title", in: lines)
        let title = cleanedTitle(rawTitle) ?? headingTitle(from: html) ?? objectType ?? objectID
        let description = fieldValue(after: "Description", in: lines)
        let curatorComment = fieldValue(after: "Curator's comments", in: lines)
        let combinedDescription = [description, curatorComment]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        let imageURL = primaryImageURL(from: html, baseURL: objectURL)

        return Artwork(
            id: "bm-\(objectID)",
            museumID: .bm,
            objectID: objectID,
            title: title,
            artworkDescription: combinedDescription.isEmpty ? nil : combinedDescription,
            artistDisplayName: firstValue(afterAnyOf: ["Artist/maker", "Maker"], in: lines),
            objectDate: firstValue(after: "Production date", in: lines),
            medium: fieldValue(after: "Materials", in: lines),
            dimensions: fieldValue(after: "Dimensions", in: lines),
            department: firstValue(after: "Department", in: lines) ?? departmentFallback,
            culture: fieldValue(after: "Cultures/periods", in: lines),
            country: firstValue(afterAnyOf: ["Made in", "Findspot"], in: lines),
            repository: "大英博物馆",
            primaryImageURL: imageURL,
            primaryImageSmallURL: imageURL,
            objectURL: objectURL
        )
    }

    private static func normalizedTextLines(from html: String) -> [String] {
        let withoutScripts = html
            .replacingOccurrences(of: "(?is)<script[^>]*>.*?</script>", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "(?is)<style[^>]*>.*?</style>", with: "\n", options: .regularExpression)
        let lineSeparated = withoutScripts
            .replacingOccurrences(of: "(?i)<br\\s*/?>", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "(?i)</(p|div|li|h1|h2|h3|dt|dd|section|tr)>", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)

        return lineSeparated
            .decodingCommonHTMLEntities()
            .components(separatedBy: .newlines)
            .map { $0.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func headingTitle(from html: String) -> String? {
        guard let value = firstRegexCapture(#"<h[12][^>]*>(.*?)</h[12]>"#, in: html) else {
            return nil
        }
        let cleaned = value
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .decodingCommonHTMLEntities()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func cleanedTitle(_ value: String?) -> String? {
        guard var title = value?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            return nil
        }
        title = title.replacingOccurrences(of: #"^Object:\s*"#, with: "", options: [.regularExpression, .caseInsensitive])
        return title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func firstValue(afterAnyOf labels: [String], in lines: [String]) -> String? {
        for label in labels {
            if let value = firstValue(after: label, in: lines) {
                return value
            }
        }
        return nil
    }

    private static func firstValue(after label: String, in lines: [String]) -> String? {
        fieldValue(after: label, in: lines)?
            .components(separatedBy: .newlines)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func fieldValue(after label: String, in lines: [String]) -> String? {
        guard let startIndex = lines.firstIndex(where: { $0.caseInsensitiveCompare(label) == .orderedSame }) else {
            return nil
        }

        var values: [String] = []
        for line in lines.dropFirst(startIndex + 1) {
            if fieldLabels.contains(line) {
                break
            }
            values.append(line)
        }

        let value = values
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func primaryImageURL(from html: String, baseURL: URL) -> URL? {
        let patterns = [
            #"<meta[^>]+property=["']og:image["'][^>]+content=["']([^"']+)["']"#,
            #"<meta[^>]+name=["']twitter:image["'][^>]+content=["']([^"']+)["']"#,
            #"<img[^>]+src=["']([^"']+)["']"#
        ]

        for pattern in patterns {
            let matches = regexCaptures(pattern, in: html)
            for rawValue in matches {
                let value = rawValue.decodingCommonHTMLEntities()
                if let url = normalizedImageURL(from: value, baseURL: baseURL) {
                    return url
                }
            }
        }

        return nil
    }

    private static func normalizedImageURL(from rawValue: String, baseURL: URL) -> URL? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              !value.hasPrefix("data:"),
              !value.contains("challenge-platform"),
              !value.localizedCaseInsensitiveContains("wechat"),
              let rawURL = URL(string: value, relativeTo: baseURL)?.absoluteURL,
              let host = rawURL.host?.lowercased(),
              host.contains("britishmuseum") || host.contains("bmimages") else {
            return nil
        }

        let url: URL
        if rawURL.scheme?.lowercased() == "http",
           var components = URLComponents(url: rawURL, resolvingAgainstBaseURL: false) {
            components.scheme = "https"
            guard let secureURL = components.url else { return nil }
            url = secureURL
        } else {
            url = rawURL
        }

        guard url.scheme?.lowercased() == "https",
              !isDecorativeImageURL(url) else {
            return nil
        }

        return url
    }

    private static func isDecorativeImageURL(_ url: URL) -> Bool {
        let path = url.path.lowercased()
        let lastPathComponent = url.lastPathComponent.lowercased()

        if path.hasSuffix(".svg") || path.hasSuffix(".ico") {
            return true
        }

        let decorativePathFragments = [
            "/themes/",
            "/core/",
            "/modules/",
            "/assets/"
        ]
        if decorativePathFragments.contains(where: { path.contains($0) }) {
            return true
        }

        let decorativeNameFragments = [
            "favicon",
            "icon",
            "logo",
            "placeholder",
            "sprite"
        ]
        return decorativeNameFragments.contains { lastPathComponent.contains($0) }
    }

    private static func firstRegexCapture(_ pattern: String, in text: String) -> String? {
        regexCaptures(pattern, in: text).first
    }

    private static func regexCaptures(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, options: [], range: range).compactMap { match in
            guard match.numberOfRanges > 1,
                  let captureRange = Range(match.range(at: 1), in: text) else {
                return nil
            }
            return String(text[captureRange])
        }
    }
}

private actor BritishMuseumResponseCache {
    static let shared = BritishMuseumResponseCache()

    private var artworksByObjectID: [String: Artwork] = [:]
    private var cachedDepartmentIndex: BritishMuseumDepartmentIndex?

    var departmentIndex: BritishMuseumDepartmentIndex? {
        cachedDepartmentIndex
    }

    func setDepartmentIndex(_ index: BritishMuseumDepartmentIndex) {
        cachedDepartmentIndex = index
    }

    func artwork(forObjectID objectID: String) -> Artwork? {
        artworksByObjectID[objectID]
    }

    func setArtwork(_ artwork: Artwork, forObjectID objectID: String) {
        artworksByObjectID[objectID] = artwork
    }
}
