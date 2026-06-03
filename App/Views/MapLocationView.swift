import SwiftUI
import MapKit
import Foundation

struct MapLocationView: View {
    @EnvironmentObject var store: NodeStore
    @State private var shouldFollowLocation = false
    @State private var hasInitialCenter = false
    @State private var isProgrammaticRegionUpdate = false
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
        ZStack(alignment: .top) {
            Map(coordinateRegion: $region, annotationItems: trustedPin.map { [$0] } ?? []) { item in
                MapMarker(coordinate: item.coordinate, tint: .accentColor)
            }
            .ignoresSafeArea(edges: .top)
            .onAppear {
                if !hasInitialCenter {
                    centerToTrustedLocationIfAvailable(preserveZoom: false)
                    hasInitialCenter = true
                }
            }
            .onChange(of: store.trustedLocation.timestamp) { _ in
                if shouldFollowLocation {
                    centerToTrustedLocationIfAvailable(preserveZoom: true)
                }
            }
            .onChange(of: region.center.latitude) { _ in
                handleRegionChanged()
            }
            .onChange(of: region.center.longitude) { _ in
                handleRegionChanged()
            }
            .onChange(of: region.span.latitudeDelta) { _ in
                handleRegionChanged()
            }
            .onChange(of: region.span.longitudeDelta) { _ in
                handleRegionChanged()
            }

            VStack(spacing: 10) {
                topBar
                Spacer()
                locationStatusCard
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
            }
            .padding(.top, 8)
        }
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "location.fill")
                    .font(.caption)
                    .foregroundStyle(store.trustedLocation.suspectedSpoofing ? .orange : .green)
                Text("Геопозиция")
                    .font(.subheadline.bold())
            }
            Spacer()
            Button {
                shouldFollowLocation.toggle()
                if shouldFollowLocation {
                    centerToTrustedLocationIfAvailable(preserveZoom: true)
                }
            } label: {
                Image(systemName: shouldFollowLocation ? "location.fill" : "location")
                    .font(.headline)
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            Button {
                centerToTrustedLocationIfAvailable(preserveZoom: true)
            } label: {
                Image(systemName: "location.viewfinder")
                    .font(.headline)
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 12)
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
            if let speed = store.trustedLocation.speedMetersPerSecond, speed >= 0 {
                Text("Скорость: \(Int(speed * 3.6)) км/ч")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(store.trustedLocation.reason)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func centerToTrustedLocationIfAvailable(preserveZoom: Bool) {
        guard let lat = store.trustedLocation.latitude, let lon = store.trustedLocation.longitude else { return }
        centerMap(to: CLLocationCoordinate2D(latitude: lat, longitude: lon), preserveZoom: preserveZoom)
    }

    private func centerMap(to coordinate: CLLocationCoordinate2D, preserveZoom: Bool) {
        isProgrammaticRegionUpdate = true
        let span = preserveZoom
            ? region.span
            : MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
        region = MKCoordinateRegion(
            center: coordinate,
            span: span
        )
        DispatchQueue.main.async {
            isProgrammaticRegionUpdate = false
        }
    }

    private func handleRegionChanged() {
        guard !isProgrammaticRegionUpdate else { return }
        shouldFollowLocation = false
    }

    private func formatCoordinate(_ value: Double) -> String {
        String(format: "%.6f", value)
    }
}
