import Foundation

#if canImport(AVFoundation)
import AVFoundation
#endif

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

/// Real voice call engine using MCSession streams + AVAudioEngine (PCM over MPC).
public final class MCStreamCallEngine: CallEngine {
    public private(set) var state: CallState = .idle

    /// Set by NodeStore before calling startCall
    public weak var weakTransport: MCPTransport?

#if canImport(AVFoundation)
    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var captureFormat: AVAudioFormat?
#endif
    private var outputStream: OutputStream?
    private var inputStream: InputStream?
    private var pendingInputStream: InputStream?
    private let audioQueue = DispatchQueue(label: "mesh.call.audio", qos: .userInteractive)
    private var streamReadTimer: Timer?

    public init() {}

    public func startCall(with peerID: PeerID, media: CallMediaType) async throws {
        state = .connecting

        // Open outgoing MCSession stream to remote peer
        var outStream: OutputStream?
        if let transport = weakTransport {
            outStream = try? transport.startAudioStream(to: peerID, name: "call-audio")
            if let s = outStream {
                outputStream = s
                s.schedule(in: .main, forMode: .default)
                s.open()
            }
        }

        // Set up AVAudioEngine on main thread
        await MainActor.run { [weak self] in
            self?.setupAudio(outputStream: outStream)
        }

        // If the remote side already opened a stream (race-free pending queue)
        if let pending = pendingInputStream {
            pendingInputStream = nil
            startReceiving(stream: pending)
        }

        state = .active
    }

    // Called from NodeStore when the remote peer opens an audio stream to us
    public func handleIncomingAudioStream(_ stream: InputStream, from peerID: PeerID) {
#if canImport(AVFoundation)
        if let engine = audioEngine, engine.isRunning {
            startReceiving(stream: stream)
        } else {
            pendingInputStream = stream
        }
#else
        pendingInputStream = stream
#endif
    }

    public func endCall() async {
        await MainActor.run { [weak self] in
            self?.teardownAudio()
        }
        state = .ended
    }

    // MARK: - Private

    @MainActor
    private func setupAudio(outputStream: OutputStream?) {
#if canImport(AVFoundation)
        let engine = AVAudioEngine()
        audioEngine = engine

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        captureFormat = format

        let player = AVAudioPlayerNode()
        playerNode = player
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self, weak outputStream] buf, _ in
            guard let outStream = outputStream, outStream.streamStatus == .open else { return }
            guard let channelData = buf.floatChannelData?[0] else { return }
            let byteCount = Int(buf.frameLength) * 4
            let data = Data(bytes: channelData, count: byteCount)
            self?.audioQueue.async {
                data.withUnsafeBytes { rawPtr in
                    guard let base = rawPtr.baseAddress else { return }
                    var remaining = data.count
                    var offset = 0
                    while remaining > 0 {
                        guard outStream.hasSpaceAvailable else { break }
                        let written = outStream.write(base.advanced(by: offset), maxLength: remaining)
                        guard written > 0 else { break }
                        offset += written
                        remaining -= written
                    }
                }
            }
        }

        do {
            try engine.start()
            player.play()
        } catch {
            // Audio start failed (e.g. mic permission denied) — call still works for signaling
        }
#endif
    }

    private func startReceiving(stream: InputStream) {
        inputStream = stream
        stream.schedule(in: .main, forMode: .default)
        stream.open()

        streamReadTimer?.invalidate()
        streamReadTimer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { [weak self] _ in
            self?.readAudioFromStream()
        }
    }

    private func readAudioFromStream() {
#if canImport(AVFoundation)
        guard let stream = inputStream, stream.hasBytesAvailable,
              let player = playerNode,
              let engine = audioEngine, engine.isRunning,
              let format = captureFormat else { return }

        var buf = [UInt8](repeating: 0, count: 8192)
        let count = stream.read(&buf, maxLength: buf.count)
        guard count > 0 else { return }

        let frameCount = count / 4  // Float32 = 4 bytes per frame
        guard frameCount > 0,
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)),
              let floatPtr = pcm.floatChannelData?[0] else { return }

        pcm.frameLength = AVAudioFrameCount(frameCount)
        buf.withUnsafeBytes { rawPtr in
            if let ptr = rawPtr.bindMemory(to: Float.self).baseAddress {
                floatPtr.assign(from: ptr, count: frameCount)
            }
        }
        player.scheduleBuffer(pcm, completionHandler: nil)
#endif
    }

    @MainActor
    private func teardownAudio() {
        streamReadTimer?.invalidate()
        streamReadTimer = nil
#if canImport(AVFoundation)
        audioEngine?.inputNode.removeTap(onBus: 0)
        playerNode?.stop()
        audioEngine?.stop()
        audioEngine = nil
        playerNode = nil
        captureFormat = nil
#endif
        outputStream?.close()
        inputStream?.close()
        outputStream = nil
        inputStream = nil
        pendingInputStream = nil
    }
}

