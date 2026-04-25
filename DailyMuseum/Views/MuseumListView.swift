import SwiftUI

struct MuseumListView: View {
    @State private var selectedMuseum: Museum?
    @State private var latencyMeasurements: [MuseumID: MuseumLatencyMeasurement] = [:]
    @State private var isLatencyTesting = false
    @State private var latencyRunToken = UUID()
    @State private var latencyTask: Task<Void, Never>?

    private let latencyService = MuseumLatencyService()

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
        .refreshable {
            await refreshLatencyMeasurements(cancelInFlight: true)
        }
        .onAppear {
            startLatencyMeasurements()
        }
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
        HStack(alignment: .center, spacing: 16) {
            museumLogoBadge(for: museum)

            VStack(alignment: .leading, spacing: 4) {
                latencyBadge(for: museum)

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
            .frame(maxWidth: .infinity, alignment: .leading)

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

    @ViewBuilder
    private func latencyBadge(for museum: Museum) -> some View {
        if let measurement = latencyMeasurements[museum.id] {
            Text(measurement.displayText)
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(latencyColor(for: measurement.quality))
                .frame(minHeight: 16, alignment: .leading)
                .accessibilityLabel("\(museum.displayName)延迟\(measurement.displayText)")
        } else if isLatencyTesting {
            ProgressView()
                .controlSize(.mini)
                .frame(height: 16, alignment: .leading)
                .accessibilityLabel("\(museum.displayName)延迟测试中")
        }
    }

    private func latencyColor(for quality: MuseumLatencyQuality) -> Color {
        switch quality {
        case .good:
            return .green
        case .warning:
            return .yellow
        case .poor:
            return .red
        }
    }

    private func startLatencyMeasurements() {
        latencyTask?.cancel()
        latencyTask = Task {
            await refreshLatencyMeasurements(cancelInFlight: false)
        }
    }

    @MainActor
    private func refreshLatencyMeasurements(cancelInFlight: Bool) async {
        if cancelInFlight {
            latencyTask?.cancel()
            latencyTask = nil
        }
        let runToken = UUID()
        latencyRunToken = runToken
        isLatencyTesting = true

        let measurements = await latencyService.measureLatencies(for: MuseumRepository.homepageMuseumIDs)

        guard !Task.isCancelled, runToken == latencyRunToken else { return }
        latencyMeasurements = measurements
        isLatencyTesting = false
        latencyTask = nil
    }
}
