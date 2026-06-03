import Foundation
import CoreLocation
import CoreMotion

public enum LocationAuthorizationState: String, Equatable {
    case notDetermined
    case restricted
    case denied
    case authorizedWhenInUse
    case authorizedAlways
}

public enum LocationConfidenceTier: String, Equatable {
    case high
    case medium
    case low
    case unreliable
}

public struct TrustedLocationSnapshot: Equatable {
    public var latitude: Double?
    public var longitude: Double?
    public var horizontalAccuracy: Double?
    public var speedMetersPerSecond: Double?
    public var timestamp: Date?
    public var trustScore: Int
    public var confidence: LocationConfidenceTier
    public var suspectedSpoofing: Bool
    public var reason: String
    public var authorization: LocationAuthorizationState

    public static let unavailable = TrustedLocationSnapshot(
        latitude: nil,
        longitude: nil,
        horizontalAccuracy: nil,
        speedMetersPerSecond: nil,
        timestamp: nil,
        trustScore: 0,
        confidence: .unreliable,
        suspectedSpoofing: false,
        reason: "Нет данных геопозиции",
        authorization: .notDetermined
    )
}

public final class LocationTrustEngine: NSObject {
    public var onSnapshotChanged: ((TrustedLocationSnapshot) -> Void)?
    public var onDiagnostics: ((String) -> Void)?

    private let locationManager: CLLocationManager
    private let motionActivityManager = CMMotionActivityManager()
    private var authorization: LocationAuthorizationState = .notDetermined
    private var lastLocation: CLLocation?
    private var lastSnapshot: TrustedLocationSnapshot = .unavailable
    private var lastMotionStationary: Bool?
    private var isRunning = false
    private var isForeground = true

