import Photos
import SwiftUI
import Translation
import UIKit

struct ArtworkDetailView: View {
    private enum Constants {
        static let placeholderAspectRatio: CGFloat = 0.8
        static let translationTargetLanguage = Locale.Language(identifier: "zh-Hans")
        static let translationAssetsNotReadyMessage = "系统翻译语言包尚未准备好。为保持当前页原位替换交互，应用不会弹出系统下载页，请先在系统里准备好语言包后再试。"
        static let unsupportedTranslationMessage = "当前系统翻译暂不支持这组语言。"
        static let unidentifiedSourceLanguageMessage = "系统暂时无法识别原文语言，未触发翻译。"
    }

    private enum TranslationToolbarState {
        case original(hasCachedTranslation: Bool)
        case translating
        case translated

        var systemImageName: String {
            switch self {
            case .original:
                return "globe"
            case .translating:
                return "globe.badge.clock"
            case .translated:
                return "globe.badge.chevron.backward"
            }
        }

        var isDisabled: Bool {
            if case .translating = self {
                return true
            }
            return false
        }

        var accessibilityLabel: String {
            switch self {
            case .original:
                return "原文"
            case .translating:
                return "翻译中"
            case .translated:
                return "译文"
            }
        }

        var accessibilityHint: String? {
            switch self {
            case .original(let hasCachedTranslation):
                return hasCachedTranslation ? "点按显示译文" : "点按翻译并显示译文"
            case .translating:
                return nil
            case .translated:
                return "点按显示原文"
            }
        }
    }

    let artwork: Artwork
    let placeholderAspectRatio: CGFloat
    let imageReloadToken: Int
    let isFavorite: Bool
    let onFavoriteButtonTap: () -> Void
    let onRefresh: () async -> Void

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @ScaledMetric(relativeTo: .body) private var compactToolbarIconPointSize: CGFloat = 18
    @ScaledMetric(relativeTo: .body) private var regularToolbarIconPointSize: CGFloat = 20

    @State private var isShowingImagePreview = false
    @State private var translatedArtwork: Artwork?
    @State private var showsTranslatedArtwork = false
    @State private var isTranslating = false
    @State private var translationConfiguration: TranslationSession.Configuration?
    @State private var loadedPreviewImage: UIImage?
    @State private var loadedImageAspectRatio: CGFloat?
    @State private var alertState: DetailAlertState?
    @State private var sharePreviewItem: SharedImageSheetItem?
    @State private var shareSheetItem: SharedImageSheetItem?
    @State private var pendingShareSheetItem: SharedImageSheetItem?
    @State private var isPreparingShareImage = false
    @State private var isShowingSecondaryActionsPopover = false
    @State private var detailFontScaleStep = 0

