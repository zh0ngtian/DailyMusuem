import Foundation
import XCTest

final class ParsingAndAPITests: XCTestCase {
    func testMuseumBackendClientDecodesDynamicMuseumMetadata() async throws {
        let recorder = RequestRecorder()
        let session = makeStubSession(testID: UUID().uuidString) { request in
            guard let url = request.url else {
                throw URLError(.badURL)
            }
            recorder.record(request)
            XCTAssertEqual(url.path, "/v1/museums/metadata")

            return StubbedResponse(
                response: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                data: try JSONSerialization.data(withJSONObject: [
                    "dataVersion": "metadata-version",
                    "data": [
                        "museums": [
                            [
                                "museumID": "nmc",
                                "displayName": "中国国家博物馆",
                                "subtitle": "北京",
                                "country": "中国",
                                "city": "北京",
                                "address": NSNull(),
                                "textPunctuationStyle": "chinese",
                                "icon": [
                                    "url": NSNull(),
                                    "assetName": "NmcHomepageLogo",
                                    "backgroundColor": NSNull()
                                ],
                                "sortOrder": 10,
                                "capabilities": [
                                    "supportsWidgetContent": true,
                                    "supportsTranslation": false,
                                    "supportsFavorites": true
                                ],
                                "defaultSourceKey": "nmc_api",
                                "sources": [
                                    [
                                        "sourceKey": "nmc_api",
                                        "displayName": "中国国家博物馆 App API",
                                        "isDefault": true,
                                        "translationSourceLanguage": NSNull(),
                                        "preferredImageURLOrder": ["primary", "thumbnail"],
                                        "imageRequestHeaders": [:]
                                    ]
                                ],
                                "categories": [],
                                "waterfallImageFetchPolicy": [
                                    "qps": 1
                                ]
                            ],
                            [
                                "museumID": "met",
                                "displayName": "大都会艺术博物馆",
                                "subtitle": "纽约",
                                "country": "美国",
                                "city": "纽约",
                                "address": "1000 5th Ave",
                                "textPunctuationStyle": "western",
                                "icon": [
                                    "url": "https://example.com/met.png",
                                    "assetName": "MetHomepageLogo",
                                    "backgroundColor": "#F4EFE8"
                                ],
                                "sortOrder": 30,
                                "capabilities": [
                                    "supportsWidgetContent": true,
                                    "supportsTranslation": true,
                                    "supportsFavorites": true
                                ],
                                "defaultSourceKey": "met_all",
                                "sources": [
                                    [
                                        "sourceKey": "met_all",
                                        "displayName": "全部展品",
                                        "isDefault": true,
                                        "translationSourceLanguage": "en",
                                        "preferredImageURLOrder": ["primary", "thumbnail"],
                                        "imageRequestHeaders": [:]
                                    ],
                                    [
                                        "sourceKey": "met_on_view",
                                        "displayName": "在展展品",
                                        "isDefault": false,
                                        "translationSourceLanguage": "en",
                                        "preferredImageURLOrder": ["primary", "thumbnail"],
                                        "imageRequestHeaders": [:]
                                    ]
                                ],
                                "categories": [
                                    [
                                        "sourceKey": "met_all",
                                        "categoryID": "asian-art",
                                        "displayName": "亚洲艺术",
                                        "sortOrder": 50
                                    ],
                                    [
                                        "sourceKey": "met_on_view",
                                        "categoryID": "asian-art",
                                        "displayName": "亚洲艺术",
                                        "sortOrder": 50
                                    ]
                                ],
                                "waterfallImageFetchPolicy": [
                                    "qps": NSNull()
                                ]
                            ]
                        ]
                    ]
                ])
            )
        }
        let client = MuseumBackendClient(baseURL: URL(string: "https://backend.example")!, session: session)

        let snapshot = try await client.museumMetadata()
        let museums = Dictionary(uniqueKeysWithValues: snapshot.museums.map { ($0.id.rawValue, $0) })

        XCTAssertEqual(snapshot.dataVersion, "metadata-version")
        XCTAssertEqual(recorder.requests.map { $0.url?.path }, ["/v1/museums/metadata"])
        XCTAssertEqual(museums["nmc"]?.waterfallImageFetchPolicy.qps, 1)
        XCTAssertTrue(museums["nmc"]?.waterfallImageFetchPolicy.isRateLimited == true)
        XCTAssertNil(museums["met"]?.waterfallImageFetchPolicy.qps)
        XCTAssertEqual(museums["met"]?.defaultSourceKey, "met_all")
        XCTAssertEqual(museums["met"]?.sources.map(\.sourceKey), ["met_all", "met_on_view"])
        XCTAssertEqual(museums["met"]?.sources.first?.translationSourceLanguage, "en")
        XCTAssertEqual(museums["met"]?.sources.first?.preferredImageURLOrder, [.primary, .thumbnail])
        XCTAssertEqual(museums["met"]?.categories.first?.categoryID, "asian-art")
        XCTAssertEqual(museums["met"]?.icon.url?.absoluteString, "https://example.com/met.png")
        XCTAssertEqual(museums["met"]?.icon.assetName, "MetHomepageLogo")
    }

