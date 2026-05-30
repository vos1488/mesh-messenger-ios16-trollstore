import SwiftUI

struct PeerListView: View {
    @EnvironmentObject var store: NodeStore
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            Group {
                if store.peers.isEmpty {
                    emptyState
                } else {
                    peerList
                }
            }
            .navigationTitle("Mesh Peers")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    statusBadge
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gear")
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
                    .environmentObject(store)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 60))
                .foregroundStyle(.secondary)
            Text("Ищем пиров…")
                .font(.title2)
                .bold()
            Text("Убедитесь, что на другом устройстве запущен MeshMessenger и они в одной сети (Wi-Fi) или рядом (Bluetooth)")
                .multilineTextAlignment(.center)
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)
            Spacer()
            myIDCard
                .padding()
        }
    }

    private var peerList: some View {
        List {
            Section("Узлы сети (\(store.peers.count))") {
                ForEach(store.peers) { peer in
                    NavigationLink(destination: ChatView(peer: peer).environmentObject(store)) {
                        PeerRowView(peer: peer)
                    }
                }
            }
            Section("Мой узел") {
                myIDCard
            }
        }
    }

    private var myIDCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(store.nickname, systemImage: "person.circle.fill")
                .font(.headline)
            if !store.myPeerURI.isEmpty {
                Text(store.myPeerURI)
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }

    private var statusBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(store.isRunning ? .green : .red)
                .frame(width: 8, height: 8)
            Text(store.isRunning ? "\(store.connectedCount()) подкл." : "Офлайн")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct PeerRowView: View {
    let peer: PeerEntry

    var body: some View {
        HStack {
            ZStack(alignment: .bottomTrailing) {
                Circle()
                    .fill(Color.accentColor.opacity(0.15))
                    .frame(width: 44, height: 44)
                Text(String(peer.nickname.prefix(1)).uppercased())
                    .font(.headline)
                    .foregroundStyle(.accentColor)
                Circle()
                    .fill(peer.isConnected ? .green : .gray)
                    .frame(width: 12, height: 12)
                    .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(peer.nickname)
                    .font(.headline)
                    .lineLimit(1)
                Text(peer.isConnected ? "Подключён" : "Последний раз: \(relativeTime(peer.lastSeen))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }

    private func relativeTime(_ date: Date) -> String {
        let interval = -date.timeIntervalSinceNow
        if interval < 60 { return "только что" }
        if interval < 3600 { return "\(Int(interval/60)) мин. назад" }
        return "\(Int(interval/3600)) ч. назад"
    }
}
