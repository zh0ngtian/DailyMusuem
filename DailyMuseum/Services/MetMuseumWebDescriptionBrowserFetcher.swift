import Foundation
import WebKit

@MainActor
final class MetMuseumWebDescriptionBrowserFetcher {
    static let shared = MetMuseumWebDescriptionBrowserFetcher()

    private var activeFetches: [UUID: MetMuseumBrowserPageFetch] = [:]

    private init() {}

    func fetchDescription(from objectURL: URL) async -> String? {
        for url in MetMuseumAPI.webDescriptionCandidateURLs(from: objectURL) {
            if let description = await fetchSingleDescription(from: url) {
                return description
            }
        }

        return nil
    }

    private func fetchSingleDescription(from url: URL) async -> String? {
        let fetch = MetMuseumBrowserPageFetch(url: url)
        activeFetches[fetch.id] = fetch
        defer { activeFetches[fetch.id] = nil }

        return await fetch.start()
    }
}

@MainActor
private final class MetMuseumBrowserPageFetch: NSObject, WKNavigationDelegate {
    let id = UUID()

    private let url: URL
    private let webView: WKWebView
    private var continuation: CheckedContinuation<String?, Never>?
    private var pollTask: Task<Void, Never>?

    init(url: URL) {
        self.url = url

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.suppressesIncrementalRendering = true

        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
        webView.isHidden = true

        super.init()

        webView.navigationDelegate = self
    }

    deinit {
        pollTask?.cancel()
        webView.navigationDelegate = nil
        webView.stopLoading()
    }

    func start() async -> String? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation

            var request = URLRequest(url: url)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
            request.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
            webView.load(request)
            startPolling()
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(with: nil)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(with: nil)
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { @MainActor [weak self] in
            guard let self else { return }

            let deadline = Date().addingTimeInterval(15)
            while Date() < deadline {
                if let description = await currentDescription() {
                    finish(with: description)
                    return
                }

                try? await Task.sleep(nanoseconds: 750_000_000)
            }

            finish(with: nil)
        }
    }

    private func currentDescription() async -> String? {
        guard let html = try? await webView.evaluateJavaScript("document.documentElement.outerHTML") as? String else {
            return nil
        }

        return MetMuseumAPI.extractWebDescription(from: html)
    }

    private func finish(with description: String?) {
        guard let continuation else {
            return
        }

        self.continuation = nil
        pollTask?.cancel()
        pollTask = nil
        continuation.resume(returning: description)
    }
}
