import SwiftUI

struct ArtworkFeedView: View {
    private enum DisplayMode {
        case waterfall
        case list

        var buttonIcon: String {
            switch self {
            case .waterfall:
                return "list.bullet"
            case .list:
                return "square.grid.2x2"
            }
        }

        var buttonLabel: String {
            switch self {
            case .waterfall:
                return "切换到列表"
            case .list:
                return "切换到瀑布流"
            }
        }
    }

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
    @State private var displayMode: DisplayMode = .waterfall

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
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .task { await viewModel.loadInitialIfNeeded() }
                case .failed(let message):
                    VStack(spacing: 16) {
                        ContentUnavailableView("加载失败", systemImage: "wifi.exclamationmark", description: Text(message))
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
                            feedContent(availableWidth: proxy.size.width - horizontalPadding * 2)
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
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    displayMode = displayMode == .waterfall ? .list : .waterfall
                } label: {
                    Image(systemName: displayMode.buttonIcon)
                }
                .accessibilityLabel(displayMode.buttonLabel)
            }
        }
        .onChange(of: settings.feedRandomOrder) { _, _ in
            Task { await viewModel.reload() }
        }
    }

    private var columnCount: Int {
        if horizontalSizeClass == .regular { return 3 }
        return 2
    }

    private var horizontalPadding: CGFloat { 12 }

    @ViewBuilder
    private func feedContent(availableWidth: CGFloat) -> some View {
        switch displayMode {
        case .waterfall:
            WaterfallGrid(
                items: viewModel.items,
                columnCount: columnCount,
                availableWidth: availableWidth
            ) { item in
                artworkNavigationLink(for: item) {
                    ArtworkCardView(item: item) { aspectRatio in
                        viewModel.updateAspectRatio(for: item.id, aspectRatio: aspectRatio)
                    }
                }
                .buttonStyle(.plain)
            }
        case .list:
            LazyVStack(spacing: 12) {
                ForEach(viewModel.items) { item in
                    artworkNavigationLink(for: item) {
                        ArtworkListRowView(item: item) { aspectRatio in
                            viewModel.updateAspectRatio(for: item.id, aspectRatio: aspectRatio)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func artworkNavigationLink<Content: View>(for item: ArtworkFeedItem, @ViewBuilder content: () -> Content) -> some View {
        NavigationLink(
            value: Route.artwork(
                ArtworkReference(
                    museumID: item.artwork.museumID,
                    objectID: item.artwork.objectID
                )
            )
        ) {
            content()
        }
    }

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

private struct ArtworkListRowView: View {
    private enum Constants {
        static let previewSize = CGSize(width: 108, height: 108)
        static let cornerRadius: CGFloat = 16
    }

    let item: ArtworkFeedItem
    let onAspectRatioKnown: (CGFloat) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            CachedAsyncImage(url: item.artwork.primaryImageSmallURL) { image in
                image
                    .resizable()
                    .scaledToFill()
            } placeholder: {
                placeholderImage
            } onImageSize: { size in
                guard size.width > 0, size.height > 0 else { return }
                onAspectRatioKnown(size.width / size.height)
            }
            .frame(width: Constants.previewSize.width, height: Constants.previewSize.height)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            VStack(alignment: .leading, spacing: 8) {
                Text(item.artwork.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(3)

                if let subtitle = item.artwork.subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 0)

                Text(item.artwork.museumID == .met ? "大都会艺术博物馆" : "东京国立博物馆")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
                .padding(.top, 4)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: Constants.cornerRadius, style: .continuous)
                .fill(.background)
                .shadow(color: Color.black.opacity(0.06), radius: 10, x: 0, y: 6)
        )
    }

    private var placeholderImage: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.systemGray5))

            VStack(spacing: 8) {
                Image(systemName: "photo")
                    .font(.system(size: 20, weight: .medium))
                Text("加载图片中")
                    .font(.caption2)
            }
            .foregroundStyle(.secondary)
        }
    }
}
