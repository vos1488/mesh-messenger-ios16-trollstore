import Foundation

#if canImport(AVFoundation) && canImport(UIKit)
import AVFoundation
import UIKit

@MainActor
final class BackgroundRuntimeManager {
    private var keepAlivePlayer: AVAudioPlayer?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private(set) var keepAliveEnabled = false

    func activateKeepAlive() {
        guard !keepAliveEnabled else { return }
        keepAliveEnabled = true
        beginBackgroundTaskIfNeeded()

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)

            let audio = try AVAudioPlayer(data: makeSilenceWavData())
            audio.numberOfLoops = -1
            audio.volume = 0.001
            audio.play()
            keepAlivePlayer = audio
        } catch {
            keepAliveEnabled = false
            endBackgroundTaskIfNeeded()
        }
    }

    func deactivateKeepAlive() {
        keepAliveEnabled = false
        keepAlivePlayer?.stop()
        keepAlivePlayer = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        endBackgroundTaskIfNeeded()
    }

    func activateCallAudio() {
        beginBackgroundTaskIfNeeded()
        keepAlivePlayer?.stop()
        keepAlivePlayer = nil
        do {
            let session = AVAudioSession.sharedInstance()
            session.requestRecordPermission { _ in }
            try session.setCategory(
                .playAndRecord,
                mode: .voiceChat,
                options: [.allowBluetooth, .defaultToSpeaker]
            )
            try session.setPreferredSampleRate(48_000)
            try session.setPreferredIOBufferDuration(0.02)
            try session.setActive(true)
        } catch {}
    }

    func deactivateCallAudio() {
        if keepAliveEnabled {
            activateKeepAlive()
            return
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        endBackgroundTaskIfNeeded()
    }

    private func beginBackgroundTaskIfNeeded() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "mesh-keepalive") { [weak self] in
            self?.endBackgroundTaskIfNeeded()
        }
    }

    private func endBackgroundTaskIfNeeded() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    private func makeSilenceWavData(duration: TimeInterval = 1.0, sampleRate: Int = 8000) -> Data {
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let bytesPerFrame = Int(channels) * Int(bitsPerSample / 8)
        let sampleCount = max(1, Int(Double(sampleRate) * duration))
        let dataSize = sampleCount * bytesPerFrame

        var data = Data()
        data.appendASCII("RIFF")
        data.appendLE(UInt32(36 + dataSize))
        data.appendASCII("WAVE")
        data.appendASCII("fmt ")
        data.appendLE(UInt32(16))
        data.appendLE(UInt16(1))
        data.appendLE(channels)
        data.appendLE(UInt32(sampleRate))
        data.appendLE(UInt32(sampleRate * bytesPerFrame))
        data.appendLE(UInt16(bytesPerFrame))
        data.appendLE(bitsPerSample)
        data.appendASCII("data")
        data.appendLE(UInt32(dataSize))
        data.append(Data(repeating: 0, count: dataSize))
        return data
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var v = value.littleEndian
        append(Data(bytes: &v, count: MemoryLayout<T>.size))
    }

    mutating func appendASCII(_ string: String) {
        append(string.data(using: .ascii) ?? Data())
    }
}

#else

@MainActor
final class BackgroundRuntimeManager {
    private(set) var keepAliveEnabled = false
    func activateKeepAlive() { keepAliveEnabled = true }
    func deactivateKeepAlive() { keepAliveEnabled = false }
    func activateCallAudio() {}
    func deactivateCallAudio() {}
}

#endif
