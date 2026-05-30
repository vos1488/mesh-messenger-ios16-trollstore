import Foundation

public actor MessagingEngine {
    private var outbox: [UUID: OutboxItem] = [:]
    private var seenMessages: Set<UUID> = []
    private var deliveredMessages: Set<UUID> = []
    private var readMessages: Set<UUID> = []

    public init() {}

    public func enqueue(_ envelope: MessageEnvelope) {
        outbox[envelope.messageID] = OutboxItem(
            envelope: envelope,
            status: .queued,
            attempts: 0,
            nextRetryAt: Date()
        )
    }

    public func pendingMessages(limit: Int = 50) -> [OutboxItem] {
        let now = Date()
        outbox.values
            .filter {
                switch $0.status {
                case .queued, .pending, .failed:
                    return ($0.nextRetryAt ?? .distantPast) <= now
                case .sent:
                    return ($0.nextRetryAt ?? .distantPast) <= now
                case .delivered, .read:
                    return false
                }
            }
            .sorted { $0.envelope.timestamp < $1.envelope.timestamp }
            .prefix(limit)
            .map { $0 }
    }

    public func markSent(messageID: UUID, nextRetryAt: Date) {
        guard var item = outbox[messageID] else { return }
        item.status = .sent
        item.nextRetryAt = nextRetryAt
        outbox[messageID] = item
    }

    public func markDelivered(messageID: UUID) {
        guard var item = outbox[messageID] else { return }
        item.status = .delivered
        item.deliveredAt = Date()
        item.nextRetryAt = nil
        outbox[messageID] = item
        deliveredMessages.insert(messageID)
    }

    public func markRead(messageID: UUID) {
        guard var item = outbox[messageID] else { return }
        item.status = .read
        item.readAt = Date()
        item.nextRetryAt = nil
        outbox[messageID] = item
        readMessages.insert(messageID)
    }

    public func markFailed(messageID: UUID, nextRetryAt: Date?) {
        guard var item = outbox[messageID] else { return }
        item.status = .failed
        item.attempts += 1
        item.nextRetryAt = nextRetryAt
        outbox[messageID] = item
    }

    public func registerRetry(messageID: UUID, nextRetryAt: Date) {
        guard var item = outbox[messageID] else { return }
        item.status = .queued
        item.attempts += 1
        item.nextRetryAt = nextRetryAt
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
        !deliveredMessages.contains(messageID)
    }

    public func shouldSendReadReceipt(_ messageID: UUID) -> Bool {
        !readMessages.contains(messageID)
    }

    public func knownMessageIDs() -> [UUID] {
        Array(seenMessages.union(outbox.keys))
    }

    public func outboxItem(messageID: UUID) -> OutboxItem? {
        outbox[messageID]
    }
}

