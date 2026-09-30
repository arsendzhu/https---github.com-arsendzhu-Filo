import AVFoundation
import Foundation

// Test harness for AudioSegmenter.swift (compiled together with it by scripts/test_audio.sh; it is NOT
// part of the helper app).
//
//   segmenter_cli selftest
//       synthetic-signal unit tests: pre-roll ring, onset with pre-roll, hangover, pauses inside a
//       sentence, noise, push-to-talk press/release/tail, maximum length. Prints test_* lines.
//   segmenter_cli segment FILE.wav [--mode vad|ptt] [--press S] [--release S] [--chunk N] [--out-dir DIR]
//       runs a WAV through the segmenter exactly as the helper feeds it (chunks of N samples) and prints
//       one JSON object per utterance.

var failures = 0

func check(_ ok: Bool, _ msg: String) {
    if ok { print("  ok: \(msg)") } else { print("  FAIL: \(msg)"); failures += 1 }
}

// MARK: synthetic signals (deterministic)

struct LCG {
    var state: UInt64 = 0x9E3779B97F4A7C15
    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state >> 11) / Double(1 << 53) * 2 - 1
    }
}

func noise(_ seconds: Double, rms: Double, rate: Double, rng: inout LCG) -> [Float] {
    let n = Int(seconds * rate)
    // uniform noise has rms = amp / sqrt(3)
    let amp = rms * 3.0.squareRoot()
    return (0..<n).map { _ in Float(rng.next() * amp) }
}

/// Voiced-speech-like: 140 Hz harmonics with a 4 Hz syllable envelope. RMS is `rms`.
func speech(_ seconds: Double, rms: Double, rate: Double) -> [Float] {
    let n = Int(seconds * rate)
    var out = [Float](repeating: 0, count: n)
    var energy = 0.0
    for i in 0..<n {
        let t = Double(i) / rate
        var v = 0.0
        for h in 1...5 { v += sin(2 * .pi * 140 * Double(h) * t) / Double(h) }
        let env = 0.55 + 0.45 * sin(2 * .pi * 4 * t)
        v *= env
        out[i] = Float(v)
        energy += v * v
    }
    let scale = rms / (energy / Double(max(n, 1))).squareRoot()
    return out.map { Float(Double($0) * scale) }
}

func mix(_ a: [Float], _ b: [Float]) -> [Float] {
    var out = a
    for i in 0..<min(a.count, b.count) { out[i] += b[i] }
    return out
}

func run(_ x: [Float], cfg: SegmenterConfig, chunk: Int = 2048, press: Int? = nil, release: Int? = nil) -> [Utterance] {
    let seg = UtteranceSegmenter(cfg)
    var out: [Utterance] = []
    func collect(_ events: [SegmenterEvent]) {
        for e in events { if case .utterance(let u) = e { out.append(u) } }
    }
    var actions: [(at: Int, press: Bool)] = []
    if let p = press { actions.append((p, true)) }
    if let r = release { actions.append((r, false)) }
    actions.sort { $0.at < $1.at }
    var pos = 0, next = 0
    while pos < x.count {
        var end = min(x.count, pos + chunk)
        if next < actions.count, actions[next].at >= pos, actions[next].at < end { end = actions[next].at }   // stop exactly on the key event
        if end > pos {
            collect(seg.feed(Array(x[pos..<end])))
            pos = end
        }
        while next < actions.count, actions[next].at <= pos {
            if actions[next].press { seg.pttPress() } else { seg.pttRelease() }
            next += 1
        }
    }
    collect(seg.finish())
    return out
}