    var body: some View {
        let typography = ArtworkDetailTypography(scaleStep: detailFontScaleStep)

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                CachedAsyncImage(
                    url: displayedArtwork.primaryImageURL ?? displayedArtwork.primaryImageSmallURL,
                    content: { image in
                        Button {
                            isShowingImagePreview = true
                        } label: {
                            image
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .buttonStyle(.plain)
                    },
                    placeholder: {
                        detailPlaceholderImage
                    },
                    onImageSize: { size in
                        guard size.width > 0, size.height > 0 else {
                            return
                        }
                        loadedImageAspectRatio = size.width / size.height
                    },
                    onUIImageLoaded: { uiImage in
                        loadedPreviewImage = uiImage
                    }
                )
                .accessibilityLabel("查看展品图片大图")
                .accessibilityAddTraits(.isButton)
                .id(imageReloadToken)
                .frame(maxWidth: .infinity)
                .aspectRatio(effectiveImageAspectRatio, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                VStack(alignment: .leading, spacing: 10) {
                    SelectableTextBlock(
                        text: displayedArtwork.title,
                        font: typography.titleFont,
                        textColor: .label
                    )

                    if let description = displayedArtwork.normalizedDescriptionText {
                        VStack(alignment: .leading, spacing: 8) {
                            SelectableTextBlock(
                                text: description,
                                font: typography.bodyFont,
                                textColor: .label,
                                lineSpacing: typography.descriptionLineSpacing
                            )
                        }
                        .padding(.top, 4)
                        .padding(.bottom, 4)
                    }

                    InfoRow(label: "作者", value: displayedArtwork.artistDisplayName, typography: typography)
                    InfoRow(label: "年代", value: displayedArtwork.objectDate, typography: typography)
                    InfoRow(label: "材质", value: displayedArtwork.medium, typography: typography)
                    InfoRow(label: "尺寸", value: displayedArtwork.dimensions, typography: typography)
                    InfoRow(label: "类别", value: displayedArtwork.department, typography: typography)
                    InfoRow(label: "文化", value: displayedArtwork.culture, typography: typography)
                    InfoRow(label: "国家", value: displayedArtwork.country, typography: typography)
                    SelectableTextBlock(
                        text: displayedArtwork.museumID.copyrightNotice,
                        font: typography.footnoteFont,
                        textColor: .secondaryLabel,
                        alignment: .center
                    )
                        .padding(.top, 8)
                        .frame(maxWidth: .infinity)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(16)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if let officialURL = artwork.objectURL {
                    Button {
                        handleAIAssistantButtonTap(officialURL: officialURL)
                    } label: {
                        toolbarIconLabel("AI 解读", systemImage: "apple.intelligence")
                    }
                    .accessibilityLabel("AI 解读")
                }

                if let url = artwork.objectURL {
                    Link(destination: url) {
                        toolbarIconLabel("官网", systemImage: "safari")
                    }
                    .accessibilityLabel("打开官网")
                }

                if artwork.supportsTranslation {
                    translationToolbarButton
                }

                favoriteToolbarButton

                secondaryActionsMenu
            }
        }
        .fullScreenCover(isPresented: $isShowingImagePreview) {
            ArtworkImagePreviewView(
                initialImage: loadedPreviewImage,
                imageURL: displayedArtwork.primaryImageURL ?? displayedArtwork.primaryImageSmallURL
            )
        }
        .refreshable {
            await onRefresh()
        }
        .translationTask(translationConfiguration) { session in
            await performTranslation(using: session)
        }
        .sheet(item: $sharePreviewItem, onDismiss: presentPendingShareSheetIfNeeded) { item in
            ArtworkSharePreviewSheet(
                item: item,
                onShare: {
                    pendingShareSheetItem = item
                    sharePreviewItem = nil
                }
            )
            .presentationDetents([.fraction(0.5)])
            .presentationDragIndicator(.hidden)
        }
        .sheet(item: $shareSheetItem) { item in
            ActivityView(activityItems: [item.image])
        }
        .onChange(of: imageReloadToken) { _, _ in
            loadedPreviewImage = nil
            loadedImageAspectRatio = nil
        }
        .onChange(of: artwork) { _, _ in
            resetTranslationState()
        }
        .alert(item: $alertState) { state in
            Alert(
                title: Text(state.title),
                message: Text(state.message),
                dismissButton: .default(Text("知道了"))
            )
        }
    }

    private var toolbarIconFont: Font {
        .system(
            size: toolbarIconPointSize,
            weight: .medium
        )
    }

    private var toolbarIconPointSize: CGFloat {
        horizontalSizeClass == .compact ? compactToolbarIconPointSize : regularToolbarIconPointSize
    }

    private func toolbarIconLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .labelStyle(.iconOnly)
            .font(toolbarIconFont)
            .imageScale(.medium)
    }

    private var favoriteToolbarButton: some View {
        Button(action: onFavoriteButtonTap) {
            toolbarIconLabel(isFavorite ? "取消收藏" : "收藏", systemImage: isFavorite ? "star.fill" : "star")
        }
        .accessibilityLabel(isFavorite ? "取消收藏" : "收藏")
    }

    private var secondaryActionsMenu: some View {
        Button {
            isShowingSecondaryActionsPopover = true
        } label: {
            toolbarIconLabel("更多", systemImage: "ellipsis")
        }
        .popover(
            isPresented: $isShowingSecondaryActionsPopover,
            attachmentAnchor: .rect(.bounds),
            arrowEdge: .top
        ) {
            ArtworkDetailMoreActionsPopover(
                isShareDisabled: isPreparingShareImage,
                isIncreaseDisabled: detailFontScaleStep >= ArtworkDetailTypography.maximumScaleStep,
                isDecreaseDisabled: detailFontScaleStep <= ArtworkDetailTypography.minimumScaleStep,
                onShare: {
                    isShowingSecondaryActionsPopover = false
                    handleShareButtonTap()
                },
                onIncrease: {
                    adjustDetailFontScale(by: 1)
                },
                onDecrease: {
                    adjustDetailFontScale(by: -1)
                }
            )
            .presentationCompactAdaptation(.popover)
        }
        .accessibilityLabel("更多操作")
    }

    @ViewBuilder
    private var translationToolbarButton: some View {
        let state = translationToolbarState
        let button = Button {
            handleTranslationButtonTap()
        } label: {
            Image(systemName: state.systemImageName)
                .font(toolbarIconFont)
                .imageScale(.medium)
        }
        .disabled(state.isDisabled)
        .accessibilityLabel(state.accessibilityLabel)

        if let accessibilityHint = state.accessibilityHint {
            button.accessibilityHint(accessibilityHint)
        } else {
            button
        }
    }

