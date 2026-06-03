import SwiftUI
import MapKit
import Foundation

struct MapLocationView: View {
    @EnvironmentObject var store: NodeStore
    @State private var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 55.751244, longitude: 37.618423),
        span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
    )

    private struct TrustedPin: Identifiable {
        let id = UUID()
        let coordinate: CLLocationCoordinate2D
    }

    private var trustedPin: TrustedPin? {
        guard let lat = store.trustedLocation.latitude, let lon = store.trustedLocation.longitude else { return nil }
        return TrustedPin(coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                if let pin = trustedPin {
                    Map(coordinateRegion: $region, annotationItems: [pin]) { item in
                        MapMarker(coordinate: item.coordinate, tint: .accentColor)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .onAppear {
                        centerMap(to: pin.coordinate)
                    }
                    .onChange(of: store.trustedLocation.timestamp) { _ in
                        centerToTrustedLocationIfAvailable()
                    }
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "location.slash")
                            .font(.system(size: 42))
                            .foregroundStyle(.secondary)
                        Text("Нет доверенной геопозиции")
                            .font(.headline)
                        Text("Проверьте доступ к геолокации в Настройках и включите trusted navigation.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }

                locationStatusCard
            }
            .padding(12)
            .navigationTitle("Карта и геопозиция")
        }
    }

    private var locationStatusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Доверие")
                    .font(.subheadline.bold())
                Spacer()
                Text("\(store.trustedLocation.trustScore)% • \(store.locationTrustSummary)")
                    .font(.caption)
                    .foregroundStyle(store.trustedLocation.suspectedSpoofing ? .orange : .secondary)
            }
            if let lat = store.trustedLocation.latitude, let lon = store.trustedLocation.longitude {
                Text("lat: \(formatCoordinate(lat))")
                    .font(.system(.caption2, design: .monospaced))
                Text("lon: \(formatCoordinate(lon))")
                    .font(.system(.caption2, design: .monospaced))
            }
            if let accuracy = store.trustedLocation.horizontalAccuracy {
                Text("Точность: ±\(Int(accuracy)) м")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(store.trustedLocation.reason)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func centerToTrustedLocationIfAvailable() {
        guard let lat = store.trustedLocation.latitude, let lon = store.trustedLocation.longitude else { return }
        centerMap(to: CLLocationCoordinate2D(latitude: lat, longitude: lon))
    }

    private func centerMap(to coordinate: CLLocationCoordinate2D) {
        region = MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
        )
    }

    private func formatCoordinate(_ value: Double) -> String {
        String(format: "%.6f", value)
    }
}
