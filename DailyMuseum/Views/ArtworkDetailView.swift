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

    @State private var isShowingImagePreview = false
    @State private var translatedArtwork: Artwork?
    @State private var showsTranslatedArtwork = false
    @State private var isTranslating = false
    @State private var translationConfiguration: TranslationSession.Configuration?
    @State private var loadedPreviewImage: UIImage?
    @State private var loadedImageAspectRatio: CGFloat?
    @State private var shareDestinationContent: ArtworkShareContent?
    @State private var systemShareContent: ArtworkShareContent?
    @State private var translationAlertMessage: String?

    var body: some View {
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
                        font: ArtworkDetailTypography.titleFont,
                        textColor: .label
                    )

                    if let description = displayedArtwork.normalizedDescriptionText {
                        VStack(alignment: .leading, spacing: 8) {
                            SelectableTextBlock(
                                text: description,
                                font: ArtworkDetailTypography.bodyFont,
                                textColor: .label,
                                lineSpacing: ArtworkDetailTypography.descriptionLineSpacing
                            )
                        }
                        .padding(.top, 4)
                        .padding(.bottom, 4)
                    }

                    InfoRow(label: "作者", value: displayedArtwork.artistDisplayName)
                    InfoRow(label: "年代", value: displayedArtwork.objectDate)
                    InfoRow(label: "材质", value: displayedArtwork.medium)
                    InfoRow(label: "尺寸", value: displayedArtwork.dimensions)
                    InfoRow(label: "类别", value: displayedArtwork.department)
                    InfoRow(label: "文化", value: displayedArtwork.culture)
                    InfoRow(label: "国家", value: displayedArtwork.country)
                    SelectableTextBlock(
                        text: displayedArtwork.museumID.copyrightNotice,
                        font: ArtworkDetailTypography.footnoteFont,
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
                if let shareContent = ArtworkShareContent(artwork: artwork) {
                    Button {
                        shareDestinationContent = shareContent
                    } label: {
                        Label("分享", systemImage: "square.and.arrow.up")
                            .labelStyle(.iconOnly)
                    }
                    .accessibilityLabel("分享")
                }

                if let url = artwork.objectURL {
                    Link(destination: url) {
                        Label("官网", systemImage: "safari")
                            .labelStyle(.iconOnly)
                    }
                    .accessibilityLabel("打开官网")
                }

                if artwork.supportsTranslation {
                    translationToolbarButton
                }

                Button(action: onFavoriteButtonTap) {
                    Image(systemName: isFavorite ? "star.fill" : "star")
                }
                .accessibilityLabel(isFavorite ? "取消收藏" : "收藏")
            }
        }
        .fullScreenCover(isPresented: $isShowingImagePreview) {
            ArtworkImagePreviewView(
                initialImage: loadedPreviewImage,
                imageURL: displayedArtwork.primaryImageURL ?? displayedArtwork.primaryImageSmallURL
            )
        }
        .sheet(item: $shareDestinationContent) { shareContent in
            ArtworkShareDestinationSheet(content: shareContent) { selectedContent in
                DispatchQueue.main.async {
                    systemShareContent = selectedContent
                }
            }
            .presentationDetents([.height(316)])
            .presentationDragIndicator(.hidden)
            .presentationBackground(Color(.systemGroupedBackground))
        }
        .sheet(item: $systemShareContent) { shareContent in
            ArtworkOtherAppsShareSheet(text: shareContent.plainText)
        }
        .refreshable {
            await onRefresh()
        }
        .translationTask(translationConfiguration) { session in
            await performTranslation(using: session)
        }
        .onChange(of: imageReloadToken) { _, _ in
            loadedPreviewImage = nil
            loadedImageAspectRatio = nil
        }
        .onChange(of: artwork) { _, _ in
            resetTranslationState()
        }
        .alert("翻译提示", isPresented: Binding(
            get: { translationAlertMessage != nil },
            set: { if !$0 { translationAlertMessage = nil } }
        )) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(translationAlertMessage ?? "")
        }
    }

    @ViewBuilder
    private var translationToolbarButton: some View {
        let state = translationToolbarState
        let button = Button {
            handleTranslationButtonTap()
        } label: {
            Image(systemName: state.systemImageName)
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

        translationAlertMessage = nil
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
                translationAlertMessage = error.localizedDescription
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
                        source: translationSourceLanguage(for: artwork.museumID),
                        target: Constants.translationTargetLanguage
                    )
                case .supported:
                    translationAlertMessage = Constants.translationAssetsNotReadyMessage
                    isTranslating = false
                    translationConfiguration = nil
                case .unsupported:
                    translationAlertMessage = Constants.unsupportedTranslationMessage
                    isTranslating = false
                    translationConfiguration = nil
                @unknown default:
                    translationAlertMessage = Constants.unsupportedTranslationMessage
                    isTranslating = false
                    translationConfiguration = nil
                }
            }
        } catch {
            await MainActor.run {
                if TranslationError.unableToIdentifyLanguage ~= error {
                    translationAlertMessage = Constants.unidentifiedSourceLanguageMessage
                } else {
                    translationAlertMessage = error.localizedDescription
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
        if let sourceLanguage = translationSourceLanguage(for: artwork.museumID) {
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

    private func translationSourceLanguage(for museumID: MuseumID) -> Locale.Language? {
        switch museumID {
        case .met:
            return Locale.Language(identifier: "en")
        case .tnm:
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
        translationAlertMessage = nil
    }
}

private enum ArtworkShareShortcutConfiguration {
    static let doubaoShortcutName = "DoubaoMuseum"

    static var doubaoInstallURL: URL? {
        URL(string: "https://www.icloud.com/shortcuts/50a57de8c0884898a895556c3e8b01b5")
    }

    static func doubaoRunURL(inputText: String) -> URL? {
        guard let installURL = doubaoInstallURL,
              let errorCallbackURL = AppDeepLink.shortcutInstallPromptURL(
                shortcutName: doubaoShortcutName,
                installURL: installURL
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

private struct ArtworkShareDestinationSheet: View {
    @Environment(\.dismiss) private var dismiss

    let content: ArtworkShareContent
    let onShareToOtherApps: (ArtworkShareContent) -> Void

    @State private var alertState: ShareActionAlertState?

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground)
                .ignoresSafeArea()

            VStack(spacing: 14) {
                Spacer(minLength: 0)

                shareOptionCard(
                    title: "微信",
                    subtitle: "跳转到微信并手动粘贴",
                    systemImage: "message.fill",
                    tint: .green,
                    action: shareToWeChat
                )

                shareOptionCard(
                    title: "问问豆包",
                    subtitle: "通过快捷指令发给豆包解读",
                    systemImage: "sparkles.rectangle.stack.fill",
                    tint: .orange,
                    action: shareToDoubao
                )

                shareOptionCard(
                    title: "其他 App",
                    subtitle: "分享到其他 App",
                    systemImage: "square.and.arrow.up",
                    tint: .accentColor
                ) {
                    dismiss()
                    onShareToOtherApps(content)
                }

                Spacer(minLength: 0)
            }
            .frame(maxHeight: .infinity)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .alert(item: $alertState) { state in
            Alert(
                title: Text(state.title),
                message: Text(state.message),
                dismissButton: .default(Text("知道了"))
            )
        }
    }

    private func shareOptionCard(
        title: String,
        subtitle: String,
        systemImage: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 16) {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color.black.opacity(0.05), lineWidth: 1)
                    }
                    .overlay {
                        Image(systemName: systemImage)
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(tint)
                    }
                    .frame(width: 56, height: 56)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 18)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(.background)
                    .shadow(color: Color.black.opacity(0.06), radius: 12, x: 0, y: 6)
            )
        }
        .buttonStyle(.plain)
    }

    private func shareToWeChat() {
        UIPasteboard.general.string = content.plainText

        guard let weChatURL = URL(string: WeChatShareDiagnostics.urlString) else {
            logWeChatShareFailure(WeChatShareDiagnostics.invalidURLSummary)
            return
        }

        let isSchemeDeclared = WeChatShareDiagnostics.isSchemeDeclared(in: Bundle.main.infoDictionary)

        guard UIApplication.shared.canOpenURL(weChatURL) else {
            logWeChatShareFailure(
                WeChatShareDiagnostics.canOpenFailureSummary(isSchemeDeclared: isSchemeDeclared)
            )
            alertState = ShareActionAlertState(
                title: "无法打开微信",
                message: "分享内容已复制到剪贴板，请手动打开微信粘贴发送。"
            )
            return
        }

        dismiss()
        UIApplication.shared.open(weChatURL) { didOpen in
            guard !didOpen else {
                return
            }

            logWeChatShareFailure(
                WeChatShareDiagnostics.openFailureSummary(isSchemeDeclared: isSchemeDeclared)
            )
        }
    }

    private func shareToDoubao() {
        guard let installURL = ArtworkShareShortcutConfiguration.doubaoInstallURL,
              let runURL = ArtworkShareShortcutConfiguration.doubaoRunURL(
                inputText: content.doubaoShortcutInputText
              ) else {
            return
        }

        dismiss()
        UIApplication.shared.open(runURL) { didOpen in
            guard !didOpen else {
                return
            }
            ShortcutInstallPromptController.shared.show(
                shortcutName: ArtworkShareShortcutConfiguration.doubaoShortcutName,
                installURL: installURL
            )
        }
    }

    private func logWeChatShareFailure(_ summary: String) {
        Task {
            await RequestLogger.shared.logEvent(
                source: "微信分享",
                summary: summary
            )
        }
    }
}