    func testMuseumMetadataStorePersistsSnapshotAndFiltersCategories() async throws {
        let suiteName = "MuseumMetadataStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let nmcID = MuseumIdentifier("nmc")
        let metID = MuseumIdentifier("met")
        let snapshot = MuseumMetadataSnapshot(
            dataVersion: "metadata-version",
            museums: [
                MuseumMetadata(
                    id: nmcID,
                    displayName: "中国国家博物馆",
                    subtitle: "北京",
                    country: "中国",
                    city: "北京",
                    address: nil,
                    textPunctuationStyle: .chinese,
                    icon: MuseumIconMetadata(url: nil, assetName: "NmcHomepageLogo", backgroundColor: nil),
                    sortOrder: 10,
                    capabilities: MuseumCapabilities(
                        supportsWidgetContent: true,
                        supportsTranslation: false,
                        supportsFavorites: true
                    ),
                    defaultSourceKey: "nmc_api",
                    sources: [
                        MuseumSourceMetadata(
                            sourceKey: "nmc_api",
                            displayName: "中国国家博物馆 App API",
                            isDefault: true,
                            translationSourceLanguage: nil,
                            preferredImageURLOrder: [.primary, .thumbnail],
                            imageRequestHeaders: [:]
                        )
                    ],
                    categories: [
                        MuseumCategoryMetadata(
                            sourceKey: "nmc_api",
                            categoryID: "archaeology",
                            displayName: "考古发掘品",
                            sortOrder: 10
                        )
                    ],
                    waterfallImageFetchPolicy: WaterfallImageFetchPolicy(qps: 1)
                ),
                MuseumMetadata(
                    id: metID,
                    displayName: "大都会艺术博物馆",
                    subtitle: "纽约",
                    country: "美国",
                    city: "纽约",
                    address: nil,
                    textPunctuationStyle: .western,
                    icon: MuseumIconMetadata(url: nil, assetName: "MetHomepageLogo", backgroundColor: nil),
                    sortOrder: 30,
                    capabilities: MuseumCapabilities(
                        supportsWidgetContent: true,
                        supportsTranslation: true,
                        supportsFavorites: true
                    ),
                    defaultSourceKey: "met_all",
                    sources: [
                        MuseumSourceMetadata(
                            sourceKey: "met_all",
                            displayName: "全部展品",
                            isDefault: true,
                            translationSourceLanguage: "en",
                            preferredImageURLOrder: [.primary, .thumbnail],
                            imageRequestHeaders: [:]
                        )
                    ],
                    categories: [
                        MuseumCategoryMetadata(
                            sourceKey: "met_all",
                            categoryID: "asian-art",
                            displayName: "亚洲艺术",
                            sortOrder: 50
                        )
                    ],
                    waterfallImageFetchPolicy: WaterfallImageFetchPolicy(qps: nil)
                )
            ]
        )
        let store = MuseumMetadataStore(defaults: defaults) { cachePolicy in
            XCTAssertEqual(cachePolicy, .networkOnly)
            return snapshot
        }

        let refreshedMuseums = try await store.refresh(cachePolicy: .networkOnly)
        let reloadedStore = MuseumMetadataStore(defaults: defaults) { _ in
            XCTFail("Reloaded store should read from defaults without refreshing")
            return MuseumMetadataSnapshot(dataVersion: "unexpected", museums: [])
        }

        XCTAssertEqual(refreshedMuseums.map(\.id.rawValue), ["nmc", "met"])
        let cachedSnapshot = await reloadedStore.cachedSnapshot()
        let reloadedCategoryIDs = await reloadedStore.categories(museumID: metID, sourceKey: nil).map(\.categoryID)
        let nmcWaterfallPolicy = await reloadedStore.waterfallImageFetchPolicy(museumID: nmcID)
        let metWaterfallPolicy = await reloadedStore.waterfallImageFetchPolicy(museumID: metID)
        XCTAssertEqual(cachedSnapshot?.dataVersion, "metadata-version")
        XCTAssertEqual(reloadedCategoryIDs, ["asian-art"])
        XCTAssertEqual(nmcWaterfallPolicy.qps, 1)
        XCTAssertNil(metWaterfallPolicy.qps)

        defaults.removePersistentDomain(forName: suiteName)
    }

