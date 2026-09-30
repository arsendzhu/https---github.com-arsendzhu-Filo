import Foundation

// Pure audio-segmentation logic (no AVFoundation, no threads): a pre-roll ring buffer, an
// energy VAD with an adaptive noise floor and a hangover, and an utterance segmenter that turns a
// continuous sample stream into utterances that never lose the first syllables or the last word.
//
// Why this exists: the old capture path started the audio engine and the recognizer only when the
// key went down (the first ~250 ms of speech were lost), stopped feeding audio the instant the key
// was released (the last word was clipped) and had no idea where speech began or ended other than
// "the transcript stopped changing". The helper now keeps a small ring buffer of recent audio,
// replays it into every new recognition request, keeps recording briefly after release, and ends an
// utterance on measured silence. Everything here is deterministic so it is unit tested on synthetic
// signals and on synthesized speech fixtures (scripts/test_audio.sh, tests/test_speech_pipeline.py).

struct SegmenterConfig {
    var sampleRate: Double = 16_000
    /// Audio kept from *before* speech starts (or before the push-to-talk key goes down).
    var preRollMs: Double = 450
    /// Silence needed after the last speech before an utterance ends; also bridges pauses inside a sentence.
    var hangoverMs: Double = 800
    /// Push-to-talk keeps recording this long after the key is released.
    var pttTailMs: Double = 300
    var frameMs: Double = 20
    /// Speech must last this long before an utterance is opened (rejects clicks and door slams).
    var onsetMs: Double = 60
    /// Utterances with less speech than this are dropped as noise.
    var minSpeechMs: Double = 120
    var maxUtteranceMs: Double = 20_000
    /// A frame counts as speech when it is this many dB above the noise floor (start / keep going).
    var onsetDb: Double = 8
    var sustainDb: Double = 5
    /// Absolute floor so digital silence and dither never trigger the VAD.
    var minSpeechRms: Double = 0.006
    var initialFloorRms: Double = 0.002
    /// The first part of every stream only measures the background level (no speech is reported).
    var calibrationMs: Double = 300
}

/// Fixed-capacity ring of the most recent samples. `snapshot()` returns them oldest first.
struct PreRollBuffer {
    private var storage: [Float]
    private var head = 0          // next write position
    private(set) var count = 0

    init(capacity: Int) {
        storage = [Float](repeating: 0, count: max(1, capacity))
    }

    var capacity: Int { storage.count }

    mutating func append(_ samples: [Float]) {
        let cap = storage.count
        if samples.count >= cap {
            storage.replaceSubrange(0..<cap, with: samples[(samples.count - cap)...])
            head = 0
            count = cap
            return
        }
        for s in samples {
            storage[head] = s
            head += 1
            if head == cap { head = 0 }
        }
        count = min(cap, count + samples.count)
    }

    func snapshot() -> [Float] {
        if count < storage.count { return Array(storage[0..<count]) }
        return Array(storage[head...]) + Array(storage[0..<head])
    }

    mutating func clear() {
        head = 0
        count = 0
    }
}

struct Utterance {
    /// Sample positions on the stream's own clock (0 = first sample fed).
    var startSample: Int
    var endSample: Int
    var speechStartSample: Int
    var speechEndSample: Int
    var samples: [Float]
    var sampleRate: Double
    /// "vad" | "ptt" | "max"
    var reason: String

    func seconds(_ sample: Int) -> Double { Double(sample) / sampleRate }
    var preRollMs: Double { Double(speechStartSample - startSample) / sampleRate * 1000 }
    var tailMs: Double { Double(endSample - speechEndSample) / sampleRate * 1000 }
    var description: String {
        String(format: "%@ start=%.2fs speech=%.2f-%.2fs end=%.2fs preroll=%.0fms tail=%.0fms",
               reason, seconds(startSample), seconds(speechStartSample), seconds(speechEndSample), seconds(endSample), preRollMs, tailMs)
    }
}

enum SegmenterEvent {
    case vadStart(time: Double)            // seconds on the stream clock; logged with each utterance
    case vadEnd(time: Double)
    case utterance(Utterance)
}

