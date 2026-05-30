import CryptoKit
import Foundation

#if canImport(Security)
import Security
#endif

public struct NodeIdentity: Sendable {
    public let profile: PeerProfile
    public let signingPublicKey: Data
    public let agreementPublicKey: Data
}

public enum IdentityError: Error {
    case invalidStoredKey
    case failedToPersistKey
}

public final class IdentityEngine {
    public private(set) var identity: NodeIdentity

    let signingPrivateKey: Curve25519.Signing.PrivateKey
    let agreementPrivateKey: Curve25519.KeyAgreement.PrivateKey

    private let signingKeyTag: String
    private let agreementKeyTag: String

    public init(nickname: String, capabilities: Set<NodeCapability>, keyNamespace: String = "default") throws {
        signingKeyTag = "mesh.identity.\(keyNamespace).signing.v1"
        agreementKeyTag = "mesh.identity.\(keyNamespace).agreement.v1"
        if let signingData = KeyStore.shared.read(tag: signingKeyTag),
           let agreementData = KeyStore.shared.read(tag: agreementKeyTag) {
            signingPrivateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: signingData)
            agreementPrivateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: agreementData)
        } else {
            signingPrivateKey = Curve25519.Signing.PrivateKey()
            agreementPrivateKey = Curve25519.KeyAgreement.PrivateKey()

            guard KeyStore.shared.write(signingPrivateKey.rawRepresentation, tag: signingKeyTag),
                  KeyStore.shared.write(agreementPrivateKey.rawRepresentation, tag: agreementKeyTag)
            else {
                throw IdentityError.failedToPersistKey
            }
        }

        let signingPublic = signingPrivateKey.publicKey.rawRepresentation
        let agreementPublic = agreementPrivateKey.publicKey.rawRepresentation
        let peerID = PeerID(Self.makePeerID(signingPublicKey: signingPublic, agreementPublicKey: agreementPublic))
        identity = NodeIdentity(
            profile: PeerProfile(peerID: peerID, nickname: nickname, capabilities: capabilities),
            signingPublicKey: signingPublic,
            agreementPublicKey: agreementPublic
        )
    }

    public func signature(for data: Data) throws -> Data {
        try signingPrivateKey.signature(for: data)
    }

    public static func makePeerID(signingPublicKey: Data, agreementPublicKey: Data) -> String {
        let digest = SHA256.hash(data: signingPublicKey + agreementPublicKey)
        return Data(digest).hexString
    }
}

final class KeyStore {
    static let shared = KeyStore()

    private init() {}

    func write(_ data: Data, tag: String) -> Bool {
        #if canImport(Security)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: "MeshMessenger",
            kSecAttrAccount: tag,
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecSuccess {
            return true
        }
        UserDefaults.standard.set(data, forKey: tag)
        return true
        #else
        UserDefaults.standard.set(data, forKey: tag)
        return true
        #endif
    }

    func read(tag: String) -> Data? {
        #if canImport(Security)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: "MeshMessenger",
            kSecAttrAccount: tag,
            kSecReturnData: kCFBooleanTrue as Any,
            kSecMatchLimit: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess {
            return item as? Data
        }
        return UserDefaults.standard.data(forKey: tag)
        #else
        return UserDefaults.standard.data(forKey: tag)
        #endif
    }
}

