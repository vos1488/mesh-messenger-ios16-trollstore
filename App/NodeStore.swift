import CryptoKit
import Foundation
import SwiftUI
import UserNotifications

#if canImport(UIKit)
import UIKit
#endif

public struct PeerEntry: Identifiable, Equatable, Codable {
    public let id: String
    public var peerID: PeerID
    public var nickname: String
    public var isConnected: Bool
    public var lastSeen: Date
    public var signingPublicKey: Data?
    public var agreementPublicKey: Data?
    public var fingerprint: String?
    public var isVerified: Bool
    public var keyVersion: Int
    public var trustWarning: String?

    public init(
        peerID: PeerID,
        nickname: String,
        isConnected: Bool = false,
        signingPublicKey: Data? = nil,
        agreementPublicKey: Data? = nil,
        fingerprint: String? = nil,
        isVerified: Bool = false,
        keyVersion: Int = 1,
        trustWarning: String? = nil
    ) {
        self.id = peerID.value
        self.peerID = peerID
        self.nickname = nickname
        self.isConnected = isConnected
        self.lastSeen = Date()
        self.signingPublicKey = signingPublicKey
        self.agreementPublicKey = agreementPublicKey
        self.fingerprint = fingerprint
        self.isVerified = isVerified
        self.keyVersion = keyVersion
        self.trustWarning = trustWarning
    }
}

public struct ChatMessage: Identifiable, Equatable, Codable {
    public let id: UUID
    public let text: String
    public let senderID: String
    public let senderNickname: String
    public let isMe: Bool
    public let timestamp: Date
    public var status: OutboxStatus
    public var attempts: Int
    public var nextRetryAt: Date?
    public var deliveredAt: Date?
    public var readAt: Date?
    public var isRead: Bool
    public var ttl: Int
    public var relayPath: [String]
    public var sessionID: String?
    public var ratchetCounter: Int?
    public var fileID: UUID?
    public var fileName: String?

    public init(
        id: UUID = UUID(),
        text: String,
        senderID: String,
        senderNickname: String,
        isMe: Bool,
        timestamp: Date = Date(),
        status: OutboxStatus = .queued,
        attempts: Int = 0,
        nextRetryAt: Date? = nil,
        deliveredAt: Date? = nil,
        readAt: Date? = nil,
        isRead: Bool = false,
        ttl: Int = 16,
        relayPath: [String] = [],
        sessionID: String? = nil,
        ratchetCounter: Int? = nil,
        fileID: UUID? = nil,
        fileName: String? = nil
    ) {
        self.id = id
        self.text = text
        self.senderID = senderID
        self.senderNickname = senderNickname
        self.isMe = isMe
        self.timestamp = timestamp
        self.status = status
        self.attempts = attempts
        self.nextRetryAt = nextRetryAt
        self.deliveredAt = deliveredAt
        self.readAt = readAt
        self.isRead = isRead
        self.ttl = ttl
        self.relayPath = relayPath
        self.sessionID = sessionID
        self.ratchetCounter = ratchetCounter
        self.fileID = fileID
        self.fileName = fileName
    }
}

