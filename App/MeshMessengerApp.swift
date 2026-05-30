import SwiftUI

@main
struct MeshMessengerApp: App {
    @StateObject private var store = NodeStore.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
        }
    }
}

struct RootView: View {
    @EnvironmentObject var store: NodeStore
    @Environment(\.scenePhase) private var scenePhase

    private var showCallScreen: Bool {
        if let call = store.activeCall {
            return call.phase != .ended
        }
        return false
    }

    var body: some View {
        Group {
            if store.isRunning {
                PeerListView()
            } else {
                LaunchView()
            }
        }
        .task {
            if !store.isRunning {
                await store.start()
            }
        }
        .onChange(of: scenePhase) { phase in
            store.handleScenePhase(phase)
        }
        .alert(item: $store.incomingCall) { offer in
            Alert(
                title: Text("Входящий звонок"),
                message: Text("\(offer.peerNickname) (\(offer.media.rawValue))"),
                primaryButton: .default(Text("Ответить")) {
                    store.acceptIncomingCall(offer)
                },
                secondaryButton: .destructive(Text("Отклонить")) {
                    store.declineIncomingCall(offer)
                }
            )
        }
        .fullScreenCover(
            isPresented: Binding(
                get: { showCallScreen },
                set: { isPresented in
                    if !isPresented, store.activeCall?.phase == .ended {
                        store.activeCall = nil
                    }
                }
            )
        ) {
            ActiveCallView()
                .environmentObject(store)
        }
    }
}

struct LaunchView: View {
    @EnvironmentObject var store: NodeStore

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "antenna.radiowaves.left.and.right.circle.fill")
                .font(.system(size: 80))
                .foregroundStyle(Color.accentColor)
            Text("MeshMessenger")
                .font(.largeTitle)
                .bold()
            Text("Децентрализованный P2P мессенджер")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if let error = store.errorMessage {
                VStack(spacing: 8) {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    Button("Повторить") {
                        Task { await store.start() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                ProgressView("Запуск узла…")
            }
            Spacer()
        }
    }
}

