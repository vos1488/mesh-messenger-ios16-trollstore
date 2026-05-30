import Foundation
import XCTest
@testable import MeshMessenger

final class CryptoEngineTests: XCTestCase {
    func testEncryptDecryptRoundTrip() throws {
        let alice = try IdentityEngine(nickname: "alice", capabilities: [.chat], keyNamespace: "test-alice")
        let bob = try IdentityEngine(nickname: "bob", capabilities: [.chat], keyNamespace: "test-bob")

        let aliceCrypto = CryptoEngine(identityEngine: alice)
        let bobCrypto = CryptoEngine(identityEngine: bob)

        let message = Data("hello mesh".utf8)
        let container = try aliceCrypto.encrypt(message, for: bob.identity.agreementPublicKey)
        let decrypted = try bobCrypto.decrypt(container)

        XCTAssertEqual(decrypted, message)
        XCTAssertNoThrow(try aliceCrypto.verify(container: container))
    }
}

