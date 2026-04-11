import CryptoKit
import Foundation
import Security
import SwiftUI
import WidgetKit

struct TencentTranslationCredentials {
    let secretID: String
    let secretKey: String
}

struct MiniMaxTranslationCredentials {
    let apiKey: String
}

enum TranslationEngine: String, CaseIterable, Identifiable {
    case tencent
    case miniMax

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .tencent:
            return "腾讯云机器翻译"
        case .miniMax:
            return "MiniMax 大模型翻译"
        }
    }
}

@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    private enum TranslationCredentialError: LocalizedError {
        case incompleteCredentials
        case emptyAPIKey

        var errorDescription: String? {
            switch self {
            case .incompleteCredentials:
                return "SecretId 和 SecretKey 需要同时填写。"
            case .emptyAPIKey:
                return "API Key 不能为空。"
            }
        }
    }

    private enum KeychainEntry {
        static let tencentService = "tech.zh0ngtian.DailyMuseum.tencentTranslation"
        static let miniMaxService = "tech.zh0ngtian.DailyMuseum.miniMaxTranslation"
        static let secretIDAccount = "secretId"
        static let secretKeyAccount = "secretKey"
        static let miniMaxAPIKeyAccount = "apiKey"
    }

    private let defaults: UserDefaults

    @AppStorage(SettingsKeys.widgetRefreshIntervalMinutes, store: UserDefaults(suiteName: SettingsKeys.appGroupID))
    var widgetRefreshIntervalMinutes: Int = WidgetRefreshInterval.oneHour.rawValue

    @AppStorage(SettingsKeys.widgetMuseumScope, store: UserDefaults(suiteName: SettingsKeys.appGroupID))
    var widgetMuseumScopeRawValue: String = WidgetMuseumScope.all.rawValue

    @AppStorage(SettingsKeys.widgetPreferHasImages, store: UserDefaults(suiteName: SettingsKeys.appGroupID))
    var widgetPreferHasImages: Bool = true

    @AppStorage(SettingsKeys.feedRandomOrder, store: UserDefaults(suiteName: SettingsKeys.appGroupID))
    var feedRandomOrder: Bool = true

    @AppStorage(SettingsKeys.museumDisplayOrder, store: UserDefaults(suiteName: SettingsKeys.appGroupID))
    var museumDisplayOrderRawValue: String = ""

    @AppStorage(SettingsKeys.translationEngine, store: UserDefaults(suiteName: SettingsKeys.appGroupID))
    var translationEngineRawValue: String = TranslationEngine.tencent.rawValue

    @Published private(set) var tencentTranslationConfigured: Bool = false
    @Published private(set) var miniMaxTranslationConfigured: Bool = false

    private init() {
        defaults = UserDefaults(suiteName: SettingsKeys.appGroupID) ?? .standard
        migrateLegacyDefaultsIfNeeded()
        tencentTranslationConfigured = tencentTranslationCredentials() != nil
        miniMaxTranslationConfigured = miniMaxTranslationCredentials() != nil
    }

    func widgetMuseumScope() -> WidgetMuseumScope {
        WidgetMuseumScope(rawValue: widgetMuseumScopeRawValue) ?? .all
    }

    func requestWidgetReload() {
        WidgetCenter.shared.reloadAllTimelines()
    }

    func orderedMuseums() -> [Museum] {
        MuseumRepository.museums(inPreferredOrder: orderedMuseumIDs())
    }

    func saveMuseumOrder(_ museums: [Museum]) {
        museumDisplayOrderRawValue = museums.map(\.id.rawValue).joined(separator: ",")
    }

    private func orderedMuseumIDs() -> [MuseumID] {
        let ids = museumDisplayOrderRawValue
            .split(separator: ",")
            .compactMap { MuseumID(rawValue: String($0)) }

        if ids.isEmpty {
            return MuseumID.allCases
        }

        return ids
    }

    private func migrateLegacyDefaultsIfNeeded() {
        let legacyStores = [
            UserDefaults(suiteName: SettingsKeys.legacyAppGroupID),
            UserDefaults.standard
        ]

        for key in SettingsKeys.defaultsBackedKeys {
            guard defaults.object(forKey: key) == nil else { continue }

            for store in legacyStores {
                guard let store, let value = store.object(forKey: key) else { continue }
                defaults.set(value, forKey: key)
                break
            }
        }
    }

    func translationEngine() -> TranslationEngine {
        if translationEngineRawValue == "openAI" {
            return .miniMax
        }
        return TranslationEngine(rawValue: translationEngineRawValue) ?? .tencent
    }

    func storedTencentTranslationSecretID() -> String {
        keychainString(service: KeychainEntry.tencentService, account: KeychainEntry.secretIDAccount) ?? ""
    }

    func storedTencentTranslationSecretKey() -> String {
        keychainString(service: KeychainEntry.tencentService, account: KeychainEntry.secretKeyAccount) ?? ""
    }

    func storedMiniMaxTranslationAPIKey() -> String {
        keychainString(service: KeychainEntry.miniMaxService, account: KeychainEntry.miniMaxAPIKeyAccount) ?? ""
    }

    func tencentTranslationCredentials() -> TencentTranslationCredentials? {
        let secretID = normalizedCredentialValue(storedTencentTranslationSecretID())
        let secretKey = normalizedCredentialValue(storedTencentTranslationSecretKey())

        guard !secretID.isEmpty, !secretKey.isEmpty else {
            return nil
        }

        return TencentTranslationCredentials(secretID: secretID, secretKey: secretKey)
    }

    func saveTencentTranslationCredentials(secretID: String, secretKey: String) throws {
        let trimmedSecretID = normalizedCredentialValue(secretID)
        let trimmedSecretKey = normalizedCredentialValue(secretKey)

        guard !trimmedSecretID.isEmpty, !trimmedSecretKey.isEmpty else {
            throw TranslationCredentialError.incompleteCredentials
        }

        try upsertKeychainString(trimmedSecretID, service: KeychainEntry.tencentService, account: KeychainEntry.secretIDAccount)
        try upsertKeychainString(trimmedSecretKey, service: KeychainEntry.tencentService, account: KeychainEntry.secretKeyAccount)
        tencentTranslationConfigured = true
    }

    func clearTencentTranslationCredentials() throws {
        try deleteKeychainValue(service: KeychainEntry.tencentService, account: KeychainEntry.secretIDAccount)
        try deleteKeychainValue(service: KeychainEntry.tencentService, account: KeychainEntry.secretKeyAccount)
        tencentTranslationConfigured = false
    }

    func miniMaxTranslationCredentials() -> MiniMaxTranslationCredentials? {
        let apiKey = normalizedCredentialValue(storedMiniMaxTranslationAPIKey())

        guard !apiKey.isEmpty else {
            return nil
        }

        return MiniMaxTranslationCredentials(apiKey: apiKey)
    }

    func saveMiniMaxTranslationAPIKey(_ apiKey: String) throws {
        let trimmedAPIKey = normalizedCredentialValue(apiKey)

        guard !trimmedAPIKey.isEmpty else {
            throw TranslationCredentialError.emptyAPIKey
        }

        try upsertKeychainString(
            trimmedAPIKey,
            service: KeychainEntry.miniMaxService,
            account: KeychainEntry.miniMaxAPIKeyAccount
        )
        miniMaxTranslationConfigured = true
    }

    func clearMiniMaxTranslationAPIKey() throws {
        try deleteKeychainValue(service: KeychainEntry.miniMaxService, account: KeychainEntry.miniMaxAPIKeyAccount)
        miniMaxTranslationConfigured = false
    }

    private func keychainString(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }

        return value
    }

    private func upsertKeychainString(_ value: String, service: String, account: String) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }

        if updateStatus != errSecItemNotFound {
            throw NSError(
                domain: NSOSStatusErrorDomain,
                code: Int(updateStatus),
                userInfo: nil
            )
        }

        var insertAttributes = query
        insertAttributes[kSecValueData as String] = data
        insertAttributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let addStatus = SecItemAdd(insertAttributes as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw NSError(
                domain: NSOSStatusErrorDomain,
                code: Int(addStatus),
                userInfo: nil
            )
        }
    }

    private func deleteKeychainValue(service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NSError(
                domain: NSOSStatusErrorDomain,
                code: Int(status),
                userInfo: nil
            )
        }
    }

    private func normalizedCredentialValue(_ value: String) -> String {
        value.replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
    }
}

