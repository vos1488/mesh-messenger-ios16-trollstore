import Foundation

public struct FileChunk: Codable, Sendable, Hashable {
    public let transferID: UUID
    public let index: Int
    public let totalChunks: Int
    public let data: Data
    public let fileHash: Data

    public init(transferID: UUID, index: Int, totalChunks: Int, data: Data, fileHash: Data) {
        self.transferID = transferID
        self.index = index
        self.totalChunks = totalChunks
        self.data = data
        self.fileHash = fileHash
    }
}

public enum TransferState: String, Codable, Sendable {
    case inProgress
    case completed
    case failed
}

public struct FileTransferSession: Codable, Sendable {
    public let transferID: UUID
    public let fileName: String
    public let expectedChunks: Int
    public var receivedChunks: Set<Int>
    public var state: TransferState

    public init(transferID: UUID, fileName: String, expectedChunks: Int, receivedChunks: Set<Int> = [], state: TransferState = .inProgress) {
        self.transferID = transferID
        self.fileName = fileName
        self.expectedChunks = expectedChunks
        self.receivedChunks = receivedChunks
        self.state = state
    }
}

