import Foundation
import CoreLocation

public struct NetworkGeoEstimate: Equatable {
    public let coordinate: CLLocationCoordinate2D
    public let radiusMeters: CLLocationDistance
    public let source: String
    public let timestamp: Date
}

public final class NetworkGeoVerifier {
    private var cachedEstimate: NetworkGeoEstimate?
    private var lastAttemptAt: Date = .distantPast
    private let minRefreshInterval: TimeInterval = 180

    public init() {}

    public func latestEstimate() -> NetworkGeoEstimate? {
        cachedEstimate
    }

    public func refreshIfNeeded() async -> NetworkGeoEstimate? {
        let now = Date()
        if let cachedEstimate, now.timeIntervalSince(cachedEstimate.timestamp) < minRefreshInterval {
            return cachedEstimate
        }
        if now.timeIntervalSince(lastAttemptAt) < 20 {
            return cachedEstimate
        }
        lastAttemptAt = now

        if let ipapi = await fetchFromIPAPI() {
            cachedEstimate = ipapi
            return ipapi
        }
        if let ipWho = await fetchFromIPWhoIs() {
            cachedEstimate = ipWho
            return ipWho
        }
        return cachedEstimate
    }

    private func fetchFromIPAPI() async -> NetworkGeoEstimate? {
        guard let url = URL(string: "https://ipapi.co/json/") else { return nil }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return nil }
            let payload = try JSONDecoder().decode(IPAPICoResponse.self, from: data)
            let coordinate = CLLocationCoordinate2D(latitude: payload.latitude, longitude: payload.longitude)
            guard CLLocationCoordinate2DIsValid(coordinate) else { return nil }
            return NetworkGeoEstimate(
                coordinate: coordinate,
                radiusMeters: 40_000,
                source: "ipapi.co",
                timestamp: Date()
            )
        } catch {
            return nil
        }
    }

    private func fetchFromIPWhoIs() async -> NetworkGeoEstimate? {
        guard let url = URL(string: "https://ipwho.is/") else { return nil }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return nil }
            let payload = try JSONDecoder().decode(IPWhoIsResponse.self, from: data)
            guard payload.success else { return nil }
            let coordinate = CLLocationCoordinate2D(latitude: payload.latitude, longitude: payload.longitude)
            guard CLLocationCoordinate2DIsValid(coordinate) else { return nil }
            return NetworkGeoEstimate(
                coordinate: coordinate,
                radiusMeters: 60_000,
                source: "ipwho.is",
                timestamp: Date()
            )
        } catch {
            return nil
        }
    }
}

private struct IPAPICoResponse: Decodable {
    let latitude: Double
    let longitude: Double
}

private struct IPWhoIsResponse: Decodable {
    let success: Bool
    let latitude: Double
    let longitude: Double
}