    private var detailPlaceholderImage: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.systemGray5))

            VStack(spacing: 12) {
                Image(systemName: "photo")
                    .font(.system(size: 30, weight: .medium))
                Text("加载图片中")
                    .font(.footnote)
            }
            .foregroundStyle(.secondary)
        }
    }

    private var effectivePlaceholderAspectRatio: CGFloat {
        guard placeholderAspectRatio.isFinite, placeholderAspectRatio > 0 else {
            return Constants.placeholderAspectRatio
        }
        return placeholderAspectRatio
    }

    private var effectiveImageAspectRatio: CGFloat {
        guard let loadedImageAspectRatio,
              loadedImageAspectRatio.isFinite,
              loadedImageAspectRatio > 0 else {
            return effectivePlaceholderAspectRatio
        }
        return loadedImageAspectRatio
    }

    private var displayedArtwork: Artwork {
        if showsTranslatedArtwork, let translatedArtwork {
            return translatedArtwork
        }
        return artwork
    }

    private var translationToolbarState: TranslationToolbarState {
        if isTranslating {
            return .translating
        }
        if translatedArtwork != nil {
            return showsTranslatedArtwork ? .translated : .original(hasCachedTranslation: true)
        }
        return .original(hasCachedTranslation: false)
    }

    private func handleTranslationButtonTap() {
        if translatedArtwork != nil {
            showsTranslatedArtwork.toggle()
            return
        }

        guard !isTranslating, artwork.supportsTranslation else {
            return
        }

        alertState = nil
        isTranslating = true
        let sourceArtwork = artwork
        Task {
            await prepareTranslation(for: sourceArtwork)
        }
    }

    private func performTranslation(using session: TranslationSession) async {
        let sourceArtwork = artwork
        let entries = sourceArtwork.translationEntries

        guard !entries.isEmpty else {
            await MainActor.run {
                isTranslating = false
                translationConfiguration = nil
            }
            return
        }

        do {
            let requests = entries.map { entry in
                TranslationSession.Request(
                    sourceText: entry.text,
                    clientIdentifier: entry.id
                )
            }
            let responses = try await session.translations(from: requests)
            let translationsByID = responses.reduce(into: [String: String]()) { partialResult, response in
                guard let identifier = response.clientIdentifier else {
                    return
                }

                let trimmedText = response.targetText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedText.isEmpty else {
                    return
                }

                partialResult[identifier] = trimmedText
            }

            await MainActor.run {
                translatedArtwork = sourceArtwork.applyingTranslations(translationsByID)
                showsTranslatedArtwork = true
                isTranslating = false
                translationConfiguration = nil
            }
        } catch {
            await MainActor.run {
                presentTranslationAlert(message: error.localizedDescription)
                isTranslating = false
                translationConfiguration = nil
            }
        }
    }

    private func prepareTranslation(for artwork: Artwork) async {
        let availability = LanguageAvailability()

        do {
            let availabilityStatus = try await translationAvailabilityStatus(
                for: artwork,
                availability: availability
            )

            await MainActor.run {
                switch availabilityStatus {
                case .installed:
                    translationConfiguration = TranslationSession.Configuration(
                        source: translationSourceLanguage(for: artwork),
                        target: Constants.translationTargetLanguage
                    )
                case .supported:
                    presentTranslationAlert(message: Constants.translationAssetsNotReadyMessage)
                    isTranslating = false
                    translationConfiguration = nil
                case .unsupported:
                    presentTranslationAlert(message: Constants.unsupportedTranslationMessage)
                    isTranslating = false
                    translationConfiguration = nil
                @unknown default:
                    presentTranslationAlert(message: Constants.unsupportedTranslationMessage)
                    isTranslating = false
                    translationConfiguration = nil
                }
            }
        } catch {
            await MainActor.run {
                if TranslationError.unableToIdentifyLanguage ~= error {
                    presentTranslationAlert(message: Constants.unidentifiedSourceLanguageMessage)
                } else {
                    presentTranslationAlert(message: error.localizedDescription)
                }
                isTranslating = false
                translationConfiguration = nil
            }
        }
    }

    private func translationAvailabilityStatus(
        for artwork: Artwork,
        availability: LanguageAvailability
    ) async throws -> LanguageAvailability.Status {
        if let sourceLanguage = translationSourceLanguage(for: artwork) {
            return await availability.status(
                from: sourceLanguage,
                to: Constants.translationTargetLanguage
            )
        }

        let sampleText = artwork.translationEntries
            .map(\.text)
            .joined(separator: "\n")
        return try await availability.status(
            for: sampleText,
            to: Constants.translationTargetLanguage
        )
    }

    private func translationSourceLanguage(for artwork: Artwork) -> Locale.Language? {
        switch artwork.museumID {
        case .met:
            return Locale.Language(identifier: "en")
        case .tnm:
            return Locale.Language(identifier: "ja")
        case .nnm:
            if NaraMuseumAPI.isOfficialObjectID(artwork.objectID) {
                return Locale.Language(identifier: "zh-Hans")
            }
            return Locale.Language(identifier: "ja")
        case .nmc, .shm:
            return nil
        }
    }

    private func resetTranslationState() {
        translatedArtwork = nil
        showsTranslatedArtwork = false
        isTranslating = false
        translationConfiguration = nil
        alertState = nil
    }

    private func handleAIAssistantButtonTap(officialURL: URL) {
        guard let shortcutInstallURL = ArtworkAIShortcutConfiguration.doubaoInstallURL else {
            return
        }

        guard let runURL = ArtworkAIShortcutConfiguration.doubaoRunURL(
            inputText: ArtworkAIShortcutConfiguration.doubaoInputText(for: officialURL)
        ) else {
            InstallPromptController.shared.showShortcutInstallPrompt(
                shortcutName: ArtworkAIShortcutConfiguration.doubaoShortcutName,
                installURL: shortcutInstallURL
            )
            return
        }

        UIApplication.shared.open(runURL) { didOpen in
            guard !didOpen else {
                return
            }
            InstallPromptController.shared.showShortcutInstallPrompt(
                shortcutName: ArtworkAIShortcutConfiguration.doubaoShortcutName,
                installURL: shortcutInstallURL
            )
        }
    }

    private func presentTranslationAlert(message: String) {
        alertState = DetailAlertState(
            title: "翻译提示",
            message: message
        )
    }

    @MainActor
    private func handleShareButtonTap() {
        guard !isPreparingShareImage else {
            return
        }

        isPreparingShareImage = true
        defer { isPreparingShareImage = false }

        guard let image = DetailScreenshotRenderer.render(
            artwork: displayedArtwork,
            image: loadedPreviewImage,
            imageAspectRatio: effectiveImageAspectRatio
        ) else {
            alertState = DetailAlertState(
                title: "分享失败",
                message: "当前详情页暂时无法生成截图，请稍后重试。"
            )
            return
        }

        sharePreviewItem = SharedImageSheetItem(image: image)
    }

    private func adjustDetailFontScale(by delta: Int) {
        detailFontScaleStep = ArtworkDetailTypography.clampedScaleStep(detailFontScaleStep + delta)
    }

    private func presentPendingShareSheetIfNeeded() {
        guard let pendingShareSheetItem else {
            return
        }
        self.pendingShareSheetItem = nil
        shareSheetItem = pendingShareSheetItem
    }
}

