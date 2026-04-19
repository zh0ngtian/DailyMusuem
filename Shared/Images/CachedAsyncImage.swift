import SwiftUI
import UIKit

struct CachedAsyncImage<Content: View, Placeholder: View>: View {
    private let url: URL?
    private let content: (Image) -> Content
    private let placeholder: () -> Placeholder
    private let onImageSize: ((CGSize) -> Void)?
    private let onUIImageLoaded: ((UIImage) -> Void)?

    @StateObject private var loader: ImageLoader
    @Environment(\.scenePhase) private var scenePhase

    init(
        url: URL?,
        @ViewBuilder content: @escaping (Image) -> Content,
        @ViewBuilder placeholder: @escaping () -> Placeholder,
        onImageSize: ((CGSize) -> Void)? = nil,
        onUIImageLoaded: ((UIImage) -> Void)? = nil
    ) {
        self.url = url
        self.content = content
        self.placeholder = placeholder
        self.onImageSize = onImageSize
        self.onUIImageLoaded = onUIImageLoaded
        _loader = StateObject(wrappedValue: ImageLoader(url: url))
    }

    var body: some View {
        ZStack {
            if let uiImage = loader.image {
                let size = uiImage.size
                content(Image(uiImage: uiImage))
                    .onAppear {
                        handleLoadedImage(uiImage, size: size)
                    }
            } else {
                placeholder()
            }
        }
        .onAppear { loader.updateURL(url) }
        .onReceive(loader.$image) { newImage in
            guard let newImage else {
                return
            }
            handleLoadedImage(newImage, size: newImage.size)
        }
        .onChange(of: url) { _, newURL in
            loader.updateURL(newURL)
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                loader.retryIfNeeded()
            }
        }
    }

    private func handleLoadedImage(_ uiImage: UIImage, size: CGSize) {
        onImageSize?(size)
        onUIImageLoaded?(uiImage)
    }
}
