import Foundation

public struct SyncEngine {
    public init() {}

    public func buildDigest(knownMessages: [UUID], knownFiles: [UUID], knownRoutes: [PeerID]) -> SyncDigest {
        SyncDigest(
            knownMessages: knownMessages.sorted { $0.uuidString < $1.uuidString },
            knownFiles: knownFiles.sorted { $0.uuidString < $1.uuidString },
            knownRoutes: knownRoutes.sorted { $0.value < $1.value }
        )
    }

    public func diff(local: SyncDigest, remote: SyncDigest) -> SyncDiff {
        let localMessages = Set(local.knownMessages)
        let localFiles = Set(local.knownFiles)
        let localRoutes = Set(local.knownRoutes)

        return SyncDiff(
            missingMessages: remote.knownMessages.filter { !localMessages.contains($0) },
            missingFiles: remote.knownFiles.filter { !localFiles.contains($0) },
            missingRoutes: remote.knownRoutes.filter { !localRoutes.contains($0) }
        )
    }
}

