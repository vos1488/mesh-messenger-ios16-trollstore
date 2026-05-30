import CryptoKit
import Foundation

public enum CryptoError: Error {
    case invalidPublicKey
    case invalidSealedBox
    case invalidSignature
}

public final class CryptoEngine {
    private let identityEngine: IdentityEngine
    private let contextInfo = Data("mesh-msg-v1".utf8)

    public init(identityEngine: IdentityEngine) {
        self.identityEngine = identityEngine
    }

    public func encrypt(_ plaintext: Data, for recipientAgreementPublicKey: Data) throws -> EncryptedContainer {
        let recipientKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: recipientAgreementPublicKey)
        let secret = try identityEngine.agreementPrivateKey.sharedSecretFromKeyAgreement(with: recipientKey)
        let symmetricKey = secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(), sharedInfo: contextInfo, outputByteCount: 32)
        let sealed = try AES.GCM.seal(plaintext, using: symmetricKey)
        let nonceData = Data(sealed.nonce)
        let bodyToSign = nonceData + sealed.ciphertext + sealed.tag + identityEngine.identity.agreementPublicKey
        let signature = try identityEngine.signature(for: bodyToSign)

        return EncryptedContainer(
            nonce: nonceData,
            ciphertext: sealed.ciphertext,
            tag: sealed.tag,
            senderSigningPublicKey: identityEngine.identity.signingPublicKey,
            senderAgreementPublicKey: identityEngine.identity.agreementPublicKey,
            signature: signature
        )
    }

    public func decrypt(_ container: EncryptedContainer) throws -> Data {
        try verify(container: container)
        let senderAgreement = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: container.senderAgreementPublicKey)
        let secret = try identityEngine.agreementPrivateKey.sharedSecretFromKeyAgreement(with: senderAgreement)
        let symmetricKey = secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(), sharedInfo: contextInfo, outputByteCount: 32)

        let nonce = try AES.GCM.Nonce(data: container.nonce)
        let sealedBox = try AES.GCM.SealedBox(nonce: nonce, ciphertext: container.ciphertext, tag: container.tag)
        return try AES.GCM.open(sealedBox, using: symmetricKey)
    }

    public func verify(container: EncryptedContainer) throws {
        let senderSigning = try Curve25519.Signing.PublicKey(rawRepresentation: container.senderSigningPublicKey)
        let body = container.nonce + container.ciphertext + container.tag + container.senderAgreementPublicKey
        guard senderSigning.isValidSignature(container.signature, for: body) else {
            throw CryptoError.invalidSignature
        }
    }
}

