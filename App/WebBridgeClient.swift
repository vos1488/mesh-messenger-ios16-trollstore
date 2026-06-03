import Foundation

public struct WebPairingPayload: Equatable {
    public let sessionID: String
    public let webSocketURL: URL
}

public enum WebBridgeEvent: Equatable {
    case connecting(String)
    case authorized(String, nickname: String?)
    case status(String)
    case disconnected(String)
    case failed(String)
}

@MainActor
public final class WebBridgeClient {
    public var onEvent: ((WebBridgeEvent) -> Void)?

    private var session: URLSession?
    private var socketTask: URLSessionWebSocketTask?
    private var heartbeatTimer: Timer?
    private var currentPayload: WebPairingPayload?
    private var isManualDisconnect = false
    private var authRetryTask: Task<Void, Never>?
    private var peerID: String = ""
    private var nickname: String = ""
    private var signingPublicKeyB64: String = ""
    private var agreementPublicKeyB64: String = ""
    private var keyFingerprint: String = ""
    private var authChallenge: String = ""
    private var authSignature: String = ""

    public init() {}

    public func connect(
        payload: WebPairingPayload,
        peerID: String,
        nickname: String,
        signingPublicKeyB64: String,
        agreementPublicKeyB64: String,
        keyFingerprint: String,
        authChallenge: String,
        authSignature: String
    ) {
        disconnect(reason: "replaced", shouldEmit: false)
        isManualDisconnect = false
        currentPayload = payload
        self.peerID = peerID
        self.nickname = nickname
        self.signingPublicKeyB64 = signingPublicKeyB64
        self.agreementPublicKeyB64 = agreementPublicKeyB64
        self.keyFingerprint = keyFingerprint
        self.authChallenge = authChallenge
        self.authSignature = authSignature
        onEvent?(.connecting(payload.sessionID))

        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 60 * 60
        let session = URLSession(configuration: cfg)
        self.session = session

        let task = session.webSocketTask(with: payload.webSocketURL)
        socketTask = task
        task.resume()
        sendAuthWithRetries()
        startHeartbeat()
        receiveNext()
    }

    public func disconnect(reason: String = "manual", shouldEmit: Bool = true) {
        isManualDisconnect = true
        authRetryTask?.cancel()
        authRetryTask = nil
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        socketTask?.cancel(with: .goingAway, reason: nil)
        socketTask = nil
        session?.invalidateAndCancel()
        session = nil
        currentPayload = nil
        if shouldEmit {
            onEvent?(.disconnected(reason))
        }
    }

    private func sendAuthWithRetries() {
        authRetryTask?.cancel()
        authRetryTask = Task { [weak self] in
            guard let self else { return }
            for n in 0..<4 {
                if Task.isCancelled { return }
                if n > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(600_000_000 * n))
                }
                self.send(message: [
                    "type": "auth",
                    "session_id": self.currentPayload?.sessionID ?? "",
                    "peer_id": self.peerID,
                    "nickname": self.nickname,
                    "platform": "ios",
                    "signing_pub_key": self.signingPublicKeyB64,
                    "agreement_pub_key": self.agreementPublicKeyB64,
                    "key_fingerprint": self.keyFingerprint,
                    "auth_challenge": self.authChallenge,
                    "auth_signature": self.authSignature
                ])
            }
        }
    }

    private func startHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.send(message: [
                "type": "heartbeat",
                "session_id": self.currentPayload?.sessionID ?? "",
                "ts": Int(Date().timeIntervalSince1970)
            ])
            self.socketTask?.sendPing { [weak self] error in
                guard let self, let error else { return }
                Task { @MainActor in
                    self.onEvent?(.failed("Ping error: \(error.localizedDescription)"))
                }
            }
        }
    }

    private func send(message: [String: Any]) {
        guard let socketTask else { return }
        guard JSONSerialization.isValidJSONObject(message),
              let data = try? JSONSerialization.data(withJSONObject: message),
              let text = String(data: data, encoding: .utf8) else { return }
        socketTask.send(.string(text)) { [weak self] error in
            guard let self, let error else { return }
            Task { @MainActor in
                self.onEvent?(.failed(error.localizedDescription))
            }
        }
    }

    private func receiveNext() {
        guard let socketTask else { return }
        socketTask.receive { [weak self] result in
            guard let self else { return }
            Task { @MainActor in
                switch result {
                case .success(let message):
                    self.handleIncoming(message)
                    self.receiveNext()
                case .failure(let error):
                    if self.isManualDisconnect {
                        return
                    }
                    self.onEvent?(.disconnected(error.localizedDescription))
                }
            }
        }
    }

    private func handleIncoming(_ message: URLSessionWebSocketTask.Message) {
        let text: String?
        switch message {
        case .string(let value):
            text = value
        case .data(let data):
            text = String(data: data, encoding: .utf8)
        @unknown default:
            text = nil
        }
        guard let text, let data = text.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        let type = (raw["type"] as? String)?.lowercased()
        switch type {
        case "authorized":
            let sid = (raw["session_id"] as? String) ?? (currentPayload?.sessionID ?? "")
            let nick = raw["web_nickname"] as? String
            onEvent?(.authorized(sid, nickname: nick))
        case "status":
            if let status = raw["status"] as? String {
                onEvent?(.status(status))
            }
        case "error":
            if let err = raw["message"] as? String {
                onEvent?(.failed(err))
            }
        default:
            break
        }
    }
}

