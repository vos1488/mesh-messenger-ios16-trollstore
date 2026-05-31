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
        let uniquePeers: [PeerEntry] = {
            var seen = Set<String>()
            return store.peers.filter { seen.insert($0.peerID.value).inserted }
        }()
        let activePeers = uniquePeers.filter { !store.threadSettings(for: $0.peerID.value).isArchived }
        let archivedPeers = uniquePeers.filter { store.threadSettings(for: $0.peerID.value).isArchived }

        List {
            Section("Узлы сети (\(activePeers.count))") {
                ForEach(sortedPeers(activePeers)) { peer in
                    let peerID = peer.peerID.value
                    let settings = store.threadSettings(for: peerID)
                    NavigationLink(destination: ChatView(peer: peer).environmentObject(store)) {
                        PeerRowView(
                            peer: peer,
                            lastMessage: store.messages[peerID]?.last,
                            unreadCount: store.unreadCount(for: peer),
                            isPinned: settings.isPinned,
                            isMuted: settings.isMuted
                        )
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button {
                            store.setChatPinned(peerID: peerID, pinned: !settings.isPinned)
                        } label: {
                            Label(settings.isPinned ? "Открепить" : "Закрепить", systemImage: settings.isPinned ? "pin.slash" : "pin")
                        }
                        .tint(.yellow)
                        Button {
                            store.setChatMuted(peerID: peerID, muted: !settings.isMuted)
                        } label: {
                            Label(settings.isMuted ? "Включить звук" : "Без звука", systemImage: settings.isMuted ? "bell" : "bell.slash")
                        }
                        .tint(.indigo)
                        Button {
                            if store.unreadCount(for: peer) > 0 {
                                store.markConversationRead(peerID: peerID)
                            } else {
                                store.markConversationUnread(peerID: peerID)
                            }
                        } label: {
                            Label(store.unreadCount(for: peer) > 0 ? "Прочитано" : "Не прочитано", systemImage: "envelope.badge")
                        }
                        .tint(.blue)
                        Button {
                            store.setChatArchived(peerID: peerID, archived: true)
                        } label: {
                            Label("В архив", systemImage: "archivebox")
                        }
                        .tint(.gray)
                        Button(role: .destructive) {
                            store.clearChat(peerID: peerID)
                        } label: {
                            Label("Очистить", systemImage: "bubble.left.and.bubble.right")
                        }
                        Button(role: .destructive) {
                            store.removePeer(peerID: peerID)
                        } label: {
                            Label("Удалить", systemImage: "person.fill.xmark")
                        }
                        .tint(.red)
                    }
                }
            }
            if !archivedPeers.isEmpty {
                Section("Архив (\(archivedPeers.count))") {
                    ForEach(sortedPeers(archivedPeers)) { peer in
                        let peerID = peer.peerID.value
                        let settings = store.threadSettings(for: peerID)
                        NavigationLink(destination: ChatView(peer: peer).environmentObject(store)) {
                            PeerRowView(
                                peer: peer,
                                lastMessage: store.messages[peerID]?.last,
                                unreadCount: store.unreadCount(for: peer),
                                isPinned: settings.isPinned,
                                isMuted: settings.isMuted
                            )
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button {
                                store.setChatArchived(peerID: peerID, archived: false)
                            } label: {
                                Label("Из архива", systemImage: "tray.and.arrow.up")
                            }
                            .tint(.green)
                            Button {
                                store.setChatMuted(peerID: peerID, muted: !settings.isMuted)
                            } label: {
                                Label(settings.isMuted ? "Включить звук" : "Без звука", systemImage: settings.isMuted ? "bell" : "bell.slash")
                            }
                            .tint(.indigo)
                        }
                    }
                }
            }
            Section("Мой узел") {
                myIDCard
            }
        }
    }

    private func sortedPeers(_ peers: [PeerEntry]) -> [PeerEntry] {
        peers.sorted { a, b in
            let aSettings = store.threadSettings(for: a.peerID.value)
            let bSettings = store.threadSettings(for: b.peerID.value)
            if aSettings.isPinned != bSettings.isPinned {
                return aSettings.isPinned && !bSettings.isPinned
            }
            let aLast = store.messages[a.peerID.value]?.last?.timestamp ?? a.lastSeen
            let bLast = store.messages[b.peerID.value]?.last?.timestamp ?? b.lastSeen
            return aLast > bLast
        }
    }

    private var myIDCard: some View {
        HStack(spacing: 12) {
            // My own avatar — derived from my peerID so it's always consistent
            PeerAvatarView(peerID: store.myPeerURI, size: 44, isConnected: store.isRunning)
            VStack(alignment: .leading, spacing: 4) {
                Text(store.nickname)
                    .font(.headline)
                if !store.myPeerURI.isEmpty {
                    Text(store.myPeerURI)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
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
    var unreadCount: Int = 0
    var isPinned: Bool = false
    var isMuted: Bool = false

    var body: some View {
        HStack {
            PeerAvatarView(peerID: peer.peerID.value, size: 44, isConnected: peer.isConnected)
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
                HStack(spacing: 6) {
                    if isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                    }
                    if isMuted {
                        Image(systemName: "bell.slash.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if unreadCount > 0 {
                        Text(unreadCount > 99 ? "99+" : "\(unreadCount)")
                            .font(.caption2.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.accentColor))
                    }
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
