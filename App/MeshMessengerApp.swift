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
    @State private var selectedTab: AppTab = .chats

    private enum AppTab: Hashable {
        case chats
        case map
    }

    private var showCallScreen: Bool {
        if let call = store.activeCall {
            return call.phase != .ended
        }
        return false
    }

    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(
                colors: [
                    Color(red: 0.06, green: 0.10, blue: 0.18),
                    Color(red: 0.08, green: 0.12, blue: 0.24),
                    Color(red: 0.05, green: 0.08, blue: 0.16)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            Group {
                if store.isRunning {
                    TabView(selection: $selectedTab) {
                        PeerListView()
                            .tag(AppTab.chats)
                            .tabItem {
                                Label("Чаты", systemImage: "bubble.left.and.bubble.right.fill")
                            }

                        MapLocationView()
                            .environmentObject(store)
                            .tag(AppTab.map)
                            .tabItem {
                                Label("Карта", systemImage: "map.fill")
                            }
                    }
                    .toolbarBackground(.visible, for: .tabBar)
                    .toolbarBackground(.ultraThinMaterial, for: .tabBar)
                } else {
                    LaunchView()
                }
            }
            .animation(.easeInOut, value: store.isRunning)

            // Update banner floats over content
            if store.isRunning {
                UpdateBannerView()
                    .transition(.asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity),
                        removal: .move(edge: .top).combined(with: .opacity)
                    ))
                    .animation(.spring(response: 0.4), value: UpdateChecker.shared.isUpdateAvailable)
            }
        }
        .task {
            if !store.isRunning {
                await store.start()
            }
        }
        .task {
            // Always check on cold start so update banner appears immediately after new releases
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            await UpdateChecker.shared.checkForUpdates(force: true)
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
        .whatsNewOnUpdate()
    }
}

struct LaunchView: View {
    @EnvironmentObject var store: NodeStore

    var body: some View {
        ZStack {
            VStack(spacing: 20) {
                Spacer()
                VStack(spacing: 16) {
                    Image(systemName: "antenna.radiowaves.left.and.right.circle.fill")
                        .font(.system(size: 80))
                        .foregroundStyle(Color.accentColor)
                    Text("MeshWave")
                        .font(.largeTitle)
                        .bold()
                    Text("Полноценная mesh-сеть: чат, карта, звонки, relay")
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
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 30)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .stroke(Color.white.opacity(0.18), lineWidth: 1)
                )

                Spacer()
            }
        }
        .padding(.horizontal, 20)
    }
}

