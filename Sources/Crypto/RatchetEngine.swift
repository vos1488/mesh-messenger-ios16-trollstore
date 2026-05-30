import CryptoKit
import Foundation

public struct RatchetedPayload: Codable, Sendable, Equatable {
    public let sessionID: String
    public let counter: Int
    public let nonce: Data
    public let ciphertext: Data
    public let tag: Data

    public init(sessionID: String, counter: Int, nonce: Data, ciphertext: Data, tag: Data) {
        self.sessionID = sessionID
        self.counter = counter
        self.nonce = nonce
        self.ciphertext = ciphertext
        self.tag = tag
    }
}

public enum RatchetError: Error {
    case missingPeerAgreementKey
    case decryptFailed
}

public actor RatchetEngine {
    private let identityEngine: IdentityEngine
    private let storageEngine: StorageEngine
    private var memorySessions: [String: StoredRatchetSession] = [:]

    public init(identityEngine: IdentityEngine, storageEngine: StorageEngine) {
        self.identityEngine = identityEngine
        self.storageEngine = storageEngine
    }

    public func encrypt(
        plaintext: Data,
        for peerID: PeerID,
        peerAgreementPublicKey: Data
    ) throws -> RatchetedPayload {
        var session = try ensureSession(peerID: peerID, peerAgreementPublicKey: peerAgreementPublicKey)

        let counter = session.sendCounter
        let messageKey = deriveMessageKey(chainKey: session.sendChainKey, counter: counter)
        let symmetricKey = SymmetricKey(data: messageKey)
        let sealed = try AES.GCM.seal(plaintext, using: symmetricKey)

        session.sendChainKey = advanceChainKey(session.sendChainKey)
        session.sendCounter += 1
        session.updatedAt = Date()
        try storageEngine.upsertRatchetSession(session)
        memorySessions[peerID.value] = session

        return RatchetedPayload(
            sessionID: session.sessionID,
            counter: counter,
            nonce: Data(sealed.nonce),
            ciphertext: sealed.ciphertext,
            tag: sealed.tag
        )
    }

    public func decrypt(
        payload: RatchetedPayload,
        from peerID: PeerID,
        peerAgreementPublicKey: Data
    ) throws -> Data {
        var session = try ensureSession(peerID: peerID, peerAgreementPublicKey: peerAgreementPublicKey)

        if payload.counter < session.recvCounter {
            throw RatchetError.decryptFailed
        }

        var candidateKey: Data?
        while session.recvCounter <= payload.counter {
            let key = deriveMessageKey(chainKey: session.recvChainKey, counter: session.recvCounter)
            session.recvChainKey = advanceChainKey(session.recvChainKey)
            if session.recvCounter == payload.counter {
                candidateKey = key
            }
            session.recvCounter += 1
        }

        guard let keyData = candidateKey else {
            throw RatchetError.decryptFailed
        }

        let nonce = try AES.GCM.Nonce(data: payload.nonce)
        let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: payload.ciphertext, tag: payload.tag)
        let plaintext = try AES.GCM.open(box, using: SymmetricKey(data: keyData))

        session.updatedAt = Date()
        try storageEngine.upsertRatchetSession(session)
        memorySessions[peerID.value] = session
        return plaintext
    }

    private func ensureSession(peerID: PeerID, peerAgreementPublicKey: Data) throws -> StoredRatchetSession {
        if let inMemory = memorySessions[peerID.value] {
            return inMemory
        }
        if let stored = try storageEngine.ratchetSession(peerID: peerID.value) {
            memorySessions[peerID.value] = stored
            return stored
        }

        let remoteKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerAgreementPublicKey)
        let secret = try identityEngine.agreementPrivateKey.sharedSecretFromKeyAgreement(with: remoteKey)
        let root = secret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(),
            sharedInfo: Data("mesh-ratchet-root-v1".utf8),
            outputByteCount: 32
        )
        let rootData = root.withUnsafeBytes { Data($0) }

        let local = identityEngine.identity.profile.peerID.value
        let isLocalFirst = local < peerID.value
        let sendLabel = isLocalFirst ? "chain-a2b" : "chain-b2a"
        let recvLabel = isLocalFirst ? "chain-b2a" : "chain-a2b"
        let sendChain = hmac(rootData, label: sendLabel)
        let recvChain = hmac(rootData, label: recvLabel)

        let created = StoredRatchetSession(
            peerID: peerID.value,
            sessionID: UUID().uuidString,
            rootKey: rootData,
            sendChainKey: sendChain,
            recvChainKey: recvChain,
            sendCounter: 0,
            recvCounter: 0,
            updatedAt: Date()
        )
        try storageEngine.upsertRatchetSession(created)
        memorySessions[peerID.value] = created
        return created
    }

    private func deriveMessageKey(chainKey: Data, counter: Int) -> Data {
        let material = hmac(chainKey, label: "msg-\(counter)")
        return Data(material.prefix(32))
    }

    private func advanceChainKey(_ chainKey: Data) -> Data {
        hmac(chainKey, label: "step")
    }

    private func hmac(_ keyData: Data, label: String) -> Data {
        let key = SymmetricKey(data: keyData)
        let mac = HMAC<SHA256>.authenticationCode(for: Data(label.utf8), using: key)
        return Data(mac)
    }
}
