import SwiftUI

struct MuseumListView: View {
    private let museums = MuseumRepository.supportedMuseums

    var body: some View {
        List {
            Section("博物馆") {
                ForEach(museums) { museum in
                    NavigationLink(value: Route.museum(museum)) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(museum.displayName)
                                .font(.headline)
                            Text(museum.subtitle)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 6)
                    }
                }
            }
        }
        .navigationTitle("DailyMuseum")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink(value: Route.settings) {
                    Image(systemName: "gear")
                }
            }
        }
    }
}

