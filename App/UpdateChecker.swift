import Foundation
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

// MARK: - Installer type detection

public enum InstallerType: String {
    case trollstore = "TrollStore"
    case esign      = "ESign / GBox"
    case unknown    = "Unknown"

    public var displayName: String { rawValue }
    public var installInstructions: String {
        switch self {
        case .trollstore:
            return "Нажмите «Установить» — TrollStore установит обновление автоматически."
        case .esign, .unknown:
            return "Нажмите «Скачать» — откроется браузер. Скачайте IPA и откройте его в ESign / GBox для переподписи и установки."
        }
    }
}

// MARK: - UpdateChecker

@MainActor
public final class UpdateChecker: ObservableObject {
    public static let shared = UpdateChecker()

    @Published public var latestVersion: String?
    @Published public var isUpdateAvailable = false
    @Published public var releaseNotes: String?
    @Published public var downloadURL: URL?
    @Published public var releasePageURL: URL?
    @Published public var isChecking = false
    @Published public var lastCheckError: String?
    @Published public var lastCheckedAt: Date?

    // Detected once at launch
    public let installerType: InstallerType = UpdateChecker.detectInstaller()

    public var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }
    public var currentBuild: Int {
        Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1") ?? 1
    }
    public var currentVersionString: String { "\(currentVersion) (\(currentBuild))" }

    // User-configurable (stored in UserDefaults)
    private static let manifestURLKey   = "mesh.update.manifestURL"
    private static let githubTokenKey   = "mesh.update.githubToken"
    private static let lastCheckTimeKey = "mesh.update.lastCheckAt"

    public var manifestURL: String {
        get {
            UserDefaults.standard.string(forKey: Self.manifestURLKey)
                ?? "https://api.github.com/repos/vos1488/mesh-messenger-ios16-trollstore/releases/latest"
        }
        set { UserDefaults.standard.set(newValue, forKey: Self.manifestURLKey) }
    }

    /// Fine-grained GitHub PAT with "Contents: Read" permission on the repo.
    /// Required for private repos. Leave empty to disable update checks.
    public var githubToken: String {
        get { UserDefaults.standard.string(forKey: Self.githubTokenKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: Self.githubTokenKey) }
    }

    private init() {
        if let d = UserDefaults.standard.object(forKey: Self.lastCheckTimeKey) as? Date {
            lastCheckedAt = d
        }
    }

    // MARK: - TrollStore / ESign detection

    private static func detectInstaller() -> InstallerType {
        // TrollStore leaves recognisable artifacts on the file system
        let trollstoreMarkers: [String] = [
            "/Applications/TrollStore.app",
            "/var/lib/dpkg/info/com.opa334.trollstore.list",
            "/var/mobile/Library/Application Support/TrollStore",
            "/var/mobile/Documents/.TrollStore"
        ]
        for path in trollstoreMarkers {
            if FileManager.default.fileExists(atPath: path) {
                return .trollstore
            }
        }
        // TrollStore (< 2.0, persisted helper) places a helper in /Applications
        if let apps = try? FileManager.default.contentsOfDirectory(atPath: "/Applications") {
            for app in apps {
                if app.lowercased().contains("trollstore") { return .trollstore }
            }
        }
        return .esign
    }

    // MARK: - Version check

    /// Check for updates. Skips if last check was <1 hour ago (unless `force` is true).
    public func checkForUpdates(force: Bool = false) async {
        guard !isChecking else { return }
        if !force, let last = lastCheckedAt, Date().timeIntervalSince(last) < 3600 { return }
        isChecking = true
        lastCheckError = nil
        defer { isChecking = false }

        guard !manifestURL.isEmpty, let url = URL(string: manifestURL) else {
            lastCheckError = "Неверный URL манифеста"
            return
        }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        if !githubToken.isEmpty {
            request.setValue("Bearer \(githubToken)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("MeshMessenger/\(currentVersion) iOS-UpdateChecker", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                switch http.statusCode {
                case 401, 403:
                    lastCheckError = "Требуется GitHub Token (настройки → Обновления)"
                case 404:
                    lastCheckError = "Репозиторий или релиз не найден"
                default:
                    lastCheckError = "HTTP \(http.statusCode)"
                }
                return
            }
            try parseGitHubRelease(data: data)
            lastCheckedAt = Date()
            UserDefaults.standard.set(lastCheckedAt, forKey: Self.lastCheckTimeKey)
        } catch let error as UpdateError {
            lastCheckError = error.localizedDescription
        } catch {
            lastCheckError = error.localizedDescription
        }
    }

    private func parseGitHubRelease(data: Data) throws {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UpdateError.invalidJSON
        }

        // GitHub Releases API
        if let tagName = json["tag_name"] as? String {
            let remote = tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            latestVersion = remote
            releaseNotes = json["body"] as? String

            if let htmlURL = json["html_url"] as? String {
                releasePageURL = URL(string: htmlURL)
            }

            // Find the IPA asset
            if let assets = json["assets"] as? [[String: Any]] {
                for asset in assets {
                    if let name = asset["name"] as? String, name.hasSuffix(".ipa"),
                       let urlStr = asset["browser_download_url"] as? String {
                        downloadURL = URL(string: urlStr)
                        break
                    }
                }
            }
            if downloadURL == nil { downloadURL = releasePageURL }

            isUpdateAvailable = isNewer(remote, than: currentVersion)
            return
        }

        // Simple custom manifest: {"version":"1.1","download_url":"...","notes":"..."}
        if let v = json["version"] as? String {
            latestVersion = v
            releaseNotes = json["notes"] as? String
            if let dl = json["download_url"] as? String { downloadURL = URL(string: dl) }
            isUpdateAvailable = isNewer(v, than: currentVersion)
            return
        }

        throw UpdateError.invalidJSON
    }

    private func isNewer(_ remote: String, than local: String) -> Bool {
        let r = remote.split(separator: ".").compactMap { Int($0) }
        let l = local.split(separator: ".").compactMap { Int($0) }
        let count = max(r.count, l.count)
        for i in 0..<count {
            let rv = i < r.count ? r[i] : 0
            let lv = i < l.count ? l[i] : 0
            if rv > lv { return true }
            if rv < lv { return false }
        }
        return false
    }

    // MARK: - Install / open

    public func triggerInstall() {
#if canImport(UIKit)
        guard let url = downloadURL else { return }
        switch installerType {
        case .trollstore:
            // Try TrollStore URL scheme first
            let encoded = url.absoluteString
                .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            if let tsURL = URL(string: "apple-magnifier://install?url=\(encoded)"),
               UIApplication.shared.canOpenURL(tsURL) {
                UIApplication.shared.open(tsURL)
            } else {
                UIApplication.shared.open(url)
            }
        case .esign, .unknown:
            // Open release page / IPA URL in Safari; user imports into their tool
            UIApplication.shared.open(url)
        }
#endif
    }

    // MARK: - Errors

    enum UpdateError: LocalizedError {
        case invalidJSON
        var errorDescription: String? {
            switch self { case .invalidJSON: return "Не удалось разобрать ответ сервера" }
        }
    }
}
