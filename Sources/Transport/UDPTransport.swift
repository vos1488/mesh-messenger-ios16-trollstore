import Foundation

#if canImport(Network)
import Network

public final class UDPTransport {
    public var onMessageReceived: ((TransportMessage, PeerID) -> Void)?
    public var onPeerConnected: ((PeerID) -> Void)?
    public var onPeerDisconnected: ((PeerID) -> Void)?

    private let localPeerID: String
    private let listenPort: NWEndpoint.Port
    private let queue = DispatchQueue(label: "mesh.udp.transport", qos: .userInitiated)
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private var listener: NWListener?
    private var cleanupTimer: DispatchSourceTimer?
    private var bootstrapEndpoints: Set<String> = []
    private var peerEndpoints: [String: String] = [:] // peerID -> "host:port"
    private var peerLastSeen: [String: Date] = [:]

    public init(localPeerID: String, listenPort: UInt16 = 58901, bootstrapEndpoints: [String] = []) {
        self.localPeerID = localPeerID
        self.listenPort = NWEndpoint.Port(rawValue: listenPort) ?? NWEndpoint.Port(rawValue: 58901)!
        self.bootstrapEndpoints = Set(bootstrapEndpoints.compactMap(Self.normalizeEndpointString(_:)))
    }

    public func updateBootstrapEndpoints(_ endpoints: [String]) {
        queue.async { [weak self] in
            self?.bootstrapEndpoints = Set(endpoints.compactMap(Self.normalizeEndpointString(_:)))
        }
    }

    public func start() throws {
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true

        let listener = try NWListener(using: params, on: listenPort)
        listener.newConnectionHandler = { [weak self] conn in
            self?.startReceiving(on: conn)
        }
        listener.stateUpdateHandler = { _ in }
        listener.start(queue: queue)
        self.listener = listener

        scheduleCleanupTimer()
        sendBootstrapHeartbeat()
    }

    public func stop() {
        queue.async { [weak self] in
            self?.cleanupTimer?.cancel()
            self?.cleanupTimer = nil
            self?.listener?.cancel()
            self?.listener = nil
            self?.peerEndpoints.removeAll()
            self?.peerLastSeen.removeAll()
        }
    }

    public func isPeerConnected(_ peerID: PeerID) -> Bool {
        queue.sync {
            guard let seen = peerLastSeen[peerID.value] else { return false }
            return Date().timeIntervalSince(seen) < 60
        }
    }

    public func connectedPeerIDs() -> [String] {
        queue.sync {
            let now = Date()
            return peerLastSeen.compactMap { key, value in
                now.timeIntervalSince(value) < 60 ? key : nil
            }
        }
    }

    public func send(message: TransportMessage, to peerID: PeerID) throws {
        let data = try encoder.encode(message)
        let endpoint = queue.sync { peerEndpoints[peerID.value] }

        if let endpoint {
            send(data: data, toEndpointString: endpoint)
            return
        }

        // If we don't know the peer endpoint yet, forward to bootstrap peers (relay mode).
        let endpoints = queue.sync { Array(bootstrapEndpoints) }
        guard !endpoints.isEmpty else { throw TransportError.peerNotConnected }
        for relay in endpoints {
            send(data: data, toEndpointString: relay)
        }
    }

    public func sendToKnownPeers(message: TransportMessage, excludingPeerIDs: Set<String>) throws {
        let data = try encoder.encode(message)
        let targets = queue.sync {
            peerEndpoints.filter { !excludingPeerIDs.contains($0.key) }.map(\.value)
        }
        var sent = false
        for endpoint in targets {
            send(data: data, toEndpointString: endpoint)
            sent = true
        }
        if !sent { throw TransportError.peerNotConnected }
    }

    public func sendHeartbeat(senderNickname: String) {
        let msg = TransportMessage(
            kind: .syncDigest,
            senderPeerID: localPeerID,
            senderNickname: senderNickname,
            receiverPeerID: "*"
        )
        guard let data = try? encoder.encode(msg) else { return }
        for endpoint in queue.sync(execute: { Array(bootstrapEndpoints) }) {
            send(data: data, toEndpointString: endpoint)
        }
    }

    private func startReceiving(on connection: NWConnection) {
        connection.start(queue: queue)
        receiveNext(on: connection)
    }

