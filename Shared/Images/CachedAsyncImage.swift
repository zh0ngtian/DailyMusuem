import SwiftUI
import UIKit

struct CachedAsyncImage<Content: View, Placeholder: View>: View {
    private let url: URL?
    private let content: (Image) -> Content
    private let placeholder: () -> Placeholder
    private let onImageSize: ((CGSize) -> Void)?

    @StateObject private var loader: ImageLoader
    @Environment(\.scenePhase) private var scenePhase

    init(
        url: URL?,
        @ViewBuilder content: @escaping (Image) -> Content,
        @ViewBuilder placeholder: @escaping () -> Placeholder,
        onImageSize: ((CGSize) -> Void)? = nil
    ) {
        self.url = url
        self.content = content
        self.placeholder = placeholder
        self.onImageSize = onImageSize
        _loader = StateObject(wrappedValue: ImageLoader(url: url))
    }

    var body: some View {
        ZStack {
            if let uiImage = loader.image {
                let size = uiImage.size
                content(Image(uiImage: uiImage))
                    .onAppear {
                        onImageSize?(size)
                    }
            } else {
                placeholder()
            }
        }
        .onAppear { loader.load() }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                loader.retryIfNeeded()
            }
        }
    }
}
