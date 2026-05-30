import Foundation

#if canImport(MultipeerConnectivity)
import MultipeerConnectivity

public enum TransportPacketKind: String, Codable, Sendable {
    case chat
    case ack
    case readReceipt
    case syncDigest
    case relay
    case fileMeta
    case fileChunk
    case callInvite
    case callAccept
    case callDecline
    case callEnd
}

public struct TransportMessage: Codable, Sendable {
    public let id: UUID
    public let kind: TransportPacketKind
    public let senderPeerID: String
    public let senderNickname: String
    public let receiverPeerID: String
    public let timestamp: Date
    public let ttl: Int
    public let relayPath: [String]

    public let text: String?
    public let ackForMessageID: UUID?
    public let readForMessageID: UUID?

    public let sessionID: String?
    public let ratchetCounter: Int?
    public let nonce: Data?
    public let ciphertext: Data?
    public let tag: Data?

    public let fileID: UUID?
    public let fileName: String?
    public let fileChunkIndex: Int?
    public let fileTotalChunks: Int?
    public let fileChunkData: Data?
    public let fileChecksum: Data?
    public let callID: UUID?
    public let callMediaType: String?

    public init(
        id: UUID = UUID(),
        kind: TransportPacketKind,
        senderPeerID: String,
        senderNickname: String,
        receiverPeerID: String,
        timestamp: Date = Date(),
        ttl: Int = 16,
        relayPath: [String] = [],
        text: String? = nil,
        ackForMessageID: UUID? = nil,
        readForMessageID: UUID? = nil,
        sessionID: String? = nil,
        ratchetCounter: Int? = nil,
        nonce: Data? = nil,
        ciphertext: Data? = nil,
        tag: Data? = nil,
        fileID: UUID? = nil,
        fileName: String? = nil,
        fileChunkIndex: Int? = nil,
        fileTotalChunks: Int? = nil,
        fileChunkData: Data? = nil,
        fileChecksum: Data? = nil,
        callID: UUID? = nil,
        callMediaType: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.senderPeerID = senderPeerID
        self.senderNickname = senderNickname
        self.receiverPeerID = receiverPeerID
        self.timestamp = timestamp
        self.ttl = ttl
        self.relayPath = relayPath
        self.text = text
        self.ackForMessageID = ackForMessageID
        self.readForMessageID = readForMessageID
        self.sessionID = sessionID
        self.ratchetCounter = ratchetCounter
        self.nonce = nonce
        self.ciphertext = ciphertext
        self.tag = tag
        self.fileID = fileID
        self.fileName = fileName
        self.fileChunkIndex = fileChunkIndex
        self.fileTotalChunks = fileTotalChunks
        self.fileChunkData = fileChunkData
        self.fileChecksum = fileChecksum
        self.callID = callID
        self.callMediaType = callMediaType
    }
}

public struct TransportDiscoveredPeer: Sendable {
    public let peerID: PeerID
    public let displayName: String
    public let signingPublicKey: Data?
    public let agreementPublicKey: Data?
}

public final class MCPTransport: NSObject {
    public var onMessageReceived: ((TransportMessage, PeerID) -> Void)?
    public var onPeerConnected: ((PeerID, String) -> Void)?
    public var onPeerDisconnected: ((PeerID) -> Void)?
    public var onPeerDiscovered: ((TransportDiscoveredPeer) -> Void)?
    /// Called when a remote peer opens an MCSession stream to us.
    public var onStreamReceived: ((InputStream, PeerID, String) -> Void)?

    private static let serviceType = "meshmsg16"

    private struct PeerCryptoInfo {
        var peerID: PeerID
        var signingPublicKey: Data?
        var agreementPublicKey: Data?
    }

    private let mcLocalPeerID: MCPeerID
    private var peerInfoMap: [String: PeerCryptoInfo] = [:] // displayName -> info
    private var session: MCSession!
    private let advertiser: MCNearbyServiceAdvertiser
    private let browser: MCNearbyServiceBrowser

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(
        localProfile: PeerProfile,
        signingPublicKey: Data,
        agreementPublicKey: Data
    ) throws {
        let shortHex = String(localProfile.peerID.value.prefix(8))
        let nick = String(localProfile.nickname.prefix(54))
        let displayName = "\(nick)#\(shortHex)"
        mcLocalPeerID = MCPeerID(displayName: displayName)

        let announcement = PeerAnnouncement(profile: localProfile)
        let encodedAnnouncement = String(decoding: try JSONEncoder().encode(announcement), as: UTF8.self)
        let discoveryInfo: [String: String] = [
            "profile": encodedAnnouncement,
            "pid": localProfile.peerID.value,
            "spk": signingPublicKey.base64EncodedString(),
            "apk": agreementPublicKey.base64EncodedString()
        ]

        advertiser = MCNearbyServiceAdvertiser(
            peer: mcLocalPeerID,
            discoveryInfo: discoveryInfo,
            serviceType: Self.serviceType
        )
        browser = MCNearbyServiceBrowser(peer: mcLocalPeerID, serviceType: Self.serviceType)
        super.init()

        session = MCSession(
            peer: mcLocalPeerID,
            securityIdentity: nil,
            encryptionPreference: .none
        )
        session.delegate = self
        advertiser.delegate = self
        browser.delegate = self
    }

