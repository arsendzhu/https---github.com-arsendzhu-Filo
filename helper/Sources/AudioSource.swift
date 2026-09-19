import AVFoundation
import Foundation

enum AudioSourceError: Error {
    case noInput
}

/// One AVAudioEngine microphone tap shared by the wake-word listener and the
/// push-to-talk capture. The engine runs only while someone is consuming.
final class AudioSource {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var consumers: [UUID: (AVAudioPCMBuffer) -> Void] = [:]
    private var tapInstalled = false

    func add(_ id: UUID, _ consumer: @escaping (AVAudioPCMBuffer) -> Void) throws {
        lock.lock()
        consumers[id] = consumer
        lock.unlock()
        do {
            try ensureRunning()
        } catch {
            lock.lock()
            consumers[id] = nil
            lock.unlock()
            throw error
        }
    }

    func remove(_ id: UUID) {
        lock.lock()
        consumers[id] = nil
        let empty = consumers.isEmpty
        lock.unlock()
        if empty { stop() }
    }

    private func ensureRunning() throws {
        if engine.isRunning { return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw AudioSourceError.noInput }
        if !tapInstalled {
            input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
                guard let self = self else { return }
                self.lock.lock()
                let current = Array(self.consumers.values)
                self.lock.unlock()
                for c in current { c(buffer) }
            }
            tapInstalled = true
        }
        engine.prepare()
        try engine.start()
    }

    private func stop() {
        if engine.isRunning { engine.stop() }
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
    }

    /// Loudness 0..1 of a buffer (RMS scaled for speech levels).
    static func level(of buffer: AVAudioPCMBuffer) -> Double {
        guard let data = buffer.floatChannelData?[0] else { return 0 }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<n { sum += data[i] * data[i] }
        return min(1.0, Double(sqrt(sum / Float(n))) * 9.0)
    }
}
