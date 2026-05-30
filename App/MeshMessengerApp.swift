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
    @State private var peerIDText = "Initializing..."
    @State private var statusText = "Node is offline"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("MeshMessenger")
                .font(.largeTitle)
                .bold()

            Text("PeerID")
                .font(.headline)
            Text(peerIDText)
                .font(.footnote)
                .textSelection(.enabled)

            Text(statusText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding()
        .onAppear {
            do {
                let identity = try IdentityEngine(
                    nickname: "iOS Node",
                    capabilities: [.chat, .voice, .video, .relay, .files]
                )
                peerIDText = identity.identity.profile.peerID.uri
                statusText = "Ready for mesh discovery"
            } catch {
                peerIDText = "Identity init failed"
                statusText = error.localizedDescription
            }
        }
    }
}

