import Foundation

public actor MessagingEngine {
    private var outbox: [UUID: OutboxItem] = [:]
    private var seenMessages: Set<UUID> = []
    private var ackedMessages: Set<UUID> = []

    public init() {}

    public func enqueue(_ envelope: MessageEnvelope) {
        outbox[envelope.messageID] = OutboxItem(envelope: envelope)
    }

    public func pendingMessages(limit: Int = 50) -> [OutboxItem] {
        outbox.values
            .filter { $0.status == .pending }
            .sorted { $0.envelope.timestamp < $1.envelope.timestamp }
            .prefix(limit)
            .map { $0 }
    }

    public func markDelivered(messageID: UUID) {
        guard var item = outbox[messageID] else { return }
        item.status = .delivered
        outbox[messageID] = item
        ackedMessages.insert(messageID)
    }

    public func markFailed(messageID: UUID) {
        guard var item = outbox[messageID] else { return }
        item.status = .failed
        item.attempts += 1
        outbox[messageID] = item
    }

    public func registerRetry(messageID: UUID) {
        guard var item = outbox[messageID] else { return }
        item.status = .pending
        item.attempts += 1
        outbox[messageID] = item
    }

    public func acceptIncoming(_ envelope: MessageEnvelope) -> Bool {
        if seenMessages.contains(envelope.messageID) {
            return false
        }
        seenMessages.insert(envelope.messageID)
        return true
    }

    public func shouldAck(_ messageID: UUID) -> Bool {
        !ackedMessages.contains(messageID)
    }

    public func knownMessageIDs() -> [UUID] {
        Array(seenMessages.union(outbox.keys))
    }
}