private enum ArtworkAIShortcutConfiguration {
    static let doubaoShortcutName = "DoubaoMuseum"
    static let doubaoAppName = "豆包"

    static var doubaoInstallURL: URL? {
        URL(string: "https://www.icloud.com/shortcuts/50a57de8c0884898a895556c3e8b01b5")
    }

    static var doubaoAppInstallURL: URL? {
        URL(string: "https://apps.apple.com/cn/app/id6459478672")
    }

    static func doubaoInputText(for officialURL: URL) -> String {
        "介绍一下这个展品：\(officialURL.absoluteString)"
    }

    static func doubaoRunURL(inputText: String) -> URL? {
        guard let shortcutInstallURL = doubaoInstallURL,
              let appInstallURL = doubaoAppInstallURL,
              let errorCallbackURL = AppDeepLink.shortcutInstallPromptURL(
                shortcutName: doubaoShortcutName,
                installURL: shortcutInstallURL,
                appName: doubaoAppName,
                appInstallURL: appInstallURL
              ) else {
            return nil
        }

        var components = URLComponents()
        components.scheme = "shortcuts"
        components.host = "x-callback-url"
        components.path = "/run-shortcut"
        components.queryItems = [
            URLQueryItem(name: "name", value: doubaoShortcutName),
            URLQueryItem(name: "input", value: "text"),
            URLQueryItem(name: "text", value: inputText),
            URLQueryItem(name: "x-error", value: errorCallbackURL.absoluteString)
        ]
        return components.url
    }
}

private struct SharedImageSheetItem: Identifiable {
    let id = UUID()
    let image: UIImage
}

private struct DetailAlertState: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

private struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(
            activityItems: activityItems,
            applicationActivities: nil
        )
        if let popoverPresentationController = controller.popoverPresentationController {
            controller.loadViewIfNeeded()
            guard let sourceView = controller.view else {
                return controller
            }
            popoverPresentationController.sourceView = sourceView
            popoverPresentationController.sourceRect = CGRect(
                x: sourceView.bounds.midX,
                y: sourceView.bounds.maxY,
                width: 1,
                height: 1
            )
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private struct ArtworkDetailMoreActionsPopover: View {
    let isShareDisabled: Bool
    let isIncreaseDisabled: Bool
    let isDecreaseDisabled: Bool
    let onShare: () -> Void
    let onIncrease: () -> Void
    let onDecrease: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            actionRow(
                title: "分享",
                systemImage: "square.and.arrow.up",
                isDisabled: isShareDisabled,
                action: onShare
            )

            Divider()

            actionRow(
                title: "更大字号",
                systemImage: "plus.magnifyingglass",
                isDisabled: isIncreaseDisabled,
                action: onIncrease
            )

            Divider()

            actionRow(
                title: "更小字号",
                systemImage: "minus.magnifyingglass",
                isDisabled: isDecreaseDisabled,
                action: onDecrease
            )
        }
        .padding(.vertical, 6)
        .frame(minWidth: 210)
        .presentationBackground(Color(.systemBackground))
    }

    private func actionRow(
        title: String,
        systemImage: String,
        isDisabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.system(size: 20, weight: .regular))
                    .frame(width: 26, alignment: .center)

                Text(title)
                    .font(.body)

                Spacer(minLength: 0)
            }
            .foregroundStyle(isDisabled ? Color(.tertiaryLabel) : Color(.label))
            .padding(.horizontal, 18)
            .frame(height: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
    }
}

