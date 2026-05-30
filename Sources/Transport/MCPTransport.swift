import Foundation

#if canImport(MultipeerConnectivity)
import MultipeerConnectivity

public struct TransportMessage: Codable, Sendable {
    public let senderPeerID: String
    public let senderNickname: String
    public let text: String
    public let timestamp: Date
    public let id: UUID

    public init(senderPeerID: String, senderNickname: String, text: String) {
        self.senderPeerID = senderPeerID
        self.senderNickname = senderNickname
        self.text = text
        self.timestamp = Date()
        self.id = UUID()
    }
}

public final class MCPTransport: NSObject {
    public var onMessageReceived: ((TransportMessage, PeerID) -> Void)?
    public var onPeerConnected: ((PeerID, String) -> Void)?
    public var onPeerDisconnected: ((PeerID) -> Void)?

    private static let serviceType = "meshmsg16"

    private let localProfile: PeerProfile
    // MCPeerID.displayName must be ≤ 63 chars — use first 8 chars of PeerID as suffix
    private let mcLocalPeerID: MCPeerID
    // Map MCPeerID.displayName → full PeerID (discovered via discoveryInfo)
    private var peerIDMap: [String: PeerID] = [:]
    private var session: MCSession!
    private let advertiser: MCNearbyServiceAdvertiser
    private let browser: MCNearbyServiceBrowser

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(localProfile: PeerProfile) throws {
        self.localProfile = localProfile

        // MCPeerID displayName limit is 63 characters.
        // Use "nick#XXXXXXXX" (nickname up to 54 chars + "#" + 8-char hex suffix).
        let shortHex = String(localProfile.peerID.value.prefix(8))
        let nick = String(localProfile.nickname.prefix(54))
        let displayName = "\(nick)#\(shortHex)"

        mcLocalPeerID = MCPeerID(displayName: displayName)

        let announcement = PeerAnnouncement(profile: localProfile)
        let encodedAnnouncement = String(
            decoding: try JSONEncoder().encode(announcement),
            as: UTF8.self
        )
        // Also include full peerID explicitly so we can reconstruct without decoding JSON
        let discoveryInfo: [String: String] = [
            "profile": encodedAnnouncement,
            "pid": localProfile.peerID.value
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
            encryptionPreference: .required
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
        // Find MCPeerID by matching stored full PeerID
        let targets = session.connectedPeers.filter { mcPeer in
            peerIDMap[mcPeer.displayName]?.value == peerID.value
        }
        guard !targets.isEmpty else { throw TransportError.peerNotConnected }
        let data = try encoder.encode(message)
        try session.send(data, toPeers: targets, with: .reliable)
    }

    public func connectedPeerIDs() -> [String] {
        session.connectedPeers.compactMap { peerIDMap[$0.displayName]?.value }
    }
}

public enum TransportError: Error {
    case peerNotConnected
}

extension MCPTransport: MCSessionDelegate {
    public func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        let meshID = peerIDMap[peerID.displayName] ?? PeerID(peerID.displayName)
        switch state {
        case .connected:    onPeerConnected?(meshID, peerID.displayName)
        case .notConnected: onPeerDisconnected?(meshID)
        default: break
        }
    }

    public func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard let msg = try? decoder.decode(TransportMessage.self, from: data) else { return }
        let meshID = peerIDMap[peerID.displayName] ?? PeerID(peerID.displayName)
        onMessageReceived?(msg, meshID)
    }

    public func session(_ session: MCSession, didReceive stream: InputStream,
                        withName streamName: String, fromPeer peerID: MCPeerID) {}
    public func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String,
                        fromPeer peerID: MCPeerID, with progress: Progress) {}
    public func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String,
                        fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

extension MCPTransport: MCNearbyServiceBrowserDelegate {
    public func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID,
                        withDiscoveryInfo info: [String: String]?) {
        guard peerID.displayName != mcLocalPeerID.displayName else { return }

        // Extract full PeerID from discoveryInfo
        if let fullPeerIDValue = info?["pid"] {
            peerIDMap[peerID.displayName] = PeerID(fullPeerIDValue)
        }

        let alreadyConnected = session.connectedPeers.contains { $0.displayName == peerID.displayName }
        guard !alreadyConnected else { return }
        browser.invitePeer(peerID, to: session, withContext: nil, timeout: 10)
    }

    public func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {}
    public func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {}
}

extension MCPTransport: MCNearbyServiceAdvertiserDelegate {
    public func advertiser(_ advertiser: MCNearbyServiceAdvertiser,
                           didReceiveInvitationFromPeer peerID: MCPeerID,
                           withContext context: Data?,
                           invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        invitationHandler(true, session)
    }

    public func advertiser(_ advertiser: MCNearbyServiceAdvertiser,
                           didNotStartAdvertisingPeer error: Error) {}
}

#else

public struct TransportMessage: Codable, Sendable {
    public let senderPeerID: String
    public let senderNickname: String
    public let text: String
    public let timestamp: Date
    public let id: UUID

    public init(senderPeerID: String, senderNickname: String, text: String) {
        self.senderPeerID = senderPeerID
        self.senderNickname = senderNickname
        self.text = text
        self.timestamp = Date()
        self.id = UUID()
    }
}

public enum TransportError: Error { case peerNotConnected }

public final class MCPTransport {
    public var onMessageReceived: ((TransportMessage, PeerID) -> Void)?
    public var onPeerConnected: ((PeerID, String) -> Void)?
    public var onPeerDisconnected: ((PeerID) -> Void)?

    public init(localProfile: PeerProfile) throws {}
    public func start() {}
    public func stop() {}
    public func send(message: TransportMessage, to peerID: PeerID) throws {
        throw TransportError.peerNotConnected
    }
    public func connectedPeerIDs() -> [String] { [] }
}
#endif
