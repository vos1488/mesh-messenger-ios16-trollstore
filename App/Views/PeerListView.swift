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
                // Deduplicate by peerID before displaying
                let uniquePeers: [PeerEntry] = {
                    var seen = Set<String>()
                    return store.peers.filter { seen.insert($0.peerID.value).inserted }
                }()
                ForEach(uniquePeers.sorted { a, b in
                    let aLast = store.messages[a.peerID.value]?.last?.timestamp ?? a.lastSeen
                    let bLast = store.messages[b.peerID.value]?.last?.timestamp ?? b.lastSeen
                    return aLast > bLast
                }) { peer in
                    NavigationLink(destination: ChatView(peer: peer).environmentObject(store)) {
                        PeerRowView(peer: peer, lastMessage: store.messages[peer.peerID.value]?.last)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            store.clearChat(peerID: peer.peerID.value)
                        } label: {
                            Label("Очистить", systemImage: "bubble.left.and.bubble.right")
                        }
                        Button(role: .destructive) {
                            store.removePeer(peerID: peer.peerID.value)
                        } label: {
                            Label("Удалить", systemImage: "person.fill.xmark")
                        }
                        .tint(.red)
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
    var lastMessage: ChatMessage? = nil

    var body: some View {
        HStack {
            ZStack(alignment: .bottomTrailing) {
                Circle()
                    .fill(Color.accentColor.opacity(0.15))
                    .frame(width: 44, height: 44)
                Text(String(peer.nickname.prefix(1)).uppercased())
                    .font(.headline)
                    .foregroundStyle(Color.accentColor)
                Circle()
                    .fill(peer.isConnected ? .green : .gray)
                    .frame(width: 12, height: 12)
                    .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(peer.nickname)
                    .font(.headline)
                    .lineLimit(1)
                if let warning = peer.trustWarning, !warning.isEmpty {
                    Text("⚠️ \(warning)")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }
                if let last = lastMessage {
                    Text((last.isMe ? "Вы: " : "") + last.text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    let trustSuffix = peer.isVerified ? " • verified" : ""
                    Text((peer.isConnected ? "Подключён" : "Был: \(relativeTime(peer.lastSeen))") + trustSuffix)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                if let last = lastMessage {
                    Text(timeString(last.timestamp))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func relativeTime(_ date: Date) -> String {
        let interval = -date.timeIntervalSinceNow
        if interval < 60 { return "только что" }
        if interval < 3600 { return "\(Int(interval/60)) мин. назад" }
        return "\(Int(interval/3600)) ч. назад"
    }

    private func timeString(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) {
            let f = DateFormatter(); f.timeStyle = .short; return f.string(from: date)
        }
        let f = DateFormatter(); f.dateFormat = "d MMM"; return f.string(from: date)
    }
}