private struct ArtworkSharePreviewSheet: View {
    @Environment(\.dismiss) private var dismiss

    let item: SharedImageSheetItem
    let onShare: () -> Void

    var body: some View {
        GeometryReader { proxy in
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("分享预览")
                        .font(.headline)
                        .foregroundStyle(Color(.label))

                    Text("确认图片内容后，再进入系统分享页面。")
                        .font(.subheadline)
                        .foregroundStyle(Color(.secondaryLabel))
                }

                ZStack {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color(.secondarySystemBackground))

                    Image(uiImage: item.image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(12)
                }
                .frame(maxWidth: .infinity)
                .layoutPriority(1)
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Color.black.opacity(0.06), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.06), radius: 16, x: 0, y: 8)

                HStack(spacing: 12) {
                    Button("取消") {
                        dismiss()
                    }
                    .buttonStyle(SharePreviewSecondaryButtonStyle())

                    Button("分享") {
                        onShare()
                    }
                    .buttonStyle(SharePreviewPrimaryButtonStyle())
                }
            }
            .padding(16)
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
        }
        .background(Color(.systemGroupedBackground))
    }
}

private struct SharePreviewPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.accentColor.opacity(configuration.isPressed ? 0.8 : 1))
            )
    }
}

private struct SharePreviewSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(Color(.label))
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(.secondarySystemBackground).opacity(configuration.isPressed ? 0.8 : 1))
            )
    }
}

private enum DetailScreenshotRenderer {
    @MainActor
    static func render(
        artwork: Artwork,
        image: UIImage?,
        imageAspectRatio: CGFloat
    ) -> UIImage? {
        let metrics = ShareSnapshotMetrics.current
        let content = ArtworkDetailShareSnapshotView(
            artwork: artwork,
            previewImage: image,
            imageAspectRatio: imageAspectRatio,
            metrics: metrics
        )
        .frame(width: metrics.width)
        .background(Color(.systemBackground))

        let renderer = ImageRenderer(content: content)
        renderer.scale = metrics.scale
        renderer.proposedSize = ProposedViewSize(width: metrics.width, height: nil)
        renderer.isOpaque = true
        return renderer.uiImage
    }
}

private struct ArtworkImagePreviewView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var loader: ImageLoader
    @State private var displayedImage: UIImage?
    @State private var isSaving = false
    @State private var alertState: PreviewAlertState?

    init(initialImage: UIImage?, imageURL: URL?) {
        _loader = StateObject(wrappedValue: ImageLoader(url: imageURL))
        _displayedImage = State(initialValue: initialImage)
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()

            Group {
                if let displayedImage {
                    ZoomableArtworkImageView(image: displayedImage)
                } else {
                    ProgressView("加载图片中")
                        .tint(.white)
                        .foregroundStyle(.white)
                }
            }
            .padding(.top, 72)
            .padding(.bottom, 24)

            previewToolbar
        }
        .background(Color.black)
        .alert(item: $alertState) { state in
            Alert(
                title: Text(state.title),
                message: Text(state.message),
                dismissButton: .default(Text("知道了"))
            )
        }
        .onAppear {
            PreviewOrientationCoordinator.shared.activatePreviewMode()
            if displayedImage == nil {
                loader.load(force: true)
            }
        }
        .onDisappear {
            PreviewOrientationCoordinator.shared.deactivatePreviewMode()
        }
        .onReceive(loader.$image) { newImage in
            guard let newImage else {
                return
            }
            displayedImage = newImage
        }
    }

    private var previewToolbar: some View {
        HStack(spacing: 12) {
            Button("关闭") {
                dismiss()
            }

            Spacer()

            Button(isSaving ? "保存中" : "保存") {
                Task {
                    await saveImage()
                }
            }
            .disabled(isSaving || displayedImage == nil)
        }
        .font(.headline)
        .foregroundStyle(.white)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.black.opacity(0.45))
    }

    @MainActor
    private func saveImage() async {
        guard let displayedImage else {
            return
        }

        isSaving = true
        defer { isSaving = false }

        let authorizationStatus = await photoLibraryAuthorizationStatus()
        guard authorizationStatus == .authorized || authorizationStatus == .limited else {
            alertState = PreviewAlertState(
                title: "无法保存",
                message: "请在系统设置中允许“博物女神”保存图片到系统相册。"
            )
            return
        }

        guard let data = encodedData(for: displayedImage) else {
            alertState = PreviewAlertState(
                title: "保存失败",
                message: "当前图片暂时无法编码保存，请稍后重试。"
            )
            return
        }

        do {
            try await saveImageDataToPhotoLibrary(data)
            alertState = PreviewAlertState(
                title: "已保存",
                message: "展品图片已保存到系统相册。"
            )
        } catch {
            alertState = PreviewAlertState(
                title: "保存失败",
                message: error.localizedDescription
            )
        }
    }

    private func photoLibraryAuthorizationStatus() async -> PHAuthorizationStatus {
        let currentStatus = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if currentStatus == .notDetermined {
            return await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        }
        return currentStatus
    }

    private func encodedData(for image: UIImage) -> Data? {
        if let pngData = image.pngData() {
            return pngData
        }
        return image.jpegData(compressionQuality: 1)
    }

    private func saveImageDataToPhotoLibrary(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: data, options: nil)
            }) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                if success {
                    continuation.resume(returning: ())
                    return
                }
                continuation.resume(throwing: PreviewImageSaveError.unknown)
            }
        }
    }
}

