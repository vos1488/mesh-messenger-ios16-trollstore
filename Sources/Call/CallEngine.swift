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
    private var wireFormat: AVAudioFormat?
    private var playbackFormat: AVAudioFormat?
    private var captureConverter: AVAudioConverter?
    private var playbackConverter: AVAudioConverter?
    private var receiveAccumulator = Data()
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
        let inputFormat = inputNode.outputFormat(forBus: 0)
        let outputFormat = engine.mainMixerNode.outputFormat(forBus: 0)
        guard let callWireFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        ) else {
            return
        }
        wireFormat = callWireFormat
        playbackFormat = outputFormat
        captureConverter = AVAudioConverter(from: inputFormat, to: callWireFormat)
        playbackConverter = AVAudioConverter(from: callWireFormat, to: outputFormat)

        let player = AVAudioPlayerNode()
        playerNode = player
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: outputFormat)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self, weak outputStream] buf, _ in
            guard let self else { return }
            guard let outStream = outputStream, outStream.streamStatus == .open else { return }
            self.encodeAndSendCapturedAudio(buf, to: outStream)
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
        inputStream?.close()
        inputStream = stream
#if canImport(AVFoundation)
        receiveAccumulator.removeAll(keepingCapacity: true)
#endif
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
              let callWireFormat = wireFormat,
              let outFormat = playbackFormat,
              let converter = playbackConverter else { return }

        var buf = [UInt8](repeating: 0, count: 8192)
        let count = stream.read(&buf, maxLength: buf.count)
        guard count > 0 else { return }
        receiveAccumulator.append(contentsOf: buf.prefix(count))

        while receiveAccumulator.count >= 2 {
            let payloadSize = (Int(receiveAccumulator[0]) << 8) | Int(receiveAccumulator[1])
            guard payloadSize > 0 else {
                receiveAccumulator.removeFirst(min(2, receiveAccumulator.count))
                continue
            }
            let totalFrameSize = 2 + payloadSize
            guard receiveAccumulator.count >= totalFrameSize else { break }

            let payload = Data(receiveAccumulator[2..<totalFrameSize])
            receiveAccumulator.removeFirst(totalFrameSize)
            enqueuePlaybackPayload(payload, wireFormat: callWireFormat, outputFormat: outFormat, converter: converter, player: player)
        }
#endif
    }

#if canImport(AVFoundation)
    private func encodeAndSendCapturedAudio(_ inputBuffer: AVAudioPCMBuffer, to stream: OutputStream) {
        guard let converter = captureConverter, let callWireFormat = wireFormat else { return }

        let ratio = callWireFormat.sampleRate / max(1, inputBuffer.format.sampleRate)
        let outCapacity = AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio) + 64
        guard outCapacity > 0,
              let wireBuffer = AVAudioPCMBuffer(pcmFormat: callWireFormat, frameCapacity: outCapacity) else { return }

        var supplied = false
        let status = converter.convert(to: wireBuffer, error: nil) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return inputBuffer
        }

        guard status == .haveData || status == .inputRanDry else { return }
        let frameLength = Int(wireBuffer.frameLength)
        guard frameLength > 0,
              let int16 = wireBuffer.int16ChannelData?[0] else { return }

        let payloadBytes = frameLength * MemoryLayout<Int16>.size
        let safePayloadBytes = min(payloadBytes, Int(UInt16.max))
        var header = UInt16(safePayloadBytes).bigEndian
        var frameData = Data(bytes: &header, count: MemoryLayout<UInt16>.size)
        frameData.append(Data(bytes: int16, count: safePayloadBytes))
        writeFramedData(frameData, to: stream)
    }

    private func writeFramedData(_ data: Data, to stream: OutputStream) {
        audioQueue.async {
            data.withUnsafeBytes { rawPtr in
                guard let base = rawPtr.baseAddress else { return }
                var remaining = data.count
                var offset = 0
                while remaining > 0 {
                    guard stream.hasSpaceAvailable else { break }
                    let written = stream.write(base.advanced(by: offset).assumingMemoryBound(to: UInt8.self), maxLength: remaining)
                    guard written > 0 else { break }
                    offset += written
                    remaining -= written
                }
            }
        }
    }

    private func enqueuePlaybackPayload(
        _ payload: Data,
        wireFormat: AVAudioFormat,
        outputFormat: AVAudioFormat,
        converter: AVAudioConverter,
        player: AVAudioPlayerNode
    ) {
        let frameCount = payload.count / MemoryLayout<Int16>.size
        guard frameCount > 0,
              let wireBuffer = AVAudioPCMBuffer(pcmFormat: wireFormat, frameCapacity: AVAudioFrameCount(frameCount)),
              let wirePtr = wireBuffer.int16ChannelData?[0] else { return }
        wireBuffer.frameLength = AVAudioFrameCount(frameCount)
        payload.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                memcpy(wirePtr, base, payload.count)
            }
        }

        let ratio = outputFormat.sampleRate / max(1, wireFormat.sampleRate)
        let outCapacity = AVAudioFrameCount(Double(wireBuffer.frameLength) * ratio) + 64
        guard outCapacity > 0,
              let outBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outCapacity) else { return }

        var supplied = false
        let status = converter.convert(to: outBuffer, error: nil) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return wireBuffer
        }
        guard status == .haveData || status == .inputRanDry else { return }
        if outBuffer.frameLength > 0 {
            player.scheduleBuffer(outBuffer, completionHandler: nil)
        }
    }
#endif

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
        wireFormat = nil
        playbackFormat = nil
        captureConverter = nil
        playbackConverter = nil
        receiveAccumulator.removeAll(keepingCapacity: false)
#endif
        outputStream?.close()
        inputStream?.close()
        outputStream = nil
        inputStream = nil
        pendingInputStream = nil
    }
}

