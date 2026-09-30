import AVFoundation
import Foundation

/// The engine-independent heart of AudioSource: it receives the microphone buffers, keeps a ring of the
/// last `preRollMs` of audio, and hands every buffer to the consumers - and, to a consumer that asks for
/// it, first the buffered pre-roll, in order and without duplicates.
///
/// The audio callback must stay light and must never block: `ingest` copies channel 0 once, appends it
/// to the ring, calls the consumers' `live` closures (which only do the cheap `request.append`) and pushes
/// everything else (levels, VAD, dumps) to `dspQueue`.
final class AudioTapCore {
    struct Consumer {
        var live: (AVAudioPCMBuffer) -> Void
        var dsp: (([Float], Double) -> Void)?
        var minSeq: Int          // only buffers newer than this are delivered live (the rest came with the replay)
    }

    private let lock = NSLock()
    private var consumers: [UUID: Consumer] = [:]
    private var ring: PreRollBuffer?
    private var ringFormat: AVAudioFormat?
    private var seq = 0
    let dspQueue = DispatchQueue(label: "filo.audio.dsp", qos: .userInitiated)
    var preRollMs: Double

    init(preRollMs: Double) {
        self.preRollMs = preRollMs
    }

    var consumerCount: Int {
        lock.lock(); defer { lock.unlock() }
        return consumers.count
    }

    var bufferedSeconds: Double {
        lock.lock(); defer { lock.unlock() }
        guard let r = ring, let f = ringFormat else { return 0 }
        return Double(r.count) / f.sampleRate
    }

    /// Audio thread. Never blocks for long, never allocates more than one array per buffer.
    func ingest(_ buffer: AVAudioPCMBuffer) {
        let n = Int(buffer.frameLength)
        guard n > 0, let channels = buffer.floatChannelData else { return }
        let mono = Array(UnsafeBufferPointer(start: channels[0], count: n))
        let rate = buffer.format.sampleRate
        lock.lock()
        if preRollMs > 0 {
            if ring == nil || ringFormat?.sampleRate != rate || ringFormat?.channelCount != buffer.format.channelCount {
                ring = PreRollBuffer(capacity: max(1, Int(rate * preRollMs / 1000)))
                ringFormat = buffer.format
            }
            ring?.append(mono)
        }
        seq += 1
        let current = consumers.values.filter { seq > $0.minSeq }
        lock.unlock()
        for c in current { c.live(buffer) }
        let dsps = current.compactMap { $0.dsp }
        if !dsps.isEmpty {
            dspQueue.async { for d in dsps { d(mono, rate) } }
        }
    }

    /// Registers a consumer. With `preRoll`, it first receives the buffered audio (as buffers in the live
    /// format, and through `dsp`), then everything ingested afterwards: strictly in order, nothing twice.
    func add(_ id: UUID, preRoll: Bool, live: @escaping (AVAudioPCMBuffer) -> Void, dsp: (([Float], Double) -> Void)? = nil) {
        lock.lock()
        defer { lock.unlock() }
        consumers[id] = Consumer(live: live, dsp: dsp, minSeq: seq)
        guard preRoll, let snap = ring?.snapshot(), !snap.isEmpty, let format = ringFormat else { return }
        // replayed while holding the lock, so no newer buffer can be delivered before it
        var pos = 0
        while pos < snap.count {
            let end = min(snap.count, pos + 2048)
            if let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(end - pos)), let channels = b.floatChannelData {
                b.frameLength = AVAudioFrameCount(end - pos)
                for ch in 0..<Int(format.channelCount) {
                    for i in 0..<(end - pos) { channels[ch][i] = snap[pos + i] }
                }
                live(b)
            }
            pos = end
        }
        if let d = dsp { let rate = format.sampleRate; dspQueue.async { d(snap, rate) } }
    }

    func remove(_ id: UUID) {
        lock.lock()
        consumers[id] = nil
        lock.unlock()
    }

    /// Forget the buffered audio (after a finished question, while Filo speaks, when muted).
    func clearPreRoll() {
        lock.lock()
        ring?.clear()
        lock.unlock()
    }
}