private struct ZoomableArtworkImageView: UIViewRepresentable {
    let image: UIImage

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = ImageScrollView()
        scrollView.backgroundColor = .clear
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 4
        scrollView.bouncesZoom = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.zoomCoordinator = context.coordinator

        let imageView = context.coordinator.imageView
        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = true
        imageView.frame = scrollView.bounds
        scrollView.addSubview(imageView)
        context.coordinator.scrollView = scrollView
        context.coordinator.updateImage(image, in: scrollView)

        let oneFingerZoomPanRecognizer = UIPanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleOneFingerZoomPan(_:))
        )
        oneFingerZoomPanRecognizer.minimumNumberOfTouches = 1
        oneFingerZoomPanRecognizer.maximumNumberOfTouches = 1
        oneFingerZoomPanRecognizer.delegate = context.coordinator
        scrollView.addGestureRecognizer(oneFingerZoomPanRecognizer)
        scrollView.panGestureRecognizer.require(toFail: oneFingerZoomPanRecognizer)
        context.coordinator.oneFingerZoomPanRecognizer = oneFingerZoomPanRecognizer

        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.updateImage(image, in: scrollView)
        context.coordinator.updateImageLayoutIfNeeded(in: scrollView)
        context.coordinator.centerImage(in: scrollView)
    }

    final class ImageScrollView: UIScrollView {
        weak var zoomCoordinator: Coordinator?

        override func layoutSubviews() {
            super.layoutSubviews()
            zoomCoordinator?.updateImageLayoutIfNeeded(in: self)
            zoomCoordinator?.centerImage(in: self)
        }
    }

    final class Coordinator: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate {
        let imageView = UIImageView()
        weak var scrollView: UIScrollView?
        weak var oneFingerZoomPanRecognizer: UIPanGestureRecognizer?
        private var renderedImage: UIImage?
        private var pendingImage: UIImage?
        private var isHandlingOneFingerZoom = false
        private var oneFingerZoomStartScale: CGFloat = 1
        private var oneFingerZoomStartTouchLocation: CGPoint = .zero
        private var oneFingerZoomAnchor: CGPoint = .zero
        private var oneFingerZoomBouncesZoomWasEnabled = true

        func updateImage(_ image: UIImage, in scrollView: UIScrollView) {
            guard renderedImage !== image else {
                return
            }
            guard !isHandlingOneFingerZoom else {
                pendingImage = image
                return
            }
            applyImage(image, in: scrollView, resetZoom: renderedImage == nil)
        }

        func updateImageLayoutIfNeeded(in scrollView: UIScrollView) {
            guard !isHandlingOneFingerZoom else {
                return
            }
            guard scrollView.zoomScale == scrollView.minimumZoomScale else {
                return
            }
            guard imageView.frame.size != scrollView.bounds.size else {
                return
            }
            imageView.frame = scrollView.bounds
            scrollView.contentSize = scrollView.bounds.size
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            imageView
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            centerImage(in: scrollView)
        }

        func centerImage(in scrollView: UIScrollView) {
            let boundsSize = scrollView.bounds.size
            var frame = imageView.frame
            frame.origin.x = frame.width < boundsSize.width ? (boundsSize.width - frame.width) / 2 : 0
            frame.origin.y = frame.height < boundsSize.height ? (boundsSize.height - frame.height) / 2 : 0
            imageView.frame = frame
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard gestureRecognizer === oneFingerZoomPanRecognizer,
                  let panRecognizer = gestureRecognizer as? UIPanGestureRecognizer else {
                return true
            }

            let velocity = panRecognizer.velocity(in: scrollView)
            return abs(velocity.y) >= abs(velocity.x)
        }

        @objc func handleOneFingerZoomPan(_ recognizer: UIPanGestureRecognizer) {
            guard let scrollView else {
                return
            }

            switch recognizer.state {
            case .began:
                isHandlingOneFingerZoom = true
                oneFingerZoomStartScale = scrollView.zoomScale
                oneFingerZoomStartTouchLocation = recognizer.location(in: scrollView)
                oneFingerZoomAnchor = contentPoint(for: oneFingerZoomStartTouchLocation, in: scrollView)
                oneFingerZoomBouncesZoomWasEnabled = scrollView.bouncesZoom
                scrollView.bouncesZoom = false
            case .changed:
                let verticalDelta = recognizer.translation(in: scrollView).y
                let scaleMultiplier = pow(2, -verticalDelta / 180)
                let nextScale = min(
                    scrollView.maximumZoomScale,
                    max(scrollView.minimumZoomScale, oneFingerZoomStartScale * scaleMultiplier)
                )
                guard nextScale.isFinite else {
                    return
                }

                applyOneFingerZoom(
                    scale: nextScale,
                    anchoredAt: oneFingerZoomAnchor,
                    touchLocation: oneFingerZoomStartTouchLocation,
                    in: scrollView
                )
            case .ended, .cancelled, .failed:
                scrollView.bouncesZoom = oneFingerZoomBouncesZoomWasEnabled
                isHandlingOneFingerZoom = false
                oneFingerZoomStartScale = scrollView.zoomScale
                oneFingerZoomStartTouchLocation = .zero
                oneFingerZoomAnchor = .zero
                applyPendingImageIfNeeded(in: scrollView)
            default:
                return
            }
        }

        private func applyImage(_ image: UIImage, in scrollView: UIScrollView, resetZoom: Bool) {
            renderedImage = image
            pendingImage = nil
            imageView.image = image
            if resetZoom {
                scrollView.zoomScale = scrollView.minimumZoomScale
                imageView.frame = scrollView.bounds
            }
            centerImage(in: scrollView)
        }

        private func applyPendingImageIfNeeded(in scrollView: UIScrollView) {
            guard let pendingImage else {
                return
            }
            applyImage(pendingImage, in: scrollView, resetZoom: false)
        }

        private func contentPoint(for touchLocation: CGPoint, in scrollView: UIScrollView) -> CGPoint {
            let zoomScale = max(scrollView.zoomScale, .leastNonzeroMagnitude)
            return CGPoint(
                x: (touchLocation.x + scrollView.contentOffset.x - imageView.frame.minX) / zoomScale,
                y: (touchLocation.y + scrollView.contentOffset.y - imageView.frame.minY) / zoomScale
            )
        }

        private func applyOneFingerZoom(
            scale: CGFloat,
            anchoredAt anchor: CGPoint,
            touchLocation: CGPoint,
            in scrollView: UIScrollView
        ) {
            UIView.performWithoutAnimation {
                scrollView.setZoomScale(scale, animated: false)
                centerImage(in: scrollView)
                let appliedScale = scrollView.zoomScale
                scrollView.contentOffset = clampedContentOffset(
                    CGPoint(
                        x: imageView.frame.minX + anchor.x * appliedScale - touchLocation.x,
                        y: imageView.frame.minY + anchor.y * appliedScale - touchLocation.y
                    ),
                    in: scrollView
                )
            }
        }

        private func clampedContentOffset(_ offset: CGPoint, in scrollView: UIScrollView) -> CGPoint {
            let maxX = max(0, scrollView.contentSize.width - scrollView.bounds.width)
            let maxY = max(0, scrollView.contentSize.height - scrollView.bounds.height)
            return CGPoint(
                x: min(max(offset.x, 0), maxX),
                y: min(max(offset.y, 0), maxY)
            )
        }
    }
}

