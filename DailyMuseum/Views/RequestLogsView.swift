import SwiftUI

@MainActor
final class RequestLogsViewModel: ObservableObject {
    @Published private(set) var entries: [RequestLogEntry] = []
    @Published private(set) var isLoading = false
    private var liveUpdateTask: Task<Void, Never>?

    func refresh() async {
        isLoading = true
        entries = await RequestLogger.shared.loadEntries()
        isLoading = false
    }

    func activate() async {
        await refresh()
        guard liveUpdateTask == nil else { return }

        liveUpdateTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .requestLoggerDidChange) {
                guard !Task.isCancelled else { break }
                await self?.refresh()
            }
        }
    }

    func deactivate() {
        liveUpdateTask?.cancel()
        liveUpdateTask = nil
    }

    func clear() async {
        await RequestLogger.shared.clear()
        entries = []
    }

    deinit {
        liveUpdateTask?.cancel()
    }
}

struct RequestLogsView: View {
    enum PresentationStyle {
        case screen
        case panel
    }

    enum PanelSizeOption: String, CaseIterable {
        case oneThird = "1/3"
        case half = "1/2"
        case full = "全屏"
    }

    let style: PresentationStyle
    let onClose: (() -> Void)?
    let selectedPanelSizeOption: PanelSizeOption?
    let onSelectPanelSizeOption: ((PanelSizeOption) -> Void)?

    @StateObject private var viewModel = RequestLogsViewModel()

    init(
        style: PresentationStyle = .screen,
        onClose: (() -> Void)? = nil,
        selectedPanelSizeOption: PanelSizeOption? = nil,
        onSelectPanelSizeOption: ((PanelSizeOption) -> Void)? = nil
    ) {
        self.style = style
        self.onClose = onClose
        self.selectedPanelSizeOption = selectedPanelSizeOption
        self.onSelectPanelSizeOption = onSelectPanelSizeOption
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Group {
                if viewModel.entries.isEmpty, !viewModel.isLoading {
                    ContentUnavailableView(
                        "暂无日志",
                        systemImage: "doc.text.magnifyingglass",
                        description: Text("后台请求发生后会显示在这里。")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(.systemBackground))
        .clipShape(
            UnevenRoundedRectangle(
                topLeadingRadius: style == .panel ? 24 : 0,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: style == .panel ? 24 : 0,
                style: .continuous
            )
        )
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

    @ViewBuilder
    private var header: some View {
        VStack(spacing: 10) {
            if style == .panel {
                HStack(spacing: 8) {
                    ForEach(PanelSizeOption.allCases, id: \.self) { option in
                        Button(option.rawValue) {
                            onSelectPanelSizeOption?(option)
                        }
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            (selectedPanelSizeOption == option ? Color.primary : Color.secondary.opacity(0.14)),
                            in: Capsule()
                        )
                        .foregroundStyle(selectedPanelSizeOption == option ? Color(.systemBackground) : .primary)
                    }
                }
            }

            HStack(spacing: 12) {
                Text("请求日志")
                    .font(.headline)
                Spacer()
                Button("清空") {
                    Task {
                        await viewModel.clear()
                    }
                }
                .disabled(viewModel.entries.isEmpty)

                if let onClose {
                    Button {
                        onClose()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(Color(.systemBackground))
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss"
        return formatter
    }()
}
