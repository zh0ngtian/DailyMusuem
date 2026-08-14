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
    @State private var pageSettingsPresentation: PageSettingsPresentation?

    init(museum: Museum) {
        self.museum = museum
        _viewModel = StateObject(wrappedValue: ArtworkFeedViewModel(museum: museum))
        _displayMode = State(initialValue: Self.persistedDisplayMode(for: museum.id))
    }

    var body: some View {
        GeometryReader { proxy in
            Group {
                switch viewModel.state {
                case .idle:
                    fullscreenLoadingView
                case .loading:
                    if viewModel.displayItems.isEmpty, !viewModel.showsInlineInitialLoading {
                        fullscreenLoadingView
                    } else {
                        feedScrollView(
                            availableWidth: proxy.size.width - horizontalPadding * 2,
                            viewportHeight: proxy.size.height,
                            isInitialLoading: true
                        )
                    }
                case .empty(let emptyState):
                    ContentUnavailableView {
                        Label(emptyState.title, systemImage: emptyState.systemImage)
                    } description: {
                        Text(emptyState.message)
                    } actions: {
                        if emptyState.suggestsChangingCategories {
                            Button("重新选择品类") {
                                presentPageSettings()
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                    feedScrollView(
                        availableWidth: proxy.size.width - horizontalPadding * 2,
                        viewportHeight: proxy.size.height,
                        isInitialLoading: false
                    )
                }
            }
            .task { await viewModel.loadInitialIfNeeded() }
        }
        .navigationTitle(museum.displayName)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    presentPageSettings()
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .accessibilityLabel("页面设置")
            }
        }
        .navigationDestination(item: $selectedArtworkReference) { reference in
            ArtworkDetailLoaderView(reference: reference)
        }
        .sheet(item: $pageSettingsPresentation) { presentation in
            NavigationStack {
                PageSettingsSheet(
                    museumID: museum.id,
                    initialDisplayMode: presentation.displayMode,
                    initialSelectedSourceKey: presentation.selectedSourceKey,
                    initialSelectedCategoryIDs: presentation.selectedCategoryIDs,
                    isCategorySelectionDisabled: viewModel.state == .loading || viewModel.isLoadingMore,
                    onApply: { draftDisplayMode, draftSelectedSourceKey, selectedCategories in
                        await applyPageSettings(
                            displayMode: draftDisplayMode,
                            selectedSourceKey: draftSelectedSourceKey,
                            selectedCategories: selectedCategories
                        )
                    }
                )
            }
            .presentationDetents([.medium, .large])
        }
    }

    private var columnCount: Int {
        if horizontalSizeClass == .regular { return 3 }
        return 2
    }

    private var horizontalPadding: CGFloat { 12 }

    private var fullscreenLoadingView: some View {
        VStack(spacing: 16) {
            ProgressView("正在加载展品...")
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func feedScrollView(
        availableWidth: CGFloat,
        viewportHeight: CGFloat,
        isInitialLoading: Bool
    ) -> some View {
        ScrollView {
            VStack(spacing: 16) {
                if isInitialLoading {
                    ProgressView("正在加载展品...")
                        .font(.footnote)
                }

                feedContent(availableWidth: availableWidth)

                if viewModel.isLoadingMore {
                    ProgressView("加载更多中...")
                        .font(.footnote)
                } else if viewModel.hasMoreItems, !isInitialLoading {
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
                    let shouldLoad = isBottomLoadPrimed && isLoadMoreTriggerVisible && !viewModel.isLoadingMore && viewModel.hasMoreItems && !isInitialLoading
                    isTrackingBottomLoadGesture = false
                    isBottomLoadPrimed = false
                    guard shouldLoad else { return }
                    Task { await viewModel.loadMoreAfterExplicitSwipeIfNeeded() }
                }
        )
        .onPreferenceChange(BottomLoadTriggerFramePreferenceKey.self) { frame in
            updateBottomLoadState(triggerFrame: frame, viewportHeight: viewportHeight)
        }
        .onChange(of: viewModel.isLoadingMore) { _, isLoading in
            if isLoading {
                isBottomLoadPrimed = false
            }
        }
        .refreshable { await viewModel.refresh() }
    }

    private func presentPageSettings() {
        pageSettingsPresentation = PageSettingsPresentation(
            displayMode: displayMode,
            selectedSourceKey: viewModel.selectedSourceKey,
            selectedCategoryIDs: Set(viewModel.selectedCategories.map(\.id))
        )
    }

    private func applyPageSettings(
        displayMode: DisplayMode,
        selectedSourceKey: String?,
        selectedCategories: [MuseumCategory]
    ) async {
        if displayMode != self.displayMode {
            self.displayMode = displayMode
            settings.saveFeedDisplayModeRawValue(displayMode.rawValue, for: museum.id)
        }

        await viewModel.applyPageSettings(
            selectedSourceKey: selectedSourceKey,
            selectedCategories: selectedCategories
        )
    }

    @ViewBuilder
    private func feedContent(availableWidth: CGFloat) -> some View {
        switch displayMode {
        case .waterfall:
            WaterfallGrid(
                items: viewModel.displayItems,
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
                ForEach(viewModel.displayItems) { item in
                    artworkNavigationLink(for: item) {
                        ArtworkListRowCardView(
                            artwork: item.artwork
                        ) { aspectRatio in
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

    private struct PageSettingsPresentation: Identifiable {
        let id = UUID()
        let displayMode: DisplayMode
        let selectedSourceKey: String?
        let selectedCategoryIDs: Set<String>
    }

    private struct PageSettingsSheet: View {
        let museumID: MuseumID
        let initialSelectedSourceKey: String?
        let isCategorySelectionDisabled: Bool
        let onApply: (DisplayMode, String?, [MuseumCategory]) async -> Void

        @Environment(\.dismiss) private var dismiss
        @State private var draftDisplayMode: DisplayMode
        @State private var draftSourceKey: String
        @State private var draftSelectedCategoryIDs: Set<String>
        @State private var isApplying = false
        @State private var alertMessage: String?

        init(
            museumID: MuseumID,
            initialDisplayMode: DisplayMode,
            initialSelectedSourceKey: String?,
            initialSelectedCategoryIDs: Set<String>,
            isCategorySelectionDisabled: Bool,
            onApply: @escaping (DisplayMode, String?, [MuseumCategory]) async -> Void
        ) {
            self.museumID = museumID
            self.initialSelectedSourceKey = initialSelectedSourceKey
            self.isCategorySelectionDisabled = isCategorySelectionDisabled
            self.onApply = onApply
            _draftDisplayMode = State(initialValue: initialDisplayMode)
            let sourceKey = initialSelectedSourceKey ?? museumID.defaultSourceKey ?? museumID.sources.first?.sourceKey ?? ""
            _draftSourceKey = State(initialValue: sourceKey)
            _draftSelectedCategoryIDs = State(initialValue: initialSelectedCategoryIDs)
        }

        var body: some View {
            Form {
                Section("显示") {
                    Picker("当前视图", selection: $draftDisplayMode) {
                        ForEach(DisplayMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(isApplying)
                }

                if showsSourcePicker {
                    Section("数据源") {
                        Picker("当前数据源", selection: $draftSourceKey) {
                            ForEach(availableSources) { source in
                                Text(source.displayName).tag(source.sourceKey)
                            }
                        }
                        .pickerStyle(.menu)
                        .disabled(isSelectionInteractionDisabled)
                        .onChange(of: draftSourceKey) { _, newValue in
                            draftSelectedCategoryIDs = Set(
                                museumID.defaultFeedCategories(sourceKey: newValue).map(\.id)
                            )
                        }
                    }
                }

                Section("筛选") {
                    Button {
                        toggleSelectAll()
                    } label: {
                        categorySelectionRow(title: "全部", isSelected: isAllCategoriesSelected)
                    }
                    .buttonStyle(.plain)
                    .disabled(isSelectionInteractionDisabled)

                    ForEach(availableCategories) { category in
                        Button {
                            toggleCategorySelection(category)
                        } label: {
                            categorySelectionRow(
                                title: category.displayName,
                                isSelected: draftSelectedCategoryIDs.contains(category.id)
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(isSelectionInteractionDisabled)
                    }

                    Text("当前选择：\(selectedCategoriesSummary)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    if isSelectionInteractionDisabled {
                        HStack(spacing: 10) {
                            ProgressView()
                                .controlSize(.small)
                            Text(isApplying ? "正在更新筛选结果…" : "当前数据加载中，稍后可调整筛选。")
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
            .interactiveDismissDisabled(isApplying)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") {
                        Task { await applyDraft() }
                    }
                    .disabled(isApplying)
                }
            }
            .alert(
                "筛选提示",
                isPresented: Binding(
                    get: { alertMessage != nil },
                    set: { isPresented in
                        if !isPresented {
                            alertMessage = nil
                        }
                    }
                ),
                actions: {
                    Button("知道了", role: .cancel) {
                        alertMessage = nil
                    }
                },
                message: {
                    Text(alertMessage ?? "")
                }
            )
        }

        private var isSelectionInteractionDisabled: Bool {
            isCategorySelectionDisabled || isApplying
        }

        private var availableSources: [MuseumSourceMetadata] {
            museumID.sources
        }

        private var showsSourcePicker: Bool {
            availableSources.count > 1
        }

        private var effectiveDraftSourceKey: String? {
            draftSourceKey.isEmpty ? nil : draftSourceKey
        }

        private var availableCategories: [MuseumCategory] {
            museumID.selectableFeedCategories(sourceKey: effectiveDraftSourceKey)
        }

        private var isAllCategoriesSelected: Bool {
            draftSelectedCategoryIDs.count == availableCategories.count
        }

        private var selectedCategoriesSummary: String {
            if isAllCategoriesSelected {
                return "全部"
            }

            let selectedCategories = availableCategories.filter { draftSelectedCategoryIDs.contains($0.id) }
            if selectedCategories.isEmpty {
                return "未选择任何品类"
            }

            if selectedCategories.count <= 2 {
                return selectedCategories.map(\.displayName).joined(separator: "、")
            }

            return "已选 \(selectedCategories.count) 类"
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

        private func toggleSelectAll() {
            if isAllCategoriesSelected {
                draftSelectedCategoryIDs = []
            } else {
                draftSelectedCategoryIDs = Set(availableCategories.map(\.id))
            }
        }

        private func toggleCategorySelection(_ category: MuseumCategory) {
            if draftSelectedCategoryIDs.contains(category.id) {
                draftSelectedCategoryIDs.remove(category.id)
            } else {
                draftSelectedCategoryIDs.insert(category.id)
            }
        }

        private func applyDraft() async {
            guard !isApplying else { return }

            let selectedCategories = availableCategories.filter { draftSelectedCategoryIDs.contains($0.id) }
            guard !selectedCategories.isEmpty else {
                alertMessage = "当前未勾选任何品类，请至少勾选一个品类后再完成。"
                return
            }

            isApplying = true
            defer { isApplying = false }

            await onApply(
                draftDisplayMode,
                effectiveDraftSourceKey,
                selectedCategories
            )
            dismiss()
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

    private static func persistedDisplayMode(for museumID: MuseumID) -> DisplayMode {
        guard
            let rawValue = SettingsStore.shared.feedDisplayModeRawValue(for: museumID),
            let displayMode = DisplayMode(rawValue: rawValue)
        else {
            return .waterfall
        }
        return displayMode
    }
}

private struct BottomLoadTriggerFramePreferenceKey: PreferenceKey {
    static var defaultValue: CGRect = .zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}
