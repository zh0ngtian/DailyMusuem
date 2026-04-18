import SwiftUI

@MainActor
final class RequestLogsViewModel: ObservableObject {
    private enum Constants {
        static let widgetSyncPollIntervalNanoseconds: UInt64 = 500_000_000
    }

    @Published private(set) var entries: [RequestLogEntry] = []
    @Published private(set) var isLoading = false
    private var liveUpdateTask: Task<Void, Never>?
    private var pollingTask: Task<Void, Never>?

    func refresh(showLoadingState: Bool = true) async {
        if showLoadingState {
            isLoading = true
        }

        let latestEntries = await RequestLogger.shared.loadEntries()
        if entries != latestEntries {
            entries = latestEntries
        }

        if showLoadingState {
            isLoading = false
        }
    }

    func activate() async {
        await refresh()
        guard liveUpdateTask == nil else { return }

        liveUpdateTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .requestLoggerDidChange) {
                guard !Task.isCancelled else { break }
                await self?.refresh(showLoadingState: false)
            }
        }

        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Constants.widgetSyncPollIntervalNanoseconds)
                guard !Task.isCancelled else { break }
                await self?.refresh(showLoadingState: false)
            }
        }
    }

    func deactivate() {
        liveUpdateTask?.cancel()
        liveUpdateTask = nil
        pollingTask?.cancel()
        pollingTask = nil
    }

    func clear() async {
        await RequestLogger.shared.clear()
        entries = []
    }

    deinit {
        liveUpdateTask?.cancel()
        pollingTask?.cancel()
    }
}

struct RequestLogsView: View {
    let onDone: (() -> Void)?

    @StateObject private var viewModel = RequestLogsViewModel()

    init(onDone: (() -> Void)? = nil) {
        self.onDone = onDone
    }

    var body: some View {
        Group {
            if viewModel.entries.isEmpty {
                Form {
                    Section {
                        if viewModel.isLoading {
                            HStack(spacing: 12) {
                                Spacer(minLength: 0)
                                ProgressView()
                                Text("正在加载日志…")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 20)
                        } else {
                            ContentUnavailableView(
                                "暂无日志",
                                systemImage: "doc.text.magnifyingglass",
                                description: Text("后台请求发生后会显示在这里。")
                            )
                            .frame(maxWidth: .infinity, minHeight: 240)
                        }
                    }

                    Section {
                        Text("下拉可刷新；新请求到达后会自动更新。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                List {
                    Section {
                        ForEach(viewModel.entries) { entry in
                            logEntryRow(entry)
                        }
                    }

                    Section {
                        Text("下拉可刷新；新请求到达后会自动更新。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("请求日志")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("清空") {
                    Task {
                        await viewModel.clear()
                    }
                }
                .disabled(viewModel.entries.isEmpty)
            }

            if let onDone {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成", action: onDone)
                }
            }
        }
        .task {
            await viewModel.activate()
        }
        .onDisappear {
            viewModel.deactivate()
        }
        .refreshable {
            await viewModel.refresh()
        }
    }

    private func logEntryRow(_ entry: RequestLogEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Text(entry.source)
                    .font(.headline)
                Spacer(minLength: 8)
                Text(LogTimestampFormatter.requestLogTimestamp(from: entry.timestamp))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(entry.summary)
                .font(.subheadline)

            if let method = entry.method, let url = entry.url {
                Text("\(method) \(url)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            HStack(spacing: 12) {
                if let statusCode = entry.statusCode {
                    Text("状态码 \(statusCode)")
                }
                if let duration = entry.durationMilliseconds {
                    Text("\(duration) ms")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}
