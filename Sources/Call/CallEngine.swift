import Foundation

public enum CallMediaType: String, Sendable {
    case voice
    case video
}

public enum CallState: String, Sendable {
    case idle
    case connecting
    case active
    case ended
}

public protocol CallEngine {
    var state: CallState { get }
    func startCall(with peerID: PeerID, media: CallMediaType) async throws
    func endCall() async
}

public final class WebRTCCallEngine: CallEngine {
    public private(set) var state: CallState = .idle

    public init() {}

    public func startCall(with peerID: PeerID, media: CallMediaType) async throws {
        _ = peerID
        _ = media
        state = .connecting
        state = .active
    }

    public func endCall() async {
        state = .ended
    }
}

