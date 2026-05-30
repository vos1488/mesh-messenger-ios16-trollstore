import Foundation
import SwiftUI
import Combine

public struct PeerEntry: Identifiable, Equatable, Codable {
    public let id: String
    public var peerID: PeerID
    public var nickname: String
    public var isConnected: Bool
    public var lastSeen: Date

    public init(peerID: PeerID, nickname: String, isConnected: Bool = false) {
        self.id = peerID.value
        self.peerID = peerID
        self.nickname = nickname
        self.isConnected = isConnected
        self.lastSeen = Date()
    }
}

public struct ChatMessage: Identifiable, Equatable, Codable {
    public let id: UUID
    public let text: String
    public let senderID: String
    public let senderNickname: String
    public let isMe: Bool
    public let timestamp: Date

    public init(id: UUID = UUID(), text: String, senderID: String,
                senderNickname: String, isMe: Bool, timestamp: Date = Date()) {
        self.id = id; self.text = text; self.senderID = senderID
        self.senderNickname = senderNickname; self.isMe = isMe; self.timestamp = timestamp
    }
}

// MARK: - Persistence helpers

private let storeDir: URL = {
    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    let dir = docs.appendingPathComponent("MeshMessenger", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}()

private func chatsDir() -> URL {
    let dir = storeDir.appendingPathComponent("chats", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func peersURL() -> URL { storeDir.appendingPathComponent("peers.json") }
private func threadURL(peerID: String) -> URL { chatsDir().appendingPathComponent("\(peerID).json") }

private let enc: JSONEncoder = {
    let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e
}()
private let dec: JSONDecoder = {
    let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
}()

@MainActor
public final class NodeStore: ObservableObject {
    @Published public var peers: [PeerEntry] = []
    @Published public var messages: [String: [ChatMessage]] = [:]
    @Published public var nickname: String = "iOS Node"
    @Published public var myPeerURI: String = ""
    @Published public var isRunning: Bool = false
    @Published public var errorMessage: String? = nil

    private var transport: MCPTransport?
    private var myPeerIDValue: String = ""

    public static let shared = NodeStore()
    private init() {
        loadPersistedData()
    }

    // MARK: - Lifecycle

    public func start() async {
        guard !isRunning else { return }
        let savedNick = UserDefaults.standard.string(forKey: "mesh_nickname") ?? nickname

        do {
            let identity = try await Task.detached(priority: .userInitiated) {
                try IdentityEngine(nickname: savedNick, capabilities: [.chat, .relay, .files])
            }.value

            let profile = identity.identity.profile
            myPeerIDValue = profile.peerID.value
            myPeerURI = profile.peerID.uri
            nickname = profile.nickname

            let t = try MCPTransport(localProfile: profile)

            t.onPeerConnected = { [weak self] peerID, displayName in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    // Try to extract nickname from displayName ("nick#hex8")
                    let nick = displayName.components(separatedBy: "#").first ?? String(peerID.value.prefix(8))
                    if let idx = self.peers.firstIndex(where: { $0.peerID.value == peerID.value }) {
                        self.peers[idx].isConnected = true
                        self.peers[idx].lastSeen = Date()
                        if self.peers[idx].nickname.hasPrefix("peer://") || self.peers[idx].nickname.count == 8 {
                            self.peers[idx].nickname = nick
                        }
                    } else {
                        self.peers.append(PeerEntry(peerID: peerID, nickname: nick, isConnected: true))
                    }
                    self.savePeers()
                }
            }

            t.onPeerDisconnected = { [weak self] peerID in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let idx = self.peers.firstIndex(where: { $0.peerID.value == peerID.value }) {
                        self.peers[idx].isConnected = false
                        self.peers[idx].lastSeen = Date()
                    }
                    self.savePeers()
                }
            }

            t.onMessageReceived = { [weak self] msg, fromPeerID in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let key = fromPeerID.value
                    var thread = self.messages[key] ?? []
                    guard !thread.contains(where: { $0.id == msg.id }) else { return }
                    thread.append(ChatMessage(
                        id: msg.id, text: msg.text, senderID: fromPeerID.value,
                        senderNickname: msg.senderNickname, isMe: false, timestamp: msg.timestamp
                    ))
                    self.messages[key] = thread
                    self.saveThread(peerID: key, messages: thread)
                    // Upsert peer entry
                    if let idx = self.peers.firstIndex(where: { $0.peerID.value == key }) {
                        self.peers[idx].nickname = msg.senderNickname
                        self.peers[idx].lastSeen = msg.timestamp
                        self.peers[idx].isConnected = true
                    } else {
                        var entry = PeerEntry(peerID: fromPeerID, nickname: msg.senderNickname, isConnected: true)
                        entry.lastSeen = msg.timestamp
                        self.peers.append(entry)
                    }
                    self.savePeers()
                }
            }

            transport = t
            t.start()
            isRunning = true
            errorMessage = nil

        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func stop() {
        transport?.stop()
        transport = nil
        isRunning = false
    }

    public func send(text: String, to peer: PeerEntry) {
        guard let t = transport, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let msg = TransportMessage(senderPeerID: myPeerIDValue, senderNickname: nickname, text: text)
        do {
            try t.send(message: msg, to: peer.peerID)
            let chatMsg = ChatMessage(
                id: msg.id, text: text, senderID: myPeerIDValue,
                senderNickname: nickname, isMe: true, timestamp: msg.timestamp
            )
            var thread = messages[peer.peerID.value] ?? []
            thread.append(chatMsg)
            messages[peer.peerID.value] = thread
            saveThread(peerID: peer.peerID.value, messages: thread)
        } catch {
            errorMessage = "Не удалось отправить: \(error.localizedDescription)"
        }
    }

    public func saveNickname(_ newNick: String) {
        nickname = newNick
        UserDefaults.standard.set(newNick, forKey: "mesh_nickname")
    }

    public func unreadCount(for peer: PeerEntry) -> Int {
        (messages[peer.peerID.value] ?? []).filter { !$0.isMe }.count
    }

    public func connectedCount() -> Int {
        peers.filter(\.isConnected).count
    }

    // MARK: - Persistence

    private func loadPersistedData() {
        // Load known peers
        if let data = try? Data(contentsOf: peersURL()),
           let stored = try? dec.decode([PeerEntry].self, from: data) {
            // Mark all as offline on startup
            peers = stored.map {
                var p = $0; p.isConnected = false; return p
            }
        }
        // Load all chat threads
        let dir = chatsDir()
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ) else { return }
        for file in files where file.pathExtension == "json" {
            let peerID = file.deletingPathExtension().lastPathComponent
            if let data = try? Data(contentsOf: file),
               let thread = try? dec.decode([ChatMessage].self, from: data) {
                messages[peerID] = thread
            }
        }
    }

    private func savePeers() {
        guard let data = try? enc.encode(peers) else { return }
        try? data.write(to: peersURL(), options: .atomic)
    }

    private func saveThread(peerID: String, messages: [ChatMessage]) {
        guard let data = try? enc.encode(messages) else { return }
        try? data.write(to: threadURL(peerID: peerID), options: .atomic)
    }
}
