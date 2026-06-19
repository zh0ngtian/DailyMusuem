import Foundation
import CryptoKit

enum MuseumBackendEnvironment {
    static var defaultBaseURL: URL {
        if let rawValue = Bundle.main.object(forInfoDictionaryKey: "MuseumBackendBaseURL") as? String,
           let url = URL(string: rawValue.trimmingCharacters(in: .whitespacesAndNewlines)),
           url.scheme != nil {
            return url
        }

        if let rawValue = ProcessInfo.processInfo.environment["MUSEUMMUSE_BACKEND_BASE_URL"],
           let url = URL(string: rawValue.trimmingCharacters(in: .whitespacesAndNewlines)),
           url.scheme != nil {
            return url
        }

        return URL(string: "http://127.0.0.1:8000")!
    }
}

enum MuseumBackendDataVersionCache {
    private static let lock = NSLock()
    private static var storedDataVersion = "unknown"

    static var current: String {
        lock.lock()
        defer { lock.unlock() }
        return storedDataVersion
    }

    static func update(_ dataVersion: String) {
        let trimmed = dataVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        lock.lock()
        storedDataVersion = trimmed
        lock.unlock()
    }
}

protocol MuseumBackendAuthProviding: Sendable {
    func authenticatedHeaders(
        method: String,
        path: String,
        queryItems: [URLQueryItem],
        body: Data?
    ) async throws -> [String: String]
}

struct MuseumBackendLocalAuthProvider: MuseumBackendAuthProviding {
    func authenticatedHeaders(
        method: String,
        path: String,
        queryItems: [URLQueryItem],
        body: Data?
    ) async throws -> [String: String] {
        [
            "X-MuseumMuse-App-Version": Self.appVersion,
            "X-MuseumMuse-Auth-Mode": "local-disabled"
        ]
    }

    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let shortVersion = info?["CFBundleShortVersionString"] as? String
        let build = info?["CFBundleVersion"] as? String
        return [shortVersion, build]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

enum MuseumBackendAuthProviderFactory {
    static func defaultProvider(baseURL: URL, session: URLSession) -> MuseumBackendAuthProviding {
        if let secret = MuseumBackendDebugAuthProvider.configuredSecret {
            return MuseumBackendDebugAuthProvider(baseURL: baseURL, session: session, secret: secret)
        }
        return MuseumBackendLocalAuthProvider()
    }
}

actor MuseumBackendDebugAuthProvider: MuseumBackendAuthProviding {
    struct Session: Sendable {
        let accessToken: String
        let expiresAt: Int
    }

    private let baseURL: URL
    private let session: URLSession
    private let secret: String
    private let deviceID: String
    private let keyID: String
    private let appVersion: String
    private var registered = false
    private var currentSession: Session?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        baseURL: URL,
        session: URLSession = .shared,
        secret: String,
        deviceID: String? = nil,
        keyID: String = "debug-key",
        appVersion: String = MuseumBackendLocalAuthProvider.appVersion
    ) {
        self.baseURL = baseURL
        self.session = session
        self.secret = secret
        self.deviceID = deviceID ?? Self.defaultDeviceID
        self.keyID = keyID
        self.appVersion = appVersion.isEmpty ? "unknown" : appVersion
    }

    func authenticatedHeaders(
        method: String,
        path: String,
        queryItems: [URLQueryItem],
        body: Data?
    ) async throws -> [String: String] {
        try await registerIfNeeded()
        let authSession = try await validSession()
        let timestamp = String(Int(Date().timeIntervalSince1970))
        let nonce = UUID().uuidString
        let requestHash = Self.canonicalRequestHash(
            method: method,
            path: path,
            queryItems: queryItems,
            body: body ?? Data(),
            timestamp: timestamp,
            nonce: nonce
        )
        return [
            "Authorization": "Bearer \(authSession.accessToken)",
            "X-MuseumMuse-Timestamp": timestamp,
            "X-MuseumMuse-Nonce": nonce,
            "X-MuseumMuse-Request-Hash": requestHash,
            "X-MuseumMuse-App-Attest-KeyID": keyID,
            "X-MuseumMuse-App-Attest-Assertion": Self.debugAssertion(for: requestHash, secret: secret),
            "X-MuseumMuse-App-Version": appVersion
        ]
    }

