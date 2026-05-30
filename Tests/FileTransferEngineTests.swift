import Foundation
import XCTest
@testable import MeshMessenger

final class FileTransferEngineTests: XCTestCase {
    func testChunkAndReassemble() async throws {
        let data = Data((0..<200_000).map { UInt8($0 % 255) })
        let engine = FileTransferEngine()

        let chunks = await engine.chunkFile(data)
        XCTAssertGreaterThan(chunks.count, 1)

        for chunk in chunks.shuffled() {
            await engine.accept(chunk: chunk)
        }

        let rebuilt = try await engine.reassemble(transferID: chunks[0].transferID)
        XCTAssertEqual(rebuilt, data)
    }
}

