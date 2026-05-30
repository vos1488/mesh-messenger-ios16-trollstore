import Foundation

public struct RouteEntry: Codable, Hashable, Sendable {
    public let destination: PeerID
    public let nextHop: PeerID
    public let cost: Int
    public let latencyMs: Int
    public let updatedAt: Date

    public init(destination: PeerID, nextHop: PeerID, cost: Int, latencyMs: Int, updatedAt: Date = Date()) {
        self.destination = destination
        self.nextHop = nextHop
        self.cost = cost
        self.latencyMs = latencyMs
        self.updatedAt = updatedAt
    }
}

public struct Packet: Codable, Sendable {
    public let envelope: MessageEnvelope
    public let routeTrace: [PeerID]

    public init(envelope: MessageEnvelope, routeTrace: [PeerID] = []) {
        self.envelope = envelope
        self.routeTrace = routeTrace
    }
}

