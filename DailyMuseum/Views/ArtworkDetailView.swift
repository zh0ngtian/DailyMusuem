import SwiftUI

struct ArtworkDetailView: View {
    let artwork: Artwork
    let imageReloadToken: Int
    let onRefresh: () async -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                CachedAsyncImage(url: artwork.primaryImageURL ?? artwork.primaryImageSmallURL) { image in
                    image
                        .resizable()
                        .scaledToFit()
                } placeholder: {
                    Rectangle().fill(.quaternary)
                }
                .id(imageReloadToken)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                VStack(alignment: .leading, spacing: 10) {
                    Text(artwork.title)
                        .font(.title2.weight(.semibold))

                    if let subtitle = artwork.subtitle {
                        Text(subtitle)
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }

                    if let description = normalizedDescription {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("展品介绍")
                                .font(.headline)
                            Text(description)
                                .font(.body)
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.top, 4)
                        .padding(.bottom, 4)
                    }

                    InfoRow(label: "年代", value: artwork.objectDate)
                    InfoRow(label: "材质", value: artwork.medium)
                    InfoRow(label: "尺寸", value: artwork.dimensions)
                    InfoRow(label: "部门", value: artwork.department)
                    InfoRow(label: "文化", value: artwork.culture)
                    InfoRow(label: "国家", value: artwork.country)
                    InfoRow(label: "馆藏", value: artwork.repository)

                    if let url = artwork.objectURL {
                        Link("在官网查看", destination: url)
                            .font(.headline)
                            .padding(.top, 4)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(16)
        }
        .navigationTitle("展品")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await onRefresh()
        }
    }

    private var normalizedDescription: String? {
        guard let description = artwork.artworkDescription else {
            return nil
        }

        let cleaned = description
            .replacingOccurrences(of: "(?i)<br\\s*/?>", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "(?i)</p>", with: "\n\n", options: .regularExpression)
            .replacingOccurrences(of: "(?i)<p[^>]*>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&#x27;", with: "'")
            .components(separatedBy: .newlines)
            .map(cleanDescriptionLine)
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
            .replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleaned.isEmpty else {
            return nil
        }

        return cleaned
    }

    private func cleanDescriptionLine(_ line: String) -> String {
        var cleaned = line.trimmingCharacters(in: .whitespacesAndNewlines)

        cleaned = cleaned.replacingOccurrences(
            of: #"^\[\s*"?\s*"#,
            with: "",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: #"\s*"?\s*\]$"#,
            with: "",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: #"^[\[\]",\s]+$"#,
            with: "",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: #"^->\s*"#,
            with: "",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: #"^>+\s*"#,
            with: "",
            options: .regularExpression
        )

        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
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
