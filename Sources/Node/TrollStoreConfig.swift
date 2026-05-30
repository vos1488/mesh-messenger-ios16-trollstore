import Foundation

public struct TrollStoreConfig {
    public static let minimumIOS = "16.0"
    public static let bundleHint = "Install with TrollStore for persistent sideloading."

    // Keep runtime requirements explicit so app startup can fail fast if not met.
    public static let requiredCapabilities = [
        "com.apple.developer.networking.multicast",
        "bluetooth-central",
        "bluetooth-peripheral"
    ]
}