    private func registerIfNeeded() async throws {
        guard !registered else { return }
        let challenge = try await fetchChallenge()
        let payload = DebugRegistrationRequest(
            deviceID: deviceID,
            keyID: keyID,
            challenge: challenge.challenge,
            assertion: Self.debugAssertion(for: challenge.challenge, secret: secret),
            appVersion: appVersion
        )
        let _: DebugRegistrationResponse = try await post(path: "/v1/auth/register", payload: payload)
        registered = true
    }

    private func validSession() async throws -> Session {
        let now = Int(Date().timeIntervalSince1970)
        if let currentSession, currentSession.expiresAt > now + 60 {
            return currentSession
        }
        let challenge = try await fetchChallenge()
        let payload = DebugSessionRequest(
            deviceID: deviceID,
            keyID: keyID,
            challenge: challenge.challenge,
            assertion: Self.debugAssertion(for: challenge.challenge, secret: secret),
            appVersion: appVersion
        )
        let response: DebugSessionResponse = try await post(path: "/v1/auth/session", payload: payload)
        let nextSession = Session(accessToken: response.accessToken, expiresAt: response.expiresAt)
        currentSession = nextSession
        return nextSession
    }

    private func fetchChallenge() async throws -> DebugChallengeResponse {
        let emptyPayload = EmptyAuthPayload()
        return try await post(path: "/v1/auth/challenge", payload: emptyPayload)
    }

    private func post<RequestBody: Encodable, ResponseBody: Decodable>(
        path: String,
        payload: RequestBody
    ) async throws -> ResponseBody {
        var request = URLRequest(url: try authURL(path: path))
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(payload)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw MuseumBackendError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return try decoder.decode(ResponseBody.self, from: data)
    }

