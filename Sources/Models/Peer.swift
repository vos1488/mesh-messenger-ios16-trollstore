import Foundation

public struct PeerID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let value: String

    public init(_ value: String) {
        self.value = value
    }

    public var uri: String {
        "peer://\(value)"
    }

    public var description: String {
        uri
    }
}

public struct PeerProfile: Codable, Hashable, Sendable {
    public let peerID: PeerID
    public var nickname: String
    public var capabilities: Set<NodeCapability>
    public var lastSeenAt: Date

    public init(peerID: PeerID, nickname: String, capabilities: Set<NodeCapability>, lastSeenAt: Date = Date()) {
        self.peerID = peerID
        self.nickname = nickname
        self.capabilities = capabilities
        self.lastSeenAt = lastSeenAt
    }
}

public enum NodeCapability: String, Codable, CaseIterable, Sendable {
    case chat
    case voice
    case video
    case relay
    case files
}

public struct PeerAnnouncement: Codable, Sendable {
    public let peerID: String
    public let nickname: String
    public let capabilities: [String]

    public init(profile: PeerProfile) {
        peerID = profile.peerID.value
        nickname = profile.nickname
        capabilities = profile.capabilities.map(\.rawValue).sorted()
    }
}

