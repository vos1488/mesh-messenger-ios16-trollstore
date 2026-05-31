import Foundation

#if canImport(AVFoundation)
import AVFoundation
#endif

#if canImport(UIKit)
import UIKit
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

public enum CallEngineError: Error {
    case transportUnavailable
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
    private var inputTapInstalled = false
#endif
    private var outputStream: OutputStream?
    private var inputStream: InputStream?
    private var pendingInputStream: InputStream?
    private let audioQueue = DispatchQueue(label: "mesh.call.audio", qos: .userInteractive)
    private var streamReadTimer: Timer?
    private var outboundFrames: [Data] = []
    private var outboundFrameOffset: Int = 0
    private var microphoneMuted = false
    private var speakerEnabled = true
    private var activePeerID: PeerID?
    private var pendingInputPeerID: PeerID?
    private let maxFramePayloadBytes = 4096

    public init() {}

    public func setMicrophoneMuted(_ muted: Bool) {
        microphoneMuted = muted
    }

    @discardableResult
    public func setSpeakerEnabled(_ enabled: Bool) -> Bool {
        speakerEnabled = enabled
        #if canImport(AVFoundation) && canImport(UIKit)
        do {
            try AVAudioSession.sharedInstance().overrideOutputAudioPort(enabled ? .speaker : .none)
            return true
        } catch {
            speakerEnabled = !enabled
            return false
        }
        #else
        return false
        #endif
    }

    public func isMicrophoneMuted() -> Bool { microphoneMuted }
    public func isSpeakerEnabled() -> Bool { speakerEnabled }

    public func startCall(with peerID: PeerID, media: CallMediaType) async throws {
        state = .connecting
        await MainActor.run { [weak self] in
            self?.teardownAudio()
        }
        activePeerID = peerID

        // Open outgoing MCSession stream to remote peer
        guard let transport = weakTransport else { throw CallEngineError.transportUnavailable }
        let outStream = try transport.startAudioStream(to: peerID, name: "call-audio")
        outputStream = outStream
        outStream.schedule(in: .main, forMode: .common)
        outStream.open()

        // Set up AVAudioEngine on main thread
        await MainActor.run { [weak self] in
            self?.setupAudio(outputStream: outStream)
        }

        // If the remote side already opened a stream (race-free pending queue)
        if let pending = pendingInputStream {
            let pendingPeer = pendingInputPeerID
            pendingInputStream = nil
            pendingInputPeerID = nil
            if let pendingPeer, pendingPeer.value != peerID.value {
                pending.close()
            } else {
                startReceiving(stream: pending, from: pendingPeer ?? peerID)
            }
        }

        state = .active
    }

    // Called from NodeStore when the remote peer opens an audio stream to us
    public func handleIncomingAudioStream(_ stream: InputStream, from peerID: PeerID) {
        if let expected = activePeerID, expected.value != peerID.value {
            stream.close()
            return
        }
#if canImport(AVFoundation)
        if let engine = audioEngine, engine.isRunning {
            startReceiving(stream: stream, from: peerID)
        } else {
            pendingInputStream = stream
            pendingInputPeerID = peerID
        }
#else
        pendingInputStream = stream
        pendingInputPeerID = peerID
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
            interleaved: false
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

        inputNode.installTap(onBus: 0, bufferSize: 960, format: inputFormat) { [weak self, weak outputStream] buf, _ in
            guard let self else { return }
            guard let outStream = outputStream, outStream.streamStatus == .open else { return }
            self.encodeAndSendCapturedAudio(buf, to: outStream)
        }
        inputTapInstalled = true

        do {
            try engine.start()
            player.play()
        } catch {
            // Audio start failed (e.g. mic permission denied) — call still works for signaling
        }
#endif
    }