    private func authURL(path: String) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw URLError(.badURL)
        }
        let basePath = components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let relativePath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let joinedPath = [basePath, relativePath].filter { !$0.isEmpty }.joined(separator: "/")
        components.percentEncodedPath = "/" + joinedPath
        components.queryItems = nil
        guard let url = components.url else { throw URLError(.badURL) }
        return url
    }

    static func canonicalRequestHash(
        method: String,
        path: String,
        queryItems: [URLQueryItem],
        body: Data,
        timestamp: String,
        nonce: String
    ) -> String {
        var queryPairs: [(name: String, value: String)] = []
        for item in queryItems {
            queryPairs.append((name: item.name, value: item.value ?? ""))
        }
        queryPairs.sort { lhs, rhs in
            lhs.name == rhs.name ? lhs.value < rhs.value : lhs.name < rhs.name
        }
        let canonicalQuery = queryPairs
            .map { item -> String in
                let encodedName = formURLEncoded(item.name)
                let encodedValue = formURLEncoded(item.value)
                return "\(encodedName)=\(encodedValue)"
            }
            .joined(separator: "&")
        let bodyHash = sha256Hex(body)
        let canonical = [
            method.uppercased(),
            path,
            canonicalQuery,
            bodyHash,
            timestamp,
            nonce
        ].joined(separator: "\n")
        return sha256Hex(Data(canonical.utf8))
    }

    static func debugAssertion(for value: String, secret: String) -> String {
        let key = SymmetricKey(data: Data(secret.utf8))
        let signature = HMAC<SHA256>.authenticationCode(for: Data(value.utf8), using: key)
        return signature.map { String(format: "%02x", $0) }.joined()
    }

    static var configuredSecret: String? {
        if let rawValue = Bundle.main.object(forInfoDictionaryKey: "MuseumBackendDebugAuthSecret") as? String,
           let secret = nonEmptyTrimmed(rawValue) {
            return secret
        }
        guard let rawValue = ProcessInfo.processInfo.environment["MUSEUMMUSE_DEBUG_AUTH_SECRET"] else {
            return nil
        }
        return nonEmptyTrimmed(rawValue)
    }

    private static var defaultDeviceID: String {
        let key = "MuseumBackendDebugDeviceID"
        if let stored = UserDefaults.standard.string(forKey: key), !stored.isEmpty {
            return stored
        }
        let value = UUID().uuidString
        UserDefaults.standard.set(value, forKey: key)
        return value
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func nonEmptyTrimmed(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func formURLEncoded(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value
            .addingPercentEncoding(withAllowedCharacters: allowed)?
            .replacingOccurrences(of: "%20", with: "+") ?? value
    }
}

private struct EmptyAuthPayload: Encodable {}

private struct DebugChallengeResponse: Decodable {
    let challenge: String
    let expiresAt: Int
    let mode: String
}

private struct DebugRegistrationRequest: Encodable {
    let deviceID: String
    let keyID: String
    let challenge: String
    let assertion: String
    let appVersion: String
}

private struct DebugRegistrationResponse: Decodable {
    let deviceID: String
    let keyID: String
    let registered: Bool
}

private struct DebugSessionRequest: Encodable {
    let deviceID: String
    let keyID: String
    let challenge: String
    let assertion: String
    let appVersion: String
}

private struct DebugSessionResponse: Decodable {
    let accessToken: String
    let tokenType: String
    let expiresAt: Int
}

struct ArtworkListQuery: Sendable {
    enum Order: String, Sendable {
        case stable
        case random
    }

    let museumID: MuseumID
    let source: String?
    let categoryIDs: [String]
    let limit: Int
    let cursor: String?
    let order: Order
    let seed: Int?
    let onlyOnView: Bool
    let hasImage: Bool
    let cachePolicy: MuseumRequestCachePolicy

    init(
        museumID: MuseumID,
        source: String? = nil,
        categoryIDs: [String] = [],
        limit: Int = 10,
        cursor: String? = nil,
        order: Order = .stable,
        seed: Int? = nil,
        onlyOnView: Bool = false,
        hasImage: Bool = true,
        cachePolicy: MuseumRequestCachePolicy = .useCaches
    ) {
        self.museumID = museumID
        self.source = source
        self.categoryIDs = categoryIDs
        self.limit = limit
        self.cursor = cursor
        self.order = order
        self.seed = seed
        self.onlyOnView = onlyOnView
        self.hasImage = hasImage
        self.cachePolicy = cachePolicy
    }
}

struct WidgetCandidateQuery: Sendable {
    let scope: WidgetMuseumScope
    let source: String?
    let categoryIDs: [String]
    let excludeKeys: [String]
    let cachePolicy: MuseumRequestCachePolicy
}

struct ArtworkPageDTO: Sendable, Equatable {
    let dataVersion: String
    let items: [Artwork]
    let nextCursor: String?
    let hasMore: Bool
}

struct BackendMuseumDTO: Decodable, Equatable {
    let museumID: MuseumID
    let displayName: String
    let country: String
    let city: String
    let subtitle: String
    let supportsWidgetContent: Bool
}

struct BackendMuseumCategoryDTO: Decodable, Equatable {
    let museumID: MuseumID
    let id: String
    let displayName: String
    let kind: MuseumCategory.Kind
    let remoteValue: String?

    func toMuseumCategory() -> MuseumCategory {
        MuseumCategory(
            museumID: museumID,
            id: id,
            displayName: displayName,
            kind: kind,
            remoteValue: remoteValue
        )
    }
}

final class MuseumBackendClient: @unchecked Sendable {
    static let shared = MuseumBackendClient()

    private let baseURL: URL
    private let session: URLSession
    private let authProvider: MuseumBackendAuthProviding
    private let decoder: JSONDecoder

    init(
        baseURL: URL = MuseumBackendEnvironment.defaultBaseURL,
        session: URLSession = .shared,
        authProvider: MuseumBackendAuthProviding? = nil
    ) {
        self.baseURL = baseURL
        self.session = session
        self.authProvider = authProvider ?? MuseumBackendAuthProviderFactory.defaultProvider(baseURL: baseURL, session: session)
        decoder = JSONDecoder()
    }

    func health(cachePolicy: MuseumRequestCachePolicy = .networkOnly) async throws {
        let request = try await makeRequest(
            method: "GET",
            path: "/health",
            queryItems: [],
            body: nil,
            cachePolicy: cachePolicy
        )
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
    }

    func probe(museumID: MuseumID, cachePolicy: MuseumRequestCachePolicy = .networkOnly) async throws {
        let request = try await makeRequest(
            method: "GET",
            path: "/v1/museums/\(museumID.rawValue)/probe",
            queryItems: [],
            body: nil,
            cachePolicy: cachePolicy
        )
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        if let envelope = try? decoder.decode(BackendEnvelope<BackendProbePayload>.self, from: data) {
            MuseumBackendDataVersionCache.update(envelope.dataVersion)
        }
    }

    func museums(cachePolicy: MuseumRequestCachePolicy = .useCaches) async throws -> [BackendMuseumDTO] {
        let envelope: BackendEnvelope<[BackendMuseumDTO]> = try await get(
            path: "/v1/museums",
            queryItems: [],
            cachePolicy: cachePolicy
        )
        MuseumBackendDataVersionCache.update(envelope.dataVersion)
        return envelope.data
    }

    func categories(
        museumID: MuseumID,
        source: String?,
        cachePolicy: MuseumRequestCachePolicy = .useCaches
    ) async throws -> [MuseumCategory] {
        var queryItems: [URLQueryItem] = []
        if let source {
            queryItems.append(URLQueryItem(name: "source", value: source))
        }

        let envelope: BackendEnvelope<[BackendMuseumCategoryDTO]> = try await get(
            path: "/v1/museums/\(museumID.rawValue)/categories",
            queryItems: queryItems,
            cachePolicy: cachePolicy
        )
        MuseumBackendDataVersionCache.update(envelope.dataVersion)
        return envelope.data.map { $0.toMuseumCategory() }
    }

    func artworks(query: ArtworkListQuery) async throws -> ArtworkPageDTO {
        let envelope: BackendEnvelope<BackendArtworkPageData> = try await get(
            path: "/v1/museums/\(query.museumID.rawValue)/artworks",
            queryItems: query.queryItems,
            cachePolicy: query.cachePolicy
        )
        let items = try envelope.data.items.map { try $0.toArtwork() }
        MuseumBackendDataVersionCache.update(envelope.dataVersion)
        return ArtworkPageDTO(
            dataVersion: envelope.dataVersion,
            items: items,
            nextCursor: envelope.data.nextCursor,
            hasMore: envelope.data.hasMore
        )
    }

    func artwork(
        museumID: MuseumID,
        objectID: String,
        source: String? = nil,
        cachePolicy: MuseumRequestCachePolicy = .useCaches
    ) async throws -> Artwork {
        var queryItems: [URLQueryItem] = []
        if let source {
            queryItems.append(URLQueryItem(name: "source", value: source))
        }
        let pathObjectID = objectID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? objectID
        let envelope: BackendEnvelope<BackendArtworkDTO> = try await get(
            path: "/v1/museums/\(museumID.rawValue)/artworks/\(pathObjectID)",
            queryItems: queryItems,
            cachePolicy: cachePolicy
        )
        MuseumBackendDataVersionCache.update(envelope.dataVersion)
        return try envelope.data.toArtwork()
    }

    func widgetCandidate(query: WidgetCandidateQuery) async throws -> Artwork? {
        let envelope: BackendEnvelope<BackendWidgetCandidateData> = try await get(
            path: "/v1/widget/candidate",
            queryItems: query.queryItems,
            cachePolicy: query.cachePolicy
        )
        MuseumBackendDataVersionCache.update(envelope.dataVersion)
        return try envelope.data.artwork?.toArtwork()
    }

    private func get<T: Decodable>(
        path: String,
        queryItems: [URLQueryItem],
        cachePolicy: MuseumRequestCachePolicy
    ) async throws -> T {
        let request = try await makeRequest(
            method: "GET",
            path: path,
            queryItems: queryItems,
            body: nil,
            cachePolicy: cachePolicy
        )
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        return try decoder.decode(T.self, from: data)
    }

    private func makeRequest(
        method: String,
        path: String,
        queryItems: [URLQueryItem],
        body: Data?,
        cachePolicy: MuseumRequestCachePolicy
    ) async throws -> URLRequest {
        let url = try makeURL(path: path, queryItems: queryItems)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.cachePolicy = cachePolicy == .networkOnly ? .reloadIgnoringLocalCacheData : .useProtocolCachePolicy
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let headers = try await authProvider.authenticatedHeaders(
            method: method,
            path: url.path,
            queryItems: queryItems,
            body: body
        )
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }

    private func makeURL(path: String, queryItems: [URLQueryItem]) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw URLError(.badURL)
        }

        let basePath = components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let relativePath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let joinedPath = [basePath, relativePath]
            .filter { !$0.isEmpty }
            .joined(separator: "/")
        components.percentEncodedPath = "/" + joinedPath
        components.queryItems = queryItems.isEmpty ? nil : queryItems

        guard let url = components.url else {
            throw URLError(.badURL)
        }
        return url
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            if let errorEnvelope = try? decoder.decode(BackendErrorEnvelope.self, from: data) {
                throw MuseumBackendError.server(
                    statusCode: http.statusCode,
                    code: errorEnvelope.error.code,
                    message: errorEnvelope.error.message
                )
            }
            throw MuseumBackendError.httpStatus(http.statusCode)
        }
    }
}

