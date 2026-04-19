import SwiftUI

struct MuseumListView: View {
    @State private var selectedMuseum: Museum?

    private var countrySections: [MuseumCountrySection] {
        MuseumRepository.homepageCountrySections
    }

    var body: some View {
        List {
            ForEach(countrySections) { section in
                Section {
                    ForEach(section.museums) { museum in
                        Button {
                            selectedMuseum = museum
                        } label: {
                            museumCard(museum, showsChevron: true)
                        }
                        .buttonStyle(.plain)
                        .listRowInsets(EdgeInsets(top: 7, leading: 20, bottom: 7, trailing: 20))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    }
                } header: {
                    Text(section.country)
                        .font(.headline)
                        .foregroundStyle(.secondary)
                        .textCase(nil)
                        .padding(.leading, 4)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color(.systemGroupedBackground))
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $selectedMuseum) { museum in
            ArtworkFeedView(museum: museum)
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                NavigationLink(value: Route.favorites) {
                    Image(systemName: "star")
                }
                .accessibilityLabel("收藏夹")

                NavigationLink(value: Route.settings) {
                    Image(systemName: "gear")
                }
                .accessibilityLabel("设置")
            }
        }
    }

    @ViewBuilder
    private func museumCard(_ museum: Museum, showsChevron: Bool) -> some View {
        HStack(spacing: 16) {
            museumLogoBadge(for: museum)

            VStack(alignment: .leading, spacing: 6) {
                Text(museum.displayName)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(museum.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 18)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.background)
                .shadow(color: Color.black.opacity(0.06), radius: 12, x: 0, y: 6)
        )
    }

    private func museumLogoBadge(for museum: Museum) -> some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(Color(.secondarySystemBackground))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.black.opacity(0.05), lineWidth: 1)
            }
            .overlay {
                Image(museum.id.homepageLogoAssetName)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 90, maxHeight: 46)
                    .accessibilityHidden(true)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 9)
            }
            .frame(width: 112, height: 68)
    }
}