final class UtteranceSegmenter {
    let cfg: SegmenterConfig
    private let frameLen: Int
    private let onsetFrames: Int
    private let hangoverFrames: Int
    private var carry: [Float] = []
    private var pre: PreRollBuffer
    private(set) var processed = 0            // samples consumed in whole frames (the stream clock)

    // VAD state
    private var floorRms: Double
    private var speaking = false              // VAD says we are inside speech (after onset debounce)
    private var candidateRun = 0
    private var silenceRun = 0
    private var runStartSample = 0
    private var lastSpeechEndSample = 0
    private var speechStartSample = 0

    // utterance under construction
    private var open = false
    private var ownedByPTT = false
    private var buf: [Float] = []
    private var bufStartSample = 0
    private var releaseAtSample: Int? = nil
    private var vadStartReported = false
    private var recentRms: [Double] = []      // last ~1.5 s of frame levels, for the steady-noise guard
    private var speakingFrames = 0

    init(_ cfg: SegmenterConfig = SegmenterConfig()) {
        self.cfg = cfg
        frameLen = max(1, Int(cfg.sampleRate * cfg.frameMs / 1000))
        onsetFrames = max(1, Int((cfg.onsetMs / cfg.frameMs).rounded()))
        hangoverFrames = max(1, Int((cfg.hangoverMs / cfg.frameMs).rounded()))
        pre = PreRollBuffer(capacity: Int(cfg.sampleRate * (cfg.preRollMs + cfg.onsetMs + cfg.frameMs) / 1000))
        floorRms = cfg.initialFloorRms
    }

    var isCapturing: Bool { open }
    /// Milliseconds since the VAD last saw a speech frame (infinity before any).
    var msSinceSpeech: Double {
        lastSpeechEndSample > 0 ? Double(processed - lastSpeechEndSample) / cfg.sampleRate * 1000 : .infinity
    }
    var noiseFloor: Double { floorRms }
    /// Position of the stream clock including the partial frame still waiting in `carry`.
    var now: Int { processed + carry.count }

    // MARK: - push-to-talk boundaries

    /// The key went down: start (or take over) an utterance right now, including the pre-roll.
    func pttPress() {
        releaseAtSample = nil
        ownedByPTT = true
        if !open { openUtterance(from: pre.snapshot(), endingAt: processed) }
    }

    /// The key went up: keep recording `pttTailMs` more, then the utterance is emitted.
    func pttRelease() {
        guard ownedByPTT else { return }
        releaseAtSample = now
    }

    /// Abandon whatever is being captured (a tap, a mute).
    func cancel() {
        open = false
        ownedByPTT = false
        releaseAtSample = nil
        buf.removeAll()
        speaking = false
        candidateRun = 0
        silenceRun = 0
    }

    // MARK: - stream input

    @discardableResult
    func feed(_ samples: [Float]) -> [SegmenterEvent] {
        var events: [SegmenterEvent] = []
        carry.append(contentsOf: samples)
        var offset = 0
        while carry.count - offset >= frameLen {
            let frame = Array(carry[offset..<(offset + frameLen)])
            offset += frameLen
            step(frame, &events)
        }
        if offset > 0 { carry.removeFirst(offset) }
        return events
    }

    /// End of stream: emit what is open (useful for files and tests).
    func finish() -> [SegmenterEvent] {
        var events: [SegmenterEvent] = []
        if open { closeUtterance(reason: ownedByPTT ? "ptt" : "vad", &events) }
        return events
    }

    // MARK: - internals

