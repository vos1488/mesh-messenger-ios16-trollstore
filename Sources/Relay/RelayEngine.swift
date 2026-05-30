import Foundation

public enum RelayDecision: Sendable {
    case deliverLocal
    case forward(nextHop: PeerID, packet: Packet)
    case drop(reason: String)
}

public actor RelayEngine {
    private let routingEngine: RoutingEngine
    private let cryptoEngine: CryptoEngine

    public init(routingEngine: RoutingEngine, cryptoEngine: CryptoEngine) {
        self.routingEngine = routingEngine
        self.cryptoEngine = cryptoEngine
    }

    public func handle(packet: Packet, localPeerID: PeerID) async -> RelayDecision {
        if packet.envelope.receiver == localPeerID {
            return .deliverLocal
        }

        guard packet.envelope.ttl > 0 else {
            return .drop(reason: "TTL exhausted")
        }

        do {
            try cryptoEngine.verify(container: packet.envelope.payload)
        } catch {
            return .drop(reason: "Invalid signature")
        }

        guard let route = await routingEngine.nextHop(for: packet.envelope.receiver) else {
            return .drop(reason: "No route to destination")
        }

        let forwarded = Packet(
            envelope: MessageEnvelope(
                messageID: packet.envelope.messageID,
                type: packet.envelope.type,
                sender: packet.envelope.sender,
                receiver: packet.envelope.receiver,
                timestamp: packet.envelope.timestamp,
                ttl: packet.envelope.ttl - 1,
                payload: packet.envelope.payload
            ),
            routeTrace: packet.routeTrace + [localPeerID]
        )
        return .forward(nextHop: route.nextHop, packet: forwarded)
    }
}

