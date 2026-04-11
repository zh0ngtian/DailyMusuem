import SwiftUI

struct MuseumListView: View {
    private let museums = MuseumRepository.supportedMuseums

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                LazyVStack(spacing: 14) {
                    ForEach(museums) { museum in
                        NavigationLink(value: Route.museum(museum)) {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(museum.displayName)
                                        .font(.headline)
                                        .foregroundStyle(.primary)
                                    Text(museum.subtitle)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
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
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink(value: Route.settings) {
                    Image(systemName: "gear")
                }
            }
        }
    }
}