enum MuseumBackendError: LocalizedError, Equatable {
    case invalidMuseumID(String)
    case httpStatus(Int)
    case server(statusCode: Int, code: String, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidMuseumID(let value):
            return "未知博物馆：\(value)"
        case .httpStatus(let statusCode):
            return "服务端请求失败：HTTP \(statusCode)"
        case .server(_, _, let message):
            return message
        }
    }
}

private extension ArtworkListQuery {
    var queryItems: [URLQueryItem] {
        var items: [URLQueryItem] = [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "order", value: order.rawValue),
            URLQueryItem(name: "has_image", value: hasImage ? "true" : "false")
        ]
        if let source {
            items.append(URLQueryItem(name: "source", value: source))
        }
        if !categoryIDs.isEmpty {
            items.append(URLQueryItem(name: "category_ids", value: categoryIDs.joined(separator: ",")))
        }
        if let cursor {
            items.append(URLQueryItem(name: "cursor", value: cursor))
        }
        if let seed {
            items.append(URLQueryItem(name: "seed", value: String(seed)))
        }
        if onlyOnView {
            items.append(URLQueryItem(name: "only_on_view", value: "true"))
        }
        return items
    }
}

private extension WidgetCandidateQuery {
    var queryItems: [URLQueryItem] {
        var items: [URLQueryItem] = [
            URLQueryItem(name: "scope", value: scope.rawValue)
        ]
        if let source {
            items.append(URLQueryItem(name: "source", value: source))
        }
        if !categoryIDs.isEmpty {
            items.append(URLQueryItem(name: "category_ids", value: categoryIDs.joined(separator: ",")))
        }
        if !excludeKeys.isEmpty {
            items.append(URLQueryItem(name: "exclude_keys", value: excludeKeys.joined(separator: ",")))
        }
        return items
    }
}

