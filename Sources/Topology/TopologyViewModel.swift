import Foundation

#if canImport(SwiftUI)
import SwiftUI
#endif

public struct TopologyNode: Identifiable, Hashable, Sendable {
    public let id: PeerID
    public let nickname: String

    public init(id: PeerID, nickname: String) {
        self.id = id
        self.nickname = nickname
    }
}

public struct TopologyEdge: Identifiable, Hashable, Sendable {
    public let id: String
    public let from: PeerID
    public let to: PeerID
    public let latencyMs: Int

    public init(from: PeerID, to: PeerID, latencyMs: Int) {
        self.from = from
        self.to = to
        self.latencyMs = latencyMs
        id = "\(from.value)->\(to.value)"
    }
}

#if canImport(SwiftUI)
@MainActor
public final class TopologyViewModel: ObservableObject {
    @Published public private(set) var nodes: [TopologyNode] = []
    @Published public private(set) var edges: [TopologyEdge] = []

    public init() {}

    public func refresh(peers: [PeerProfile], routes: [RouteEntry]) {
        nodes = peers
            .map { TopologyNode(id: $0.peerID, nickname: $0.nickname) }
            .sorted { $0.nickname < $1.nickname }
        edges = routes.map { TopologyEdge(from: $0.nextHop, to: $0.destination, latencyMs: $0.latencyMs) }
    }
}
#endif