func selftest() -> Int32 {
    let rate = 16_000.0
    let cfg = SegmenterConfig()
    var rng = LCG()
    let sr = Int(rate)

    print("test_preroll_ring_buffer")
    var ring = PreRollBuffer(capacity: 300)
    ring.append((0..<1000).map { Float($0) })
    var snap = ring.snapshot()
    check(snap.count == 300 && snap.first == 700 && snap.last == 999, "a full ring keeps the newest 300 samples, oldest first")
    ring.clear()
    ring.append([1, 2, 3])
    ring.append([4, 5])
    snap = ring.snapshot()
    check(snap == [1, 2, 3, 4, 5], "a partly filled ring returns what it has in order")
    ring.append((0..<298).map { Float(10 + $0) })
    snap = ring.snapshot()
    check(snap.count == 300 && snap[0] == 4 && snap[1] == 5 && snap[2] == 10 && snap.last == 307, "the ring wraps around correctly (drops the 3 oldest of 303 values)")

    print("test_onset_keeps_preroll_and_hangover_tail")
    var x = noise(1.0, rms: 0.003, rate: rate, rng: &rng)
    x += mix(speech(1.5, rms: 0.15, rate: rate), noise(1.5, rms: 0.003, rate: rate, rng: &rng))
    x += noise(2.0, rms: 0.003, rate: rate, rng: &rng)
    var us = run(x, cfg: cfg)
    check(us.count == 1, "one utterance for one sentence (got \(us.count))")
    if let u = us.first {
        print("    \(u.description)")
        check(abs(u.seconds(u.speechStartSample) - 1.0) < 0.06, "speech onset found at 1.00 s (\(u.seconds(u.speechStartSample)))")
        check(u.preRollMs >= 0.95 * cfg.preRollMs, "the utterance starts \(Int(u.preRollMs)) ms before the first syllable (pre-roll \(Int(cfg.preRollMs)) ms)")
        check(abs(u.seconds(u.speechEndSample) - 2.5) < 0.08, "speech end found at 2.50 s (\(u.seconds(u.speechEndSample)))")
        check(u.tailMs >= cfg.hangoverMs - 40, "the utterance keeps \(Int(u.tailMs)) ms of trailing audio (hangover \(Int(cfg.hangoverMs)) ms)")
        check(u.startSample <= Int(0.55 * rate) + 20 && u.endSample >= Int(3.3 * rate) - 700, "the audio spans [0.55 s, 3.3 s]: \(u.seconds(u.startSample))-\(u.seconds(u.endSample))")
    }

    print("test_hangover_bridges_pauses_inside_a_sentence")
    let pausedShort = speech(1.0, rms: 0.15, rate: rate) + noise(0.6, rms: 0.003, rate: rate, rng: &rng) + speech(1.0, rms: 0.15, rate: rate)
    x = noise(0.8, rms: 0.003, rate: rate, rng: &rng) + pausedShort + noise(2.0, rms: 0.003, rate: rate, rng: &rng)
    us = run(x, cfg: cfg)
    check(us.count == 1, "a 0.6 s pause inside a sentence does not end the utterance (got \(us.count))")
    if let u = us.first { check(u.seconds(u.speechEndSample) > 3.3, "...and the second half is inside it (speech ends at \(u.seconds(u.speechEndSample)) s)") }
    let pausedLong = speech(1.0, rms: 0.15, rate: rate) + noise(1.6, rms: 0.003, rate: rate, rng: &rng) + speech(1.0, rms: 0.15, rate: rate)
    x = noise(0.8, rms: 0.003, rate: rate, rng: &rng) + pausedLong + noise(2.0, rms: 0.003, rate: rate, rng: &rng)
    us = run(x, cfg: cfg)
    check(us.count == 2, "a 1.6 s silence ends the first utterance and a second one starts (got \(us.count))")
    if us.count == 2 { check(us[1].preRollMs >= 150, "the second utterance still has pre-roll from the gap (\(Int(us[1].preRollMs)) ms)") }

    print("test_noise_does_not_trigger")
    x = noise(8.0, rms: 0.02, rate: rate, rng: &rng)
    us = run(x, cfg: cfg)
    check(us.isEmpty, "8 s of steady room noise (rms 0.02) triggers nothing (got \(us.count))")
    x = noise(1.0, rms: 0.002, rate: rate, rng: &rng) + noise(6.0, rms: 0.012, rate: rate, rng: &rng)
    us = run(x, cfg: cfg)
    check(us.isEmpty, "a room that gets louder is absorbed by the noise floor (got \(us.count))")
    var clicks = noise(3.0, rms: 0.003, rate: rate, rng: &rng)
    for i in 20_000..<20_400 { clicks[i] = 0.4 }    // a 25 ms click
    us = run(clicks, cfg: cfg)
    check(us.isEmpty, "a 25 ms click is not speech (got \(us.count))")

    print("test_speech_in_noise_10db")
    let quiet = noise(1.0, rms: 0.03, rate: rate, rng: &rng)
    x = quiet + mix(speech(2.0, rms: 0.1, rate: rate), noise(2.0, rms: 0.03, rate: rate, rng: &rng)) + noise(2.0, rms: 0.03, rate: rate, rng: &rng)
    us = run(x, cfg: cfg)
    check(us.count == 1, "speech at 10 dB SNR is found (got \(us.count))")
    if let u = us.first {
        check(u.seconds(u.speechStartSample) < 1.15 && u.seconds(u.speechEndSample) > 2.85, "...and covers the sentence: \(u.seconds(u.speechStartSample))-\(u.seconds(u.speechEndSample))")
        check(u.preRollMs >= 0.9 * cfg.preRollMs, "pre-roll is intact in noise (\(Int(u.preRollMs)) ms)")
    }

    print("test_ptt_press_release_and_tail")
    // the player presses 150 ms after starting to talk and lets go 100 ms before the end of the last word
    x = noise(1.2, rms: 0.003, rate: rate, rng: &rng) + speech(1.8, rms: 0.15, rate: rate) + noise(2.0, rms: 0.003, rate: rate, rng: &rng)
    let press = Int(1.35 * rate), release = Int(2.9 * rate)
    us = run(x, cfg: cfg, press: press, release: release)
    check(us.count == 1 && us[0].reason == "ptt", "push-to-talk yields one 'ptt' utterance (got \(us.count))")
    if let u = us.first {
        print("    \(u.description)")
        check(u.startSample <= Int(1.2 * rate), "the first syllable (1.20 s), spoken before the key press (1.35 s), is inside: starts at \(u.seconds(u.startSample)) s")
        check(u.endSample >= Int(3.0 * rate), "the last syllable (3.00 s), spoken after the release (2.90 s), is inside: ends at \(u.seconds(u.endSample)) s")
        check(u.endSample >= release + Int(0.3 * rate) - 320, "recording continued 300 ms after the release")
        check(u.endSample <= release + Int(0.3 * rate) + 2 * 2048, "...and stopped right there (\(u.seconds(u.endSample)) s)")
    }
    x = noise(3.0, rms: 0.003, rate: rate, rng: &rng)
    us = run(x, cfg: cfg, press: sr, release: 2 * sr)
    check(us.count == 1 && us[0].reason == "ptt" && us[0].samples.count > Int(1.2 * rate), "a key press with no speech still returns the audio for the recogniser to judge (\(us.first?.samples.count ?? 0) samples)")

    print("test_max_length")
    x = speech(25.0, rms: 0.15, rate: rate)
    us = run(x, cfg: cfg)
    check(us.count >= 2 && us[0].reason == "max", "25 s of uninterrupted speech is cut at the maximum length (got \(us.count) utterances)")

    print("test_device_rate_48k")
    var cfg48 = cfg
    cfg48.sampleRate = 48_000
    let r48 = 48_000.0
    x = noise(1.0, rms: 0.003, rate: r48, rng: &rng) + speech(1.2, rms: 0.15, rate: r48) + noise(2.0, rms: 0.003, rate: r48, rng: &rng)
    us = run(x, cfg: cfg48, chunk: 2048)
    check(us.count == 1 && us[0].preRollMs >= 0.95 * cfg.preRollMs && us[0].tailMs >= cfg.hangoverMs - 40, "the same behaviour at the microphone's native 48 kHz")

    print("test_resampler")
    let tone48 = (0..<48_000).map { Float(sin(2 * .pi * 440 * Double($0) / 48_000)) }
    let tone16 = Resampler.resample(tone48, from: 48_000, to: 16_000)
    check(abs(tone16.count - 16_000) <= 2, "48 kHz -> 16 kHz gives one third of the samples (\(tone16.count))")
    let peak = tone16.map { abs($0) }.max() ?? 0
    check(peak > 0.9 && peak < 1.05, "...and keeps the amplitude of a 440 Hz tone (peak \(peak))")

    tapCoreTests()
    endpointingTests()
    dumpTests()

    print(failures == 0 ? "all segmenter checks passed" : "\(failures) segmenter checks FAILED")
    return failures == 0 ? 0 : 1
}

