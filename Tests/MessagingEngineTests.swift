import Foundation
import XCTest
@testable import MeshMessenger

final class MessagingEngineTests: XCTestCase {
    func testDeduplicationRejectsSeenMessages() async throws {
        let sender = PeerID("sender")
        let receiver = PeerID("receiver")
        let payload = EncryptedContainer(
            nonce: Data(),
            ciphertext: Data([1, 2]),
            tag: Data([3]),
            senderSigningPublicKey: Data([4]),
            senderAgreementPublicKey: Data([5]),
            signature: Data([6])
        )

        let envelope = MessageEnvelope(type: .text, sender: sender, receiver: receiver, payload: payload)
        let messaging = MessagingEngine()

        let first = await messaging.acceptIncoming(envelope)
        let second = await messaging.acceptIncoming(envelope)

        XCTAssertTrue(first)
        XCTAssertFalse(second)
    }
}