    private func step(_ frame: [Float], _ events: inout [SegmenterEvent]) {
        let frameStart = processed
        processed += frameLen
        let rms = UtteranceSegmenter.rms(frame)
        var isSpeech = false
        if Double(processed) / cfg.sampleRate * 1000 <= cfg.calibrationMs {
            floorRms = max(1e-5, min(0.05, 0.5 * floorRms + 0.5 * rms))     // calibrating: just learn the room
        } else {
            isSpeech = classify(rms)
            updateFloor(rms, speech: isSpeech)
        }

        // audio routing: into the open utterance, otherwise into the pre-roll ring
        if open { buf.append(contentsOf: frame) } else { pre.append(frame) }

        // Steady-noise guard: real speech rises and falls with every syllable, a fan that just
        // switched on does not. "Speech" that stays this flat for 1.5 s is the new noise floor.
        recentRms.append(rms)
        if recentRms.count > 75 { recentRms.removeFirst() }
        speakingFrames = speaking ? speakingFrames + 1 : 0
        if speaking && speakingFrames >= 75 && recentRms.count == 75 {
            let mean = recentRms.reduce(0, +) / 75
            let variance = recentRms.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / 75
            if mean > 0 && variance.squareRoot() / mean < 0.12 {
                floorRms = min(0.05, max(1e-5, mean))
                speaking = false
                candidateRun = 0
                silenceRun = 0
                speakingFrames = 0
                if open && !ownedByPTT { cancel() }
                return
            }
        }

        // VAD state machine (frame quantised)
        if isSpeech {
            if !speaking {
                if candidateRun == 0 { runStartSample = frameStart }
                candidateRun += 1
                if candidateRun >= onsetFrames {
                    speaking = true
                    speechStartSample = runStartSample
                    vadStartReported = false
                    events.append(.vadStart(time: Double(speechStartSample) / cfg.sampleRate))
                    if !open {
                        // the ring holds everything up to and including this frame
                        openUtterance(from: pre.snapshot(), endingAt: processed)
                    }
                }
            }
            silenceRun = 0
            lastSpeechEndSample = processed
        } else {
            candidateRun = 0
            if speaking {
                silenceRun += 1
                if silenceRun >= hangoverFrames {
                    speaking = false
                    events.append(.vadEnd(time: Double(lastSpeechEndSample) / cfg.sampleRate))
                    if open && !ownedByPTT { closeUtterance(reason: "vad", &events) }
                }
            }
        }

        if open {
            if let release = releaseAtSample, processed >= release + Int(cfg.sampleRate * cfg.pttTailMs / 1000) {
                closeUtterance(reason: "ptt", &events)
            } else if buf.count >= Int(cfg.sampleRate * cfg.maxUtteranceMs / 1000) {
                closeUtterance(reason: ownedByPTT ? "ptt" : "max", &events)
            }
        }
    }

    private func openUtterance(from head: [Float], endingAt endSample: Int) {
        open = true
        buf = head
        bufStartSample = endSample - head.count
        pre.clear()
    }

    private func closeUtterance(reason: String, _ events: inout [SegmenterEvent]) {
        defer {
            // recent audio stays available as pre-roll for a quick follow-on utterance
            let keep = min(buf.count, pre.capacity)
            pre.clear()
            if keep > 0 { pre.append(Array(buf[(buf.count - keep)...])) }
            open = false
            ownedByPTT = false
            releaseAtSample = nil
            buf = []
            speaking = false
            candidateRun = 0
            silenceRun = 0
        }
        // never touched by speech: nothing to report (a PTT press with no speech still returns the audio)
        let hasSpeech = lastSpeechEndSample > speechStartSample && lastSpeechEndSample > bufStartSample
        let speechMs = Double(max(0, lastSpeechEndSample - speechStartSample)) / cfg.sampleRate * 1000
        if !ownedByPTT && (!hasSpeech || speechMs < cfg.minSpeechMs) { return }
        let sStart = hasSpeech ? max(speechStartSample, bufStartSample) : bufStartSample
        let sEnd = hasSpeech ? lastSpeechEndSample : bufStartSample + buf.count
        events.append(.utterance(Utterance(
            startSample: bufStartSample, endSample: bufStartSample + buf.count,
            speechStartSample: sStart, speechEndSample: max(sEnd, sStart),
            samples: buf, sampleRate: cfg.sampleRate, reason: reason)))
    }

    private func classify(_ rms: Double) -> Bool {
        let inside = speaking || candidateRun > 0
        let threshold = max(inside ? cfg.minSpeechRms * 0.7 : cfg.minSpeechRms,
                            floorRms * pow(10, (inside ? cfg.sustainDb : cfg.onsetDb) / 20))
        return rms > threshold
    }

