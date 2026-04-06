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

    private let url: URL?
    private var task: Task<Void, Never>?
    private var retryCount = 0

    init(url: URL?) {
        self.url = url
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
                image = cached
                retryCount = 0
                return
            }

            while !Task.isCancelled {
                do {
                    let (data, response) = try await URLSession.shared.data(from: url)
                    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                        throw URLError(.badServerResponse)
                    }
                    guard let downloaded = UIImage(data: data) else {
                        throw URLError(.cannotDecodeContentData)
                    }
                    await ImageMemoryCache.shared.setImage(downloaded, for: url)
                    image = downloaded
                    error = nil
                    retryCount = 0
                    return
                } catch is CancellationError {
                    return
                } catch {
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