// MARK: the audio tap core (pre-roll replay), endpointing, debug dump

func makeBuffer(rate: Double, channels: AVAudioChannelCount, start: Int, frames: Int) -> AVAudioPCMBuffer {
    let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: channels, interleaved: false)!
    let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(frames))!
    b.frameLength = AVAudioFrameCount(frames)
    for ch in 0..<Int(channels) { for i in 0..<frames { b.floatChannelData![ch][i] = Float(start + i) } }
    return b
}

final class Collector {
    private let lock = NSLock()
    var samples: [Float] = []
    var channelsSeen = Set<Int>()
    var dspSamples: [Float] = []
    func live(_ b: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        samples.append(contentsOf: UnsafeBufferPointer(start: b.floatChannelData![0], count: Int(b.frameLength)))
        channelsSeen.insert(Int(b.format.channelCount))
    }
    func dsp(_ x: [Float], _ rate: Double) {
        lock.lock(); defer { lock.unlock() }
        dspSamples.append(contentsOf: x)
    }
    var contiguous: Bool {
        lock.lock(); defer { lock.unlock() }
        for i in 1..<max(1, samples.count) where samples[i] != samples[i - 1] + 1 { return false }
        return true
    }
}

func tapCoreTests() {
    print("test_tap_core_preroll_replay")
    let rate = 48_000.0
    let core = AudioTapCore(preRollMs: 450)
    var next = 0
    for _ in 0..<20 { core.ingest(makeBuffer(rate: rate, channels: 1, start: next, frames: 2048)); next += 2048 }
    let want = Int(rate * 0.450)
    check(abs(core.bufferedSeconds - 0.450) < 0.002, "the ring holds 450 ms (\(core.bufferedSeconds) s)")
    let c = Collector()
    core.add(UUID(), preRoll: true, live: c.live, dsp: c.dsp)
    check(c.samples.count == want && c.samples.first == Float(next - want) && c.samples.last == Float(next - 1), "a new consumer first receives the last 450 ms (\(c.samples.count) samples, from \(Int(c.samples.first ?? -1)))")
    for _ in 0..<3 { core.ingest(makeBuffer(rate: rate, channels: 1, start: next, frames: 2048)); next += 2048 }
    check(c.samples.count == want + 3 * 2048 && c.contiguous && c.samples.last == Float(next - 1), "...followed by the live audio, contiguous, nothing twice")
    core.dspQueue.sync {}
    check(c.dspSamples.count == c.samples.count && c.dspSamples == c.samples, "the analysis queue sees exactly the same audio in the same order")

    let plain = Collector()
    core.add(UUID(), preRoll: false, live: plain.live)
    check(plain.samples.isEmpty, "a consumer that does not ask for pre-roll gets none")
    core.ingest(makeBuffer(rate: rate, channels: 1, start: next, frames: 2048)); next += 2048
    check(plain.samples.count == 2048 && plain.samples.first == Float(next - 2048), "...and only the audio from now on")

    core.clearPreRoll()
    let after = Collector()
    core.add(UUID(), preRoll: true, live: after.live)
    check(after.samples.isEmpty, "after clearPreRoll() nothing is replayed (Filo's own voice, a muted mic)")

    let stereo = AudioTapCore(preRollMs: 200)
    for i in 0..<10 { stereo.ingest(makeBuffer(rate: 44_100, channels: 2, start: i * 1024, frames: 1024)) }
    let sc = Collector()
    stereo.add(UUID(), preRoll: true, live: sc.live)
    check(sc.channelsSeen == [2] && sc.samples.count == Int(44_100 * 0.2), "replayed buffers keep the live format (2 channels, 44.1 kHz): \(sc.channelsSeen) \(sc.samples.count)")

    // ordering under concurrency: the audio thread keeps delivering while a consumer joins
    var raceFailures = 0
    for round in 0..<60 {
        let racy = AudioTapCore(preRollMs: 450)
        for i in 0..<12 { racy.ingest(makeBuffer(rate: rate, channels: 1, start: i * 2048, frames: 2048)) }
        let col = Collector()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            for i in 12..<40 { racy.ingest(makeBuffer(rate: rate, channels: 1, start: i * 2048, frames: 2048)) }
            done.signal()
        }
        usleep(UInt32(200 + (round % 7) * 150))
        racy.add(UUID(), preRoll: true, live: col.live)
        done.wait()
        if !col.contiguous || col.samples.last != Float(40 * 2048 - 1) { raceFailures += 1 }
    }
    check(raceFailures == 0, "joining while the audio thread delivers never reorders, skips or repeats audio (60 races, \(raceFailures) failures)")
}

