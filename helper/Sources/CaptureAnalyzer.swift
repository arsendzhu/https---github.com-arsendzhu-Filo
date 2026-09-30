import Foundation

/// Settings shared by the push-to-talk capture and the wake-word listener (set from launch flags and the
/// `set_vocab` command).
final class CaptureSettings {
    var pttTailMs: Double = 300
    var hangoverMs: Double = 900
    var vocabulary: [String] = []          // sent to every recognition request as contextualStrings
    var debugAudioDir: String = ""         // non-empty: every captured utterance is saved here as a 16 kHz WAV
    var debugAudioKeep: Int = 20
}

/// Debug audio dump: `logs/audio/utt_<time>_<label>.wav`, newest 20 kept. Off unless --debug-audio-dir is set;
/// nothing is written or kept otherwise.
final class AudioDump {
    private let dir: URL
    private let keep: Int
    static var shared: AudioDump?

    init?(path: String, keep: Int) {
        dir = URL(fileURLWithPath: path, isDirectory: true)
        self.keep = max(1, keep)
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) } catch { return nil }
    }

    func save(_ samples: [Float], rate: Double, label: String, note: String) {
        guard samples.count > Int(rate * 0.1) else { return }
        let x16 = Resampler.resample(samples, from: rate, to: 16_000)
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss_SSS"
        let name = "utt_\(f.string(from: Date()))_\(label).wav"
        do {
            try WavIO.write16(x16, rate: 16_000, to: dir.appendingPathComponent(name))
            Log.info(String(format: "audio dump: %@ %.2f s %@", name, Double(x16.count) / 16_000, note))
        } catch {
            Log.info("audio dump failed: \(error)")
            return
        }
        prune()
    }

    private func prune() {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        let old = files.filter { $0.hasPrefix("utt_") && $0.hasSuffix(".wav") }.sorted().dropLast(keep)
        for f in old { try? FileManager.default.removeItem(at: dir.appendingPathComponent(f)) }
    }
}

/// Watches the audio of one capture (or one wake session) off the audio thread: voice-activity detection
/// (its start/end times are logged per utterance), how long it has been quiet (the end-of-question signal),
/// and - only when the debug dump is on - the raw audio.
final class CaptureAnalyzer {
    /// Background level learned from earlier captures, so a capture that starts with speech is not
    /// mistaken for a noisy room.
    private static var roomFloor = 0.004

    let label: String
    private let lock = NSLock()
    private var seg: UtteranceSegmenter?
    private var rate = 0.0
    private var recorder: [Float] = []
    private var markIndex = 0
    private var lastVoice = Date.distantPast
    private var voiceSeen = false
    private var vadStart: Double?
    private var vadEnd: Double?
    private let hangoverMs: Double

    init(label: String, hangoverMs: Double) {
        self.label = label
        self.hangoverMs = hangoverMs
    }

    /// dsp queue
    func feed(_ x: [Float], rate: Double) {
        lock.lock()
        defer { lock.unlock() }
        if seg == nil || rate != self.rate {
            var cfg = SegmenterConfig()
            cfg.sampleRate = rate
            cfg.hangoverMs = hangoverMs
            cfg.calibrationMs = 0
            cfg.initialFloorRms = CaptureAnalyzer.roomFloor
            seg = UtteranceSegmenter(cfg)
            self.rate = rate
        }
        if AudioDump.shared != nil {
            recorder.append(contentsOf: x)
            let cap = Int(rate * 25)
            if recorder.count > cap {
                let drop = recorder.count - cap
                recorder.removeFirst(drop)
                markIndex = max(0, markIndex - drop)
            }
        }
        for e in seg!.feed(x) {
            switch e {
            case .vadStart(let t):
                vadStart = t
                Log.debug(String(format: "vad[%@] speech starts at %.2f s", label, t))
            case .vadEnd(let t):
                vadEnd = t
                Log.debug(String(format: "vad[%@] speech ends at %.2f s", label, t))
            case .utterance:
                break
            }
        }
        if seg!.msSinceSpeech < 100 {
            lastVoice = Date()
            voiceSeen = true
        }
    }

    /// Main thread. Seconds since the VAD last heard speech; large until any was heard.
    var silenceSeconds: Double {
        lock.lock()
        defer { lock.unlock() }
        return voiceSeen ? Date().timeIntervalSince(lastVoice) : 999
    }

    /// The capture proper starts now (the wake phrase was heard): what the dump keeps starts about a second before.
    func markCaptureStart() {
        lock.lock()
        markIndex = max(0, recorder.count - Int(rate * 1.0))
        vadStart = nil
        vadEnd = nil
        lock.unlock()
    }

    /// The capture is over: log the VAD summary, write the debug WAV, remember the room's noise level.
    func finish(note: String) {
        lock.lock()
        let samples = Array(recorder[min(markIndex, recorder.count)...])
        let r = rate
        let start = vadStart, end = vadEnd
        let floor = seg?.noiseFloor
        recorder.removeAll()
        markIndex = 0
        lock.unlock()
        if let f = floor { CaptureAnalyzer.roomFloor = 0.5 * CaptureAnalyzer.roomFloor + 0.5 * min(0.02, f) }
        let span = (start != nil && end != nil) ? String(format: "vad speech %.2f-%.2f s", start!, end!) : "no speech seen by the VAD"
        Log.info("capture[\(label)] finished: \(span) \(note)")
        AudioDump.shared?.save(samples, rate: r, label: label, note: "\(span) \(note)")
    }
}

enum Endpointing {
    /// Words that almost never end a sentence: when the transcript stops on one, the player is mid-thought.
    static let dangling: Set<String> = [
        "and", "or", "but", "the", "a", "an", "of", "in", "on", "at", "to", "for", "with", "from", "by", "about",
        "is", "are", "was", "were", "what", "which", "who", "how", "where", "when", "why", "my", "your", "his", "her",
        "its", "their", "that", "this", "if", "so", "because", "then", "than", "as", "do", "does", "did", "can",
        "could", "should", "would", "will", "uh", "um", "hmm", "like", "into", "onto", "against", "after", "before",
    ]

    static func looksIncomplete(_ transcript: String) -> Bool {
        let last = transcript.lowercased().split(whereSeparator: { !$0.isLetter && $0 != "'" }).last.map(String.init) ?? ""
        return dangling.contains(last)
    }

    /// Whether the question is over: enough measured silence *and* a transcript that has stopped changing.
    /// A transcript that ends on a dangling word ("... how do I beat the") gets extra time.
    static func questionIsOver(silenceMs: Double, transcriptIdleMs: Double, transcript: String, hangoverMs: Double) -> Bool {
        let extra = looksIncomplete(transcript) ? 700.0 : 0.0
        return silenceMs >= hangoverMs + extra && transcriptIdleMs >= 700 + extra * 0.5
    }
}
