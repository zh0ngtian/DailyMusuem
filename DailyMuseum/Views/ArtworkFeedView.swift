import SwiftUI

struct ArtworkFeedView: View {
    private enum Constants {
        static let loadMoreOverscrollThreshold: CGFloat = 96
        static let loadMoreResetThreshold: CGFloat = 32
        static let scrollCoordinateSpace = "artwork-feed-scroll"
    }

    let museum: Museum

    @StateObject private var viewModel: ArtworkFeedViewModel
    @StateObject private var settings = SettingsStore.shared
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var isLoadMoreTriggerVisible = false
    @State private var isBottomLoadPrimed = false
    @State private var isTrackingBottomLoadGesture = false

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
                                VStack(spacing: 8) {
                                    Image(systemName: "arrow.up")
                                        .font(.footnote.weight(.semibold))
                                    Text(isBottomLoadPrimed ? "松开加载下一批" : "继续上滑加载下一批")
                                        .font(.footnote)
                                }
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                                    .contentShape(Rectangle())
                                    .background(
                                        GeometryReader { triggerProxy in
                                            Color.clear.preference(
                                                key: BottomLoadTriggerFramePreferenceKey.self,
                                                value: triggerProxy.frame(in: .named(Constants.scrollCoordinateSpace))
                                            )
                                        }
                                    )
                            }
                        }
                        .padding(.horizontal, horizontalPadding)
                        .padding(.top, 12)
                        .padding(.bottom, 24)
                    }
                    .coordinateSpace(name: Constants.scrollCoordinateSpace)
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 12)
                            .onChanged { _ in
                                isTrackingBottomLoadGesture = true
                            }
                            .onEnded { _ in
                                let shouldLoad = isBottomLoadPrimed && isLoadMoreTriggerVisible && !viewModel.isLoadingMore && viewModel.hasMoreItems
                                isTrackingBottomLoadGesture = false
                                isBottomLoadPrimed = false
                                guard shouldLoad else { return }
                                Task { await viewModel.loadMoreAfterExplicitSwipeIfNeeded() }
                            }
                    )
                    .onPreferenceChange(BottomLoadTriggerFramePreferenceKey.self) { frame in
                        updateBottomLoadState(triggerFrame: frame, viewportHeight: proxy.size.height)
                    }
                    .onChange(of: viewModel.isLoadingMore) { _, isLoading in
                        if isLoading {
                            isBottomLoadPrimed = false
                        }
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

    private func updateBottomLoadState(triggerFrame: CGRect, viewportHeight: CGFloat) {
        let overscroll = max(0, viewportHeight - triggerFrame.maxY)
        isLoadMoreTriggerVisible = triggerFrame.minY < viewportHeight

        guard isTrackingBottomLoadGesture, isLoadMoreTriggerVisible, !viewModel.isLoadingMore, viewModel.hasMoreItems else {
            return
        }

        if overscroll >= Constants.loadMoreOverscrollThreshold {
            isBottomLoadPrimed = true
        } else if overscroll <= Constants.loadMoreResetThreshold {
            isBottomLoadPrimed = false
        }
    }
}

private struct BottomLoadTriggerFramePreferenceKey: PreferenceKey {
    static var defaultValue: CGRect = .zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}