    private func startReceiving(stream: InputStream, from peerID: PeerID) {
        activePeerID = peerID
        inputStream?.close()
        inputStream = stream
#if canImport(AVFoundation)
        receiveAccumulator.removeAll(keepingCapacity: true)
#endif
        stream.schedule(in: .main, forMode: .common)
        stream.open()

        streamReadTimer?.invalidate()
        let timer = Timer(timeInterval: 0.02, repeats: true) { [weak self] _ in
            self?.readAudioFromStream()
        }
        streamReadTimer = timer
        RunLoop.main.add(timer, forMode: .common)
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
            guard payloadSize > 0, payloadSize <= maxFramePayloadBytes else {
                receiveAccumulator.removeFirst(1)
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
        guard !microphoneMuted else { return }
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
        guard frameLength > 0 else { return }
        let payloadBytes = frameLength * MemoryLayout<Int16>.size
        guard payloadBytes > 0, let payload = dataFromPCMBuffer(wireBuffer, byteCount: payloadBytes) else { return }

        let safePayloadBytes = min(payload.count, Int(UInt16.max))
        var header = UInt16(safePayloadBytes).bigEndian
        var frameData = Data(bytes: &header, count: MemoryLayout<UInt16>.size)
        frameData.append(payload.prefix(safePayloadBytes))
        queueFramedData(frameData, to: stream)
    }

    private func queueFramedData(_ data: Data, to stream: OutputStream) {
        audioQueue.async {
            self.outboundFrames.append(data)
            self.flushOutboundFrames(to: stream)
        }
    }

    private func flushOutboundFrames(to stream: OutputStream) {
        while !outboundFrames.isEmpty {
            guard stream.hasSpaceAvailable else { return }
            let frame = outboundFrames[0]
            let remaining = frame.count - outboundFrameOffset
            guard remaining > 0 else {
                outboundFrames.removeFirst()
                outboundFrameOffset = 0
                continue
            }
            let wrote: Int = frame.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return stream.write(
                    base.advanced(by: outboundFrameOffset).assumingMemoryBound(to: UInt8.self),
                    maxLength: remaining
                )
            }
            guard wrote > 0 else { return }
            outboundFrameOffset += wrote
            if outboundFrameOffset >= frame.count {
                outboundFrames.removeFirst()
                outboundFrameOffset = 0
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
              let wireBuffer = AVAudioPCMBuffer(pcmFormat: wireFormat, frameCapacity: AVAudioFrameCount(frameCount)) else { return }
        wireBuffer.frameLength = AVAudioFrameCount(frameCount)
        copyPayload(payload, to: wireBuffer)

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

    private func dataFromPCMBuffer(_ buffer: AVAudioPCMBuffer, byteCount: Int) -> Data? {
        if let ptr = buffer.int16ChannelData?[0] {
            return Data(bytes: ptr, count: byteCount)
        }
        let abl = buffer.audioBufferList.pointee.mBuffers
        guard let mData = abl.mData else { return nil }
        let available = Int(abl.mDataByteSize)
        guard available > 0 else { return nil }
        return Data(bytes: mData, count: min(byteCount, available))
    }

    private func copyPayload(_ payload: Data, to buffer: AVAudioPCMBuffer) {
        if let ptr = buffer.int16ChannelData?[0] {
            payload.withUnsafeBytes { raw in
                if let base = raw.baseAddress {
                    memcpy(ptr, base, payload.count)
                }
            }
            return
        }
        var abl = buffer.audioBufferList.pointee
        guard let mData = abl.mBuffers.mData else { return }
        payload.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                memcpy(mData, base, min(payload.count, Int(abl.mBuffers.mDataByteSize)))
            }
        }
    }
#endif

    @MainActor
    private func teardownAudio() {
        streamReadTimer?.invalidate()
        streamReadTimer = nil
#if canImport(AVFoundation)
        if inputTapInstalled {
            audioEngine?.inputNode.removeTap(onBus: 0)
            inputTapInstalled = false
        }
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
        audioQueue.sync {
            outboundFrames.removeAll(keepingCapacity: false)
            outboundFrameOffset = 0
        }
        outputStream?.close()
        inputStream?.close()
        outputStream = nil
        inputStream = nil
        pendingInputStream = nil
        pendingInputPeerID = nil
        activePeerID = nil
        microphoneMuted = false
        speakerEnabled = true
    }
}

