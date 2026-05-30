import Foundation

public final class Node {
    public let identityEngine: IdentityEngine
    public let cryptoEngine: CryptoEngine
    public let messagingEngine: MessagingEngine
    public let routingEngine: RoutingEngine
    public let relayEngine: RelayEngine
    public let fileTransferEngine: FileTransferEngine
    public let syncEngine: SyncEngine
    public let dhtEngine: DHTEngine
    public let storageEngine: StorageEngine
    public let discoveryEngine: any DiscoveryEngine
    public let callEngine: WebRTCCallEngine
    public var onStorageError: ((Error) -> Void)?
    public var onDiscoveryError: ((Error) -> Void)?

    public init(nickname: String, databaseURL: URL) throws {
        identityEngine = try IdentityEngine(
            nickname: nickname,
            capabilities: [.chat, .voice, .video, .relay, .files]
        )
        cryptoEngine = CryptoEngine(identityEngine: identityEngine)
        messagingEngine = MessagingEngine()
        routingEngine = RoutingEngine()
        relayEngine = RelayEngine(routingEngine: routingEngine, cryptoEngine: cryptoEngine)
        fileTransferEngine = FileTransferEngine()
        syncEngine = SyncEngine()
        dhtEngine = DHTEngine()
        storageEngine = try StorageEngine(databaseURL: databaseURL)
        try storageEngine.bootstrapSchema()
        discoveryEngine = try MCPDiscoveryEngine(localProfile: identityEngine.identity.profile)
        callEngine = WebRTCCallEngine()

        discoveryEngine.onPeerFound = { [weak self] profile in
            guard let self else { return }
            Task {
                await self.dhtEngine.upsert(peer: profile)
                do {
                    try self.storageEngine.save(peer: profile)
                } catch {
                    self.onStorageError?(error)
                }
            }
        }
        discoveryEngine.onDiscoveryError = { [weak self] error in
            self?.onDiscoveryError?(error)
        }
    }

    public var localPeerID: PeerID {
        identityEngine.identity.profile.peerID
    }

    public func start() {
        discoveryEngine.start()
    }

    public func stop() {
        discoveryEngine.stop()
    }

    @discardableResult
    public func sendText(_ text: String, to receiver: PeerID, receiverAgreementPublicKey: Data) async throws -> MessageEnvelope {
        let encrypted = try cryptoEngine.encrypt(Data(text.utf8), for: receiverAgreementPublicKey)
        let envelope = MessageEnvelope(
            type: .text,
            sender: identityEngine.identity.profile.peerID,
            receiver: receiver,
            payload: encrypted
        )
        await messagingEngine.enqueue(envelope)
        try storageEngine.save(message: envelope, status: .pending)
        return envelope
    }

    public func receive(packet: Packet) async -> RelayDecision {
        let decision = await relayEngine.handle(packet: packet, localPeerID: localPeerID)
        if case .deliverLocal = decision {
            let accepted = await messagingEngine.acceptIncoming(packet.envelope)
            if accepted {
                do {
                    try storageEngine.save(message: packet.envelope, status: .delivered)
                } catch {
                    onStorageError?(error)
                }
            }
        }
        return decision
    }

    public func localSyncDigest() async -> SyncDigest {
        let messages = await messagingEngine.knownMessageIDs()
        let files = await fileTransferEngine.knownTransferIDs()
        let routes = await routingEngine.knownRouteDestinations()
        return syncEngine.buildDigest(knownMessages: messages, knownFiles: files, knownRoutes: routes)
    }

    public func syncDiff(remoteDigest: SyncDigest) async -> SyncDiff {
        let local = await localSyncDigest()
        return syncEngine.diff(local: local, remote: remoteDigest)
    }
}

