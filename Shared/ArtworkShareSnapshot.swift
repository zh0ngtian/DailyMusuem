import SwiftUI
import UIKit

struct ArtworkShareImageItem: Identifiable {
    let id = UUID()
    let image: UIImage
}

struct ArtworkSharePresentationState {
    var previewItem: ArtworkShareImageItem?
    var shareSheetItem: ArtworkShareImageItem?
    var pendingShareSheetItem: ArtworkShareImageItem?
    private(set) var isSharePreparationQueuedAfterSecondaryActionsDismissal = false

    mutating func presentPreview(with image: UIImage) {
        previewItem = ArtworkShareImageItem(image: image)
    }

    mutating func queueSharePreparationAfterSecondaryActionsDismissal() {
        isSharePreparationQueuedAfterSecondaryActionsDismissal = true
    }

    mutating func consumeQueuedSharePreparationAfterSecondaryActionsDismissal() -> Bool {
        guard isSharePreparationQueuedAfterSecondaryActionsDismissal else {
            return false
        }
        isSharePreparationQueuedAfterSecondaryActionsDismissal = false
        return true
    }

    mutating func confirmPreviewShare(_ item: ArtworkShareImageItem) {
        pendingShareSheetItem = item
        previewItem = nil
    }

    mutating func presentPendingShareSheetIfNeeded() {
        guard let pendingShareSheetItem else {
            return
        }
        self.pendingShareSheetItem = nil
        shareSheetItem = pendingShareSheetItem
    }
}

struct ArtworkShareSnapshotMetrics: Equatable {
    let width: CGFloat
    let scale: CGFloat

    @MainActor
    static var current: ArtworkShareSnapshotMetrics {
        let screenBounds = UIScreen.main.bounds
        let width = screenBounds.width > 0 ? screenBounds.width : 393
        let scale = UIScreen.main.scale > 0 ? UIScreen.main.scale : 3

        return ArtworkShareSnapshotMetrics(
            width: width,
            scale: scale
        )
    }
}

enum ArtworkShareSnapshotRenderer {
    @MainActor
    static func render(
        artwork: Artwork,
        image: UIImage?,
        imageAspectRatio: CGFloat,
        metrics: ArtworkShareSnapshotMetrics? = nil
    ) -> UIImage? {
        let resolvedMetrics = metrics ?? .current
        let content = ArtworkShareSnapshotView(
            artwork: artwork,
            previewImage: image,
            imageAspectRatio: imageAspectRatio,
            metrics: resolvedMetrics
        )
        .frame(width: resolvedMetrics.width)
        .background(Color(.systemBackground))

        let renderer = ImageRenderer(content: content)
        renderer.scale = resolvedMetrics.scale
        renderer.proposedSize = ProposedViewSize(width: resolvedMetrics.width, height: nil)
        renderer.isOpaque = true
        return renderer.uiImage
    }
}

private struct ArtworkShareSnapshotView: View {
    let artwork: Artwork
    let previewImage: UIImage?
    let imageAspectRatio: CGFloat
    let metrics: ArtworkShareSnapshotMetrics

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
