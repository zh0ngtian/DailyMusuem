import SwiftUI

struct ArtworkFeedView: View {
    private enum DisplayMode: String, CaseIterable, Identifiable {
        case waterfall
        case list

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .waterfall:
                return "瀑布流"
            case .list:
                return "列表"
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
    @State private var selectedArtworkReference: ArtworkReference?
    @State private var isShowingPageSettings = false
    @State private var draftDisplayMode: DisplayMode = .waterfall
    @State private var draftSelectedCategoryIDs: Set<String> = []
    @State private var isApplyingPageSettings = false

    init(museum: Museum) {
        self.museum = museum
        _viewModel = StateObject(wrappedValue: ArtworkFeedViewModel(museum: museum))
        _displayMode = State(
            initialValue: DisplayMode(
                rawValue: SettingsStore.shared.feedDisplayModeRawValue(for: museum.id) ?? ""
            ) ?? .waterfall
        )
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
                    preparePageSettingsDraft()
                    isShowingPageSettings = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .accessibilityLabel("页面设置")
            }
        }
        .navigationDestination(item: $selectedArtworkReference) { reference in
            ArtworkDetailLoaderView(reference: reference)
        }
        .sheet(isPresented: $isShowingPageSettings) {
            NavigationStack {
                pageSettingsView
            }
            .presentationDetents([.medium, .large])
            .interactiveDismissDisabled(isApplyingPageSettings)
        }
        .onChange(of: settings.feedRandomOrder) { _, _ in
            Task { await viewModel.reload() }
        }
    }

    private var isCategorySelectionDisabled: Bool {
        viewModel.state == .loading || viewModel.isLoadingMore || isApplyingPageSettings
    }

    private var columnCount: Int {
        if horizontalSizeClass == .regular { return 3 }
        return 2
    }

    private var horizontalPadding: CGFloat { 12 }

    private var pageSettingsView: some View {
        Form {
            Section("显示") {
                Picker("当前视图", selection: $draftDisplayMode) {
                    ForEach(DisplayMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(isApplyingPageSettings)
            }

            Section("筛选") {
                Button {
                    draftSelectedCategoryIDs = Set(viewModel.availableCategories.map(\.id))
                } label: {
                    categorySelectionRow(title: "全部", isSelected: draftIsAllCategoriesSelected)
                }
                .buttonStyle(.plain)
                .disabled(isCategorySelectionDisabled)

                ForEach(viewModel.availableCategories) { category in
                    Button {
                        toggleDraftCategorySelection(category)
                    } label: {
                        categorySelectionRow(
                            title: category.displayName,
                            isSelected: draftSelectedCategoryIDs.contains(category.id)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(isCategorySelectionDisabled)
                }

                Text("当前选择：\(draftSelectedCategoriesSummary)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if isCategorySelectionDisabled {
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        Text("正在更新筛选结果…")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                Text("在这里的改动只有点击“完成”后才生效；直接下滑关闭不会保存本次修改。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("页面设置")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("完成") {
                    Task { await applyPageSettingsDraft() }
                }
                .disabled(isApplyingPageSettings)
            }
        }
    }

    private func categorySelectionRow(title: String, isSelected: Bool) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
        }
        .contentShape(Rectangle())
    }

    private var draftIsAllCategoriesSelected: Bool {
        draftSelectedCategoryIDs.count == viewModel.availableCategories.count
    }

    private var draftSelectedCategoriesSummary: String {
        if draftIsAllCategoriesSelected {
            return "全部"
        }

        let selectedCategories = viewModel.availableCategories.filter { draftSelectedCategoryIDs.contains($0.id) }
        if selectedCategories.count <= 2 {
            return selectedCategories.map(\.displayName).joined(separator: "、")
        }

        return "已选 \(selectedCategories.count) 类"
    }

    private func preparePageSettingsDraft() {
        draftDisplayMode = displayMode
        draftSelectedCategoryIDs = Set(viewModel.selectedCategories.map(\.id))
        isApplyingPageSettings = false
    }

    private func toggleDraftCategorySelection(_ category: MuseumCategory) {
        if draftSelectedCategoryIDs.contains(category.id) {
            guard draftSelectedCategoryIDs.count > 1 else { return }
            draftSelectedCategoryIDs.remove(category.id)
        } else {
            draftSelectedCategoryIDs.insert(category.id)
        }
    }

    private func applyPageSettingsDraft() async {
        guard !isApplyingPageSettings else { return }
        isApplyingPageSettings = true
        defer { isApplyingPageSettings = false }

        let selectedCategories = viewModel.availableCategories.filter { draftSelectedCategoryIDs.contains($0.id) }

        if draftDisplayMode != displayMode {
            displayMode = draftDisplayMode
            settings.saveFeedDisplayModeRawValue(draftDisplayMode.rawValue, for: museum.id)
        }

        await viewModel.applySelectedCategories(selectedCategories)
        isShowingPageSettings = false
    }

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
        Button {
            selectedArtworkReference = ArtworkReference(
                museumID: item.artwork.museumID,
                objectID: item.artwork.objectID,
                imageAspectRatio: item.displayImageAspectRatio
            )
        } label: {
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

                Text(item.artwork.museumID.displayName)
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
