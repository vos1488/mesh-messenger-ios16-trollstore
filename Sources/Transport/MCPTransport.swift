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
    private let mcLocalPeerID: MCPeerID
    private var session: MCSession!
    private let advertiser: MCNearbyServiceAdvertiser
    private let browser: MCNearbyServiceBrowser

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(localProfile: PeerProfile) throws {
        self.localProfile = localProfile
        mcLocalPeerID = MCPeerID(displayName: localProfile.peerID.value)

        let announcement = PeerAnnouncement(profile: localProfile)
        let encodedAnnouncement = String(
            decoding: try JSONEncoder().encode(announcement),
            as: UTF8.self
        )
        let discoveryInfo = ["profile": encodedAnnouncement, "nick": localProfile.nickname]

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
        let targets = session.connectedPeers.filter { $0.displayName == peerID.value }
        guard !targets.isEmpty else { throw TransportError.peerNotConnected }
        let data = try encoder.encode(message)
        try session.send(data, toPeers: targets, with: .reliable)
    }

    public func connectedPeerIDs() -> [String] {
        session.connectedPeers.map { $0.displayName }
    }
}

public enum TransportError: Error {
    case peerNotConnected
}

extension MCPTransport: MCSessionDelegate {
    public func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        let meshID = PeerID(peerID.displayName)
        switch state {
        case .connected:    onPeerConnected?(meshID, peerID.displayName)
        case .notConnected: onPeerDisconnected?(meshID)
        default: break
        }
    }

    public func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard let msg = try? decoder.decode(TransportMessage.self, from: data) else { return }
        onMessageReceived?(msg, PeerID(peerID.displayName))
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
