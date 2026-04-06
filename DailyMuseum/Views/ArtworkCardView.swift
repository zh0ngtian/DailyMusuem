import SwiftUI

struct ArtworkCardView: View {
    let item: ArtworkFeedItem
    let onAspectRatioKnown: (CGFloat) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CachedAsyncImage(url: item.artwork.primaryImageSmallURL) { image in
                image
                    .resizable()
                    .scaledToFill()
            } placeholder: {
                Rectangle()
                    .fill(.quaternary)
            } onImageSize: { size in
                if size.width > 0, size.height > 0 {
                    onAspectRatioKnown(size.width / size.height)
                }
            }
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
}

