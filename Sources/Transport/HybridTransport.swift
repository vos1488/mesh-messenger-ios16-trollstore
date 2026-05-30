import Foundation

public final class HybridTransport {
    public var onMessageReceived: ((TransportMessage, PeerID) -> Void)?
    public var onPeerConnected: ((PeerID, String) -> Void)?
    public var onPeerDisconnected: ((PeerID) -> Void)?
    public var onPeerDiscovered: ((TransportDiscoveredPeer) -> Void)?
    public var onStreamReceived: ((InputStream, PeerID, String) -> Void)?

    public var streamTransport: MCPTransport { mcpTransport }

    private let mcpTransport: MCPTransport
    private let udpTransport: UDPTransport

    public init(
        localProfile: PeerProfile,
        signingPublicKey: Data,
        agreementPublicKey: Data,
        wanBootstrapEndpoints: [String]
    ) throws {
        mcpTransport = try MCPTransport(
            localProfile: localProfile,
            signingPublicKey: signingPublicKey,
            agreementPublicKey: agreementPublicKey
        )
        udpTransport = UDPTransport(
            localPeerID: localProfile.peerID.value,
            bootstrapEndpoints: wanBootstrapEndpoints
        )
        wireCallbacks()
    }

    public func updateWANBootstrapEndpoints(_ endpoints: [String]) {
        udpTransport.updateBootstrapEndpoints(endpoints)
    }

    public func start() {
        mcpTransport.start()
        try? udpTransport.start()
    }

    public func stop() {
        mcpTransport.stop()
        udpTransport.stop()
    }

    public func send(message: TransportMessage, to peerID: PeerID) throws {
        if mcpTransport.isPeerConnected(peerID) {
            try mcpTransport.send(message: message, to: peerID)
            return
        }
        guard shouldUseUDP(for: message.kind) else {
            throw TransportError.peerNotConnected
        }
        try udpTransport.send(message: message, to: peerID)
    }

    public func sendToConnectedPeers(message: TransportMessage, excludingPeerIDs: Set<String>) throws {
        var sent = false
        do {
            try mcpTransport.sendToConnectedPeers(message: message, excludingPeerIDs: excludingPeerIDs)
            sent = true
        } catch {}

        if shouldUseUDP(for: message.kind) {
            do {
                try udpTransport.sendToKnownPeers(message: message, excludingPeerIDs: excludingPeerIDs)
                sent = true
            } catch {}
        }

        if !sent {
            throw TransportError.peerNotConnected
        }
    }

    public func isPeerConnected(_ peerID: PeerID) -> Bool {
        mcpTransport.isPeerConnected(peerID) || udpTransport.isPeerConnected(peerID)
    }

    public func connectedPeerIDs() -> [String] {
        let mcp = Set(mcpTransport.connectedPeerIDs())
        let udp = Set(udpTransport.connectedPeerIDs())
        return Array(mcp.union(udp)).sorted()
    }

    public func peerKeys(peerID: PeerID) -> (signing: Data?, agreement: Data?) {
        mcpTransport.peerKeys(peerID: peerID)
    }

    public func sendHeartbeat(senderNickname: String) {
        udpTransport.sendHeartbeat(senderNickname: senderNickname)
    }

    private func wireCallbacks() {
        mcpTransport.onPeerDiscovered = { [weak self] discovered in
            self?.onPeerDiscovered?(discovered)
        }
        mcpTransport.onPeerConnected = { [weak self] peerID, displayName in
            self?.onPeerConnected?(peerID, displayName)
        }
        mcpTransport.onPeerDisconnected = { [weak self] peerID in
            self?.onPeerDisconnected?(peerID)
        }
        mcpTransport.onMessageReceived = { [weak self] message, peerID in
            self?.onMessageReceived?(message, peerID)
        }
        mcpTransport.onStreamReceived = { [weak self] stream, peerID, name in
            self?.onStreamReceived?(stream, peerID, name)
        }

        udpTransport.onPeerConnected = { [weak self] peerID in
            let display = "wan-\(peerID.value.prefix(8))"
            self?.onPeerConnected?(peerID, display)
        }
        udpTransport.onPeerDisconnected = { [weak self] peerID in
            self?.onPeerDisconnected?(peerID)
        }
        udpTransport.onMessageReceived = { [weak self] message, peerID in
            self?.onMessageReceived?(message, peerID)
        }
    }

    private func shouldUseUDP(for kind: TransportPacketKind) -> Bool {
        switch kind {
        case .chat, .ack, .readReceipt, .syncDigest, .relay, .callInvite, .callAccept, .callDecline, .callEnd:
            return true
        case .fileMeta, .fileChunk:
            // 64KB chunks are too large for UDP datagrams, keep file transport on MCP relay for now.
            return false
        }
    }
}
