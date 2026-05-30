import Foundation

public struct GroupChat: Codable, Sendable, Hashable {
    public let groupID: UUID
    public var members: [PeerID]

    public init(groupID: UUID = UUID(), members: [PeerID]) {
        self.groupID = groupID
        self.members = members
    }
}

