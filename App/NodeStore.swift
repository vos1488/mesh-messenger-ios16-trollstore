import Foundation
import SwiftUI
import Combine

public struct PeerEntry: Identifiable, Equatable {
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

public struct ChatMessage: Identifiable, Equatable {
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
    private init() {}

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

            t.onPeerConnected = { [weak self] peerID, _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let idx = self.peers.firstIndex(where: { $0.peerID.value == peerID.value }) {
                        self.peers[idx].isConnected = true
                        self.peers[idx].lastSeen = Date()
                    } else {
                        let shortID = String(peerID.value.prefix(8))
                        self.peers.append(PeerEntry(peerID: peerID, nickname: shortID, isConnected: true))
                    }
                }
            }

            t.onPeerDisconnected = { [weak self] peerID in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let idx = self.peers.firstIndex(where: { $0.peerID.value == peerID.value }) {
                        self.peers[idx].isConnected = false
                        self.peers[idx].lastSeen = Date()
                    }
                }
            }

            t.onMessageReceived = { [weak self] msg, fromPeerID in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let chatMsg = ChatMessage(
                        id: msg.id,
                        text: msg.text,
                        senderID: fromPeerID.value,
                        senderNickname: msg.senderNickname,
                        isMe: false,
                        timestamp: msg.timestamp
                    )
                    let key = fromPeerID.value
                    var thread = self.messages[key] ?? []
                    guard !thread.contains(where: { $0.id == msg.id }) else { return }
                    thread.append(chatMsg)
                    self.messages[key] = thread
                    // Update peer entry
                    if let idx = self.peers.firstIndex(where: { $0.peerID.value == key }) {
                        self.peers[idx].nickname = msg.senderNickname
                        self.peers[idx].lastSeen = msg.timestamp
                    } else {
                        var entry = PeerEntry(peerID: fromPeerID, nickname: msg.senderNickname, isConnected: true)
                        entry.lastSeen = msg.timestamp
                        self.peers.append(entry)
                    }
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
}