    public func start() {
        advertiser.startAdvertisingPeer()
        browser.startBrowsingForPeers()
    }

    public func stop() {
        advertiser.stopAdvertisingPeer()
        browser.stopBrowsingForPeers()
        session.disconnect()
    }

    public func send(message: TransportMessage, to peerID: PeerID) throws {
        let targets = session.connectedPeers.filter { mcPeer in
            peerInfoMap[mcPeer.displayName]?.peerID.value == peerID.value
        }
        guard !targets.isEmpty else { throw TransportError.peerNotConnected }
        let data = try encoder.encode(message)
        try session.send(data, toPeers: targets, with: .reliable)
    }

    public func sendToConnectedPeers(message: TransportMessage, excludingPeerIDs: Set<String>) throws {
        let targets = session.connectedPeers.filter { peer in
            guard let full = peerInfoMap[peer.displayName]?.peerID.value else { return false }
            return !excludingPeerIDs.contains(full)
        }
        guard !targets.isEmpty else { throw TransportError.peerNotConnected }
        let data = try encoder.encode(message)
        try session.send(data, toPeers: targets, with: .reliable)
    }

    public func isPeerConnected(_ peerID: PeerID) -> Bool {
        session.connectedPeers.contains { peer in
            peerInfoMap[peer.displayName]?.peerID.value == peerID.value
        }
    }

    public func connectedPeerIDs() -> [String] {
        session.connectedPeers.compactMap { peerInfoMap[$0.displayName]?.peerID.value }
    }

    /// Opens an MCSession output stream to the given peer. The remote side receives it via `onStreamReceived`.
    public func startAudioStream(to peerID: PeerID, name: String) throws -> OutputStream {
        let targets = session.connectedPeers.filter { mcPeer in
            peerInfoMap[mcPeer.displayName]?.peerID.value == peerID.value
        }
        guard let target = targets.first else { throw TransportError.peerNotConnected }
        return try session.startStream(withName: name, toPeer: target)
    }

    public func peerKeys(peerID: PeerID) -> (signing: Data?, agreement: Data?) {
        guard let info = peerInfoMap.values.first(where: { $0.peerID.value == peerID.value }) else {
            return (nil, nil)
        }
        return (info.signingPublicKey, info.agreementPublicKey)
    }
}

public enum TransportError: Error {
    case peerNotConnected
}

extension MCPTransport: MCSessionDelegate {
    public func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        let meshID = peerInfoMap[peerID.displayName]?.peerID ?? PeerID(peerID.displayName)
        switch state {
        case .connected:
            onPeerConnected?(meshID, peerID.displayName)
        case .notConnected:
            onPeerDisconnected?(meshID)
        default:
            break
        }
    }

    public func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard let msg = try? decoder.decode(TransportMessage.self, from: data) else { return }
        let meshID = peerInfoMap[peerID.displayName]?.peerID ?? PeerID(peerID.displayName)
        onMessageReceived?(msg, meshID)
    }

    public func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {
        let meshID = peerInfoMap[peerID.displayName]?.peerID ?? PeerID(peerID.displayName)
        onStreamReceived?(stream, meshID, streamName)
    }
    public func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    public func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

extension MCPTransport: MCNearbyServiceBrowserDelegate {
    public func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        guard peerID.displayName != mcLocalPeerID.displayName else { return }

        let fullPeerID = PeerID(info?["pid"] ?? peerID.displayName)
        let signing = info?["spk"].flatMap { Data(base64Encoded: $0) }
        let agreement = info?["apk"].flatMap { Data(base64Encoded: $0) }
        peerInfoMap[peerID.displayName] = PeerCryptoInfo(
            peerID: fullPeerID,
            signingPublicKey: signing,
            agreementPublicKey: agreement
        )
        onPeerDiscovered?(
            TransportDiscoveredPeer(
                peerID: fullPeerID,
                displayName: peerID.displayName,
                signingPublicKey: signing,
                agreementPublicKey: agreement
            )
        )

        let alreadyConnected = session.connectedPeers.contains { $0.displayName == peerID.displayName }
        guard !alreadyConnected else { return }
        browser.invitePeer(peerID, to: session, withContext: nil, timeout: 10)
    }

    public func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {}
    public func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {}
}

