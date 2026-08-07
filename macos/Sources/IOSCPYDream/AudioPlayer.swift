import AVFoundation
import Foundation

final class AudioPlayer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.ioscpy.audio-player", qos: .userInteractive)
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var currentRate: Double = 0
    private var currentChannels: AVAudioChannelCount = 0
    private var queuedSeconds: Double = 0
    private var running = false

    init() {
        engine.attach(player)
    }

    func enqueue(_ packet: Data) {
        queue.async { [weak self] in self?.enqueueLocked(packet) }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.player.stop()
            self.engine.stop()
            self.engine.reset()
            self.queuedSeconds = 0
            self.running = false
            self.currentRate = 0
            self.currentChannels = 0
        }
    }

    private func enqueueLocked(_ packet: Data) {
        guard packet.count >= 16,
              packet.readBE(UInt32.self, at: 0) == 0x4150_434D else { return }
        let rate = Double(packet.readBE(UInt32.self, at: 4))
        let channels = AVAudioChannelCount(packet.readBE(UInt16.self, at: 8))
        let frames = AVAudioFrameCount(packet.readBE(UInt32.self, at: 12))
        guard rate >= 8_000, rate <= 192_000,
              channels > 0, channels <= 2,
              frames > 0, frames <= 8192,
              packet.count >= 16 + Int(frames) * Int(channels) * 4 else { return }

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: rate,
            channels: channels,
            interleaved: false
        ), let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        buffer.frameLength = frames
        guard let channelData = buffer.floatChannelData else { return }
        var offset = 16
        for frame in 0..<Int(frames) {
            for channel in 0..<Int(channels) {
                let bits = packet.readBE(UInt32.self, at: offset)
                channelData[channel][frame] = Float(bitPattern: bits)
                offset += 4
            }
        }

        do {
            if currentRate != rate || currentChannels != channels || !running {
                player.stop()
                engine.stop()
                engine.reset()
                engine.connect(player, to: engine.mainMixerNode, format: format)
                try engine.start()
                player.play()
                currentRate = rate
                currentChannels = channels
                queuedSeconds = 0
                running = true
            }

            if queuedSeconds > 0.12 {
                player.stop()
                queuedSeconds = 0
                player.play()
            }
            let duration = Double(frames) / rate
            queuedSeconds += duration
            player.scheduleBuffer(buffer) { [weak self] in
                self?.didConsume(duration: duration)
            }
            if !player.isPlaying { player.play() }
        } catch {
            NSLog("[ioscpy] audio engine failed: %@", error.localizedDescription)
            running = false
        }
    }

    private func didConsume(duration: Double) {
        queue.async { [weak self] in
            guard let self else { return }
            self.queuedSeconds = max(0, self.queuedSeconds - duration)
        }
    }
}