    func testMuseumBackendDebugAuthProviderIssuesSignedBusinessHeaders() async throws {
        let recorder = RequestRecorder()
        let session = makeStubSession(testID: UUID().uuidString) { request in
            guard let url = request.url else {
                throw URLError(.badURL)
            }
            recorder.record(request)

            let json: [String: Any]
            switch url.path {
            case "/v1/auth/challenge":
                let challenge = recorder.requests.count == 1 ? "register-challenge" : "session-challenge"
                json = [
                    "challenge": challenge,
                    "expiresAt": 4_102_444_800,
                    "mode": "debug"
                ]
            case "/v1/auth/register":
                json = [
                    "deviceID": "device-1",
                    "keyID": "debug-key",
                    "registered": true
                ]
            case "/v1/auth/session":
                json = [
                    "accessToken": "debug-session-token",
                    "tokenType": "Bearer",
                    "expiresAt": 4_102_444_800
                ]
            default:
                XCTFail("Unexpected auth URL: \(url.absoluteString)")
                json = [:]
            }

            return StubbedResponse(
                response: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                data: try JSONSerialization.data(withJSONObject: json)
            )
        }
        let provider = MuseumBackendDebugAuthProvider(
            baseURL: URL(string: "https://backend.example")!,
            session: session,
            secret: "debug-secret",
            deviceID: "device-1",
            appVersion: "1.0 1"
        )

        let headers = try await provider.authenticatedHeaders(
            method: "GET",
            path: "/v1/museums",
            queryItems: [
                URLQueryItem(name: "limit", value: "10"),
                URLQueryItem(name: "category", value: "space value")
            ],
            body: nil
        )

        XCTAssertEqual(
            recorder.requests.compactMap { $0.url?.path },
            ["/v1/auth/challenge", "/v1/auth/register", "/v1/auth/challenge", "/v1/auth/session"]
        )
        XCTAssertEqual(headers["Authorization"], "Bearer debug-session-token")
        XCTAssertEqual(headers["X-MuseumMuse-App-Attest-KeyID"], "debug-key")
        XCTAssertEqual(headers["X-MuseumMuse-App-Version"], "1.0 1")

        let timestamp = try XCTUnwrap(headers["X-MuseumMuse-Timestamp"])
        let nonce = try XCTUnwrap(headers["X-MuseumMuse-Nonce"])
        let expectedHash = MuseumBackendDebugAuthProvider.canonicalRequestHash(
            method: "GET",
            path: "/v1/museums",
            queryItems: [
                URLQueryItem(name: "limit", value: "10"),
                URLQueryItem(name: "category", value: "space value")
            ],
            body: Data(),
            timestamp: timestamp,
            nonce: nonce
        )
        XCTAssertEqual(headers["X-MuseumMuse-Request-Hash"], expectedHash)
        XCTAssertEqual(
            headers["X-MuseumMuse-App-Attest-Assertion"],
            MuseumBackendDebugAuthProvider.debugAssertion(for: expectedHash, secret: "debug-secret")
        )
    }

