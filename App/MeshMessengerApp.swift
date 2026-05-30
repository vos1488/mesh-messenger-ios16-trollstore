import SwiftUI

@main
struct MeshMessengerApp: App {
    var body: some Scene {
        WindowGroup {
            HomeView()
        }
    }
}

struct HomeView: View {
    enum LaunchState {
        case idle
        case loading
        case ready(peerURI: String)
        case failed(message: String)
    }

    @State private var launchState: LaunchState = .idle

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("MeshMessenger")
                .font(.largeTitle)
                .bold()

            switch launchState {
            case .idle, .loading:
                ProgressView()
                Text("Запуск узла…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

            case .ready(let peerURI):
                Text("PeerID")
                    .font(.headline)
                Text(peerURI)
                    .font(.footnote)
                    .textSelection(.enabled)
                Text("Готов к mesh discovery")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

            case .failed(let message):
                Text("Не удалось инициализировать узел")
                    .font(.headline)
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Повторить") {
                    Task { await initializeIdentity() }
                }
            }
        }
        .padding()
        .task {
            if case .idle = launchState {
                await initializeIdentity()
            }
        }
    }

    private func initializeIdentity() async {
        launchState = .loading
        do {
            let identity = try await Task.detached(priority: .userInitiated) {
                try IdentityEngine(
                    nickname: "iOS Node",
                    capabilities: [.chat, .voice, .video, .relay, .files]
                )
            }.value
            launchState = .ready(peerURI: identity.identity.profile.peerID.uri)
        } catch {
            launchState = .failed(message: error.localizedDescription)
        }
    }
}

