import Foundation

#if canImport(MultipeerConnectivity)
import MultipeerConnectivity
#endif

public protocol DiscoveryEngine: AnyObject {
    var onPeerFound: ((PeerProfile) -> Void)? { get set }
    var onPeerLost: ((PeerID) -> Void)? { get set }
    var onDiscoveryError: ((Error) -> Void)? { get set }

    func start()
    func stop()
}

#if canImport(MultipeerConnectivity)
public final class MCPDiscoveryEngine: NSObject, DiscoveryEngine {
    public var onPeerFound: ((PeerProfile) -> Void)?
    public var onPeerLost: ((PeerID) -> Void)?
    public var onDiscoveryError: ((Error) -> Void)?

    private static let serviceType = "meshmsg16"
    private let localProfile: PeerProfile
    private let localPeerID: MCPeerID
    private let advertiser: MCNearbyServiceAdvertiser
    private let browser: MCNearbyServiceBrowser

    public init(localProfile: PeerProfile) throws {
        self.localProfile = localProfile
        localPeerID = MCPeerID(displayName: localProfile.peerID.value)

        let announcement = PeerAnnouncement(profile: localProfile)
        let encodedAnnouncement = String(decoding: try JSONEncoder().encode(announcement), as: UTF8.self)
        let discoveryInfo = [
            "profile": encodedAnnouncement
        ]
        advertiser = MCNearbyServiceAdvertiser(peer: localPeerID, discoveryInfo: discoveryInfo, serviceType: Self.serviceType)
        browser = MCNearbyServiceBrowser(peer: localPeerID, serviceType: Self.serviceType)
        super.init()
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
    }
}

extension MCPDiscoveryEngine: MCNearbyServiceBrowserDelegate {
    public func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {}

    public func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        guard let json = info?["profile"]?.data(using: .utf8) else {
            onDiscoveryError?(NSError(domain: "MCPDiscoveryEngine", code: 1001, userInfo: [NSLocalizedDescriptionKey: "Missing profile payload"]))
            return
        }

        let announcement: PeerAnnouncement
        do {
            announcement = try JSONDecoder().decode(PeerAnnouncement.self, from: json)
        } catch {
            onDiscoveryError?(error)
            return
        }

        let capabilities = Set(announcement.capabilities.compactMap(NodeCapability.init(rawValue:)))
        let profile = PeerProfile(
            peerID: PeerID(announcement.peerID),
            nickname: announcement.nickname,
            capabilities: capabilities
        )
        onPeerFound?(profile)
    }

    public func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        onPeerLost?(PeerID(peerID.displayName))
    }
}

extension MCPDiscoveryEngine: MCNearbyServiceAdvertiserDelegate {
    public func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {}

    public func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        invitationHandler(false, nil)
    }
}
#else
public final class MCPDiscoveryEngine: DiscoveryEngine {
    public var onPeerFound: ((PeerProfile) -> Void)?
    public var onPeerLost: ((PeerID) -> Void)?
    public var onDiscoveryError: ((Error) -> Void)?

    public init(localProfile: PeerProfile) throws {
        _ = localProfile
    }

    public func start() {}
    public func stop() {}
}
#endif

