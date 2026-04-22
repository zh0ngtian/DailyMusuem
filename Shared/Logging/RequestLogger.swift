import Darwin
import Foundation

extension Notification.Name {
    static let requestLoggerDidChange = Notification.Name("requestLoggerDidChange")
}

enum WeChatShareDiagnostics {
    static let scheme = "weixin"
    static let urlString = "\(scheme)://"

    static func isSchemeDeclared(in infoDictionary: [String: Any]?) -> Bool {
        guard let rawSchemes = infoDictionary?["LSApplicationQueriesSchemes"] as? [String] else {
            return false
        }

        return rawSchemes.contains { candidate in
            candidate.caseInsensitiveCompare(scheme) == .orderedSame
        }
    }

    static var invalidURLSummary: String {
        "分享失败：无法构造微信 URL（\(urlString)）。"
    }

    static func canOpenFailureSummary(isSchemeDeclared: Bool) -> String {
        if isSchemeDeclared {
            return "分享失败：canOpenURL(\(urlString)) 返回 false，可能未安装微信，或系统当前无法拉起微信。"
        }

        return "分享失败：canOpenURL(\(urlString)) 返回 false，且 Info.plist 未声明 LSApplicationQueriesSchemes=\(scheme)，当前无法准确判断是否已安装微信。"
    }

    static func openFailureSummary(isSchemeDeclared: Bool) -> String {
        let declaration = isSchemeDeclared
            ? "Info.plist 已声明 LSApplicationQueriesSchemes=\(scheme)。"
            : "Info.plist 未声明 LSApplicationQueriesSchemes=\(scheme)。"
        return "分享失败：UIApplication.open(\(urlString)) 回调返回 false。\(declaration)"
    }
}

struct RequestLogEntry: Identifiable, Codable, Hashable {
    let id: UUID
    let timestamp: Date
    let source: String
    let summary: String
    let instanceToken: String?
    let method: String?
    let url: String?
    let statusCode: Int?
    let durationMilliseconds: Int?
}

actor RequestLogger {
    static let shared = RequestLogger()

    private enum Constants {
        static let maxEntryCount = 800
        static let directoryName = "Logs"
        static let fileName = "request-logs.json"
        static let lockFileName = "request-logs.lock"
        static let lockPollIntervalNanoseconds: UInt64 = 100_000_000
        static let lockWaitTimeout: TimeInterval = 5
        static let staleLockThreshold: TimeInterval = 10
    }

    private let directoryURL: URL
    private let fileURL: URL
    private let lockURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(fileManager: FileManager = .default) {
        let baseURL = fileManager.containerURL(forSecurityApplicationGroupIdentifier: SettingsKeys.appGroupID)
            ?? fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        directoryURL = baseURL.appendingPathComponent(Constants.directoryName, isDirectory: true)
        fileURL = directoryURL.appendingPathComponent(Constants.fileName)
        lockURL = directoryURL.appendingPathComponent(Constants.lockFileName)
    }

    func logEvent(
        source: String,
        summary: String,
        instanceToken: String? = nil
    ) async {
        await append(
            RequestLogEntry(
                id: UUID(),
                timestamp: Date(),
                source: source,
                summary: summary,
                instanceToken: instanceToken,
                method: nil,
                url: nil,
                statusCode: nil,
                durationMilliseconds: nil
            )
        )
    }

    func logRequestStart(
        source: String,
        method: String = "GET",
        url: URL,
        instanceToken: String? = nil
    ) async {
        await append(
            RequestLogEntry(
                id: UUID(),
                timestamp: Date(),
                source: source,
                summary: "开始请求",
                instanceToken: instanceToken,
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
        responseBytes: Int,
        instanceToken: String? = nil
    ) async {
        await append(
            RequestLogEntry(
                id: UUID(),
                timestamp: Date(),
                source: source,
                summary: "请求成功，响应 \(responseBytes) bytes",
                instanceToken: instanceToken,
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
        error: Error,
        instanceToken: String? = nil
    ) async {
        await append(
            RequestLogEntry(
                id: UUID(),
                timestamp: Date(),
                source: source,
                summary: "请求失败：\(error.localizedDescription)",
                instanceToken: instanceToken,
                method: method,
                url: url.absoluteString,
                statusCode: nil,
                durationMilliseconds: Int((duration * 1000).rounded())
            )
        )
    }

    func loadEntries() async -> [RequestLogEntry] {
        let entries = loadEntriesFromDisk()
        return entries.sorted { $0.timestamp > $1.timestamp }
    }

    func clear() async {
        await withFileLock {
            try? FileManager.default.removeItem(at: fileURL)
        }
        notifyDidChange()
    }

    private func append(_ entry: RequestLogEntry) async {
        await withFileLock {
            var entries = loadEntriesFromDisk()
            entries.append(entry)
            if entries.count > Constants.maxEntryCount {
                entries.removeFirst(entries.count - Constants.maxEntryCount)
            }
            persist(entries: entries)
        }
        notifyDidChange()
    }

    private func loadEntriesFromDisk() -> [RequestLogEntry] {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? decoder.decode([RequestLogEntry].self, from: data) else {
            return []
        }
        return decoded
    }

    private func persist(entries: [RequestLogEntry]) {
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let data = try encoder.encode(entries)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            // Ignore logging persistence failures to avoid affecting product behavior.
        }
    }

    private func withFileLock(_ operation: () -> Void) async {
        let deadline = Date().addingTimeInterval(Constants.lockWaitTimeout)

        while true {
            do {
                if try acquireLock() {
                    defer { releaseLock() }
                    operation()
                    return
                }
            } catch {
                operation()
                return
            }

            if isStaleLock() {
                releaseLock()
                continue
            }

            if Date() >= deadline {
                operation()
                return
            }

            try? await Task.sleep(nanoseconds: Constants.lockPollIntervalNanoseconds)
        }
    }

    private func acquireLock() throws -> Bool {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let fileDescriptor = open(lockURL.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard fileDescriptor >= 0 else {
            if errno == EEXIST {
                return false
            }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        close(fileDescriptor)
        return true
    }

    private func releaseLock() {
        try? FileManager.default.removeItem(at: lockURL)
    }

    private func isStaleLock() -> Bool {
        guard let values = try? lockURL.resourceValues(forKeys: [.contentModificationDateKey]),
              let modifiedAt = values.contentModificationDate else {
            return false
        }

        return Date().timeIntervalSince(modifiedAt) >= Constants.staleLockThreshold
    }

    private func notifyDidChange() {
        NotificationCenter.default.post(name: .requestLoggerDidChange, object: nil)
    }
}
