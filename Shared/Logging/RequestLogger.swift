import Foundation

extension Notification.Name {
    static let requestLoggerDidChange = Notification.Name("requestLoggerDidChange")
}

struct RequestLogEntry: Identifiable, Codable, Hashable {
    let id: UUID
    let timestamp: Date
    let source: String
    let summary: String
    let method: String?
    let url: String?
    let statusCode: Int?
    let durationMilliseconds: Int?
}

actor RequestLogger {
    static let shared = RequestLogger()

    private enum Constants {
        static let maxEntryCount = 800
        static let fileName = "request-logs.json"
    }

    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var cachedEntries: [RequestLogEntry]?

    init(fileManager: FileManager = .default) {
        let baseURL = fileManager.containerURL(forSecurityApplicationGroupIdentifier: SettingsKeys.appGroupID)
            ?? fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let directoryURL = baseURL.appendingPathComponent("Logs", isDirectory: true)
        fileURL = directoryURL.appendingPathComponent(Constants.fileName)
    }

    func logEvent(source: String, summary: String) async {
        await append(
            RequestLogEntry(
                id: UUID(),
                timestamp: Date(),
                source: source,
                summary: summary,
                method: nil,
                url: nil,
                statusCode: nil,
                durationMilliseconds: nil
            )
        )
    }

    func logRequestStart(source: String, method: String = "GET", url: URL) async {
        await append(
            RequestLogEntry(
                id: UUID(),
                timestamp: Date(),
                source: source,
                summary: "开始请求",
                method: method,
                url: url.absoluteString,
                statusCode: nil,
                durationMilliseconds: nil
            )
        )
    }

    func logRequestSuccess(
        source: String,
        method: String = "GET",
        url: URL,
        statusCode: Int,
        duration: TimeInterval,
        responseBytes: Int
    ) async {
        await append(
            RequestLogEntry(
                id: UUID(),
                timestamp: Date(),
                source: source,
                summary: "请求成功，响应 \(responseBytes) bytes",
                method: method,
                url: url.absoluteString,
                statusCode: statusCode,
                durationMilliseconds: Int((duration * 1000).rounded())
            )
        )
    }

    func logRequestFailure(
        source: String,
        method: String = "GET",
        url: URL,
        duration: TimeInterval,
        error: Error
    ) async {
        await append(
            RequestLogEntry(
                id: UUID(),
                timestamp: Date(),
                source: source,
                summary: "请求失败：\(error.localizedDescription)",
                method: method,
                url: url.absoluteString,
                statusCode: nil,
                durationMilliseconds: Int((duration * 1000).rounded())
            )
        )
    }

    func loadEntries() async -> [RequestLogEntry] {
        let entries = await cachedOrDiskEntries()
        return entries.sorted { $0.timestamp > $1.timestamp }
    }

    func clear() async {
        cachedEntries = []
        try? FileManager.default.removeItem(at: fileURL)
        notifyDidChange()
    }

    private func append(_ entry: RequestLogEntry) async {
        var entries = await cachedOrDiskEntries()
        entries.append(entry)
        if entries.count > Constants.maxEntryCount {
            entries.removeFirst(entries.count - Constants.maxEntryCount)
        }
        cachedEntries = entries
        await persist(entries: entries)
        notifyDidChange()
    }

    private func cachedOrDiskEntries() async -> [RequestLogEntry] {
        if let cachedEntries {
            return cachedEntries
        }
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? decoder.decode([RequestLogEntry].self, from: data) else {
            cachedEntries = []
            return []
        }
        cachedEntries = decoded
        return decoded
    }

    private func persist(entries: [RequestLogEntry]) async {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try encoder.encode(entries)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            // Ignore logging persistence failures to avoid affecting product behavior.
        }
    }

    private func notifyDidChange() {
        NotificationCenter.default.post(name: .requestLoggerDidChange, object: nil)
    }
}
