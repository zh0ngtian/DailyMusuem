import Photos
import SwiftUI
import UIKit

struct ArtworkDetailView: View {
    private enum Constants {
        static let placeholderAspectRatio: CGFloat = 0.8
    }

    let artwork: Artwork
    let placeholderAspectRatio: CGFloat
    let imageReloadToken: Int
    let showsTranslationButton: Bool
    let translationButtonTitle: String
    let translationButtonDisabled: Bool
    let onTranslationButtonTap: () async -> Void
    let onRefresh: () async -> Void

    @State private var isShowingImagePreview = false
    @State private var loadedPreviewImage: UIImage?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                CachedAsyncImage(
                    url: artwork.primaryImageURL ?? artwork.primaryImageSmallURL,
                    content: { image in
                        Button {
                            isShowingImagePreview = true
                        } label: {
                            image
                                .resizable()
                                .scaledToFit()
                        }
                        .buttonStyle(.plain)
                    },
                    placeholder: {
                        detailPlaceholderImage
                    },
                    onUIImageLoaded: { uiImage in
                        loadedPreviewImage = uiImage
                    }
                )
                .accessibilityLabel("查看展品图片大图")
                .accessibilityAddTraits(.isButton)
                .id(imageReloadToken)
                .frame(maxWidth: .infinity)
                .aspectRatio(effectivePlaceholderAspectRatio, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                VStack(alignment: .leading, spacing: 10) {
                    Text(artwork.title)
                        .font(.title2.weight(.semibold))

                    if let description = artwork.normalizedDescriptionText {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(description)
                                .font(.body)
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.top, 4)
                        .padding(.bottom, 4)
                    }

                    InfoRow(label: "艺术家", value: artwork.artistDisplayName)
                    InfoRow(label: "年代", value: artwork.objectDate)
                    InfoRow(label: "材质", value: artwork.medium)
                    InfoRow(label: "尺寸", value: artwork.dimensions)
                    InfoRow(label: "类别", value: artwork.department)
                    InfoRow(label: "文化", value: artwork.culture)
                    InfoRow(label: "国家", value: artwork.country)
                    InfoRow(label: "馆藏", value: artwork.repository)

                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(16)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let url = artwork.objectURL {
                ToolbarItem(placement: .topBarTrailing) {
                    Link("官网", destination: url)
                }
            }
            if showsTranslationButton {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(translationButtonTitle) {
                        Task {
                            await onTranslationButtonTap()
                        }
                    }
                    .disabled(translationButtonDisabled)
                }
            }
        }
        .fullScreenCover(isPresented: $isShowingImagePreview) {
            ArtworkImagePreviewView(
                initialImage: loadedPreviewImage,
                imageURL: artwork.primaryImageURL ?? artwork.primaryImageSmallURL
            )
        }
        .refreshable {
            await onRefresh()
        }
        .onChange(of: imageReloadToken) { _, _ in
            loadedPreviewImage = nil
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

private struct InfoRow: View {
    let label: String
    let value: String?

    var body: some View {
        if let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(label)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .leading)
                Text(value)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
        }
    }
}
