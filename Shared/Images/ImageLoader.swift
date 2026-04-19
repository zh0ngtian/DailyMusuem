import Foundation
import UIKit

@MainActor
final class ImageLoader: ObservableObject {
    private enum Constants {
        static let maxRetryCount = 3
    }

    @Published private(set) var image: UIImage?
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var error: Error?

    private var url: URL?
    private var task: Task<Void, Never>?
    private var retryCount = 0

    init(url: URL?) {
        self.url = url
    }

    func updateURL(_ newURL: URL?) {
        guard newURL != url else {
            if image == nil, task == nil {
                load()
            }
            return
        }

        task?.cancel()
        task = nil
        retryCount = 0
        error = nil
        image = nil
        url = newURL
        load()
    }

    func load(force: Bool = false) {
        if force {
            task?.cancel()
            task = nil
            retryCount = 0
        }
        guard task == nil else { return }
        guard let url else { return }
        guard image == nil else { return }

        task = Task {
            isLoading = true
            error = nil
            defer {
                isLoading = false
                task = nil
            }

            if let cached = await ImageMemoryCache.shared.image(for: url) {
                await RequestLogger.shared.logEvent(source: "App 图片", summary: "命中内存缓存，\(url.absoluteString)")
                image = cached
                retryCount = 0
                return
            }

            while !Task.isCancelled {
                let start = Date()
                do {
                    await RequestLogger.shared.logRequestStart(source: "App 图片", url: url)
                    let (data, response) = try await URLSession.shared.data(from: url)
                    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                        throw URLError(.badServerResponse)
                    }
                    guard let downloaded = UIImage(data: data) else {
                        throw URLError(.cannotDecodeContentData)
                    }
                    await RequestLogger.shared.logRequestSuccess(
                        source: "App 图片",
                        url: url,
                        statusCode: http.statusCode,
                        duration: Date().timeIntervalSince(start),
                        responseBytes: data.count
                    )
                    await ImageMemoryCache.shared.setImage(downloaded, for: url)
                    image = downloaded
                    error = nil
                    retryCount = 0
                    return
                } catch is CancellationError {
                    return
                } catch {
                    await RequestLogger.shared.logRequestFailure(
                        source: "App 图片",
                        url: url,
                        duration: Date().timeIntervalSince(start),
                        error: error
                    )
                    self.error = error
                    retryCount += 1

                    guard retryCount < Constants.maxRetryCount else {
                        return
                    }

                    let delay = UInt64(retryCount) * 1_000_000_000
                    try? await Task.sleep(nanoseconds: delay)
                }
            }
        }
    }

    func retryIfNeeded() {
        guard image == nil else { return }
        load(force: true)
    }

    deinit {
        task?.cancel()
    }
}
