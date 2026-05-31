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
            return "Нажмите «Установить» — IPA скачается и передастся в TrollStore автоматически."
        case .esign, .unknown:
            return "Нажмите «Скачать» — IPA скачается и откроется меню «Поделиться» для импорта в ESign / GBox."
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
    @Published public var isInstallingUpdate = false
    @Published public var installStatusText: String?
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
    private static let defaultIPAName   = "MeshMessenger-TrollStore-unsigned.ipa"

    private var updateAssetAPIURL: URL?
    private var updateAssetName: String = defaultIPAName

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
                    lastCheckError = "Доступ запрещён. Если это приватный форк — добавьте GitHub Token в настройки."
                case 404:
                    lastCheckError = "Релиз не найден. Проверьте URL манифеста."
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

        updateAssetAPIURL = nil
        updateAssetName = Self.defaultIPAName
        downloadURL = nil

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
                    guard let name = asset["name"] as? String, name.hasSuffix(".ipa") else { continue }
                    updateAssetName = name
                    if let apiURLString = asset["url"] as? String {
                        updateAssetAPIURL = URL(string: apiURLString)
                    }
                    if let browserURLString = asset["browser_download_url"] as? String {
                        downloadURL = URL(string: browserURLString)
                    }
                    if let assetID = asset["id"] as? Int {
                        let fallbackAPI = "https://api.github.com/repos/vos1488/mesh-messenger-ios16-trollstore/releases/assets/\(assetID)"
                        updateAssetAPIURL = updateAssetAPIURL ?? URL(string: fallbackAPI)
                    }
                    if updateAssetAPIURL != nil || downloadURL != nil {
                        break
                    }
                }
            }
            if updateAssetAPIURL == nil && downloadURL == nil {
                throw UpdateError.ipaAssetNotFound
            }

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
        Task { [weak self] in
            await self?.downloadAndInstallUpdate()
        }
    }

    public func downloadAndInstallUpdate() async {
        guard !isInstallingUpdate else { return }
        guard isUpdateAvailable else {
            lastCheckError = "Новых обновлений пока нет"
            return
        }

        // Prefer browser_download_url for public repo (no auth needed).
        // Fall back to API URL (may require token for private forks).
        let source = downloadURL ?? updateAssetAPIURL
        guard let source else {
            lastCheckError = "Не найден IPA-ассет релиза"
            return
        }

        isInstallingUpdate = true
        lastCheckError = nil
        installStatusText = "Скачиваем IPA…"
        defer {
            isInstallingUpdate = false
            installStatusText = nil
        }

        do {
            let localIPA = try await downloadIPA(from: source)
            installStatusText = "Открываем установщик…"
            presentInstaller(for: localIPA)
        } catch let error as UpdateError {
            lastCheckError = error.localizedDescription
        } catch {
            lastCheckError = error.localizedDescription
        }
    }

    private func downloadIPA(from sourceURL: URL) async throws -> URL {
        var request = URLRequest(url: sourceURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 180)
        request.setValue("MeshMessenger/\(currentVersion) iOS-UpdateInstaller", forHTTPHeaderField: "User-Agent")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")

        // Add auth only if a token is configured (needed for private forks only)
        if shouldUseGitHubAuth(for: sourceURL), !githubToken.isEmpty {
            request.setValue("Bearer \(githubToken)", forHTTPHeaderField: "Authorization")
        }

        let (tempURL, response) = try await URLSession.shared.download(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UpdateError.invalidServerResponse
        }
        guard (200...299).contains(http.statusCode) else {
            switch http.statusCode {
            case 401, 403:
                throw UpdateError.missingTokenForPrivateRepo
            case 404:
                throw UpdateError.ipaAssetNotFound
            default:
                throw UpdateError.httpError(http.statusCode)
            }
        }

        let fileName = sanitizedFileName(updateAssetName)
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: tempURL, to: destination)
        return destination
    }

    private func shouldUseGitHubAuth(for url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        if host == "api.github.com" { return true }
        if host == "github.com", url.path.contains("/releases/") { return true }
        if host.contains("githubusercontent.com"), !githubToken.isEmpty {
            return true
        }
        return false
    }

    private func sanitizedFileName(_ name: String) -> String {
        let forbidden = CharacterSet(charactersIn: "\\/:*?\"<>|")
        let parts = name.components(separatedBy: forbidden)
        let cleaned = parts.joined(separator: "_")
        return cleaned.isEmpty ? Self.defaultIPAName : cleaned
    }

    private func presentInstaller(for localIPA: URL) {
#if canImport(UIKit)
        if installerType == .trollstore {
            let encoded = localIPA.absoluteString
                .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            if let tsURL = URL(string: "apple-magnifier://install?url=\(encoded)"),
               UIApplication.shared.canOpenURL(tsURL) {
                UIApplication.shared.open(tsURL)
                return
            }
        }
        presentShareSheet(for: localIPA)
#endif
    }

#if canImport(UIKit)
    private func presentShareSheet(for localIPA: URL) {
        guard let presenter = topMostViewController() else {
            lastCheckError = "Не удалось открыть меню установки"
            return
        }

        let activity = UIActivityViewController(activityItems: [localIPA], applicationActivities: nil)
        if let popover = activity.popoverPresentationController {
            popover.sourceView = presenter.view
            popover.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 1, height: 1)
        }
        presenter.present(activity, animated: true)
    }

    private func topMostViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windows = scenes.flatMap { $0.windows }
        let root = windows.first(where: \.isKeyWindow)?.rootViewController
        return traverseTop(from: root)
    }

    private func traverseTop(from controller: UIViewController?) -> UIViewController? {
        if let nav = controller as? UINavigationController {
            return traverseTop(from: nav.visibleViewController)
        }
        if let tab = controller as? UITabBarController {
            return traverseTop(from: tab.selectedViewController)
        }
        if let presented = controller?.presentedViewController {
            return traverseTop(from: presented)
        }
        return controller
    }
#endif

    // MARK: - Errors

    enum UpdateError: LocalizedError {
        case invalidJSON
        case missingTokenForPrivateRepo
        case ipaAssetNotFound
        case invalidServerResponse
        case httpError(Int)

        var errorDescription: String? {
            switch self {
            case .invalidJSON:
                return "Не удалось разобрать ответ сервера"
            case .missingTokenForPrivateRepo:
                return "Нужен GitHub Token с правом Contents: Read для закрытого репозитория"
            case .ipaAssetNotFound:
                return "IPA-файл не найден в последнем релизе"
            case .invalidServerResponse:
                return "Некорректный ответ сервера обновлений"
            case .httpError(let status):
                return "Ошибка загрузки IPA (HTTP \(status))"
            }
        }
    }
}
