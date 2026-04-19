import SwiftUI

struct ArtworkListRowCardView: View {
    private enum Constants {
        static let previewSize = CGSize(width: 108, height: 108)
        static let cornerRadius: CGFloat = 16
    }

    let artwork: Artwork
    var footerText: String?
    var onAspectRatioKnown: ((CGFloat) -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            CachedAsyncImage(url: artwork.primaryImageSmallURL ?? artwork.primaryImageURL) { image in
                image
                    .resizable()
                    .scaledToFill()
            } placeholder: {
                placeholderImage
            } onImageSize: { size in
                guard size.width > 0, size.height > 0 else { return }
                onAspectRatioKnown?(size.width / size.height)
            }
            .frame(width: Constants.previewSize.width, height: Constants.previewSize.height)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            VStack(alignment: .leading, spacing: 8) {
                Text(artwork.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(3)

                if let subtitle = artwork.subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                if let footerText, !footerText.isEmpty {
                    Spacer(minLength: 0)

                    Text(footerText)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
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