    func testMuseumBackendSimpleAuthProviderIssuesSignedBusinessHeaders() async throws {
        let provider = MuseumBackendSimpleAuthProvider(secret: "simple-secret", appVersion: "1.0 1")

        let headers = try await provider.authenticatedHeaders(
            method: "GET",
            path: "/v1/widget/candidate",
            queryItems: [
                URLQueryItem(name: "scope", value: "all"),
                URLQueryItem(name: "category_ids", value: "space value")
            ],
            body: nil
        )

        XCTAssertEqual(headers["X-MuseumMuse-Auth-Mode"], "simple")
        XCTAssertEqual(headers["X-MuseumMuse-App-Version"], "1.0 1")
        XCTAssertNil(headers["X-MuseumMuse-App-Attest-KeyID"])
        XCTAssertNil(headers["X-MuseumMuse-App-Attest-Assertion"])

        let timestamp = try XCTUnwrap(headers["X-MuseumMuse-Timestamp"])
        let nonce = try XCTUnwrap(headers["X-MuseumMuse-Nonce"])
        let expectedHash = MuseumBackendRequestSigner.canonicalRequestHash(
            method: "GET",
            path: "/v1/widget/candidate",
            queryItems: [
                URLQueryItem(name: "scope", value: "all"),
                URLQueryItem(name: "category_ids", value: "space value")
            ],
            body: Data(),
            timestamp: timestamp,
            nonce: nonce
        )
        XCTAssertEqual(headers["X-MuseumMuse-Request-Hash"], expectedHash)
        XCTAssertEqual(
            headers["Authorization"],
            "Bearer \(MuseumBackendRequestSigner.hmacHex(for: expectedHash, secret: "simple-secret"))"
        )
    }

    private func makeStubSession(
        testID: String,
        handler: @escaping @Sendable (URLRequest) throws -> StubbedResponse
    ) -> URLSession {
        StubURLProtocol.register(handler: handler, for: testID)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        configuration.httpAdditionalHeaders = [StubURLProtocol.testIDHeader: testID]
        return URLSession(configuration: configuration)
    }
}

private struct StubbedResponse {
    let response: HTTPURLResponse
    let data: Data
}

private final class StubURLProtocol: URLProtocol {
    static let testIDHeader = "X-Stub-Test-ID"

    private static var handlers: [String: @Sendable (URLRequest) throws -> StubbedResponse] = [:]
    private static let lock = NSLock()

    static func register(
        handler: @escaping @Sendable (URLRequest) throws -> StubbedResponse,
        for testID: String
    ) {
        lock.lock()
        handlers[testID] = handler
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.value(forHTTPHeaderField: testIDHeader) != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let testID = request.value(forHTTPHeaderField: Self.testIDHeader) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        Self.lock.lock()
        let handler = Self.handlers[testID]
        Self.lock.unlock()

        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        do {
            let stub = try handler(request)
            client?.urlProtocol(self, didReceive: stub.response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: stub.data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class RequestRecorder {
    private let lock = NSLock()
    private(set) var requests: [URLRequest] = []

    func record(_ request: URLRequest) {
        lock.lock()
        requests.append(request)
        lock.unlock()
    }
}