func endpointingTests() {
    print("test_endpointing")
    check(Endpointing.looksIncomplete("how do I beat the") && Endpointing.looksIncomplete("what about the second phase of") && Endpointing.looksIncomplete("Where can I find it in"), "a transcript ending on a dangling word is judged unfinished")
    check(!Endpointing.looksIncomplete("How do I beat the Eye of Cthulhu") && !Endpointing.looksIncomplete("what about the second phase") && !Endpointing.looksIncomplete(""), "finished sentences are not")
    check(Endpointing.questionIsOver(silenceMs: 950, transcriptIdleMs: 800, transcript: "how do I beat Lady Butterfly", hangoverMs: 900), "0.95 s of silence and a settled transcript end the question")
    check(!Endpointing.questionIsOver(silenceMs: 600, transcriptIdleMs: 900, transcript: "how do I beat Lady Butterfly", hangoverMs: 900), "a 0.6 s pause does not")
    check(!Endpointing.questionIsOver(silenceMs: 1200, transcriptIdleMs: 300, transcript: "how do I beat Lady Butterfly", hangoverMs: 900), "the transcript is still changing: not over")
    check(!Endpointing.questionIsOver(silenceMs: 1200, transcriptIdleMs: 1000, transcript: "how do I beat the", hangoverMs: 900), "a sentence that stops on 'the' gets extra time")
    check(Endpointing.questionIsOver(silenceMs: 1700, transcriptIdleMs: 1200, transcript: "how do I beat the", hangoverMs: 900), "...but not forever")
}

