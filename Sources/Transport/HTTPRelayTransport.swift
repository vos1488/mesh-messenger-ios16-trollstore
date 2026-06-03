import Foundation

/// Lightweight HTTP store-and-forward relay transport.
/// Works through symmetric NAT, CGNAT, and 2G/EDGE because all communication
/// is outbound HTTP — no inbound connections required.
///
/// The server is a blind relay: it stores encrypted TransportMessage payloads
/// (base64-encoded JSON) and delivers them to recipients on the next poll.
public final class HTTPRelayTransport {
    public var onMessageReceived: ((TransportMessage, PeerID) -> Void)?

    private let localPeerID: String
    private let baseURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let queue = DispatchQueue(label: "mesh.http.relay", qos: .utility)

    private var pollTimer: DispatchSourceTimer?
    /// Last poll timestamp (unix seconds). Server returns messages after this time.
    private var lastPollTimestamp: Double = 0
    /// Deduplication: message IDs we've already delivered.
    private var seenMessageIDs = Set<String>()
    private var seenMessageOrder = [String]() // FIFO for bounded size

    private static let maxSeenIDs = 2000

    public init(localPeerID: String, baseURL: URL) {
        self.localPeerID = localPeerID
        self.baseURL = baseURL
    }

    public func start() {
        lastPollTimestamp = Date().timeIntervalSince1970 - 30 // fetch last 30s on startup
        schedulePoll()
    }

    public func stop() {
        pollTimer?.cancel()
        pollTimer = nil
    }

    /// Send a TransportMessage to a specific peer via HTTP relay.
    public func send(message: TransportMessage, to peerID: PeerID) throws {
        guard let payloadData = try? encoder.encode(message) else {
            throw TransportError.peerNotConnected
        }
        let payloadB64 = payloadData.base64EncodedString()
        let envelope = HTTPRelayEnvelope(
            messageID: message.id.uuidString,
            fromPeerID: localPeerID,
            toPeerID: peerID.value,
            payloadB64: payloadB64,
            createdAt: message.timestamp.timeIntervalSince1970
        )
        Task { [weak self] in
            await self?.performSend(envelope: envelope)
        }
    }

    // MARK: - Private

    private func schedulePoll() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        // Poll every 3 seconds — fast enough for chat UX, light on 2G/EDGE.
        timer.schedule(deadline: .now() + 3, repeating: .seconds(3))
        timer.setEventHandler { [weak self] in
            self?.pollInbox()
        }
        timer.resume()
        pollTimer = timer
    }

    private func pollInbox() {
        var comps = URLComponents(url: baseURL.appendingPathComponent("api/mesh/relay/inbox"),
                                   resolvingAgainstBaseURL: false)!
        let since = String(format: "%.6f", lastPollTimestamp)
        comps.queryItems = [
            URLQueryItem(name: "peer_id", value: localPeerID),
            URLQueryItem(name: "since", value: since)
        ]
        guard let url = comps.url else { return }

        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        req.cachePolicy = .reloadIgnoringLocalCacheData

        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let self, let data else { return }
            self.queue.async { self.handlePollResponse(data: data) }
        }.resume()
    }

    private func handlePollResponse(data: Data) {
        struct InboxResponse: Decodable {
            struct Envelope: Decodable {
                let message_id: String
                let payload_b64: String
                let created_at: Double
            }
            let messages: [Envelope]
        }
        guard let resp = try? JSONDecoder().decode(InboxResponse.self, from: data) else { return }
        var latestTS = lastPollTimestamp
        for envelope in resp.messages {
            if envelope.created_at > latestTS {
                latestTS = envelope.created_at
            }
            guard !seenMessageIDs.contains(envelope.message_id) else { continue }
            guard let payloadData = Data(base64Encoded: envelope.payload_b64),
                  let msg = try? decoder.decode(TransportMessage.self, from: payloadData),
                  msg.senderPeerID != localPeerID else { continue }

            markSeen(id: envelope.message_id)
            let sender = PeerID(msg.senderPeerID)
            DispatchQueue.main.async { [weak self] in
                self?.onMessageReceived?(msg, sender)
            }
        }
        // Advance timestamp so next poll only fetches new messages.
        if latestTS > lastPollTimestamp {
            lastPollTimestamp = latestTS
        }
    }

    @discardableResult
    private func performSend(envelope: HTTPRelayEnvelope) async -> Bool {
        let url = baseURL.appendingPathComponent("api/mesh/relay/send")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 8
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard let body = try? encoder.encode(envelope) else { return false }
        req.httpBody = body
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse {
                return (200...299).contains(http.statusCode)
            }
            return false
        } catch {
            return false
        }
    }

    private func markSeen(id: String) {
        seenMessageIDs.insert(id)
        seenMessageOrder.append(id)
        if seenMessageOrder.count > Self.maxSeenIDs {
            let drop = seenMessageOrder.removeFirst()
            seenMessageIDs.remove(drop)
        }
    }
}

private struct HTTPRelayEnvelope: Encodable {
    let messageID: String
    let fromPeerID: String
    let toPeerID: String
    let payloadB64: String
    let createdAt: Double

    enum CodingKeys: String, CodingKey {
        case messageID = "message_id"
        case fromPeerID = "from_peer_id"
        case toPeerID = "to_peer_id"
        case payloadB64 = "payload_b64"
        case createdAt = "created_at"
    }
}