private let appStoreDir: URL = {
    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    let dir = docs.appendingPathComponent("MeshMessenger", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}()

private func meshDBURL() -> URL { appStoreDir.appendingPathComponent("mesh.sqlite3") }

@MainActor
public final class NodeStore: ObservableObject {
    @Published public var peers: [PeerEntry] = []
    @Published public var messages: [String: [ChatMessage]] = [:]
    @Published public var fileProgress: [UUID: Double] = [:]
    @Published public var nickname: String = "iOS Node"
    @Published public var myPeerURI: String = ""
    @Published public var isRunning: Bool = false
    @Published public var errorMessage: String? = nil

    private var transport: MCPTransport?
    private var storageEngine: StorageEngine?
    private var ratchetEngine: RatchetEngine?
    private var identityEngine: IdentityEngine?
    private let fileTransferEngine = FileTransferEngine()
    private var deliveryTask: Task<Void, Never>?
    private var myPeerIDValue: String = ""
    private var knownMessageIDs: Set<UUID> = []
    private var incomingFileNames: [UUID: String] = [:]

    public static let shared = NodeStore()
    private init() {}

    // MARK: - Lifecycle

    public func start() async {
        guard !isRunning else { return }
        let savedNick = UserDefaults.standard.string(forKey: "mesh_nickname") ?? nickname

        do {
            let identity = try await Task.detached(priority: .userInitiated) {
                try IdentityEngine(nickname: savedNick, capabilities: [.chat, .relay, .files])
            }.value

            let storage = try StorageEngine(databaseURL: meshDBURL())
            try storage.bootstrapSchema()

            identityEngine = identity
            storageEngine = storage
            ratchetEngine = RatchetEngine(identityEngine: identity, storageEngine: storage)

            let profile = identity.identity.profile
            myPeerIDValue = profile.peerID.value
            myPeerURI = profile.peerID.uri
            nickname = profile.nickname

            loadPersistedData()

            let t = try MCPTransport(
                localProfile: profile,
                signingPublicKey: identity.identity.signingPublicKey,
                agreementPublicKey: identity.identity.agreementPublicKey
            )

            t.onPeerDiscovered = { [weak self] discovered in
                Task { @MainActor [weak self] in
                    self?.handleDiscoveredPeer(discovered)
                }
            }
            t.onPeerConnected = { [weak self] peerID, displayName in
                Task { @MainActor [weak self] in
                    self?.handleConnectedPeer(peerID: peerID, displayName: displayName)
                }
            }
            t.onPeerDisconnected = { [weak self] peerID in
                Task { @MainActor [weak self] in
                    self?.handleDisconnectedPeer(peerID: peerID)
                }
            }
            t.onMessageReceived = { [weak self] packet, fromPeerID in
                Task { @MainActor [weak self] in
                    await self?.handleIncoming(packet: packet, fromPeerID: fromPeerID)
                }
            }

            transport = t
            t.start()
            startDeliveryLoop()
            requestNotificationPermission()
            isRunning = true
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func stop() {
        deliveryTask?.cancel()
        deliveryTask = nil
        transport?.stop()
        transport = nil
        isRunning = false
    }

    public func onAppBecameActive() {
        Task { @MainActor in
            if isRunning {
                processDeliveryQueue()
            } else {
                await start()
            }
        }
    }

    // MARK: - Messaging

    public func send(text: String, to peer: PeerEntry) {
        let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }

        Task { @MainActor in
            var encryptedPayload: RatchetedPayload?
            do {
                if let agreement = peer.agreementPublicKey, let ratchetEngine {
                    encryptedPayload = try await ratchetEngine.encrypt(
                        plaintext: Data(content.utf8),
                        for: peer.peerID,
                        peerAgreementPublicKey: agreement
                    )
                }
            } catch {
                errorMessage = "E2EE ошибка: \(error.localizedDescription)"
            }

            let messageID = UUID()
            let packet = TransportMessage(
                id: messageID,
                kind: .chat,
                senderPeerID: myPeerIDValue,
                senderNickname: nickname,
                receiverPeerID: peer.peerID.value,
                ttl: 16,
                relayPath: [myPeerIDValue],
                text: encryptedPayload == nil ? content : nil,
                sessionID: encryptedPayload?.sessionID,
                ratchetCounter: encryptedPayload?.counter,
                nonce: encryptedPayload?.nonce,
                ciphertext: encryptedPayload?.ciphertext,
                tag: encryptedPayload?.tag
            )

            let record = StoredMessageRecord(
                messageID: messageID,
                peerID: peer.peerID.value,
                senderID: myPeerIDValue,
                senderNickname: nickname,
                textBody: content,
                timestamp: packet.timestamp,
                status: .queued,
                attempts: 0,
                nextRetryAt: Date(),
                deliveredAt: nil,
                readAt: nil,
                lastError: nil,
                isOutgoing: true,
                isRead: false,
                ttl: packet.ttl,
                relayPath: packet.relayPath,
                sessionID: packet.sessionID,
                ratchetCounter: packet.ratchetCounter,
                nonce: packet.nonce,
                ciphertext: packet.ciphertext,
                tag: packet.tag,
                fileID: nil,
                fileName: nil,
                fileChunkIndex: nil,
                fileTotalChunks: nil,
                fileChunkData: nil,
                fileChecksum: nil
            )

            saveMessage(record)
            appendOrUpdateMessage(peerID: peer.peerID.value, mapFromRecord(record))
            attemptDelivery(record)
        }
    }

    public func markConversationRead(peerID: String) {
        guard let storageEngine else { return }
        let readAt = Date()
        do {
            let readIDs = try storageEngine.markPeerMessagesRead(peerID: peerID, myPeerID: myPeerIDValue, at: readAt)
            guard var thread = messages[peerID] else { return }
            for i in thread.indices {
                if !thread[i].isMe {
                    thread[i].isRead = true
                    thread[i].readAt = readAt
                    thread[i].status = .read
                }
            }
            messages[peerID] = thread

            if let latestRead = readIDs.last, let transport {
                let receipt = TransportMessage(
                    kind: .readReceipt,
                    senderPeerID: myPeerIDValue,
                    senderNickname: nickname,
                    receiverPeerID: peerID,
                    readForMessageID: latestRead
                )
                try? transport.send(message: receipt, to: PeerID(peerID))
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func sendFile(at url: URL, to peer: PeerEntry) {
        guard let transport, let storageEngine else { return }
        Task { @MainActor in
            let hasSecurityScope = url.startAccessingSecurityScopedResource()
            defer {
                if hasSecurityScope {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            do {
                let data = try Data(contentsOf: url)
                let transferID = UUID()
                let chunks = await fileTransferEngine.chunkFile(data, transferID: transferID)
                guard let first = chunks.first else { return }

                let meta = TransportMessage(
                    kind: .fileMeta,
                    senderPeerID: myPeerIDValue,
                    senderNickname: nickname,
                    receiverPeerID: peer.peerID.value,
                    fileID: transferID,
                    fileName: url.lastPathComponent,
                    fileTotalChunks: chunks.count,
                    fileChecksum: first.fileHash
                )
                try transport.send(message: meta, to: peer.peerID)

                try storageEngine.upsertFileTransfer(
                    StoredFileTransferRecord(
                        fileID: transferID,
                        peerID: peer.peerID.value,
                        displayName: url.lastPathComponent,
                        sizeBytes: data.count,
                        chunkSize: fileTransferEngine.chunkSize,
                        totalChunks: chunks.count,
                        completedChunks: 0,
                        state: "sending",
                        checksum: first.fileHash,
                        updatedAt: Date()
                    )
                )

                for chunk in chunks {
                    let chunkPacket = TransportMessage(
                        kind: .fileChunk,
                        senderPeerID: myPeerIDValue,
                        senderNickname: nickname,
                        receiverPeerID: peer.peerID.value,
                        fileID: transferID,
                        fileName: url.lastPathComponent,
                        fileChunkIndex: chunk.index,
                        fileTotalChunks: chunk.totalChunks,
                        fileChunkData: chunk.data,
                        fileChecksum: chunk.fileHash
                    )
                    try transport.send(message: chunkPacket, to: peer.peerID)
                    let progress = Double(chunk.index + 1) / Double(chunks.count)
                    fileProgress[transferID] = progress
                    try storageEngine.upsertFileTransfer(
                        StoredFileTransferRecord(
                            fileID: transferID,
                            peerID: peer.peerID.value,
                            displayName: url.lastPathComponent,
                            sizeBytes: data.count,
                            chunkSize: fileTransferEngine.chunkSize,
                            totalChunks: chunks.count,
                            completedChunks: chunk.index + 1,
                            state: progress >= 1 ? "completed" : "sending",
                            checksum: chunk.fileHash,
                            updatedAt: Date()
                        )
                    )
                }
            } catch {
                errorMessage = "Файл не отправлен: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Trust

    public func verifyPeer(peerID: String, isVerified: Bool) {
        guard let idx = peers.firstIndex(where: { $0.peerID.value == peerID }) else { return }
        peers[idx].isVerified = isVerified
        savePeer(peers[idx])
    }

    // MARK: - Public helpers

    public func saveNickname(_ newNick: String) {
        nickname = newNick
        UserDefaults.standard.set(newNick, forKey: "mesh_nickname")
    }

    public func unreadCount(for peer: PeerEntry) -> Int {
        (messages[peer.peerID.value] ?? []).filter { !$0.isMe && !$0.isRead }.count
    }

    public func connectedCount() -> Int {
        peers.filter(\.isConnected).count
    }

    public func searchMessages(peerID: String?, query: String) -> [ChatMessage] {
        guard let storageEngine, !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        let rows = (try? storageEngine.searchMessages(query: query, peerID: peerID, limit: 200)) ?? []
        return rows.map(mapFromRecord)
    }

    // MARK: - Incoming handling

    private func handleIncoming(packet: TransportMessage, fromPeerID: PeerID) async {
        switch packet.kind {
        case .ack:
            handleAck(packet)
            return
        case .readReceipt:
            handleReadReceipt(packet)
            return
        default:
            break
        }

        if knownMessageIDs.contains(packet.id) {
            if packet.kind == .chat {
                sendAck(for: packet.id, to: fromPeerID)
            }
            return
        }
        knownMessageIDs.insert(packet.id)

        if packet.receiverPeerID != myPeerIDValue {
            relay(packet: packet, fromPeerID: fromPeerID)
            return
        }

        switch packet.kind {
        case .chat, .relay:
            let text = await decryptOrFallback(packet: packet, fromPeerID: fromPeerID)
            let incoming = StoredMessageRecord(
                messageID: packet.id,
                peerID: fromPeerID.value,
                senderID: fromPeerID.value,
                senderNickname: packet.senderNickname,
                textBody: text,
                timestamp: packet.timestamp,
                status: .delivered,
                attempts: 0,
                nextRetryAt: nil,
                deliveredAt: Date(),
                readAt: nil,
                lastError: nil,
                isOutgoing: false,
                isRead: false,
                ttl: packet.ttl,
                relayPath: packet.relayPath,
                sessionID: packet.sessionID,
                ratchetCounter: packet.ratchetCounter,
                nonce: packet.nonce,
                ciphertext: packet.ciphertext,
                tag: packet.tag,
                fileID: packet.fileID,
                fileName: packet.fileName,
                fileChunkIndex: packet.fileChunkIndex,
                fileTotalChunks: packet.fileTotalChunks,
                fileChunkData: packet.fileChunkData,
                fileChecksum: packet.fileChecksum
            )
            saveMessage(incoming)
            appendOrUpdateMessage(peerID: fromPeerID.value, mapFromRecord(incoming))
            upsertPeerFromMessage(senderID: fromPeerID, nickname: packet.senderNickname)
            sendAck(for: packet.id, to: fromPeerID)
            notifyIncomingMessage(from: packet.senderNickname, text: text)

        case .fileMeta:
            if let fileID = packet.fileID, let name = packet.fileName, let totalChunks = packet.fileTotalChunks {
                incomingFileNames[fileID] = name
                try? storageEngine?.upsertFileTransfer(
                    StoredFileTransferRecord(
                        fileID: fileID,
                        peerID: fromPeerID.value,
                        displayName: name,
                        sizeBytes: 0,
                        chunkSize: awaitChunkSize,
                        totalChunks: totalChunks,
                        completedChunks: 0,
                        state: "receiving",
                        checksum: packet.fileChecksum,
                        updatedAt: Date()
                    )
                )
            }

        case .fileChunk:
            handleIncomingFileChunk(packet: packet, fromPeerID: fromPeerID)

        case .syncDigest:
            processDeliveryQueue()

        case .ack, .readReceipt:
            break
        }
    }

    private var awaitChunkSize: Int { 64 * 1024 }

    private func handleIncomingFileChunk(packet: TransportMessage, fromPeerID: PeerID) {
        guard let fileID = packet.fileID,
              let idx = packet.fileChunkIndex,
              let total = packet.fileTotalChunks,
              let data = packet.fileChunkData,
              let checksum = packet.fileChecksum else { return }

        Task { @MainActor in
            await fileTransferEngine.accept(
                chunk: FileChunk(
                    transferID: fileID,
                    index: idx,
                    totalChunks: total,
                    data: data,
                    fileHash: checksum
                )
            )
            let progress = await fileTransferEngine.progress(for: fileID)
            fileProgress[fileID] = progress
            try? storageEngine?.upsertFileTransfer(
                StoredFileTransferRecord(
                    fileID: fileID,
                    peerID: fromPeerID.value,
                    displayName: incomingFileNames[fileID] ?? (packet.fileName ?? "file.bin"),
                    sizeBytes: 0,
                    chunkSize: awaitChunkSize,
                    totalChunks: total,
                    completedChunks: max(1, Int(Double(total) * progress)),
                    state: progress >= 1 ? "completed" : "receiving",
                    checksum: checksum,
                    updatedAt: Date()
                )
            )

            guard progress >= 1 else { return }
            do {
                let rebuilt = try await fileTransferEngine.reassemble(transferID: fileID)
                let receiveDir = appStoreDir.appendingPathComponent("received", isDirectory: true)
                try? FileManager.default.createDirectory(at: receiveDir, withIntermediateDirectories: true)
                let fileName = incomingFileNames[fileID] ?? "received-\(fileID.uuidString).bin"
                let url = receiveDir.appendingPathComponent(fileName)
                try rebuilt.write(to: url, options: .atomic)
            } catch {
                errorMessage = "Файл повреждён: \(error.localizedDescription)"
            }
        }
    }

    private func decryptOrFallback(packet: TransportMessage, fromPeerID: PeerID) async -> String {
        if let nonce = packet.nonce,
           let ciphertext = packet.ciphertext,
           let tag = packet.tag,
           let sessionID = packet.sessionID,
           let counter = packet.ratchetCounter,
           let peer = peers.first(where: { $0.peerID.value == fromPeerID.value }),
           let agreement = peer.agreementPublicKey,
           let ratchetEngine {
            do {
                let payload = RatchetedPayload(
                    sessionID: sessionID,
                    counter: counter,
                    nonce: nonce,
                    ciphertext: ciphertext,
                    tag: tag
                )
                let plain = try await ratchetEngine.decrypt(
                    payload: payload,
                    from: fromPeerID,
                    peerAgreementPublicKey: agreement
                )
                return String(decoding: plain, as: UTF8.self)
            } catch {
                return "🔒 [не удалось расшифровать]"
            }
        }
        return packet.text ?? ""
    }

    private func handleAck(_ packet: TransportMessage) {
        guard let ackFor = packet.ackForMessageID else { return }
        let deliveredAt = Date()
        try? storageEngine?.markMessageStatus(
            messageID: ackFor,
            status: .delivered,
            nextRetryAt: nil,
            deliveredAt: deliveredAt
        )

        for key in messages.keys {
            if let idx = messages[key]?.firstIndex(where: { $0.id == ackFor }) {
                messages[key]?[idx].status = .delivered
                messages[key]?[idx].deliveredAt = deliveredAt
                messages[key]?[idx].nextRetryAt = nil
                break
            }
        }
    }

    private func handleReadReceipt(_ packet: TransportMessage) {
        guard let readFor = packet.readForMessageID else { return }
        let readAt = Date()
        try? storageEngine?.markOutgoingAsRead(messageID: readFor, at: readAt)
        for key in messages.keys {
            if let idx = messages[key]?.firstIndex(where: { $0.id == readFor }) {
                messages[key]?[idx].status = .read
                messages[key]?[idx].readAt = readAt
                messages[key]?[idx].isRead = true
                break
            }
        }
    }

    private func relay(packet: TransportMessage, fromPeerID: PeerID) {
        guard packet.ttl > 0, let transport else { return }
        var path = packet.relayPath
        if !path.contains(myPeerIDValue) {
            path.append(myPeerIDValue)
        }
        let relayPacket = TransportMessage(
            id: packet.id,
            kind: .relay,
            senderPeerID: packet.senderPeerID,
            senderNickname: packet.senderNickname,
            receiverPeerID: packet.receiverPeerID,
            timestamp: packet.timestamp,
            ttl: packet.ttl - 1,
            relayPath: path,
            text: packet.text,
            ackForMessageID: packet.ackForMessageID,
            readForMessageID: packet.readForMessageID,
            sessionID: packet.sessionID,
            ratchetCounter: packet.ratchetCounter,
            nonce: packet.nonce,
            ciphertext: packet.ciphertext,
            tag: packet.tag,
            fileID: packet.fileID,
            fileName: packet.fileName,
            fileChunkIndex: packet.fileChunkIndex,
            fileTotalChunks: packet.fileTotalChunks,
            fileChunkData: packet.fileChunkData,
            fileChecksum: packet.fileChecksum
        )
        let excluded = Set(path + [fromPeerID.value])
        try? transport.sendToConnectedPeers(message: relayPacket, excludingPeerIDs: excluded)
    }

    private func sendAck(for messageID: UUID, to peerID: PeerID) {
        guard let transport else { return }
        let ack = TransportMessage(
            kind: .ack,
            senderPeerID: myPeerIDValue,
            senderNickname: nickname,
            receiverPeerID: peerID.value,
            ackForMessageID: messageID
        )
        try? transport.send(message: ack, to: peerID)
    }

    // MARK: - Delivery queue

    private func startDeliveryLoop() {
        deliveryTask?.cancel()
        deliveryTask = Task(priority: .background) { [weak self] in
            while !(Task.isCancelled) {
                await MainActor.run { self?.processDeliveryQueue() }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func processDeliveryQueue() {
        guard let storageEngine else { return }
        let now = Date()
        let due = (try? storageEngine.fetchDueOutgoingMessages(now: now, limit: 64)) ?? []
        for record in due where record.status != .delivered && record.status != .read {
            attemptDelivery(record)
        }
    }

    private func attemptDelivery(_ record: StoredMessageRecord) {
        guard let transport, let storageEngine else { return }

        let packet = TransportMessage(
            id: record.messageID,
            kind: record.fileID == nil ? .chat : .fileChunk,
            senderPeerID: record.senderID,
            senderNickname: record.senderNickname,
            receiverPeerID: record.peerID,
            timestamp: record.timestamp,
            ttl: record.ttl,
            relayPath: record.relayPath,
            text: record.textBody,
            sessionID: record.sessionID,
            ratchetCounter: record.ratchetCounter,
            nonce: record.nonce,
            ciphertext: record.ciphertext,
            tag: record.tag,
            fileID: record.fileID,
            fileName: record.fileName,
            fileChunkIndex: record.fileChunkIndex,
            fileTotalChunks: record.fileTotalChunks,
            fileChunkData: record.fileChunkData,
            fileChecksum: record.fileChecksum
        )

        do {
            let target = PeerID(record.peerID)
            if transport.isPeerConnected(target) {
                try transport.send(message: packet, to: target)
            } else {
                let excluded = Set(record.relayPath)
                try transport.sendToConnectedPeers(message: packet, excludingPeerIDs: excluded)
            }

            let attempts = record.attempts + 1
            let nextRetry = Date().addingTimeInterval(backoffSeconds(forAttempt: attempts))
            try storageEngine.markMessageStatus(
                messageID: record.messageID,
                status: .sent,
                attempts: attempts,
                nextRetryAt: nextRetry
            )
            updateMessageStatus(
                messageID: record.messageID,
                status: .sent,
                attempts: attempts,
                nextRetryAt: nextRetry,
                error: nil
            )
        } catch {
            let attempts = record.attempts + 1
            let nextRetry = Date().addingTimeInterval(backoffSeconds(forAttempt: attempts))
            try? storageEngine.markMessageStatus(
                messageID: record.messageID,
                status: .failed,
                attempts: attempts,
                nextRetryAt: nextRetry,
                lastError: error.localizedDescription
            )
            updateMessageStatus(
                messageID: record.messageID,
                status: .failed,
                attempts: attempts,
                nextRetryAt: nextRetry,
                error: error.localizedDescription
            )
        }
    }

    private func backoffSeconds(forAttempt attempt: Int) -> TimeInterval {
        let raw = pow(2.0, Double(max(1, attempt)))
        return min(120, raw)
    }

    // MARK: - Peer management

    private func handleDiscoveredPeer(_ discovered: TransportDiscoveredPeer) {
        let peerID = discovered.peerID.value
        let displayNick = discovered.displayName.components(separatedBy: "#").first ?? String(peerID.prefix(8))
        let fingerprint = makeFingerprint(signing: discovered.signingPublicKey, agreement: discovered.agreementPublicKey)

        if let idx = peers.firstIndex(where: { $0.peerID.value == peerID }) {
            var peer = peers[idx]
            let existingFingerprint = peer.fingerprint
            peer.nickname = displayNick
            peer.signingPublicKey = discovered.signingPublicKey
            peer.agreementPublicKey = discovered.agreementPublicKey
            peer.fingerprint = fingerprint
            peer.lastSeen = Date()
            if let existingFingerprint, let fingerprint, existingFingerprint != fingerprint {
                peer.keyVersion += 1
                peer.isVerified = false
                peer.trustWarning = "Ключ контакта изменился"
            }
            peers[idx] = peer
            savePeer(peer)
            return
        }

        var entry = PeerEntry(
            peerID: discovered.peerID,
            nickname: displayNick,
            isConnected: false,
            signingPublicKey: discovered.signingPublicKey,
            agreementPublicKey: discovered.agreementPublicKey,
            fingerprint: fingerprint
        )
        entry.lastSeen = Date()
        peers.append(entry)
        savePeer(entry)
    }

    private func handleConnectedPeer(peerID: PeerID, displayName: String) {
        let nick = displayName.components(separatedBy: "#").first ?? String(peerID.value.prefix(8))
        if let idx = peers.firstIndex(where: { $0.peerID.value == peerID.value }) {
            peers[idx].isConnected = true
            peers[idx].lastSeen = Date()
            if peers[idx].nickname.count <= 8 {
                peers[idx].nickname = nick
            }
            savePeer(peers[idx])
        } else {
            var peer = PeerEntry(peerID: peerID, nickname: nick, isConnected: true)
            peer.lastSeen = Date()
            peers.append(peer)
            savePeer(peer)
        }
        processDeliveryQueue()
    }

    private func handleDisconnectedPeer(peerID: PeerID) {
        guard let idx = peers.firstIndex(where: { $0.peerID.value == peerID.value }) else { return }
        peers[idx].isConnected = false
        peers[idx].lastSeen = Date()
        savePeer(peers[idx])
    }

    private func upsertPeerFromMessage(senderID: PeerID, nickname: String) {
        if let idx = peers.firstIndex(where: { $0.peerID.value == senderID.value }) {
            peers[idx].nickname = nickname
            peers[idx].lastSeen = Date()
            peers[idx].isConnected = true
            savePeer(peers[idx])
        } else {
            var entry = PeerEntry(peerID: senderID, nickname: nickname, isConnected: true)
            entry.lastSeen = Date()
            peers.append(entry)
            savePeer(entry)
        }
    }

    private func makeFingerprint(signing: Data?, agreement: Data?) -> String? {
        guard let signing, let agreement else { return nil }
        let digest = SHA256.hash(data: signing + agreement)
        let full = Data(digest).hexString
        return String(full.prefix(16))
    }

    // MARK: - Persistence

    private func loadPersistedData() {
        guard let storageEngine else { return }
        peers.removeAll()
        messages.removeAll()
        knownMessageIDs.removeAll()

        let storedPeers = (try? storageEngine.fetchChatPeers()) ?? []
        peers = storedPeers.map { row in
            var peer = PeerEntry(
                peerID: PeerID(row.peerID),
                nickname: row.nickname,
                isConnected: false,
                signingPublicKey: row.signingPublicKey,
                agreementPublicKey: row.agreementPublicKey,
                fingerprint: row.fingerprint,
                isVerified: row.isVerified,
                keyVersion: row.keyVersion,
                trustWarning: row.trustWarning
            )
            peer.lastSeen = row.lastSeen
            return peer
        }

        for peer in peers {
            let rows = (try? storageEngine.fetchChatMessages(peerID: peer.peerID.value, limit: 2000)) ?? []
            let mapped = rows.map(mapFromRecord)
            messages[peer.peerID.value] = mapped
            for row in rows {
                knownMessageIDs.insert(row.messageID)
            }
        }
    }

    private func savePeer(_ peer: PeerEntry) {
        guard let storageEngine else { return }
        try? storageEngine.upsertChatPeer(
            StoredPeerRecord(
                peerID: peer.peerID.value,
                nickname: peer.nickname,
                lastSeen: peer.lastSeen,
                isConnected: peer.isConnected,
                signingPublicKey: peer.signingPublicKey,
                agreementPublicKey: peer.agreementPublicKey,
                fingerprint: peer.fingerprint,
                isVerified: peer.isVerified,
                keyVersion: peer.keyVersion,
                trustWarning: peer.trustWarning
            )
        )
    }

    private func saveMessage(_ record: StoredMessageRecord) {
        knownMessageIDs.insert(record.messageID)
        try? storageEngine?.upsertChatMessage(record)
    }

    private func mapFromRecord(_ record: StoredMessageRecord) -> ChatMessage {
        ChatMessage(
            id: record.messageID,
            text: record.textBody ?? "",
            senderID: record.senderID,
            senderNickname: record.senderNickname,
            isMe: record.isOutgoing,
            timestamp: record.timestamp,
            status: record.status,
            attempts: record.attempts,
            nextRetryAt: record.nextRetryAt,
            deliveredAt: record.deliveredAt,
            readAt: record.readAt,
            isRead: record.isRead,
            ttl: record.ttl,
            relayPath: record.relayPath,
            sessionID: record.sessionID,
            ratchetCounter: record.ratchetCounter,
            fileID: record.fileID,
            fileName: record.fileName
        )
    }

    private func appendOrUpdateMessage(peerID: String, _ message: ChatMessage) {
        var thread = messages[peerID] ?? []
        if let idx = thread.firstIndex(where: { $0.id == message.id }) {
            thread[idx] = message
        } else {
            thread.append(message)
            thread.sort { $0.timestamp < $1.timestamp }
        }
        messages[peerID] = thread
    }

    private func updateMessageStatus(
        messageID: UUID,
        status: OutboxStatus,
        attempts: Int,
        nextRetryAt: Date?,
        error: String?
    ) {
        _ = error
        for key in messages.keys {
            if let idx = messages[key]?.firstIndex(where: { $0.id == messageID }) {
                messages[key]?[idx].status = status
                messages[key]?[idx].attempts = attempts
                messages[key]?[idx].nextRetryAt = nextRetryAt
                return
            }
        }
    }

    // MARK: - Notifications

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    private func notifyIncomingMessage(from nickname: String, text: String) {
        #if canImport(UIKit)
        if UIApplication.shared.applicationState == .active {
            return
        }
        #endif
        let content = UNMutableNotificationContent()
        content.title = nickname
        content.body = text
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.2, repeats: false)
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request)
    }
}