private struct ArtworkOtherAppsShareSheet: UIViewControllerRepresentable {
    let text: String

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(
            activityItems: [text],
            applicationActivities: nil
        )
        controller.excludedActivityTypes = [
            UIActivity.ActivityType("com.tencent.xin.session"),
            UIActivity.ActivityType("com.tencent.xin.sharetimeline")
        ]
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private struct ShareActionAlertState: Identifiable {
    let id = UUID()
    let title: String
    let message: String
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
                message: "请在系统设置中允许“每日博物馆”保存图片到系统相册。"
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
        let scrollView = UIScrollView()
        scrollView.backgroundColor = .clear
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 4
        scrollView.bouncesZoom = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false

        let imageView = context.coordinator.imageView
        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = true
        imageView.frame = scrollView.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        imageView.image = image
        scrollView.addSubview(imageView)
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.imageView.image = image
        if context.coordinator.lastRenderedImageIdentifier != ObjectIdentifier(image) {
            context.coordinator.lastRenderedImageIdentifier = ObjectIdentifier(image)
            scrollView.zoomScale = 1
            context.coordinator.imageView.frame = scrollView.bounds
        }
        context.coordinator.centerImage(in: scrollView)
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        let imageView = UIImageView()
        var lastRenderedImageIdentifier: ObjectIdentifier?

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

private enum ArtworkDetailTypography {
    static let titleFont = scaledFont(textStyle: .title2, weight: .semibold)
    static let bodyFont = scaledFont(textStyle: .body)
    static let infoLabelFont = scaledFont(textStyle: .subheadline, weight: .semibold)
    static let infoValueFont = scaledFont(textStyle: .subheadline)
    static let footnoteFont = scaledFont(textStyle: .footnote)
    static let descriptionLineSpacing: CGFloat = 5
    static let infoValueIndent: CGFloat = 58

    private static func scaledFont(textStyle: UIFont.TextStyle, weight: UIFont.Weight = .regular) -> UIFont {
        let pointSize = UIFont.preferredFont(forTextStyle: textStyle).pointSize
        let baseFont = UIFont.systemFont(ofSize: pointSize, weight: weight)
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

    var body: some View {
        if let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            SelectableAttributedTextView(attributedText: attributedText)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var attributedText: NSAttributedString {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byWordWrapping
        paragraphStyle.tabStops = [
            NSTextTab(
                textAlignment: .left,
                location: ArtworkDetailTypography.infoValueIndent
            )
        ]
        paragraphStyle.defaultTabInterval = ArtworkDetailTypography.infoValueIndent
        paragraphStyle.firstLineHeadIndent = 0
        paragraphStyle.headIndent = ArtworkDetailTypography.infoValueIndent

        let attributedText = NSMutableAttributedString()
        attributedText.append(
            NSAttributedString(
                string: "\(label)\t",
                attributes: [
                    .font: ArtworkDetailTypography.infoLabelFont,
                    .foregroundColor: UIColor.secondaryLabel,
                    .paragraphStyle: paragraphStyle
                ]
            )
        )
        attributedText.append(
            NSAttributedString(
                string: value ?? "",
                attributes: [
                    .font: ArtworkDetailTypography.infoValueFont,
                    .foregroundColor: UIColor.label,
                    .paragraphStyle: paragraphStyle
                ]
            )
        )
        return attributedText
    }
}