extension MCPTransport: MCNearbyServiceAdvertiserDelegate {
    public func advertiser(
        _ advertiser: MCNearbyServiceAdvertiser,
        didReceiveInvitationFromPeer peerID: MCPeerID,
        withContext context: Data?,
        invitationHandler: @escaping (Bool, MCSession?) -> Void
    ) {
        invitationHandler(true, session)
    }

    public func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {}
}

#else

public enum TransportPacketKind: String, Codable, Sendable {
    case chat
    case ack
    case readReceipt
    case syncDigest
    case relay
    case fileMeta
    case fileChunk
    case callInvite
    case callAccept
    case callDecline
    case callEnd
}

public struct TransportMessage: Codable, Sendable {
    public let id: UUID
    public let kind: TransportPacketKind
    public let senderPeerID: String
    public let senderNickname: String
    public let receiverPeerID: String
    public let timestamp: Date
    public let ttl: Int
    public let relayPath: [String]
    public let text: String?
    public let ackForMessageID: UUID?
    public let readForMessageID: UUID?
    public let sessionID: String?
    public let ratchetCounter: Int?
    public let nonce: Data?
    public let ciphertext: Data?
    public let tag: Data?
    public let fileID: UUID?
    public let fileName: String?
    public let fileChunkIndex: Int?
    public let fileTotalChunks: Int?
    public let fileChunkData: Data?
    public let fileChecksum: Data?
    public let callID: UUID?
    public let callMediaType: String?

    public init(
        id: UUID = UUID(),
        kind: TransportPacketKind,
        senderPeerID: String,
        senderNickname: String,
        receiverPeerID: String,
        timestamp: Date = Date(),
        ttl: Int = 16,
        relayPath: [String] = [],
        text: String? = nil,
        ackForMessageID: UUID? = nil,
        readForMessageID: UUID? = nil,
        sessionID: String? = nil,
        ratchetCounter: Int? = nil,
        nonce: Data? = nil,
        ciphertext: Data? = nil,
        tag: Data? = nil,
        fileID: UUID? = nil,
        fileName: String? = nil,
        fileChunkIndex: Int? = nil,
        fileTotalChunks: Int? = nil,
        fileChunkData: Data? = nil,
        fileChecksum: Data? = nil,
        callID: UUID? = nil,
        callMediaType: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.senderPeerID = senderPeerID
        self.senderNickname = senderNickname
        self.receiverPeerID = receiverPeerID
        self.timestamp = timestamp
        self.ttl = ttl
        self.relayPath = relayPath
        self.text = text
        self.ackForMessageID = ackForMessageID
        self.readForMessageID = readForMessageID
        self.sessionID = sessionID
        self.ratchetCounter = ratchetCounter
        self.nonce = nonce
        self.ciphertext = ciphertext
        self.tag = tag
        self.fileID = fileID
        self.fileName = fileName
        self.fileChunkIndex = fileChunkIndex
        self.fileTotalChunks = fileTotalChunks
        self.fileChunkData = fileChunkData
        self.fileChecksum = fileChecksum
        self.callID = callID
        self.callMediaType = callMediaType
    }
}

public struct TransportDiscoveredPeer: Sendable {
    public let peerID: PeerID
    public let displayName: String
    public let signingPublicKey: Data?
    public let agreementPublicKey: Data?
}

public enum TransportError: Error { case peerNotConnected }

public final class MCPTransport {
    public var onMessageReceived: ((TransportMessage, PeerID) -> Void)?
    public var onPeerConnected: ((PeerID, String) -> Void)?
    public var onPeerDisconnected: ((PeerID) -> Void)?
    public var onPeerDiscovered: ((TransportDiscoveredPeer) -> Void)?
    public var onStreamReceived: ((InputStream, PeerID, String) -> Void)?

    public init(localProfile: PeerProfile, signingPublicKey: Data, agreementPublicKey: Data) throws {
        _ = localProfile
        _ = signingPublicKey
        _ = agreementPublicKey
    }
    public func start() {}
    public func stop() {}
    public func send(message: TransportMessage, to peerID: PeerID) throws {
        _ = message
        _ = peerID
        throw TransportError.peerNotConnected
    }
    public func sendToConnectedPeers(message: TransportMessage, excludingPeerIDs: Set<String>) throws {
        _ = message
        _ = excludingPeerIDs
        throw TransportError.peerNotConnected
    }
    public func isPeerConnected(_ peerID: PeerID) -> Bool { _ = peerID; return false }
    public func connectedPeerIDs() -> [String] { [] }
    public func startAudioStream(to peerID: PeerID, name: String) throws -> OutputStream {
        _ = peerID
        _ = name
        throw TransportError.peerNotConnected
    }
    public func peerKeys(peerID: PeerID) -> (signing: Data?, agreement: Data?) { _ = peerID; return (nil, nil) }
}
#endif
