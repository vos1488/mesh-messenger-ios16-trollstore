import Foundation

public struct SyncDigest: Codable, Sendable {
    public let knownMessages: [UUID]
    public let knownFiles: [UUID]
    public let knownRoutes: [PeerID]

    public init(knownMessages: [UUID], knownFiles: [UUID], knownRoutes: [PeerID]) {
        self.knownMessages = knownMessages
        self.knownFiles = knownFiles
        self.knownRoutes = knownRoutes
    }
}

public struct SyncDiff: Codable, Sendable {
    public let missingMessages: [UUID]
    public let missingFiles: [UUID]
    public let missingRoutes: [PeerID]

    public init(missingMessages: [UUID], missingFiles: [UUID], missingRoutes: [PeerID]) {
        self.missingMessages = missingMessages
        self.missingFiles = missingFiles
        self.missingRoutes = missingRoutes
    }
}

