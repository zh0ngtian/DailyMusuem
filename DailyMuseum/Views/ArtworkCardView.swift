import SwiftUI

struct ArtworkCardView: View {
    private enum Constants {
        static let extremeImagePadding: CGFloat = 14
    }

    let item: ArtworkFeedItem
    let onAspectRatioKnown: (CGFloat) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CachedAsyncImage(url: item.artwork.primaryImageSmallURL ?? item.artwork.primaryImageURL) { image in
                imageContent(image: image)
            } placeholder: {
                placeholderImage
            } onImageSize: { size in
                if size.width > 0, size.height > 0 {
                    onAspectRatioKnown(size.width / size.height)
                }
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(displayAspectRatio, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(item.artwork.title)
                    .font(.headline)
                    .lineLimit(2)

                if let subtitle = item.artwork.subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 10)
        }
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.background)
                .shadow(color: Color.black.opacity(0.06), radius: 10, x: 0, y: 6)
        }
    }

    private var displayAspectRatio: CGFloat {
        CGFloat(item.displayImageAspectRatio)
    }

    @ViewBuilder
    private func imageContent(image: Image) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.systemGray5))

            image
                .resizable()
                .aspectRatio(contentMode: item.needsExtremeAspectRatioPadding ? .fit : .fill)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(extremeImageInsets)
        }
    }

    private var extremeImageInsets: EdgeInsets {
        guard item.needsExtremeAspectRatioPadding else {
            return EdgeInsets()
        }

        if item.isExtremelyWideImage {
            return EdgeInsets(
                top: Constants.extremeImagePadding,
                leading: 0,
                bottom: Constants.extremeImagePadding,
                trailing: 0
            )
        }

        return EdgeInsets(
            top: 0,
            leading: Constants.extremeImagePadding,
            bottom: 0,
            trailing: Constants.extremeImagePadding
        )
    }

    private var placeholderImage: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.systemGray5))

            VStack(spacing: 10) {
                Image(systemName: "photo")
                    .font(.system(size: 24, weight: .medium))
                Text("加载图片中")
                    .font(.footnote)
            }
            .foregroundStyle(.secondary)
        }
    }
}