struct TencentTranslationClient {
    private enum Constants {
        static let endpoint = URL(string: "https://tmt.tencentcloudapi.com")!
        static let host = "tmt.tencentcloudapi.com"
        static let service = "tmt"
        static let region = "ap-shanghai"
        static let version = "2018-03-21"
        static let action = "TextTranslate"
        static let algorithm = "TC3-HMAC-SHA256"
        static let contentType = "application/json"
        static let chunkLimit = 5000
    }

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func testCredentials(_ credentials: TencentTranslationCredentials) async throws -> String {
        try await translateText("hello world", source: "auto", credentials: credentials)
    }

    func translate(artwork: Artwork, credentials: TencentTranslationCredentials) async throws -> Artwork {
        let sourceLanguage = artwork.museumID.defaultTranslationSourceLanguage
        let translatedTitle = try await translateIfNeeded(artwork.title, source: sourceLanguage, credentials: credentials)
        let translatedDescription = try await translateIfNeeded(
            artwork.normalizedDescriptionText,
            source: sourceLanguage,
            credentials: credentials
        )
        let translatedMedium = try await translateIfNeeded(artwork.medium, source: sourceLanguage, credentials: credentials)
        let translatedDimensions = try await translateIfNeeded(artwork.dimensions, source: sourceLanguage, credentials: credentials)
        let translatedDepartment = try await translateIfNeeded(artwork.department, source: sourceLanguage, credentials: credentials)
        let translatedCulture = try await translateIfNeeded(artwork.culture, source: sourceLanguage, credentials: credentials)
        let translatedCountry = try await translateIfNeeded(artwork.country, source: sourceLanguage, credentials: credentials)
        let translatedRepository = try await translateIfNeeded(artwork.repository, source: sourceLanguage, credentials: credentials)

        return Artwork(
            id: artwork.id,
            museumID: artwork.museumID,
            objectID: artwork.objectID,
            title: translatedTitle ?? artwork.title,
            artworkDescription: translatedDescription ?? artwork.normalizedDescriptionText,
            artistDisplayName: artwork.artistDisplayName,
            objectDate: artwork.objectDate,
            medium: translatedMedium ?? artwork.medium,
            dimensions: translatedDimensions ?? artwork.dimensions,
            department: translatedDepartment ?? artwork.department,
            culture: translatedCulture ?? artwork.culture,
            country: translatedCountry ?? artwork.country,
            repository: translatedRepository ?? artwork.repository,
            primaryImageURL: artwork.primaryImageURL,
            primaryImageSmallURL: artwork.primaryImageSmallURL,
            objectURL: artwork.objectURL
        )
    }