func dumpTests() {
    print("test_debug_audio_dump")
    let dir = NSTemporaryDirectory() + "filo-dump-test-\(getpid())"
    try? FileManager.default.removeItem(atPath: dir)
    guard let dump = AudioDump(path: dir, keep: 20) else { check(false, "the dump directory could not be created"); return }
    var tone = [Float](repeating: 0, count: 48_000)
    for i in 0..<48_000 {
        let phase: Double = 2.0 * Double.pi * 300.0 * Double(i) / 48_000.0
        tone[i] = Float(0.3 * sin(phase))
    }
    for i in 0..<25 {
        dump.save(tone, rate: 48_000, label: i % 2 == 0 ? "ptt" : "wake", note: "test \(i)")
        usleep(3000)
    }
    let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasSuffix(".wav") }.sorted()
    check(files.count == 20, "only the newest 20 dumps are kept (\(files.count))")
    if let f = files.last, let (x, r) = try? WavIO.read(URL(fileURLWithPath: dir).appendingPathComponent(f)) {
        check(r == 16_000 && abs(x.count - 16_000) < 4 && (x.map { abs($0) }.max() ?? 0) > 0.25, "a dump is a 16 kHz mono WAV with the audio in it (\(Int(r)) Hz, \(x.count) samples)")
    } else {
        check(false, "the newest dump could not be read back")
    }
    try? FileManager.default.removeItem(atPath: dir)
}

// MARK: segment a WAV like the helper would

func segmentFile(_ args: [String]) -> Int32 {
    guard let path = args.first else { print("usage: segment FILE.wav [--mode vad|ptt] [--press S] [--release S] [--chunk N] [--out-dir DIR]"); return 2 }
    var mode = "vad", press = 0.0, release = 0.0, chunk = 2048
    var outDir: String? = nil
    var i = 1
    while i < args.count {
        switch args[i] {
        case "--mode": i += 1; mode = args[i]
        case "--press": i += 1; press = Double(args[i]) ?? 0
        case "--release": i += 1; release = Double(args[i]) ?? 0
        case "--chunk": i += 1; chunk = Int(args[i]) ?? 2048
        case "--out-dir": i += 1; outDir = args[i]
        default: break
        }
        i += 1
    }
    do {
        let (x, rate) = try WavIO.read(URL(fileURLWithPath: path))
        var cfg = SegmenterConfig()
        cfg.sampleRate = rate
        let us = mode == "ptt"
            ? run(x, cfg: cfg, chunk: chunk, press: Int(press * rate), release: Int(release * rate))
            : run(x, cfg: cfg, chunk: chunk)
        for (n, u) in us.enumerated() {
            let obj: [String: Any] = [
                "reason": u.reason, "start": u.seconds(u.startSample), "end": u.seconds(u.endSample),
                "speech_start": u.seconds(u.speechStartSample), "speech_end": u.seconds(u.speechEndSample),
                "preroll_ms": u.preRollMs, "tail_ms": u.tailMs, "index": n,
            ]
            let data = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
            print(String(data: data, encoding: .utf8)!)
            if let dir = outDir {
                try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                try WavIO.write16(u.samples, rate: rate, to: URL(fileURLWithPath: dir).appendingPathComponent("utt_\(n).wav"))
            }
        }
        return 0
    } catch {
        print("error: \(error)")
        return 1
    }
}

@main
struct SegmenterCLI {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        switch args.first ?? "selftest" {
        case "selftest": exit(selftest())
        case "segment": exit(segmentFile(Array(args.dropFirst())))
        default:
            print("usage: segmenter_cli selftest | segment FILE.wav ...")
            exit(2)
        }
    }
}
