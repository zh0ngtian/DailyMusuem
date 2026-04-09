import SwiftUI

struct ArtworkFeedView: View {
    let museum: Museum

    @StateObject private var viewModel: ArtworkFeedViewModel
    @StateObject private var settings = SettingsStore.shared
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    init(museum: Museum) {
        self.museum = museum
        _viewModel = StateObject(wrappedValue: ArtworkFeedViewModel(museum: museum))
    }

    var body: some View {
        GeometryReader { proxy in
            Group {
                switch viewModel.state {
                case .idle, .loading:
                    VStack(spacing: 16) {
                        ProgressView("正在加载展品...")
                        if !viewModel.loadingLogs.isEmpty {
                            ScrollView {
                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(Array(viewModel.loadingLogs.enumerated()), id: \.offset) { _, log in
                                        Text(log)
                                            .font(.footnote.monospaced())
                                            .foregroundStyle(.secondary)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                                .padding(12)
                            }
                            .frame(maxWidth: 520, maxHeight: 240)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .task { await viewModel.loadInitialIfNeeded() }
                case .failed(let message):
                    VStack(spacing: 16) {
                        ContentUnavailableView("加载失败", systemImage: "wifi.exclamationmark", description: Text(message))
                        if !viewModel.loadingLogs.isEmpty {
                            ScrollView {
                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(Array(viewModel.loadingLogs.enumerated()), id: \.offset) { _, log in
                                        Text(log)
                                            .font(.footnote.monospaced())
                                            .foregroundStyle(.secondary)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                                .padding(12)
                            }
                            .frame(maxWidth: 520, maxHeight: 220)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                    }
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("重试") { Task { await viewModel.reload() } }
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .loaded:
                    ScrollView {
                        VStack(spacing: 16) {
                            WaterfallGrid(
                                items: viewModel.items,
                                columnCount: columnCount,
                                availableWidth: proxy.size.width - horizontalPadding * 2
                            ) { item in
                                NavigationLink(
                                    value: Route.artwork(
                                        ArtworkReference(
                                            museumID: item.artwork.museumID,
                                            objectID: item.artwork.objectID
                                        )
                                    )
                                ) {
                                    ArtworkCardView(item: item) { aspectRatio in
                                        viewModel.updateAspectRatio(for: item.id, aspectRatio: aspectRatio)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                            if viewModel.isLoadingMore {
                                ProgressView("加载更多中...")
                                    .font(.footnote)
                            } else if viewModel.hasMoreItems {
                                Color.clear
                                    .frame(height: 1)
                                    .onAppear {
                                        Task { await viewModel.loadMoreIfNeeded() }
                                    }
                            }
                        }
                        .padding(.horizontal, horizontalPadding)
                        .padding(.top, 12)
                        .padding(.bottom, 24)
                    }
                    .refreshable { await viewModel.reload() }
                }
            }
        }
        .navigationTitle(museum.displayName)
        .onChange(of: settings.feedRandomOrder) { _, _ in
            Task { await viewModel.reload() }
        }
    }

    private var columnCount: Int {
        if horizontalSizeClass == .regular { return 3 }
        return 2
    }

    private var horizontalPadding: CGFloat { 12 }
}