    public override init() {
        locationManager = CLLocationManager()
        super.init()
        locationManager.delegate = self
        locationManager.distanceFilter = 5
        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        locationManager.pausesLocationUpdatesAutomatically = true
        locationManager.activityType = .fitness
        updateAuthorization(locationManager.authorizationStatus)
    }

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        startMotionTrackingIfAvailable()
        requestLocationAccessIfNeeded()
        startLocationUpdatesForCurrentMode()
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        locationManager.stopUpdatingLocation()
        locationManager.stopMonitoringSignificantLocationChanges()
        motionActivityManager.stopActivityUpdates()
    }

    public func setForegroundActive(_ active: Bool) {
        isForeground = active
        guard isRunning else { return }
        startLocationUpdatesForCurrentMode()
    }

    private func requestLocationAccessIfNeeded() {
        switch locationManager.authorizationStatus {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            break
        case .restricted, .denied:
            publish(
                reason: "Доступ к геолокации отключен",
                trustScore: 0,
                suspectedSpoofing: false
            )
        @unknown default:
            break
        }
    }

    private func startLocationUpdatesForCurrentMode() {
        guard authorization == .authorizedAlways || authorization == .authorizedWhenInUse else { return }
        if isForeground {
            locationManager.stopMonitoringSignificantLocationChanges()
            locationManager.startUpdatingLocation()
        } else {
            locationManager.stopUpdatingLocation()
            locationManager.startMonitoringSignificantLocationChanges()
        }
    }

    private func startMotionTrackingIfAvailable() {
        guard CMMotionActivityManager.isActivityAvailable() else {
            lastMotionStationary = nil
            return
        }
        motionActivityManager.startActivityUpdates(to: .main) { [weak self] activity in
            guard let self, let activity else { return }
            self.lastMotionStationary = activity.stationary && !activity.walking && !activity.running && !activity.automotive
        }
    }

    private func updateAuthorization(_ status: CLAuthorizationStatus) {
        switch status {
        case .notDetermined: authorization = .notDetermined
        case .restricted: authorization = .restricted
        case .denied: authorization = .denied
        case .authorizedWhenInUse: authorization = .authorizedWhenInUse
        case .authorizedAlways: authorization = .authorizedAlways
        @unknown default: authorization = .restricted
        }
    }

    private func evaluate(location: CLLocation) {
        var score = 100
        var spoofSignals: [String] = []

        if location.horizontalAccuracy <= 0 {
            score -= 40
            spoofSignals.append("невалидная точность")
        } else if location.horizontalAccuracy > 300 {
            score -= 40
            spoofSignals.append("очень низкая точность")
        } else if location.horizontalAccuracy > 100 {
            score -= 20
            spoofSignals.append("низкая точность")
        }

        let age = abs(location.timestamp.timeIntervalSinceNow)
        if age > 20 {
            score -= 30
            spoofSignals.append("устаревшая позиция")
        } else if age > 10 {
            score -= 15
        }

        if let prev = lastLocation {
            let dt = max(0.1, location.timestamp.timeIntervalSince(prev.timestamp))
            let distance = location.distance(from: prev)
            let impliedSpeed = distance / dt
            if impliedSpeed > 120 {
                score -= 70
                spoofSignals.append("телепорт: \(Int(impliedSpeed)) м/с")
            } else if impliedSpeed > 65 {
                score -= 25
                spoofSignals.append("аномально высокая скорость")
            }
        }

        if location.speed > 90 {
            score -= 30
            spoofSignals.append("скорость датчика аномальна")
        }

        if let stationary = lastMotionStationary, stationary, location.speed > 12 {
            score -= 25
            spoofSignals.append("motion/location конфликт")
        }

        if #available(iOS 15.0, *) {
            if let src = location.sourceInformation, src.isSimulatedBySoftware {
                score -= 80
                spoofSignals.append("simulated by software")
            }
        }

        score = min(100, max(0, score))
        let suspectedSpoofing = spoofSignals.contains(where: {
            $0.contains("телепорт") || $0.contains("simulated") || $0.contains("конфликт")
        })

        let reason: String
        if spoofSignals.isEmpty {
            reason = "Позиция подтверждена по сенсорам устройства"
        } else {
            reason = spoofSignals.joined(separator: ", ")
        }

        publish(
            location: location,
            reason: reason,
            trustScore: score,
            suspectedSpoofing: suspectedSpoofing
        )
        lastLocation = location
    }

    private func publish(
        location: CLLocation? = nil,
        reason: String,
        trustScore: Int,
        suspectedSpoofing: Bool
    ) {
        let confidence: LocationConfidenceTier
        switch trustScore {
        case 80...100: confidence = .high
        case 55..<80: confidence = .medium
        case 30..<55: confidence = .low
        default: confidence = .unreliable
        }

        let snapshot = TrustedLocationSnapshot(
            latitude: location?.coordinate.latitude ?? lastSnapshot.latitude,
            longitude: location?.coordinate.longitude ?? lastSnapshot.longitude,
            horizontalAccuracy: location?.horizontalAccuracy ?? lastSnapshot.horizontalAccuracy,
            speedMetersPerSecond: location?.speed ?? lastSnapshot.speedMetersPerSecond,
            timestamp: location?.timestamp ?? lastSnapshot.timestamp,
            trustScore: trustScore,
            confidence: confidence,
            suspectedSpoofing: suspectedSpoofing,
            reason: reason,
            authorization: authorization
        )
        lastSnapshot = snapshot
        onDiagnostics?(reason)
        onSnapshotChanged?(snapshot)
    }
}

extension LocationTrustEngine: CLLocationManagerDelegate {
    public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        updateAuthorization(manager.authorizationStatus)
        requestLocationAccessIfNeeded()
        startLocationUpdatesForCurrentMode()
    }

    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let latest = locations.last else { return }
        evaluate(location: latest)
    }

    public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        publish(
            reason: "Ошибка геолокации: \(error.localizedDescription)",
            trustScore: 0,
            suspectedSpoofing: false
        )
    }
}
