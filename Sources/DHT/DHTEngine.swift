import Foundation

public actor DHTEngine {
    private var peers: [PeerID: PeerProfile] = [:]
    private var peerPublicKeys: [PeerID: Data] = [:]
    private let bucketSize: Int

    public init(bucketSize: Int = 20) {
        self.bucketSize = bucketSize
    }

    public func upsert(peer: PeerProfile, signingPublicKey: Data? = nil) {
        peers[peer.peerID] = peer
        if let signingPublicKey {
            peerPublicKeys[peer.peerID] = signingPublicKey
        }
    }

    public func profile(for peerID: PeerID) -> PeerProfile? {
        peers[peerID]
    }

    public func signingKey(for peerID: PeerID) -> Data? {
        peerPublicKeys[peerID]
    }

    public func closestPeers(to target: PeerID, limit: Int = 8) -> [PeerProfile] {
        let all = peers.values.sorted {
            xorDistance($0.peerID, target) < xorDistance($1.peerID, target)
        }
        return Array(all.prefix(min(limit, bucketSize)))
    }

    public func allPeers() -> [PeerProfile] {
        peers.values.sorted { $0.peerID.value < $1.peerID.value }
    }

    private func xorDistance(_ lhs: PeerID, _ rhs: PeerID) -> UInt64 {
        shortHexValue(lhs.value) ^ shortHexValue(rhs.value)
    }

    private func shortHexValue(_ hex: String) -> UInt64 {
        let trimmed = String(hex.prefix(16))
        return UInt64(trimmed, radix: 16) ?? 0
    }
}