    /// Follows the background level: down quickly, up slowly, and never while speech is in progress.
    private func updateFloor(_ rms: Double, speech: Bool) {
        if speech { return }
        if rms < floorRms {
            floorRms = 0.6 * floorRms + 0.4 * rms
        } else {
            let a = cfg.frameMs / 3000.0
            floorRms = floorRms * (1 - a) + rms * a
        }
        floorRms = min(0.05, max(1e-5, floorRms))
    }

    static func rms(_ x: [Float]) -> Double {
        guard !x.isEmpty else { return 0 }
        var sum: Float = 0
        for v in x { sum += v * v }
        return Double((sum / Float(x.count)).squareRoot())
    }
}

enum Resampler {
    /// Mono resample by linear interpolation; when decimating, the input is box-averaged first so
    /// the high frequencies fold in less. Fine for VAD, debug dumps and offline recognisers.
    static func resample(_ x: [Float], from: Double, to: Double) -> [Float] {
        guard !x.isEmpty, from > 0, to > 0 else { return [] }
        if abs(from - to) < 0.5 { return x }
        var src = x
        if to < from {
            let k = max(1, Int((from / to).rounded(.down)))
            if k > 1 {
                var out = [Float](repeating: 0, count: x.count / k)
                for i in 0..<out.count {
                    var s: Float = 0
                    for j in 0..<k { s += x[i * k + j] }
                    out[i] = s / Float(k)
                }
                src = out
                return resample(src, from: from / Double(k), to: to)
            }
        }
        let ratio = from / to
        let n = Int(Double(src.count) / ratio)
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let pos = Double(i) * ratio
            let i0 = Int(pos)
            let frac = Float(pos - Double(i0))
            let a = src[min(i0, src.count - 1)]
            let b = src[min(i0 + 1, src.count - 1)]
            out[i] = a + (b - a) * frac
        }
        return out
    }
}

enum WavIO {
    /// Mono 16-bit PCM WAV.
    static func write16(_ samples: [Float], rate: Double, to url: URL) throws {
        var pcm = Data()
        pcm.reserveCapacity(samples.count * 2)
        for s in samples {
            let v = Int16(max(-1, min(1, s)) * 32767)
            withUnsafeBytes(of: v.littleEndian) { pcm.append(contentsOf: $0) }
        }
        var header = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { header.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { header.append(contentsOf: $0) } }
        header.append("RIFF".data(using: .ascii)!)
        u32(UInt32(36 + pcm.count))
        header.append("WAVEfmt ".data(using: .ascii)!)
        u32(16); u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate) * 2); u16(2); u16(16)
        header.append("data".data(using: .ascii)!)
        u32(UInt32(pcm.count))
        try (header + pcm).write(to: url)
    }

    /// 16-bit PCM WAV (mono, or the first channel of several) -> samples in -1...1 and the sample rate.
    static func read(_ url: URL) throws -> (samples: [Float], rate: Double) {
        let d = try Data(contentsOf: url)
        func u16(_ o: Int) -> Int { Int(d[o]) | Int(d[o + 1]) << 8 }
        func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
        guard d.count > 44, String(data: d[0..<4], encoding: .ascii) == "RIFF" else { throw NSError(domain: "wav", code: 1) }
        var pos = 12
        var channels = 1, rate = 16000, bits = 16
        while pos + 8 <= d.count {
            let id = String(data: d[pos..<(pos + 4)], encoding: .ascii) ?? ""
            let len = u32(pos + 4)
            if id == "fmt " {
                channels = u16(pos + 10)
                rate = u32(pos + 12)
                bits = u16(pos + 22)
            } else if id == "data" {
                guard bits == 16 else { throw NSError(domain: "wav", code: 2) }
                let n = min(len, d.count - pos - 8) / (2 * channels)
                var out = [Float](repeating: 0, count: n)
                for i in 0..<n {
                    let o = pos + 8 + i * 2 * channels
                    out[i] = Float(Int16(truncatingIfNeeded: u16(o))) / 32768
                }
                return (out, Double(rate))
            }
            pos += 8 + len + (len & 1)
        }
        throw NSError(domain: "wav", code: 3)
    }
}