private struct PreviewAlertState: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

private enum PreviewImageSaveError: LocalizedError {
    case unknown

    var errorDescription: String? {
        switch self {
        case .unknown:
            return "系统相册返回了未知结果，请稍后重试。"
        }
    }
}

private struct ShareSnapshotMetrics {
    let width: CGFloat
    let scale: CGFloat

    @MainActor
    static var current: ShareSnapshotMetrics {
        let screenBounds = UIScreen.main.bounds
        let width = screenBounds.width > 0 ? screenBounds.width : 393
        let scale = UIScreen.main.scale > 0 ? UIScreen.main.scale : 3

        return ShareSnapshotMetrics(
            width: width,
            scale: scale
        )
    }
}

private struct ArtworkDetailShareSnapshotView: View {
    let artwork: Artwork
    let previewImage: UIImage?
    let imageAspectRatio: CGFloat
    let metrics: ShareSnapshotMetrics

    private var infoRows: [(String, String)] {
        [
            ("作者", artwork.artistDisplayName),
            ("年代", artwork.objectDate),
            ("材质", artwork.medium),
            ("尺寸", artwork.dimensions),
            ("类别", artwork.department),
            ("文化", artwork.culture),
            ("国家", artwork.country)
        ]
        .compactMap { label, value in
            guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !trimmed.isEmpty else {
                return nil
            }
            return (label, trimmed)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            imageSection

            Text(artwork.title)
                .font(.system(.title2, weight: .semibold))
                .foregroundStyle(Color(.label))
                .fixedSize(horizontal: false, vertical: true)

            if let description = artwork.normalizedDescriptionText {
                Text(description)
                    .font(.body)
                    .foregroundStyle(Color(.label))
                    .lineSpacing(5)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 4)
            }

            VStack(alignment: .leading, spacing: 10) {
                ForEach(infoRows, id: \.0) { row in
                    shareInfoRow(label: row.0, value: row.1)
                }
            }

            Text(artwork.museumID.copyrightNotice)
                .font(.footnote)
                .foregroundStyle(Color(.secondaryLabel))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemBackground))
    }

    @ViewBuilder
    private var imageSection: some View {
        if let previewImage {
            Image(uiImage: previewImage)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity)
                .aspectRatio(normalizedImageAspectRatio, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.systemGray5))
                .overlay {
                    VStack(spacing: 12) {
                        Image(systemName: "photo")
                            .font(.system(size: 30, weight: .medium))
                        Text("加载图片中")
                            .font(.footnote)
                    }
                    .foregroundStyle(Color(.secondaryLabel))
                }
                .frame(maxWidth: .infinity)
                .aspectRatio(normalizedImageAspectRatio, contentMode: .fit)
        }
    }

    private var normalizedImageAspectRatio: CGFloat {
        guard imageAspectRatio.isFinite, imageAspectRatio > 0 else {
            return 0.8
        }
        return imageAspectRatio
    }

    private func shareInfoRow(label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Text(label)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color(.secondaryLabel))
                .frame(width: 44, alignment: .leading)

            Text(value)
                .font(.subheadline)
                .foregroundStyle(Color(.label))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ArtworkDetailTypography {
    static let minimumScaleStep = -2
    static let maximumScaleStep = 3
    static let `default` = ArtworkDetailTypography()

    let titleFont: UIFont
    let bodyFont: UIFont
    let infoLabelFont: UIFont
    let infoValueFont: UIFont
    let footnoteFont: UIFont
    let descriptionLineSpacing: CGFloat
    let infoLabelWidth: CGFloat

    init(scaleStep: Int = 0) {
        let clampedStep = Self.clampedScaleStep(scaleStep)
        let multiplier = 1 + CGFloat(clampedStep) * 0.12
        titleFont = Self.scaledFont(textStyle: .title2, weight: .semibold, multiplier: multiplier)
        bodyFont = Self.scaledFont(textStyle: .body, multiplier: multiplier)
        infoLabelFont = Self.scaledFont(textStyle: .subheadline, weight: .semibold, multiplier: multiplier)
        infoValueFont = Self.scaledFont(textStyle: .subheadline, multiplier: multiplier)
        footnoteFont = Self.scaledFont(textStyle: .footnote, multiplier: multiplier)
        descriptionLineSpacing = 5 * multiplier
        infoLabelWidth = 44
    }

    static func clampedScaleStep(_ step: Int) -> Int {
        min(max(step, minimumScaleStep), maximumScaleStep)
    }

    private static func scaledFont(
        textStyle: UIFont.TextStyle,
        weight: UIFont.Weight = .regular,
        multiplier: CGFloat
    ) -> UIFont {
        let pointSize = UIFont.preferredFont(forTextStyle: textStyle).pointSize
        let baseFont = UIFont.systemFont(ofSize: pointSize * multiplier, weight: weight)
        return UIFontMetrics(forTextStyle: textStyle).scaledFont(for: baseFont)
    }
}

