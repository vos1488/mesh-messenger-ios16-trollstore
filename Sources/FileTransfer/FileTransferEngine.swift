import CryptoKit
import Foundation

public enum FileTransferError: Error {
    case transferUnknown
    case notComplete
    case integrityMismatch
}

public actor FileTransferEngine {
    public let chunkSize = 64 * 1024

    private var received: [UUID: [Int: Data]] = [:]
    private var expectedChunks: [UUID: Int] = [:]
    private var expectedHash: [UUID: Data] = [:]

    public init() {}

    public func chunkFile(_ data: Data, transferID: UUID = UUID()) -> [FileChunk] {
        let hash = Data(SHA256.hash(data: data))
        let totalChunks = max(1, Int(ceil(Double(data.count) / Double(chunkSize))))
        var chunks: [FileChunk] = []
        chunks.reserveCapacity(totalChunks)

        for index in 0..<totalChunks {
            let start = index * chunkSize
            let end = min(start + chunkSize, data.count)
            let chunkData = data.subdata(in: start..<end)
            chunks.append(
                FileChunk(
                    transferID: transferID,
                    index: index,
                    totalChunks: totalChunks,
                    data: chunkData,
                    fileHash: hash
                )
            )
        }

        return chunks
    }

    public func accept(chunk: FileChunk) {
        var map = received[chunk.transferID, default: [:]]
        map[chunk.index] = chunk.data
        received[chunk.transferID] = map
        expectedChunks[chunk.transferID] = chunk.totalChunks
        expectedHash[chunk.transferID] = chunk.fileHash
    }

    public func progress(for transferID: UUID) -> Double {
        let got = Double(received[transferID]?.count ?? 0)
        let expected = Double(expectedChunks[transferID] ?? 1)
        return min(1.0, got / expected)
    }

    public func reassemble(transferID: UUID) throws -> Data {
        guard let map = received[transferID],
              let total = expectedChunks[transferID],
              let hash = expectedHash[transferID]
        else {
            throw FileTransferError.transferUnknown
        }

        guard map.count == total else {
            throw FileTransferError.notComplete
        }

        let rebuilt = (0..<total).reduce(into: Data()) { partial, index in
            partial.append(map[index] ?? Data())
        }

        let rebuiltHash = Data(SHA256.hash(data: rebuilt))
        guard rebuiltHash == hash else {
            throw FileTransferError.integrityMismatch
        }

        return rebuilt
    }

    public func knownTransferIDs() -> [UUID] {
        Array(expectedChunks.keys)
    }
}

