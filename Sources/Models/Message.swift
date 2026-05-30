import Foundation

public enum MessageType: String, Codable, Sendable {
    case text = "TEXT"
    case image = "IMAGE"
    case video = "VIDEO"
    case voice = "VOICE"
    case file = "FILE"
    case system = "SYSTEM"
}

public struct EncryptedContainer: Codable, Sendable, Hashable {
    public let nonce: Data
    public let ciphertext: Data
    public let tag: Data
    public let senderSigningPublicKey: Data
    public let senderAgreementPublicKey: Data
    public let signature: Data

    public init(
        nonce: Data,
        ciphertext: Data,
        tag: Data,
        senderSigningPublicKey: Data,
        senderAgreementPublicKey: Data,
        signature: Data
    ) {
        self.nonce = nonce
        self.ciphertext = ciphertext
        self.tag = tag
        self.senderSigningPublicKey = senderSigningPublicKey
        self.senderAgreementPublicKey = senderAgreementPublicKey
        self.signature = signature
    }
}

public struct MessageEnvelope: Codable, Sendable, Hashable {
    public let messageID: UUID
    public let type: MessageType
    public let sender: PeerID
    public let receiver: PeerID
    public let timestamp: Date
    public let ttl: Int
    public let payload: EncryptedContainer

    public init(
        messageID: UUID = UUID(),
        type: MessageType,
        sender: PeerID,
        receiver: PeerID,
        timestamp: Date = Date(),
        ttl: Int = 16,
        payload: EncryptedContainer
    ) {
        self.messageID = messageID
        self.type = type
        self.sender = sender
        self.receiver = receiver
        self.timestamp = timestamp
        self.ttl = ttl
        self.payload = payload
    }
}

public enum OutboxStatus: String, Codable, Sendable {
    case queued
    case pending
    case sent
    case delivered
    case read
    case failed
    case poisoned
}

public struct OutboxItem: Codable, Sendable {
    public let envelope: MessageEnvelope
    public var status: OutboxStatus
    public var attempts: Int
    public var nextRetryAt: Date?
    public var deliveredAt: Date?
    public var readAt: Date?

    public init(
        envelope: MessageEnvelope,
        status: OutboxStatus = .queued,
        attempts: Int = 0,
        nextRetryAt: Date? = nil,
        deliveredAt: Date? = nil,
        readAt: Date? = nil
    ) {
        self.envelope = envelope
        self.status = status
        self.attempts = attempts
        self.nextRetryAt = nextRetryAt
        self.deliveredAt = deliveredAt
        self.readAt = readAt
    }
}

