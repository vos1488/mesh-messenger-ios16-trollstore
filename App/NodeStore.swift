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

public struct ChatThreadSettings: Equatable, Codable {
    public var isMuted: Bool
    public var isPinned: Bool
    public var isArchived: Bool
    public var markedUnread: Bool

    public init(
        isMuted: Bool = false,
        isPinned: Bool = false,
        isArchived: Bool = false,
        markedUnread: Bool = false
    ) {
        self.isMuted = isMuted
        self.isPinned = isPinned
        self.isArchived = isArchived
        self.markedUnread = markedUnread
    }
}

public struct IncomingCallOffer: Identifiable, Equatable {
    public let id: UUID
    public let peerID: String
    public let peerNickname: String
    public let media: CallMediaType
    public let timestamp: Date
}

public struct ActiveCallSession: Identifiable, Equatable {
    public enum Phase: String {
        case ringing
        case connecting
        case active
        case ended
    }

    public let id: UUID
    public let peerID: String
    public let peerNickname: String
    public let media: CallMediaType
    public var phase: Phase
    public var startedAt: Date?
}

public struct DebugEvent: Identifiable, Equatable {
    public let id = UUID()
    public let timestamp: Date
    public let category: String
    public let message: String
}

private let appStoreDir: URL = {
    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    let legacyDir = docs.appendingPathComponent("MeshMessenger", isDirectory: true)
    let dir = docs.appendingPathComponent("MeshWave", isDirectory: true)
    if !FileManager.default.fileExists(atPath: dir.path),
       FileManager.default.fileExists(atPath: legacyDir.path) {
        try? FileManager.default.moveItem(at: legacyDir, to: dir)
    }
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}()

private func meshDBURL() -> URL { appStoreDir.appendingPathComponent("mesh.sqlite3") }

@MainActor
public final class NodeStore: ObservableObject {
    @Published public var peers: [PeerEntry] = []
    @Published public var messages: [String: [ChatMessage]] = [:]
    @Published public var fileProgress: [UUID: Double] = [:]
    @Published public var incomingCall: IncomingCallOffer?
    @Published public var activeCall: ActiveCallSession?
    @Published public var nickname: String = "iOS Node"
    @Published public var myPeerURI: String = ""
    @Published public var isRunning: Bool = false
    @Published public var errorMessage: String? = nil
    @Published public var wanBootstrapRaw: String = ""
    @Published public var debugEvents: [DebugEvent] = []
    @Published public var webSessionID: String?
    @Published public var webSessionStatusText: String = "Отключено"
    @Published public var webSessionAuthorized: Bool = false
    @Published public var callMicrophoneMuted: Bool = false
    @Published public var callSpeakerEnabled: Bool = true
    @Published public var chatThreadSettings: [String: ChatThreadSettings] = [:]
    @Published public var peerPresenceLastSeen: [String: Date] = [:]
    @Published public var peerTypingUntil: [String: Date] = [:]
    @Published public var locationTrackingEnabled: Bool = true
    @Published public var trustedLocation: TrustedLocationSnapshot = .unavailable

    private var transport: HybridTransport?
    private var storageEngine: StorageEngine?
    private var ratchetEngine: RatchetEngine?
    private var identityEngine: IdentityEngine?
    private var webBridgeClient: WebBridgeClient?
    private let fileTransferEngine = FileTransferEngine()
    private let callEngine = MCStreamCallEngine()
    private let backgroundRuntime = BackgroundRuntimeManager()
    private var locationTrustEngine: LocationTrustEngine?
    private var deliveryTask: Task<Void, Never>?
    private var outgoingCallInviteTask: Task<Void, Never>?
    private var outgoingCallTimeoutTask: Task<Void, Never>?
    private var callActivationInProgress = false
    private var myPeerIDValue: String = ""
    private var knownMessageIDs: Set<UUID> = []
    private var incomingFileNames: [UUID: String] = [:]
    private var currentScenePhase: ScenePhase = .active
    private var lastHeartbeatAt: Date = .distantPast
    private var typingStateSent: [String: Bool] = [:]
    private var lastTypingSentAt: [String: Date] = [:]
    private var isStartingNode = false
    private let maxDeliveryAttempts = 8
    private let maxMessagesPerPeerInMemory = 2000
    private let maxMessagesPerPeerOnStartup = 600
    private let locationTrackingUserDefaultsKey = "mesh.location.trust.enabled"

    public static let shared = NodeStore()
    private init() {}

    // MARK: - Lifecycle

    public func start() async {
        guard !isRunning, !isStartingNode else { return }
        isStartingNode = true
        defer { isStartingNode = false }
        let savedNick = UserDefaults.standard.string(forKey: "mesh_nickname") ?? nickname

        do {
            let identity = try await Task.detached(priority: .userInitiated) {
                try IdentityEngine(nickname: savedNick, capabilities: [.chat, .relay, .files])
            }.value

            let storage = try StorageEngine(databaseURL: meshDBURL())
            try storage.bootstrapSchema()
            try storage.recoverOutgoingOutbox(now: Date())

            identityEngine = identity
            storageEngine = storage
            ratchetEngine = RatchetEngine(identityEngine: identity, storageEngine: storage)

            let profile = identity.identity.profile
            myPeerIDValue = profile.peerID.value
            myPeerURI = profile.peerID.uri
            nickname = profile.nickname
            wanBootstrapRaw = UserDefaults.standard.string(forKey: "mesh_wan_bootstrap") ?? ""
            locationTrackingEnabled = UserDefaults.standard.object(forKey: locationTrackingUserDefaultsKey) as? Bool ?? true

            loadPersistedData()

            let t = try HybridTransport(
                localProfile: profile,
                signingPublicKey: identity.identity.signingPublicKey,
                agreementPublicKey: identity.identity.agreementPublicKey,
                wanBootstrapEndpoints: parseWANEndpoints(from: wanBootstrapRaw)
            )
            runStartupSmokeCheck(storage: storage, transport: t)

            t.onPeerDiscovered = { [weak self] discovered in
                Task { @MainActor [weak self] in
                    self?.handleDiscoveredPeer(discovered)
                }
            }
            t.onPeerConnected = { [weak self] peerID, displayName in
                Task { @MainActor [weak self] in
                    self?.appendDebug("net", "peer connected: \(peerID.value.prefix(8)) via \(displayName)")
                    self?.handleConnectedPeer(peerID: peerID, displayName: displayName)
                }
            }
            t.onPeerDisconnected = { [weak self] peerID in
                Task { @MainActor [weak self] in
                    self?.appendDebug("net", "peer disconnected: \(peerID.value.prefix(8))")
                    self?.handleDisconnectedPeer(peerID: peerID)
                }
            }
            t.onMessageReceived = { [weak self] packet, fromPeerID in
                Task { @MainActor [weak self] in
                    self?.appendDebug("pkt", "rx \(packet.kind.rawValue) \(packet.id.uuidString.prefix(8)) from \(fromPeerID.value.prefix(8))")
                    await self?.handleIncoming(packet: packet, fromPeerID: fromPeerID)
                }
            }
            t.onStreamReceived = { [weak self] stream, peerID, name in
                guard name.hasPrefix("call-audio") else {
                    stream.close()
                    return
                }
                Task { @MainActor [weak self] in
                    guard let self else {
                        stream.close()
                        return
                    }
                    guard let activeCall = self.activeCall,
                          (activeCall.phase == .connecting || activeCall.phase == .active),
                          activeCall.peerID == peerID.value else {
                        self.appendDebug("call", "drop unexpected stream from \(peerID.value.prefix(8))")
                        stream.close()
                        return
                    }
                    self.callEngine.handleIncomingAudioStream(stream, from: peerID)
                }
            }

            transport = t
            callEngine.weakTransport = t.streamTransport
            t.start()
            startDeliveryLoop()
            requestNotificationPermission()
            configureLocationTrustEngineIfNeeded()
            isRunning = true
            errorMessage = nil
            appendDebug("node", "node started as \(myPeerIDValue.prefix(8))")
        } catch {
            reportError(domain: "startup", userPrefix: "Ошибка запуска", error: error, surfaceToUser: true)
        }
    }

