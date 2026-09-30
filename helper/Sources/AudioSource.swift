import AVFoundation
import Foundation

enum AudioSourceError: Error {
    case noInput
    case muted
}

/// One AVAudioEngine microphone tap shared by the wake-word listener and the push-to-talk capture.
///
/// Since the pre-roll work the engine can stay warm: with `keepWarm` on it keeps running with no consumer
/// so the last ~450 ms of audio is always in the ring and a new recognition request can start with the
/// words spoken just before it (the old code cold-started the engine on every key press and lost the first
/// syllables). The ring lives in memory only and is dropped whenever the microphone stops (mute, Filo
/// speaking). All the work happens in AudioTapCore; this class only owns the engine.
final class AudioSource {
    private let engine = AVAudioEngine()
    let core: AudioTapCore
    private let stateLock = NSLock()
    private var tapInstalled = false
    private(set) var keepWarm = false
    private(set) var suspended = false

    init(preRollMs: Double) {
        core = AudioTapCore(preRollMs: preRollMs)
    }

    /// `preRoll`: replay the buffered audio into this consumer before the live audio.
    /// `live` runs on the audio thread (keep it to request.append); `dsp` runs on a serial queue.
    func add(_ id: UUID, preRoll: Bool = false, _ live: @escaping (AVAudioPCMBuffer) -> Void, dsp: (([Float], Double) -> Void)? = nil) throws {
        if suspended { throw AudioSourceError.muted }
        // engine first: a running engine has a ring to replay, a cold one starts empty
        try ensureRunning()
        core.add(id, preRoll: preRoll, live: live, dsp: dsp)
    }

    func remove(_ id: UUID) {
        core.remove(id)
        stopIfIdle()
    }

    /// Keep the engine (and the pre-roll ring) running while nobody consumes.
    func setKeepWarm(_ on: Bool) {
        stateLock.lock()
        keepWarm = on
        let s = suspended
        stateLock.unlock()
        if on && !s {
            try? ensureRunning()
        } else {
            stopIfIdle()
        }
    }

    /// The user muted the microphone: engine off, ring dropped, nothing may start until resume().
    func suspend() {
        stateLock.lock()
        suspended = true
        stateLock.unlock()
        stopEngine()
    }

    func resume() {
        stateLock.lock()
        suspended = false
        let warm = keepWarm
        stateLock.unlock()
        if warm { try? ensureRunning() }
    }

    func clearPreRoll() {
        core.clearPreRoll()
    }

    private func stopIfIdle() {
        stateLock.lock()
        let warm = keepWarm && !suspended
        stateLock.unlock()
        if !warm && core.consumerCount == 0 { stopEngine() }
    }

    private func ensureRunning() throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        if engine.isRunning { return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw AudioSourceError.noInput }
        if !tapInstalled {
            input.installTap(onBus: 0, bufferSize: 2048, format: format) { [core] buffer, _ in
                core.ingest(buffer)
            }
            tapInstalled = true
        }
        engine.prepare()
        try engine.start()
    }

    private func stopEngine() {
        stateLock.lock()
        defer { stateLock.unlock() }
        if engine.isRunning { engine.stop() }
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        core.clearPreRoll()
    }

    /// Loudness 0..1 of a buffer (RMS scaled for speech levels).
    static func level(of buffer: AVAudioPCMBuffer) -> Double {
        guard let data = buffer.floatChannelData?[0] else { return 0 }
        return level(of: Array(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength))))
    }

    static func level(of samples: [Float]) -> Double {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for s in samples { sum += s * s }
        return min(1.0, Double((sum / Float(samples.count)).squareRoot()) * 9.0)
    }
}