private struct BackendEnvelope<T: Decodable>: Decodable {
    let dataVersion: String
    let data: T
}

private struct BackendProbePayload: Decodable {
    let museumID: String
    let availableArtworkCount: Int
}

private struct BackendArtworkPageData: Decodable {
    let items: [BackendArtworkDTO]
    let nextCursor: String?
    let hasMore: Bool
}

private struct BackendWidgetCandidateData: Decodable {
    let artwork: BackendArtworkDTO?
}

private struct BackendArtworkDTO: Decodable {
    let id: String
    let museumID: String
    let objectID: String
    let title: String
    let artworkDescription: String?
    let artistDisplayName: String?
    let objectDate: String?
    let medium: String?
    let dimensions: String?
    let department: String?
    let culture: String?
    let country: String?
    let repository: String?
    let primaryImageURL: String?
    let primaryImageSmallURL: String?
    let objectURL: String?

    func toArtwork() throws -> Artwork {
        guard let museumID = MuseumID(rawValue: museumID) else {
            throw MuseumBackendError.invalidMuseumID(self.museumID)
        }

        return Artwork(
            id: id,
            museumID: museumID,
            objectID: objectID,
            title: title,
            artworkDescription: artworkDescription,
            artistDisplayName: artistDisplayName,
            objectDate: objectDate,
            medium: medium,
            dimensions: dimensions,
            department: department,
            culture: culture,
            country: country,
            repository: repository,
            primaryImageURL: Self.makeURL(primaryImageURL),
            primaryImageSmallURL: Self.makeURL(primaryImageSmallURL),
            objectURL: Self.makeURL(objectURL)
        )
    }

    private static func makeURL(_ rawValue: String?) -> URL? {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else {
            return nil
        }
        return URL(string: rawValue)
    }
}

private struct BackendErrorEnvelope: Decodable {
    let error: BackendErrorPayload
}

private struct BackendErrorPayload: Decodable {
    let code: String
    let message: String
}