    public func stop() {
        deliveryTask?.cancel()
        deliveryTask = nil
        cancelOutgoingCallTimers()
        callActivationInProgress = false
        disconnectWebSession()
        transport?.stop()
        transport = nil
        callEngine.weakTransport = nil
        Task { @MainActor in
            await callEngine.endCall()
        }
        backgroundRuntime.deactivateCallAudio()
        backgroundRuntime.deactivateKeepAlive()
        resetCallControls()
        incomingCall = nil
        activeCall = nil
        peerTypingUntil.removeAll()
        typingStateSent.removeAll()
        lastTypingSentAt.removeAll()
        trustedLocation = .unavailable
        locationTrustEngine?.stop()
        isRunning = false
        appendDebug("node", "node stopped")
    }

    public func onAppBecameActive() {
        Task { @MainActor in
            currentScenePhase = .active
            if activeCall == nil {
                backgroundRuntime.deactivateKeepAlive()
            }
            if isRunning {
                processDeliveryQueue()
                broadcastSyncDigest()
                for peer in peers where peer.isConnected {
                    sendLatestReadReceipt(to: peer.peerID.value)
                }
            } else {
                await start()
            }
        }
    }

    public func handleScenePhase(_ phase: ScenePhase) {
        guard currentScenePhase != phase else { return }
        currentScenePhase = phase
        switch phase {
        case .active:
            locationTrustEngine?.setForegroundActive(true)
            onAppBecameActive()
        case .background:
            locationTrustEngine?.setForegroundActive(false)
            if activeCall != nil {
                backgroundRuntime.activateCallAudio()
            } else {
                backgroundRuntime.activateKeepAlive()
            }
            processDeliveryQueue()
        case .inactive:
            break
        @unknown default:
            break
        }
    }