    private func receiveNext(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data,
               let msg = try? self.decoder.decode(TransportMessage.self, from: data),
               msg.senderPeerID != self.localPeerID {
                let endpoint = Self.endpointString(connection.endpoint)
                self.register(senderPeerID: msg.senderPeerID, endpoint: endpoint)
                self.onMessageReceived?(msg, PeerID(msg.senderPeerID))
            }
            if error == nil {
                self.receiveNext(on: connection)
            } else {
                connection.cancel()
            }
        }
    }

    private func register(senderPeerID: String, endpoint: String?) {
        guard let endpoint else { return }
        let wasKnown = peerEndpoints[senderPeerID] != nil
        peerEndpoints[senderPeerID] = endpoint
        peerLastSeen[senderPeerID] = Date()
        if !wasKnown {
            onPeerConnected?(PeerID(senderPeerID))
        }
    }

    private func scheduleCleanupTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 20, repeating: .seconds(20))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let now = Date()
            let stale = self.peerLastSeen.filter { now.timeIntervalSince($0.value) > 90 }.map(\.key)
            for peerID in stale {
                self.peerLastSeen.removeValue(forKey: peerID)
                self.peerEndpoints.removeValue(forKey: peerID)
                self.onPeerDisconnected?(PeerID(peerID))
            }
        }
        timer.resume()
        cleanupTimer = timer
    }

    private func sendBootstrapHeartbeat() {
        let boot = queue.sync { Array(bootstrapEndpoints) }
        guard !boot.isEmpty else { return }
        let msg = TransportMessage(
            kind: .syncDigest,
            senderPeerID: localPeerID,
            senderNickname: "wan",
            receiverPeerID: "*"
        )
        guard let data = try? encoder.encode(msg) else { return }
        for endpoint in boot {
            send(data: data, toEndpointString: endpoint)
        }
    }

    private func send(data: Data, toEndpointString endpointString: String) {
        guard let parsed = Self.parseEndpoint(endpointString) else { return }
        // Try to send from the same local UDP listen port to keep NAT mapping stable across networks.
        sendUsingConnection(data: data, host: parsed.host, port: parsed.port, bindToListenPort: true)
        // Fallback path in case local-port binding is unavailable on the current network stack.
        sendUsingConnection(data: data, host: parsed.host, port: parsed.port, bindToListenPort: false)
    }

    private func sendUsingConnection(
        data: Data,
        host: NWEndpoint.Host,
        port: NWEndpoint.Port,
        bindToListenPort: Bool
    ) {
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true
        if bindToListenPort {
            params.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host("0.0.0.0"), port: listenPort)
        }
        let conn = NWConnection(host: host, port: port, using: params)
        conn.start(queue: queue)
        conn.send(content: data, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }

    private static func normalizeEndpointString(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return parseEndpoint(value).map { "\($0.host):\($0.port.rawValue)" }
    }

    private static func parseEndpoint(_ value: String) -> (host: NWEndpoint.Host, port: NWEndpoint.Port)? {
        let parts = value.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              let portValue = UInt16(parts[1]),
              let port = NWEndpoint.Port(rawValue: portValue) else { return nil }
        return (host: NWEndpoint.Host(parts[0]), port: port)
    }

    private static func endpointString(_ endpoint: NWEndpoint) -> String? {
        guard case let .hostPort(host, port) = endpoint else { return nil }
        return "\(host):\(port.rawValue)"
    }
}

#else

public final class UDPTransport {
    public var onMessageReceived: ((TransportMessage, PeerID) -> Void)?
    public var onPeerConnected: ((PeerID) -> Void)?
    public var onPeerDisconnected: ((PeerID) -> Void)?

    public init(localPeerID: String, listenPort: UInt16 = 58901, bootstrapEndpoints: [String] = []) {
        _ = localPeerID
        _ = listenPort
        _ = bootstrapEndpoints
    }
    public func updateBootstrapEndpoints(_ endpoints: [String]) { _ = endpoints }
    public func start() throws {}
    public func stop() {}
    public func isPeerConnected(_ peerID: PeerID) -> Bool { _ = peerID; return false }
    public func connectedPeerIDs() -> [String] { [] }
    public func send(message: TransportMessage, to peerID: PeerID) throws { _ = message; _ = peerID; throw TransportError.peerNotConnected }
    public func sendToKnownPeers(message: TransportMessage, excludingPeerIDs: Set<String>) throws { _ = message; _ = excludingPeerIDs; throw TransportError.peerNotConnected }
    public func sendHeartbeat(senderNickname: String) { _ = senderNickname }
}

#endif