    private func translateIfNeeded(
        _ text: String?,
        source: String,
        credentials: TencentTranslationCredentials
    ) async throws -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }

        let chunks = chunkedText(from: text, limit: Constants.chunkLimit)
        var translatedChunks: [String] = []
        translatedChunks.reserveCapacity(chunks.count)

        for chunk in chunks {
            translatedChunks.append(try await translateText(chunk, source: source, credentials: credentials))
        }

        let joined = translatedChunks
            .joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }

    private func translateText(
        _ text: String,
        source: String,
        credentials: TencentTranslationCredentials
    ) async throws -> String {
        let requestBody = TencentTranslationRequest(
            SourceText: text,
            Source: source,
            Target: "zh",
            ProjectId: 0
        )
        let encoder = JSONEncoder()
        let bodyData = try encoder.encode(requestBody)
        let payload = String(decoding: bodyData, as: UTF8.self)

        let timestamp = Int(Date().timeIntervalSince1970)
        let date = utcDateString(timestamp: timestamp)
        let authorization = makeAuthorization(
            payload: payload,
            timestamp: timestamp,
            date: date,
            secretID: credentials.secretID,
            secretKey: credentials.secretKey
        )

        var request = URLRequest(url: Constants.endpoint)
        request.httpMethod = "POST"
        request.httpBody = bodyData
        request.timeoutInterval = 20
        request.setValue(Constants.contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(Constants.host, forHTTPHeaderField: "Host")
        request.setValue(Constants.action, forHTTPHeaderField: "X-TC-Action")
        request.setValue("\(timestamp)", forHTTPHeaderField: "X-TC-Timestamp")
        request.setValue(Constants.version, forHTTPHeaderField: "X-TC-Version")
        request.setValue(Constants.region, forHTTPHeaderField: "X-TC-Region")
        request.setValue(authorization, forHTTPHeaderField: "Authorization")

        let logger = RequestLogger.shared
        let start = Date()
        await logger.logRequestStart(source: "腾讯云翻译", method: "POST", url: Constants.endpoint)

        do {
            let (data, response) = try await session.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            try validate(response: response, data: data)
            let decoded = try JSONDecoder().decode(TencentTranslationResponseEnvelope.self, from: data)

            if let apiError = decoded.Response.Error {
                throw TencentTranslationError.apiError(
                    code: apiError.Code,
                    message: apiError.Message
                )
            }

            guard let targetText = decoded.Response.TargetText?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !targetText.isEmpty else {
                throw TencentTranslationError.emptyResult
            }

            await logger.logRequestSuccess(
                source: "腾讯云翻译",
                method: "POST",
                url: Constants.endpoint,
                statusCode: statusCode,
                duration: Date().timeIntervalSince(start),
                responseBytes: data.count
            )
            return targetText
        } catch {
            await logger.logRequestFailure(
                source: "腾讯云翻译",
                method: "POST",
                url: Constants.endpoint,
                duration: Date().timeIntervalSince(start),
                error: error
            )
            throw error
        }
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            return
        }

        guard (200..<300).contains(http.statusCode) else {
            if let decoded = try? JSONDecoder().decode(TencentTranslationResponseEnvelope.self, from: data),
               let apiError = decoded.Response.Error {
                throw TencentTranslationError.apiError(
                    code: apiError.Code,
                    message: apiError.Message
                )
            }
            throw URLError(.badServerResponse)
        }
    }

    private func makeAuthorization(
        payload: String,
        timestamp: Int,
        date: String,
        secretID: String,
        secretKey: String
    ) -> String {
        let canonicalHeaders = [
            "content-type:\(Constants.contentType.lowercased())",
            "host:\(Constants.host)",
            "x-tc-action:\(Constants.action.lowercased())"
        ].joined(separator: "\n") + "\n"

        let signedHeaders = "content-type;host;x-tc-action"
        let canonicalRequest = [
            "POST",
            "/",
            "",
            canonicalHeaders,
            signedHeaders,
            sha256Hex(payload)
        ].joined(separator: "\n")

        let credentialScope = "\(date)/\(Constants.service)/tc3_request"
        let stringToSign = [
            Constants.algorithm,
            "\(timestamp)",
            credentialScope,
            sha256Hex(canonicalRequest)
        ].joined(separator: "\n")

        let secretDate = hmacSHA256(key: Data(("TC3" + secretKey).utf8), message: date)
        let secretService = hmacSHA256(key: secretDate, message: Constants.service)
        let secretSigning = hmacSHA256(key: secretService, message: "tc3_request")
        let signature = hmacSHA256Hex(key: secretSigning, message: stringToSign)

        return "\(Constants.algorithm) Credential=\(secretID)/\(credentialScope), SignedHeaders=\(signedHeaders), Signature=\(signature)"
    }

    private func chunkedText(from text: String, limit: Int) -> [String] {
        guard text.count > limit else {
            return [text]
        }

        var chunks: [String] = []
        var current = ""

        for paragraph in text.components(separatedBy: "\n\n") {
            if paragraph.count > limit {
                if !current.isEmpty {
                    chunks.append(current)
                    current = ""
                }
                chunks.append(contentsOf: paragraphCharacterChunks(paragraph, limit: limit))
                continue
            }

            let candidate = current.isEmpty ? paragraph : "\(current)\n\n\(paragraph)"
            if candidate.count <= limit {
                current = candidate
            } else {
                if !current.isEmpty {
                    chunks.append(current)
                }
                current = paragraph
            }
        }

        if !current.isEmpty {
            chunks.append(current)
        }

        return chunks
    }

    private func paragraphCharacterChunks(_ text: String, limit: Int) -> [String] {
        var chunks: [String] = []
        var start = text.startIndex

        while start < text.endIndex {
            let end = text.index(start, offsetBy: limit, limitedBy: text.endIndex) ?? text.endIndex
            chunks.append(String(text[start..<end]))
            start = end
        }

        return chunks
    }

    private func utcDateString(timestamp: Int) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(timestamp)))
    }

    private func hmacSHA256(key: Data, message: String) -> Data {
        let symmetricKey = SymmetricKey(data: key)
        let signature = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: symmetricKey)
        return Data(signature)
    }

    private func hmacSHA256Hex(key: Data, message: String) -> String {
        hmacSHA256(key: key, message: message).map { String(format: "%02x", $0) }.joined()
    }

    private func sha256Hex(_ message: String) -> String {
        let digest = SHA256.hash(data: Data(message.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

private struct TencentTranslationRequest: Encodable {
    let SourceText: String
    let Source: String
    let Target: String
    let ProjectId: Int
}

private struct TencentTranslationResponseEnvelope: Decodable {
    let Response: TencentTranslationResponse
}

private struct TencentTranslationResponse: Decodable {
    let TargetText: String?
    let Source: String?
    let Target: String?
    let RequestId: String
    let Error: TencentTranslationAPIError?
}

private struct TencentTranslationAPIError: Decodable {
    let Code: String
    let Message: String
}

private enum TencentTranslationError: LocalizedError {
    case apiError(code: String, message: String)
    case emptyResult

    var errorDescription: String? {
        switch self {
        case let .apiError(code, message):
            return "腾讯云翻译失败：\(code) - \(message)"
        case .emptyResult:
            return "腾讯云翻译未返回有效结果。"
        }
    }
}

struct MiniMaxTranslationClient {
    private enum Constants {
        static let endpoint = URL(string: "https://api.minimaxi.com/v1/text/chatcompletion_v2")!
        static let model = "MiniMax-M2.7"
        static let contentType = "application/json"
        static let chunkLimit = 5000
    }

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func testCredentials(_ credentials: MiniMaxTranslationCredentials) async throws -> String {
        try await translateText("hello world", source: "en", credentials: credentials)
    }

    func translate(artwork: Artwork, credentials: MiniMaxTranslationCredentials) async throws -> Artwork {
        let sourceLanguage = artwork.museumID.defaultTranslationSourceLanguage
        let translatedTitle = try await translateIfNeeded(artwork.title, source: sourceLanguage, credentials: credentials)
        let translatedDescription = try await translateIfNeeded(
            artwork.normalizedDescriptionText,
            source: sourceLanguage,
            credentials: credentials
        )
        let translatedMedium = try await translateIfNeeded(artwork.medium, source: sourceLanguage, credentials: credentials)
        let translatedDimensions = try await translateIfNeeded(artwork.dimensions, source: sourceLanguage, credentials: credentials)
        let translatedDepartment = try await translateIfNeeded(artwork.department, source: sourceLanguage, credentials: credentials)
        let translatedCulture = try await translateIfNeeded(artwork.culture, source: sourceLanguage, credentials: credentials)
        let translatedCountry = try await translateIfNeeded(artwork.country, source: sourceLanguage, credentials: credentials)
        let translatedRepository = try await translateIfNeeded(artwork.repository, source: sourceLanguage, credentials: credentials)

        return Artwork(
            id: artwork.id,
            museumID: artwork.museumID,
            objectID: artwork.objectID,
            title: translatedTitle ?? artwork.title,
            artworkDescription: translatedDescription ?? artwork.normalizedDescriptionText,
            artistDisplayName: artwork.artistDisplayName,
            objectDate: artwork.objectDate,
            medium: translatedMedium ?? artwork.medium,
            dimensions: translatedDimensions ?? artwork.dimensions,
            department: translatedDepartment ?? artwork.department,
            culture: translatedCulture ?? artwork.culture,
            country: translatedCountry ?? artwork.country,
            repository: translatedRepository ?? artwork.repository,
            primaryImageURL: artwork.primaryImageURL,
            primaryImageSmallURL: artwork.primaryImageSmallURL,
            objectURL: artwork.objectURL
        )
    }

    private func translateIfNeeded(
        _ text: String?,
        source: String,
        credentials: MiniMaxTranslationCredentials
    ) async throws -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }

        let chunks = chunkedText(from: text, limit: Constants.chunkLimit)
        var translatedChunks: [String] = []
        translatedChunks.reserveCapacity(chunks.count)

        for chunk in chunks {
            translatedChunks.append(try await translateText(chunk, source: source, credentials: credentials))
        }

        let joined = translatedChunks
            .joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }

    private func translateText(
        _ text: String,
        source: String,
        credentials: MiniMaxTranslationCredentials
    ) async throws -> String {
        let systemPrompt = """
        You translate museum content from \(source) into Simplified Chinese.
        Return only the translated text.
        Preserve paragraph breaks and line breaks.
        Do not add explanations, quotes, bullet points, prefixes, or markdown.
        """

        let requestBody = MiniMaxTranslationRequest(
            model: Constants.model,
            messages: [
                .init(role: "system", name: "MiniMax AI", text: systemPrompt),
                .init(role: "user", name: "用户", text: text)
            ]
        )
        let encoder = JSONEncoder()
        let bodyData = try encoder.encode(requestBody)

        var request = URLRequest(url: Constants.endpoint)
        request.httpMethod = "POST"
        request.httpBody = bodyData
        request.timeoutInterval = 30
        request.setValue(Constants.contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(credentials.apiKey)", forHTTPHeaderField: "Authorization")

        let logger = RequestLogger.shared
        let start = Date()
        await logger.logRequestStart(source: "MiniMax 翻译", method: "POST", url: Constants.endpoint)

        do {
            let (data, response) = try await session.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            try validate(response: response, data: data)

            let decoded = try JSONDecoder().decode(MiniMaxTranslationResponse.self, from: data)
            let text = decoded.choices.first?.message.content.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty else {
                throw MiniMaxTranslationError.emptyResult
            }

            await logger.logRequestSuccess(
                source: "MiniMax 翻译",
                method: "POST",
                url: Constants.endpoint,
                statusCode: statusCode,
                duration: Date().timeIntervalSince(start),
                responseBytes: data.count
            )
            return text
        } catch {
            await logger.logRequestFailure(
                source: "MiniMax 翻译",
                method: "POST",
                url: Constants.endpoint,
                duration: Date().timeIntervalSince(start),
                error: error
            )
            throw error
        }
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            return
        }

        guard (200..<300).contains(http.statusCode) else {
            if let decoded = try? JSONDecoder().decode(MiniMaxTranslationResponse.self, from: data),
               let message = decoded.baseResp.statusMsg.nilIfEmpty {
                throw MiniMaxTranslationError.apiError(message: message)
            }
            throw URLError(.badServerResponse)
        }
    }

    private func chunkedText(from text: String, limit: Int) -> [String] {
        guard text.count > limit else {
            return [text]
        }

        var chunks: [String] = []
        var current = ""

        for paragraph in text.components(separatedBy: "\n\n") {
            if paragraph.count > limit {
                if !current.isEmpty {
                    chunks.append(current)
                    current = ""
                }
                chunks.append(contentsOf: paragraphCharacterChunks(paragraph, limit: limit))
                continue
            }

            let candidate = current.isEmpty ? paragraph : "\(current)\n\n\(paragraph)"
            if candidate.count <= limit {
                current = candidate
            } else {
                if !current.isEmpty {
                    chunks.append(current)
                }
                current = paragraph
            }
        }

        if !current.isEmpty {
            chunks.append(current)
        }

        return chunks
    }

    private func paragraphCharacterChunks(_ text: String, limit: Int) -> [String] {
        var chunks: [String] = []
        var start = text.startIndex

        while start < text.endIndex {
            let end = text.index(start, offsetBy: limit, limitedBy: text.endIndex) ?? text.endIndex
            chunks.append(String(text[start..<end]))
            start = end
        }

        return chunks
    }
}

private struct MiniMaxTranslationRequest: Encodable {
    let model: String
    let messages: [MiniMaxTranslationMessage]
}

private struct MiniMaxTranslationMessage: Encodable {
    let role: String
    let name: String
    let text: String

    enum CodingKeys: String, CodingKey {
        case role
        case name
        case text = "content"
    }
}

private struct MiniMaxTranslationResponse: Decodable {
    let choices: [MiniMaxTranslationChoice]
    let baseResp: MiniMaxBaseResponse

    enum CodingKeys: String, CodingKey {
        case choices
        case baseResp = "base_resp"
    }
}

private struct MiniMaxTranslationChoice: Decodable {
    let message: MiniMaxTranslationMessageContent
}

private struct MiniMaxTranslationMessageContent: Decodable {
    let content: String
}

private struct MiniMaxBaseResponse: Decodable {
    let statusCode: Int
    let statusMsg: String

    enum CodingKeys: String, CodingKey {
        case statusCode = "status_code"
        case statusMsg = "status_msg"
    }
}

private enum MiniMaxTranslationError: LocalizedError {
    case apiError(message: String)
    case emptyResult

    var errorDescription: String? {
        switch self {
        case let .apiError(message):
            return "MiniMax 翻译失败：\(message)"
        case .emptyResult:
            return "MiniMax 翻译未返回有效结果。"
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