    public func setLocationTrackingEnabled(_ enabled: Bool) {
        locationTrackingEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: locationTrackingUserDefaultsKey)
        if enabled {
            configureLocationTrustEngineIfNeeded()
        } else {
            locationTrustEngine?.stop()
            trustedLocation = .unavailable
        }
    }

    public var locationTrustSummary: String {
        switch trustedLocation.confidence {
        case .high:
            return "Высокое доверие"
        case .medium:
            return "Среднее доверие"
        case .low:
            return "Низкое доверие"
        case .unreliable:
            return "Недостоверно"
        }
    }

    private func configureLocationTrustEngineIfNeeded() {
        guard locationTrackingEnabled else { return }
        if locationTrustEngine == nil {
            let engine = LocationTrustEngine()
            engine.onSnapshotChanged = { [weak self] snapshot in
                Task { @MainActor [weak self] in
                    self?.trustedLocation = snapshot
                }
            }
            engine.onDiagnostics = { [weak self] text in
                Task { @MainActor [weak self] in
                    self?.appendDebug("geo", text)
                }
            }
            locationTrustEngine = engine
        }
        locationTrustEngine?.setForegroundActive(currentScenePhase == .active)
        locationTrustEngine?.start()
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
                reportError(domain: "crypto", userPrefix: "E2EE ошибка", error: error, surfaceToUser: true)
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

    public func sendTyping(isTyping: Bool, to peer: PeerEntry) {
        guard isRunning else { return }
        let peerID = peer.peerID.value
        let now = Date()
        let minInterval: TimeInterval = isTyping ? 1.0 : 0.3
        if typingStateSent[peerID] == isTyping,
           now.timeIntervalSince(lastTypingSentAt[peerID] ?? .distantPast) < minInterval {
            return
        }
        if !isTyping, typingStateSent[peerID] != true {
            return
        }

        let packet = TransportMessage(
            kind: .typing,
            senderPeerID: myPeerIDValue,
            senderNickname: nickname,
            receiverPeerID: peerID,
            ttl: 8,
            relayPath: [myPeerIDValue],
            typing: isTyping
        )
        do {
            try sendTransportMessage(packet, targetPeerID: peerID, relayExcluding: Set([myPeerIDValue]))
            typingStateSent[peerID] = isTyping
            lastTypingSentAt[peerID] = now
        } catch {
            appendDebug("net", "typing signal failed: \(error.localizedDescription)")
        }
    }

    public func isPeerTyping(_ peerID: String, now: Date = Date()) -> Bool {
        guard let until = peerTypingUntil[peerID] else { return false }
        return until > now
    }

    public func peerPresenceText(_ peerID: String, now: Date = Date()) -> String {
        if let peer = peers.first(where: { $0.peerID.value == peerID }), peer.isConnected {
            return "онлайн"
        }
        guard let last = peerPresenceLastSeen[peerID] else { return "не в сети" }
        let delta = now.timeIntervalSince(last)
        if delta < 45 { return "онлайн недавно" }
        if delta < 180 { return "был(а) только что" }
        if delta < 3600 { return "был(а) \(Int(delta / 60)) мин назад" }
        return "не в сети"
    }

    // MARK: - Clear chat

    public func clearChat(peerID: String) {
        let removedIDs = Set((messages[peerID] ?? []).map(\.id))
        knownMessageIDs.subtract(removedIDs)
        messages[peerID] = []
        guard let storageEngine else { return }
        do {
            try storageEngine.deleteMessages(peerID: peerID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func deleteLocalMessage(peerID: String, messageID: UUID) {
        guard var thread = messages[peerID] else { return }
        thread.removeAll { $0.id == messageID }
        messages[peerID] = thread
        knownMessageIDs.remove(messageID)
        guard let storageEngine else { return }
        do {
            try storageEngine.deleteMessage(messageID: messageID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func clearAllChats() {
        messages.removeAll()
        knownMessageIDs.removeAll()
        guard let storageEngine else { return }
        do {
            try storageEngine.deleteAllMessages()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Remove peer

    /// Remove a peer and all its messages from memory and DB.
    public func removePeer(peerID: String) {
        let removedIDs = Set((messages[peerID] ?? []).map(\.id))
        knownMessageIDs.subtract(removedIDs)
        peers.removeAll { $0.peerID.value == peerID }
        messages.removeValue(forKey: peerID)
        chatThreadSettings.removeValue(forKey: peerID)
        guard let storageEngine else { return }
        do {
            try storageEngine.deleteMessages(peerID: peerID)
            try storageEngine.deletePeer(peerID: peerID)
            try storageEngine.deleteChatThreadSettings(peerID: peerID)
        } catch {
            errorMessage = error.localizedDescription
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
            if var settings = chatThreadSettings[peerID], settings.markedUnread {
                settings.markedUnread = false
                setChatThreadSettings(peerID: peerID, settings: settings)
            }

            if let latestRead = readIDs.last {
                let receipt = TransportMessage(
                    kind: .readReceipt,
                    senderPeerID: myPeerIDValue,
                    senderNickname: nickname,
                    receiverPeerID: peerID,
                    readForMessageID: latestRead
                )
                Task { @MainActor [weak self] in
                    await self?.sendControlMessageWithRetry(
                        receipt,
                        targetPeerID: peerID,
                        attempts: 3,
                        tag: "read receipt"
                    )
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func sendFile(at url: URL, to peer: PeerEntry) {
        guard let storageEngine else { return }
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

                let messageRecord = StoredMessageRecord(
                    messageID: meta.id,
                    peerID: peer.peerID.value,
                    senderID: myPeerIDValue,
                    senderNickname: nickname,
                    textBody: "Файл: \(url.lastPathComponent)",
                    timestamp: meta.timestamp,
                    status: .sent,
                    attempts: 0,
                    nextRetryAt: nil,
                    deliveredAt: nil,
                    readAt: nil,
                    lastError: nil,
                    isOutgoing: true,
                    isRead: false,
                    ttl: meta.ttl,
                    relayPath: meta.relayPath,
                    sessionID: nil,
                    ratchetCounter: nil,
                    nonce: nil,
                    ciphertext: nil,
                    tag: nil,
                    fileID: transferID,
                    fileName: url.lastPathComponent,
                    fileChunkIndex: nil,
                    fileTotalChunks: chunks.count,
                    fileChunkData: nil,
                    fileChecksum: first.fileHash
                )
                saveMessage(messageRecord)
                appendOrUpdateMessage(peerID: peer.peerID.value, mapFromRecord(messageRecord))

                try await sendTransportMessageWithRetry(
                    meta,
                    targetPeerID: peer.peerID.value,
                    relayExcluding: Set([myPeerIDValue]),
                    maxAttempts: 4
                )

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
                    try await sendTransportMessageWithRetry(
                        chunkPacket,
                        targetPeerID: peer.peerID.value,
                        relayExcluding: Set([myPeerIDValue]),
                        maxAttempts: 4
                    )
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
                reportError(domain: "files", userPrefix: "Файл не отправлен", error: error, surfaceToUser: true)
            }
        }
    }

    // MARK: - Calls

    public func startVoiceCall(to peer: PeerEntry) {
        if let current = activeCall, current.phase != .ended {
            errorMessage = "Уже есть активный звонок"
            appendDebug("call", "start ignored: active call \(current.id.uuidString.prefix(8))")
            return
        }
        let callID = UUID()
        resetCallControls()
        cancelOutgoingCallTimers()
        appendDebug("call", "invite \(callID.uuidString.prefix(8)) -> \(peer.peerID.value.prefix(8))")
        activeCall = ActiveCallSession(
            id: callID,
            peerID: peer.peerID.value,
            peerNickname: peer.nickname,
            media: .voice,
            phase: .ringing,
            startedAt: nil
        )
        let invite = TransportMessage(
            kind: .callInvite,
            senderPeerID: myPeerIDValue,
            senderNickname: nickname,
            receiverPeerID: peer.peerID.value,
            callID: callID,
            callMediaType: CallMediaType.voice.rawValue
        )
        if sendCallSignal(invite, targetPeerID: peer.peerID.value) {
            scheduleOutgoingCallRetries(callID: callID, peerID: peer.peerID.value, media: .voice)
        } else {
            errorMessage = "Не удалось начать звонок"
            activeCall = nil
        }
    }

    public func acceptIncomingCall(_ offer: IncomingCallOffer? = nil) {
        let incoming = offer ?? incomingCall
        guard let incoming else { return }
        if let current = activeCall, current.id == incoming.id, current.phase != .ended {
            appendDebug("call", "accept ignored: call already in phase \(current.phase.rawValue)")
            return
        }
        guard !callActivationInProgress else {
            appendDebug("call", "accept ignored: activation in progress")
            return
        }
        incomingCall = nil
        appendDebug("call", "accept \(incoming.id.uuidString.prefix(8)) from \(incoming.peerID.prefix(8))")

        // CRITICAL: send callAccept BEFORE changing AVAudioSession
        // (activating voiceChat audio session can disrupt BT/MPC transport)
        let accept = TransportMessage(
            kind: .callAccept,
            senderPeerID: myPeerIDValue,
            senderNickname: nickname,
            receiverPeerID: incoming.peerID,
            callID: incoming.id,
            callMediaType: incoming.media.rawValue
        )
        if !sendCallSignal(accept, targetPeerID: incoming.peerID) {
            appendDebug("error", "call accept first send failed")
        }
        retryCallSignal(message: accept, targetPeerID: incoming.peerID, attempts: 2)

        activeCall = ActiveCallSession(
            id: incoming.id,
            peerID: incoming.peerID,
            peerNickname: incoming.peerNickname,
            media: incoming.media,
            phase: .connecting,
            startedAt: nil
        )
        callEngine.weakTransport = transport?.streamTransport
        callActivationInProgress = true

        Task { @MainActor in
            defer { self.callActivationInProgress = false }
            do {
                // Activate audio session before starting engine (required for mic input)
                backgroundRuntime.activateCallAudio()
                try await callEngine.startCall(with: PeerID(incoming.peerID), media: incoming.media)
                callEngine.setMicrophoneMuted(callMicrophoneMuted)
                _ = callEngine.setSpeakerEnabled(callSpeakerEnabled)
                activeCall?.phase = .active
                activeCall?.startedAt = Date()
            } catch {
                await callEngine.endCall()
                errorMessage = "Ошибка звонка: \(error.localizedDescription)"
                activeCall = nil
                backgroundRuntime.deactivateCallAudio()
                resetCallControls()
                appendDebug("error", "call start failed: \(error.localizedDescription)")
            }
        }
    }

    public func declineIncomingCall(_ offer: IncomingCallOffer? = nil) {
        let incoming = offer ?? incomingCall
        guard let incoming else { return }
        let decline = TransportMessage(
            kind: .callDecline,
            senderPeerID: myPeerIDValue,
            senderNickname: nickname,
            receiverPeerID: incoming.peerID,
            callID: incoming.id,
            callMediaType: incoming.media.rawValue
        )
        _ = sendCallSignal(decline, targetPeerID: incoming.peerID)
        retryCallSignal(message: decline, targetPeerID: incoming.peerID, attempts: 1)
        incomingCall = nil
    }

    public func endCurrentCall() {
        guard let activeCall else { return }
        callActivationInProgress = false
        cancelOutgoingCallTimers()
        appendDebug("call", "end \(activeCall.id.uuidString.prefix(8))")
        let end = TransportMessage(
            kind: .callEnd,
            senderPeerID: myPeerIDValue,
            senderNickname: nickname,
            receiverPeerID: activeCall.peerID,
            callID: activeCall.id,
            callMediaType: activeCall.media.rawValue
        )
        _ = sendCallSignal(end, targetPeerID: activeCall.peerID)
        retryCallSignal(message: end, targetPeerID: activeCall.peerID, attempts: 1)
        Task { @MainActor in
            await callEngine.endCall()
            self.activeCall?.phase = .ended
            self.backgroundRuntime.deactivateCallAudio()
            self.resetCallControls()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.activeCall = nil
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

    public func saveWANBootstrapEndpoints(_ raw: String) {
        wanBootstrapRaw = raw
        UserDefaults.standard.set(raw, forKey: "mesh_wan_bootstrap")
        transport?.updateWANBootstrapEndpoints(parseWANEndpoints(from: raw))
        appendDebug("wan", "bootstrap updated: \(parseWANEndpoints(from: raw).joined(separator: ", "))")
    }

    public func connectWebSession(from qrPayload: String) {
        guard let payload = parseWebPairPayload(from: qrPayload) else {
            webSessionStatusText = "Неверный QR"
            webSessionAuthorized = false
            appendDebug("web", "invalid QR payload")
            return
        }
        guard !myPeerIDValue.isEmpty else {
            webSessionStatusText = "Узел не запущен"
            webSessionAuthorized = false
            appendDebug("web", "node not running for web auth")
            return
        }
        guard let identity = identityEngine else {
            webSessionStatusText = "Крипто-движок недоступен"
            webSessionAuthorized = false
            appendDebug("web", "identity engine unavailable")
            return
        }

        let issuedAt = Int(Date().timeIntervalSince1970)
        let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let challenge = "\(payload.sessionID):\(issuedAt):\(nonce)"
        guard let challengeData = challenge.data(using: .utf8),
              let signatureData = try? identity.signature(for: challengeData) else {
            webSessionStatusText = "Не удалось подписать web auth"
            webSessionAuthorized = false
            appendDebug("web", "failed to sign auth challenge")
            return
        }
        let signingKeyB64 = identity.identity.signingPublicKey.base64EncodedString()
        let agreementKeyB64 = identity.identity.agreementPublicKey.base64EncodedString()
        let fingerprint = Data(SHA256.hash(data: identity.identity.signingPublicKey + identity.identity.agreementPublicKey)).hexString

        ensureWebBridgeClient()
        webSessionID = payload.sessionID
        webSessionStatusText = "Подключение…"
        webSessionAuthorized = false
        appendDebug("web", "connect session \(payload.sessionID.prefix(8))")
        webBridgeClient?.connect(
            payload: payload,
            peerID: myPeerIDValue,
            nickname: nickname,
            signingPublicKeyB64: signingKeyB64,
            agreementPublicKeyB64: agreementKeyB64,
            keyFingerprint: fingerprint,
            authChallenge: challenge,
            authSignature: signatureData.base64EncodedString()
        )
    }

    public func disconnectWebSession() {
        webBridgeClient?.disconnect(reason: "manual")
        webSessionID = nil
        webSessionAuthorized = false
        webSessionStatusText = "Отключено"
    }

    public func unreadCount(for peer: PeerEntry) -> Int {
        let peerID = peer.peerID.value
        let unread = (messages[peerID] ?? []).filter { !$0.isMe && !$0.isRead }.count
        let forced = chatThreadSettings[peerID]?.markedUnread ?? false
        return forced && unread == 0 ? 1 : unread
    }

    public func threadSettings(for peerID: String) -> ChatThreadSettings {
        chatThreadSettings[peerID] ?? ChatThreadSettings()
    }

    public func setChatMuted(peerID: String, muted: Bool) {
        var settings = threadSettings(for: peerID)
        settings.isMuted = muted
        setChatThreadSettings(peerID: peerID, settings: settings)
    }

    public func setChatPinned(peerID: String, pinned: Bool) {
        var settings = threadSettings(for: peerID)
        settings.isPinned = pinned
        setChatThreadSettings(peerID: peerID, settings: settings)
    }

    public func setChatArchived(peerID: String, archived: Bool) {
        var settings = threadSettings(for: peerID)
        settings.isArchived = archived
        if archived {
            settings.markedUnread = false
        }
        setChatThreadSettings(peerID: peerID, settings: settings)
    }

    public func markConversationUnread(peerID: String) {
        var settings = threadSettings(for: peerID)
        settings.markedUnread = true
        setChatThreadSettings(peerID: peerID, settings: settings)
    }

    public func toggleCallMicrophoneMuted() {
        setCallMicrophoneMuted(!callMicrophoneMuted)
    }

    public func setCallMicrophoneMuted(_ muted: Bool) {
        callMicrophoneMuted = muted
        callEngine.setMicrophoneMuted(muted)
    }

    public func toggleCallSpeakerEnabled() {
        setCallSpeakerEnabled(!callSpeakerEnabled)
    }

    public func setCallSpeakerEnabled(_ enabled: Bool) {
        if callEngine.setSpeakerEnabled(enabled) {
            callSpeakerEnabled = enabled
            return
        }
        errorMessage = "Не удалось переключить аудиовыход"
        appendDebug("error", "speaker switch failed")
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
        let logicalSender = PeerID(packet.senderPeerID)
        notePeerPresence(peerID: logicalSender.value)

        if packet.ttl <= 0, packet.receiverPeerID != myPeerIDValue {
            appendDebug("relay", "drop ttl=0 \(packet.id.uuidString.prefix(8))")
            return
        }
        if packet.receiverPeerID != myPeerIDValue, packet.relayPath.contains(myPeerIDValue) {
            appendDebug("relay", "drop loop \(packet.id.uuidString.prefix(8))")
            return
        }

        switch packet.kind {
        case .ack:
            handleAck(packet)
            return
        case .readReceipt:
            handleReadReceipt(packet)
            return
        case .callInvite:
            if packet.receiverPeerID == myPeerIDValue {
                handleIncomingCallInvite(packet, fromPeerID: logicalSender, relayHopPeerID: fromPeerID)
                return
            }
        case .callAccept:
            if packet.receiverPeerID == myPeerIDValue {
                handleIncomingCallAccept(packet, fromPeerID: logicalSender, relayHopPeerID: fromPeerID)
                return
            }
        case .callDecline:
            if packet.receiverPeerID == myPeerIDValue {
                handleIncomingCallDecline(packet, fromPeerID: logicalSender, relayHopPeerID: fromPeerID)
                return
            }
        case .callEnd:
            if packet.receiverPeerID == myPeerIDValue {
                handleIncomingCallEnd(packet, fromPeerID: logicalSender, relayHopPeerID: fromPeerID)
                return
            }
        case .syncDigest:
            processDeliveryQueue()
            return
        case .typing:
            if packet.receiverPeerID == myPeerIDValue {
                handleTypingSignal(packet, fromPeerID: logicalSender)
            } else {
                relay(packet: packet, fromPeerID: fromPeerID)
            }
            return
        default:
            break
        }

        let storedAlready = (try? storageEngine?.hasMessage(messageID: packet.id)) ?? false
        if knownMessageIDs.contains(packet.id) || storedAlready {
            if packet.kind == .chat || packet.kind == .relay {
                sendAck(for: packet.id, to: logicalSender)
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
            let text = await decryptOrFallback(packet: packet, fromPeerID: logicalSender)
            let incoming = StoredMessageRecord(
                messageID: packet.id,
                peerID: logicalSender.value,
                senderID: logicalSender.value,
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
            appendOrUpdateMessage(peerID: logicalSender.value, mapFromRecord(incoming))
            upsertPeerFromMessage(senderID: logicalSender, nickname: packet.senderNickname)
            sendAck(for: packet.id, to: logicalSender)
            notifyIncomingMessage(from: packet.senderNickname, text: text, peerID: logicalSender.value)

        case .fileMeta:
            if let fileID = packet.fileID, let name = packet.fileName, let totalChunks = packet.fileTotalChunks {
                let safeName = sanitizedIncomingFileName(name, fileID: fileID)
                incomingFileNames[fileID] = safeName
                let fileMessage = StoredMessageRecord(
                    messageID: packet.id,
                    peerID: logicalSender.value,
                    senderID: logicalSender.value,
                    senderNickname: packet.senderNickname,
                    textBody: "Входящий файл: \(safeName)",
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
                    sessionID: nil,
                    ratchetCounter: nil,
                    nonce: nil,
                    ciphertext: nil,
                    tag: nil,
                    fileID: fileID,
                    fileName: safeName,
                    fileChunkIndex: nil,
                    fileTotalChunks: totalChunks,
                    fileChunkData: nil,
                    fileChecksum: packet.fileChecksum
                )
                saveMessage(fileMessage)
                appendOrUpdateMessage(peerID: logicalSender.value, mapFromRecord(fileMessage))
                try? storageEngine?.upsertFileTransfer(
                    StoredFileTransferRecord(
                        fileID: fileID,
                        peerID: logicalSender.value,
                        displayName: safeName,
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
            handleIncomingFileChunk(packet: packet, fromPeerID: logicalSender)

        case .ack, .readReceipt, .callInvite, .callAccept, .callDecline, .callEnd, .typing:
            break
        case .syncDigest:
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
                    displayName: incomingFileNames[fileID] ?? sanitizedIncomingFileName(packet.fileName ?? "file.bin", fileID: fileID),
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
                let fileName = incomingFileNames[fileID] ?? sanitizedIncomingFileName("received-\(fileID.uuidString).bin", fileID: fileID)
                let url = receiveDir.appendingPathComponent(fileName)
                try rebuilt.write(to: url, options: .atomic)
            } catch {
                errorMessage = "Файл повреждён: \(error.localizedDescription)"
            }
        }
    }

    private func sanitizedIncomingFileName(_ raw: String, fileID: UUID) -> String {
        let invalid = CharacterSet(charactersIn: "\\/:*?\"<>|")
        let compact = raw.components(separatedBy: invalid).joined(separator: "_")
        let trimmed = compact.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "received-\(fileID.uuidString).bin"
        }
        // Keep names reasonable and filesystem-friendly.
        return String(trimmed.prefix(96))
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

    private func handleTypingSignal(_ packet: TransportMessage, fromPeerID: PeerID) {
        guard packet.receiverPeerID == myPeerIDValue else { return }
        let isTyping = packet.typing ?? false
        if isTyping {
            peerTypingUntil[fromPeerID.value] = Date().addingTimeInterval(4)
        } else {
            peerTypingUntil.removeValue(forKey: fromPeerID.value)
        }
    }

    private func notePeerPresence(peerID: String) {
        peerPresenceLastSeen[peerID] = Date()
        if let idx = peers.firstIndex(where: { $0.peerID.value == peerID }) {
            peers[idx].lastSeen = Date()
        }
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
            kind: packet.kind,
            senderPeerID: packet.senderPeerID,
            senderNickname: packet.senderNickname,
            receiverPeerID: packet.receiverPeerID,
            timestamp: packet.timestamp,
            ttl: packet.ttl - 1,
            relayPath: path,
            text: packet.text,
            ackForMessageID: packet.ackForMessageID,
            readForMessageID: packet.readForMessageID,
            typing: packet.typing,
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
            fileChecksum: packet.fileChecksum,
            callID: packet.callID,
            callMediaType: packet.callMediaType
        )
        let excluded = Set(path + [fromPeerID.value])
        try? transport.sendToConnectedPeers(message: relayPacket, excludingPeerIDs: excluded)
    }

    private func sendAck(for messageID: UUID, to peerID: PeerID) {
        let ack = TransportMessage(
            kind: .ack,
            senderPeerID: myPeerIDValue,
            senderNickname: nickname,
            receiverPeerID: peerID.value,
            ackForMessageID: messageID
        )
        Task { @MainActor [weak self] in
            await self?.sendControlMessageWithRetry(ack, targetPeerID: peerID.value, attempts: 3, tag: "ack")
        }
    }

    private func handleIncomingCallInvite(_ packet: TransportMessage, fromPeerID: PeerID, relayHopPeerID: PeerID) {
        guard packet.receiverPeerID == myPeerIDValue, let callID = packet.callID else { return }
        let media = CallMediaType(rawValue: packet.callMediaType ?? "voice") ?? .voice
        if let existing = incomingCall, existing.id == callID {
            appendDebug("call", "duplicate invite \(callID.uuidString.prefix(8))")
            return
        }
        appendDebug(
            "call",
            "incoming invite \(callID.uuidString.prefix(8)) from \(fromPeerID.value.prefix(8)) hop \(relayHopPeerID.value.prefix(8))"
        )
        if let current = activeCall, current.phase != .ended {
            let decline = TransportMessage(
                kind: .callDecline,
                senderPeerID: myPeerIDValue,
                senderNickname: nickname,
                receiverPeerID: fromPeerID.value,
                callID: callID,
                callMediaType: media.rawValue
            )
            _ = sendCallSignal(decline, targetPeerID: fromPeerID.value)
            retryCallSignal(message: decline, targetPeerID: fromPeerID.value, attempts: 1)
            return
        }
        incomingCall = IncomingCallOffer(
            id: callID,
            peerID: fromPeerID.value,
            peerNickname: packet.senderNickname,
            media: media,
            timestamp: Date()
        )
        if currentScenePhase != .active {
            notifyIncomingMessage(from: packet.senderNickname, text: "Входящий \(media.rawValue) звонок")
        }
    }

    private func handleIncomingCallAccept(_ packet: TransportMessage, fromPeerID: PeerID, relayHopPeerID: PeerID) {
        guard let callID = packet.callID,
              activeCall?.id == callID else { return }
        guard activeCall?.phase == .ringing else {
            appendDebug("call", "accept ignored in phase \(activeCall?.phase.rawValue ?? "nil")")
            return
        }
        guard !callActivationInProgress else {
            appendDebug("call", "accept duplicate ignored: activation in progress")
            return
        }

        cancelOutgoingCallTimers()
        activeCall?.phase = .connecting
        appendDebug("call", "accepted by \(fromPeerID.value.prefix(8)) hop \(relayHopPeerID.value.prefix(8))")
        callEngine.weakTransport = transport?.streamTransport
        callActivationInProgress = true

        Task { @MainActor in
            defer { self.callActivationInProgress = false }
            do {
                backgroundRuntime.activateCallAudio()
                let media = activeCall?.media ?? .voice
                try await callEngine.startCall(with: PeerID(fromPeerID.value), media: media)
                callEngine.setMicrophoneMuted(callMicrophoneMuted)
                _ = callEngine.setSpeakerEnabled(callSpeakerEnabled)
                activeCall?.phase = .active
                activeCall?.startedAt = Date()
            } catch {
                await callEngine.endCall()
                errorMessage = "Ошибка звонка: \(error.localizedDescription)"
                activeCall = nil
                backgroundRuntime.deactivateCallAudio()
                resetCallControls()
                appendDebug("error", "caller start failed: \(error.localizedDescription)")
            }
        }
    }

    private func handleIncomingCallDecline(_ packet: TransportMessage, fromPeerID: PeerID, relayHopPeerID: PeerID) {
        guard let callID = packet.callID,
              activeCall?.id == callID else { return }
        callActivationInProgress = false
        cancelOutgoingCallTimers()
        Task { @MainActor in
            await callEngine.endCall()
            activeCall?.phase = .ended
            appendDebug("call", "declined by \(fromPeerID.value.prefix(8)) hop \(relayHopPeerID.value.prefix(8))")
            backgroundRuntime.deactivateCallAudio()
            resetCallControls()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.activeCall = nil
            }
        }
    }

    private func handleIncomingCallEnd(_ packet: TransportMessage, fromPeerID: PeerID, relayHopPeerID: PeerID) {
        if let incoming = incomingCall, incoming.id == packet.callID {
            incomingCall = nil
        }
        guard let callID = packet.callID,
              activeCall?.id == callID else { return }
        callActivationInProgress = false
        cancelOutgoingCallTimers()
        Task { @MainActor in
            await callEngine.endCall()
            activeCall?.phase = .ended
            appendDebug("call", "ended by remote \(fromPeerID.value.prefix(8)) hop \(relayHopPeerID.value.prefix(8))")
            backgroundRuntime.deactivateCallAudio()
            resetCallControls()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.activeCall = nil
            }
        }
    }

    private func broadcastSyncDigest() {
        guard let transport else { return }
        let heartbeat = TransportMessage(
            kind: .syncDigest,
            senderPeerID: myPeerIDValue,
            senderNickname: nickname,
            receiverPeerID: "*"
        )
        try? transport.sendToConnectedPeers(message: heartbeat, excludingPeerIDs: [])
        transport.sendHeartbeat(senderNickname: nickname)
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
        maybeSendHeartbeat()
        let now = Date()
        let due = (try? storageEngine.fetchDueOutgoingMessages(now: now, limit: 64)) ?? []
        for record in due where record.status != .delivered && record.status != .read {
            attemptDelivery(record)
        }
    }

    private func maybeSendHeartbeat() {
        let now = Date()
        peerTypingUntil = peerTypingUntil.filter { $0.value > now }
        let minInterval: TimeInterval
        if activeCall != nil {
            minInterval = 8
        } else if currentScenePhase == .background {
            minInterval = 28
        } else {
            minInterval = 12
        }
        guard now.timeIntervalSince(lastHeartbeatAt) >= minInterval else { return }
        lastHeartbeatAt = now
        broadcastSyncDigest()
    }

    private func attemptDelivery(_ record: StoredMessageRecord) {
        guard let storageEngine else { return }
        if record.attempts >= maxDeliveryAttempts {
            try? storageEngine.markMessageStatus(
                messageID: record.messageID,
                status: .poisoned,
                attempts: record.attempts,
                nextRetryAt: nil,
                lastError: "max attempts exceeded"
            )
            updateMessageStatus(
                messageID: record.messageID,
                status: .poisoned,
                attempts: record.attempts,
                nextRetryAt: nil,
                error: "max attempts exceeded"
            )
            appendDebug("delivery", "poisoned \(record.messageID.uuidString.prefix(8))")
            return
        }

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
            try sendTransportMessage(
                packet,
                targetPeerID: record.peerID,
                relayExcluding: Set(record.relayPath)
            )

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
            appendDebug("delivery", "sent \(record.messageID.uuidString.prefix(8)) #\(attempts)")
        } catch {
            let attempts = record.attempts + 1
            let poisoned = attempts >= maxDeliveryAttempts
            let nextRetry = poisoned ? nil : Date().addingTimeInterval(backoffSeconds(forAttempt: attempts))
            try? storageEngine.markMessageStatus(
                messageID: record.messageID,
                status: poisoned ? .poisoned : .failed,
                attempts: attempts,
                nextRetryAt: nextRetry,
                lastError: error.localizedDescription
            )
            updateMessageStatus(
                messageID: record.messageID,
                status: poisoned ? .poisoned : .failed,
                attempts: attempts,
                nextRetryAt: nextRetry,
                error: error.localizedDescription
            )
            reportError(
                domain: "network",
                userPrefix: poisoned ? "Доставка остановлена" : "Проблема доставки",
                error: error,
                surfaceToUser: false
            )
            appendDebug("delivery", "\(poisoned ? "poisoned" : "retry") \(record.messageID.uuidString.prefix(8)) #\(attempts)")
        }
    }

    private func backoffSeconds(forAttempt attempt: Int) -> TimeInterval {
        let raw = pow(2.0, Double(max(1, attempt)))
        return min(120, raw)
    }

    // MARK: - Call reliability

    private func scheduleOutgoingCallRetries(callID: UUID, peerID: String, media: CallMediaType) {
        outgoingCallInviteTask?.cancel()
        outgoingCallTimeoutTask?.cancel()

        outgoingCallInviteTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for attempt in 2...5 {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled else { return }
                guard let current = self.activeCall, current.id == callID, current.phase == .ringing else { return }

                let invite = TransportMessage(
                    kind: .callInvite,
                    senderPeerID: self.myPeerIDValue,
                    senderNickname: self.nickname,
                    receiverPeerID: peerID,
                    callID: callID,
                    callMediaType: media.rawValue
                )
                if let transport = self.transport {
                    do {
                        try transport.send(message: invite, to: PeerID(peerID))
                    } catch {
                        try? transport.sendToConnectedPeers(message: invite, excludingPeerIDs: [self.myPeerIDValue])
                    }
                }
                self.appendDebug("call", "re-invite \(callID.uuidString.prefix(8)) attempt \(attempt)")
            }
        }

        outgoingCallTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 25_000_000_000)
            guard let self else { return }
            guard let current = self.activeCall, current.id == callID, current.phase == .ringing else { return }
            self.errorMessage = "Звонок не принят (таймаут)"
            self.appendDebug("call", "timeout \(callID.uuidString.prefix(8))")
            self.activeCall?.phase = .ended
            self.backgroundRuntime.deactivateCallAudio()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.activeCall = nil
            }
        }
    }

    private func retryCallSignal(message: TransportMessage, targetPeerID: String, attempts: Int) {
        guard attempts > 0 else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            for n in 1...attempts {
                try? await Task.sleep(nanoseconds: UInt64(700_000_000 * n))
                guard self.transport != nil else { return }
                _ = self.sendCallSignal(message, targetPeerID: targetPeerID)
            }
        }
    }

    @discardableResult
    private func sendCallSignal(_ message: TransportMessage, targetPeerID: String) -> Bool {
        do {
            try sendTransportMessage(message, targetPeerID: targetPeerID, relayExcluding: Set([myPeerIDValue]))
            return true
        } catch {
            reportError(domain: "network", userPrefix: "Сигнал звонка не отправлен", error: error, surfaceToUser: false)
            appendDebug("call", "signal \(message.kind.rawValue) failed")
            return false
        }
    }

    private func cancelOutgoingCallTimers() {
        outgoingCallInviteTask?.cancel()
        outgoingCallInviteTask = nil
        outgoingCallTimeoutTask?.cancel()
        outgoingCallTimeoutTask = nil
    }

    // MARK: - Peer management

    private func handleDiscoveredPeer(_ discovered: TransportDiscoveredPeer) {
        let peerID = discovered.peerID.value
        let displayNick = discovered.displayName.components(separatedBy: "#").first ?? String(peerID.prefix(8))
        let fingerprint = makeFingerprint(signing: discovered.signingPublicKey, agreement: discovered.agreementPublicKey)
        notePeerPresence(peerID: peerID)

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
        notePeerPresence(peerID: peerID.value)
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
        sendLatestReadReceipt(to: peerID.value)
        processDeliveryQueue()
    }

    private func handleDisconnectedPeer(peerID: PeerID) {
        guard let idx = peers.firstIndex(where: { $0.peerID.value == peerID.value }) else { return }
        peers[idx].isConnected = false
        peers[idx].lastSeen = Date()
        peerTypingUntil.removeValue(forKey: peerID.value)
        savePeer(peers[idx])
    }

    private func upsertPeerFromMessage(senderID: PeerID, nickname: String) {
        notePeerPresence(peerID: senderID.value)
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
        chatThreadSettings.removeAll()
        knownMessageIDs.removeAll()
        peerTypingUntil.removeAll()

        let storedPeers = (try? storageEngine.fetchChatPeers()) ?? []
        // Deduplicate by peerID (keep the most recently seen entry)
        var seenPeerIDs = Set<String>()
        let uniqueStoredPeers = storedPeers.filter { seenPeerIDs.insert($0.peerID).inserted }
        peers = uniqueStoredPeers.map { row in
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
        peerPresenceLastSeen = Dictionary(uniqueKeysWithValues: peers.map { ($0.peerID.value, $0.lastSeen) })

        let storedThreadSettings = (try? storageEngine.fetchChatThreadSettings()) ?? []
        for row in storedThreadSettings {
            chatThreadSettings[row.peerID] = ChatThreadSettings(
                isMuted: row.isMuted,
                isPinned: row.isPinned,
                isArchived: row.isArchived,
                markedUnread: row.markedUnread
            )
        }

        for peer in peers {
            let rows = (try? storageEngine.fetchChatMessages(peerID: peer.peerID.value, limit: maxMessagesPerPeerOnStartup)) ?? []
            var seenMessageIDs = Set<UUID>()
            let uniqueRows = rows.filter { seenMessageIDs.insert($0.messageID).inserted }
            let mapped = uniqueRows.map(mapFromRecord)
            messages[peer.peerID.value] = mapped
            for row in uniqueRows {
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

    private func setChatThreadSettings(peerID: String, settings: ChatThreadSettings) {
        chatThreadSettings[peerID] = settings
        guard let storageEngine else { return }
        try? storageEngine.upsertChatThreadSettings(
            StoredChatThreadSettings(
                peerID: peerID,
                isMuted: settings.isMuted,
                isPinned: settings.isPinned,
                isArchived: settings.isArchived,
                markedUnread: settings.markedUnread,
                updatedAt: Date()
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
            if thread.count > maxMessagesPerPeerInMemory {
                thread.removeFirst(thread.count - maxMessagesPerPeerInMemory)
            }
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

    private func sendLatestReadReceipt(to peerID: String) {
        guard let storageEngine else { return }
        guard let messageID = try? storageEngine.latestReadIncomingMessageID(peerID: peerID) else { return }
        let receipt = TransportMessage(
            kind: .readReceipt,
            senderPeerID: myPeerIDValue,
            senderNickname: nickname,
            receiverPeerID: peerID,
            readForMessageID: messageID
        )
        Task { @MainActor [weak self] in
            await self?.sendControlMessageWithRetry(receipt, targetPeerID: peerID, attempts: 3, tag: "read receipt")
        }
    }

    private func parseWANEndpoints(from raw: String) -> [String] {
        raw
            .split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func runStartupSmokeCheck(storage: StorageEngine, transport: HybridTransport) {
        if myPeerIDValue.isEmpty || !myPeerURI.hasPrefix("peer://") {
            appendDebug("startup", "invalid local identity")
        }
        do {
            _ = try storage.fetchChatPeers()
        } catch {
            reportError(domain: "storage", userPrefix: "Smoke-check БД", error: error, surfaceToUser: false)
        }
        let updateURL = UpdateChecker.shared.manifestURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !updateURL.isEmpty, URL(string: updateURL) == nil {
            appendDebug("startup", "invalid update manifest URL")
        }
        _ = transport.connectedPeerIDs()
        appendDebug("startup", "smoke-check passed")
    }

    private func sendTransportMessage(
        _ message: TransportMessage,
        targetPeerID: String,
        relayExcluding: Set<String>
    ) throws {
        guard let transport else { throw TransportError.peerNotConnected }
        let target = PeerID(targetPeerID)
        if transport.isPeerConnected(target) {
            try transport.send(message: message, to: target)
            return
        }
        do {
            try transport.send(message: message, to: target)
        } catch {
            try transport.sendToConnectedPeers(
                message: message,
                excludingPeerIDs: relayExcluding.union(message.relayPath)
            )
        }
    }

    private func sendTransportMessageWithRetry(
        _ message: TransportMessage,
        targetPeerID: String,
        relayExcluding: Set<String>,
        maxAttempts: Int
    ) async throws {
        let attempts = max(1, maxAttempts)
        var lastError: Error?
        for attempt in 1...attempts {
            do {
                try sendTransportMessage(message, targetPeerID: targetPeerID, relayExcluding: relayExcluding)
                return
            } catch {
                lastError = error
                guard attempt < attempts else { break }
                let delaySeconds = min(6.0, max(0.25, backoffSeconds(forAttempt: attempt) / 4.0))
                try await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            }
        }
        throw lastError ?? TransportError.peerNotConnected
    }

    private func sendControlMessageWithRetry(
        _ message: TransportMessage,
        targetPeerID: String,
        attempts: Int,
        tag: String
    ) async {
        do {
            try await sendTransportMessageWithRetry(
                message,
                targetPeerID: targetPeerID,
                relayExcluding: Set([myPeerIDValue]),
                maxAttempts: attempts
            )
        } catch is CancellationError {
            return
        } catch {
            reportError(domain: "network", userPrefix: "Не отправлен \(tag)", error: error, surfaceToUser: false)
        }
    }

    private func reportError(
        domain: String,
        userPrefix: String,
        error: Error,
        surfaceToUser: Bool
    ) {
        appendDebug("error", "[\(domain)] \(userPrefix): \(error.localizedDescription)")
        if surfaceToUser {
            errorMessage = "\(userPrefix): \(error.localizedDescription)"
        }
    }

    private func resetCallControls() {
        callMicrophoneMuted = false
        callSpeakerEnabled = true
        callEngine.setMicrophoneMuted(false)
        _ = callEngine.setSpeakerEnabled(true)
    }

    private func parseWebPairPayload(from raw: String) -> WebPairingPayload? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let url = URL(string: trimmed), url.scheme?.lowercased() == "meshweb" {
            guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
            let sessionID = components.queryItems?.first(where: { $0.name == "sid" || $0.name == "session" })?.value
            guard let sessionID, !sessionID.isEmpty else { return nil }
            guard let wsEncoded = components.queryItems?.first(where: { $0.name == "ws" })?.value else { return nil }
            let wsString = wsEncoded.removingPercentEncoding ?? wsEncoded
            guard let wsURL = URL(string: wsString),
                  let scheme = wsURL.scheme?.lowercased(),
                  scheme == "ws" || scheme == "wss" else { return nil }
            return WebPairingPayload(sessionID: sessionID, webSocketURL: wsURL)
        }

        if let url = URL(string: trimmed),
           let scheme = url.scheme?.lowercased(),
           (scheme == "ws" || scheme == "wss") {
            let parts = url.pathComponents.filter { $0 != "/" }
            let sessionID = parts.last ?? UUID().uuidString
            return WebPairingPayload(sessionID: sessionID, webSocketURL: url)
        }

        if let url = URL(string: trimmed),
           let scheme = url.scheme?.lowercased(),
           (scheme == "http" || scheme == "https") {
            let parts = url.pathComponents.filter { $0 != "/" }
            guard let sessionID = parts.last, !sessionID.isEmpty else { return nil }
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
            components.scheme = scheme == "https" ? "wss" : "ws"
            components.path = "/ws/mobile/\(sessionID)"
            components.query = nil
            guard let wsURL = components.url else { return nil }
            return WebPairingPayload(sessionID: sessionID, webSocketURL: wsURL)
        }

        return nil
    }

    private func ensureWebBridgeClient() {
        if webBridgeClient != nil { return }
        let client = WebBridgeClient()
        client.onEvent = { [weak self] event in
            guard let self else { return }
            switch event {
            case .connecting(let sessionID):
                self.webSessionID = sessionID
                self.webSessionAuthorized = false
                self.webSessionStatusText = "Подключение…"
                self.appendDebug("web", "connecting \(sessionID.prefix(8))")
            case .authorized(let sessionID, let nickname):
                self.webSessionID = sessionID
                self.webSessionAuthorized = true
                if let nickname, !nickname.isEmpty {
                    self.webSessionStatusText = "Авторизовано: \(nickname)"
                } else {
                    self.webSessionStatusText = "Авторизовано"
                }
                self.appendDebug("web", "authorized \(sessionID.prefix(8))")
            case .status(let message):
                self.webSessionStatusText = message
                self.appendDebug("web", message)
            case .disconnected(let reason):
                self.webSessionAuthorized = false
                self.webSessionStatusText = "Отключено: \(reason)"
                self.appendDebug("web", "disconnected: \(reason)")
            case .failed(let message):
                self.webSessionAuthorized = false
                self.webSessionStatusText = "Ошибка: \(message)"
                self.errorMessage = "Web-сессия: \(message)"
                self.appendDebug("error", "web bridge failed: \(message)")
            }
        }
        webBridgeClient = client
    }

    private func appendDebug(_ category: String, _ message: String) {
        debugEvents.insert(
            DebugEvent(timestamp: Date(), category: category, message: message),
            at: 0
        )
        if debugEvents.count > 400 {
            debugEvents.removeLast(debugEvents.count - 400)
        }
    }

    // MARK: - Notifications

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    private func notifyIncomingMessage(from nickname: String, text: String, peerID: String? = nil) {
        if let peerID, threadSettings(for: peerID).isMuted {
            return
        }
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