private struct SelectableTextBlock: View {
    let text: String
    let font: UIFont
    let textColor: UIColor
    var alignment: NSTextAlignment = .natural
    var lineSpacing: CGFloat = 0

    var body: some View {
        SelectableAttributedTextView(attributedText: attributedText)
            .frame(maxWidth: .infinity, alignment: alignment == .center ? .center : .leading)
    }

    private var attributedText: NSAttributedString {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = alignment
        paragraphStyle.lineBreakMode = .byWordWrapping
        paragraphStyle.lineSpacing = lineSpacing

        return NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: textColor,
                .paragraphStyle: paragraphStyle
            ]
        )
    }
}

private struct SelectableAttributedTextView: UIViewRepresentable {
    let attributedText: NSAttributedString

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.backgroundColor = .clear
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = false
        textView.adjustsFontForContentSizeCategory = true
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainer.maximumNumberOfLines = 0
        textView.textContainer.lineBreakMode = .byWordWrapping
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return textView
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        uiView.attributedText = attributedText
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let targetWidth = proposal.width ?? 0
        let fittingWidth = targetWidth > 0 ? targetWidth : UIView.noIntrinsicMetric
        let fittingSize = uiView.sizeThatFits(
            CGSize(width: fittingWidth, height: CGFloat.greatestFiniteMagnitude)
        )

        return CGSize(
            width: targetWidth > 0 ? targetWidth : fittingSize.width,
            height: ceil(fittingSize.height)
        )
    }
}

private struct InfoRow: View {
    let label: String
    let value: String?
    let typography: ArtworkDetailTypography

    var body: some View {
        if let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            HStack(alignment: .top, spacing: 14) {
                Text(label)
                    .font(Font(typography.infoLabelFont))
                    .foregroundStyle(Color(.secondaryLabel))
                    .frame(width: typography.infoLabelWidth, alignment: .leading)

                SelectableTextBlock(
                    text: value,
                    font: typography.infoValueFont,
                    textColor: .label
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
