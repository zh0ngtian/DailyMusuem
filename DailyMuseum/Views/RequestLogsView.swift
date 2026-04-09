import SwiftUI

@MainActor
final class RequestLogsViewModel: ObservableObject {
    @Published private(set) var entries: [RequestLogEntry] = []
    @Published private(set) var isLoading = false

    func refresh() async {
        isLoading = true
        entries = await RequestLogger.shared.loadEntries()
        isLoading = false
    }

    func clear() async {
        await RequestLogger.shared.clear()
        entries = []
    }
}

struct RequestLogsView: View {
    @StateObject private var viewModel = RequestLogsViewModel()

    var body: some View {
        Group {
            if viewModel.entries.isEmpty, !viewModel.isLoading {
                ContentUnavailableView(
                    "暂无日志",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("后台请求发生后会显示在这里。")
                )
            } else {
                List(viewModel.entries) { entry in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .top) {
                            Text(entry.source)
                                .font(.headline)
                            Spacer(minLength: 8)
                            Text(Self.timestampFormatter.string(from: entry.timestamp))
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
                .listStyle(.plain)
            }
        }
        .navigationTitle("请求日志")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("清空") {
                    Task {
                        await viewModel.clear()
                    }
                }
                .disabled(viewModel.entries.isEmpty)
            }
        }
        .task {
            await viewModel.refresh()
        }
        .refreshable {
            await viewModel.refresh()
        }
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss"
        return formatter
    }()
}
