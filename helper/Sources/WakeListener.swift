import AVFoundation
import Foundation
import Speech

/// Always-on "hey filo" listening with on-device speech recognition. After the
/// wake phrase it keeps transcribing until the player goes quiet, then sends
/// the question as `final`. Sessions are restarted regularly to keep
/// transcripts short, and fully stopped (not just muted) while Filo itself is
/// speaking so it can never hear its own voice; macOS shows its orange
/// microphone indicator whenever a session is actually running.
final class WakeListener {
    static let maxSession: TimeInterval = 55
    static let noSpeechTimeout: TimeInterval = 5
    static let maxQuestion: TimeInterval = 15

    private let recognizer: SFSpeechRecognizer?
    private let audio: AudioSource
    private let matcher: WakeMatcher
    private let silence: TimeInterval
    private let allowServer: Bool
    private let settings: CaptureSettings
    private var analyzer: CaptureAnalyzer?
    private let send: ([String: Any]) -> Void
    private let consumerId = UUID()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var sessionActive = false
    private var enabled = false
    private var capturing = false
    private var captureFrom = 0
    private var scanned = 0
    private var lastTokenCount = 0
    private var lastQuestion = ""
    private var lastChange = Date()
    private var captureStarted = Date()
    private var sessionStarted = Date()
    private var ticker: Timer?
    private var restartWork: DispatchWorkItem?
    private var failures = 0
    private var openListening = false
    private var noSpeechTimeout: TimeInterval = WakeListener.noSpeechTimeout
    // No pause()/resume(): wake_pause/wake_resume now fully stop() and
    // start() the session (see HelperController) so a session is never left
    // running — and picking up Filo's own voice — while it speaks.
    /// false = no wake phrase; sessions only run while open listening is requested
    var detectWake = true
    /// Microphone muted by the user: no session may start until it is cleared.
    var micMuted = false

    var phrase: String { matcher.phrase }
    var isCapturing: Bool { capturing }

    init(phrase: String, silenceMs: Int, localeId: String, allowServer: Bool, audio: AudioSource, settings: CaptureSettings, send: @escaping ([String: Any]) -> Void) {
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeId)) ?? SFSpeechRecognizer()
        matcher = WakeMatcher(phrase: phrase)
        silence = Double(max(silenceMs, 400)) / 1000.0
        self.allowServer = allowServer
        self.audio = audio
        self.settings = settings
        self.send = send
    }

    // MARK: - control

    /// Starts wake-phrase listening (no-op when the wake word is disabled).
    func start() {
        guard detectWake, !micMuted else { return }
        enabled = true
        guard !sessionActive else { return }
        guard let recognizer = recognizer, recognizer.isAvailable else {
            send(["event": "error", "code": "speech_unavailable", "message": "Speech recognition isn't available, so the wake word is off. The hotkey still works for typing."])
            enabled = false
            return
        }
        Permissions.request { [weak self] ok, code, message in
            guard let self = self, self.enabled else { return }
            guard ok else {
                self.enabled = false
                self.send(["event": "error", "code": code, "message": message])
                return
            }
            self.beginSession(recognizer)
        }
    }

    /// Stops listening (push-to-talk takes the microphone, or wake word disabled).
    func stop() {
        enabled = false
        openListening = false
        restartWork?.cancel()
        restartWork = nil
        endSession()
    }

    /// Filo just asked "anything else?": capture the next thing said without a
    /// wake phrase. Sends `partial`/`final`, or `listen_timeout` after `timeout`
    /// seconds of silence, or `bye` if the player says goodbye.
    func listenOpen(timeout: TimeInterval) {
        guard !micMuted else {
            send(["event": "listen_timeout", "reason": "muted"])
            return
        }
        enabled = true
        guard let recognizer = recognizer, recognizer.isAvailable else {
            send(["event": "listen_timeout", "reason": "speech_unavailable"])
            return
        }
        if sessionActive {
            beginOpenCapture(timeout)
            return
        }
        Permissions.request { [weak self] ok, code, message in
            guard let self = self, self.enabled else { return }
            guard ok else {
                self.send(["event": "error", "code": code, "message": message])
                self.send(["event": "listen_timeout", "reason": code])
                return
            }
            self.beginSession(recognizer)
            self.beginOpenCapture(timeout)
        }
    }

    /// Back to plain wake-word listening (or idle when the wake word is off).
    func cancelCapture() {
        guard capturing else { return }
        capturing = false
        openListening = false
        noSpeechTimeout = WakeListener.noSpeechTimeout
        if !detectWake {
            stop()
        }
    }

    private func beginOpenCapture(_ timeout: TimeInterval) {
        analyzer?.markCaptureStart()
        capturing = true
        openListening = true
        captureFrom = lastTokenCount
        scanned = lastTokenCount
        captureStarted = Date()
        lastChange = Date()
        lastQuestion = ""
        noSpeechTimeout = max(timeout, 2.0)
        Log.info("open listening for \(Int(noSpeechTimeout)) s")
    }

    // MARK: - session

    private func beginSession(_ recognizer: SFSpeechRecognizer) {
        endSession()
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition && !allowServer {
            req.requiresOnDeviceRecognition = true
        }
        req.taskHint = .dictation
        // the wake phrase itself, and the game's vocabulary, as hints for the recogniser
        req.contextualStrings = Array(([matcher.phrase, "bye filo", "hey filo"] + settings.vocabulary).prefix(100))
        if #available(macOS 13.0, *) {
            req.addsPunctuation = true
        }
        let an = CaptureAnalyzer(label: "wake", hangoverMs: settings.hangoverMs)
        var lastLevel = Date.distantPast
        do {
            // The pre-roll replay means a session restart (every 55 s, after each question) does not drop the
            // words spoken while the recogniser was being set up. live = request.append only (audio thread);
            // levels, VAD and the debug dump run on the analysis queue.
            try audio.add(consumerId, preRoll: true, { buffer in
                req.append(buffer)
            }, dsp: { [weak self] samples, rate in
                an.feed(samples, rate: rate)
                guard let self = self, self.capturing else { return }
                let now = Date()
                if now.timeIntervalSince(lastLevel) > 0.06 {
                    lastLevel = now
                    self.send(["event": "level", "value": AudioSource.level(of: samples)])
                }
            })
        } catch {
            send(["event": "error", "code": "no_input_device", "message": "No microphone input was found, so the wake word is off."])
            enabled = false
            return
        }
        request = req
        analyzer = an
        sessionActive = true
        sessionStarted = Date()
        scanned = 0
        lastTokenCount = 0
        capturing = false
        lastQuestion = ""
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            DispatchQueue.main.async { self?.handle(result: result, error: error) }
        }
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.tick() }
        Log.debug("wake session started (on-device: \(req.requiresOnDeviceRecognition))")
    }

    private func endSession() {
        ticker?.invalidate()
        ticker = nil
        audio.remove(consumerId)
        analyzer = nil
        task?.cancel()
        task = nil
        request = nil
        sessionActive = false
        capturing = false
    }

    private func scheduleRestart(after delay: TimeInterval) {
        guard enabled else { return }
        restartWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.enabled, !self.sessionActive, let r = self.recognizer else { return }
            self.beginSession(r)
        }
        restartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func handle(result: SFSpeechRecognitionResult?, error: Error?) {
        guard sessionActive else { return }
        if let result = result {
            let words = result.bestTranscription.formattedString.split(separator: " ").map(String.init)
            let norm = words.map(WakeMatcher.normalize)
            lastTokenCount = norm.count
            if !capturing {
                if matcher.matchBye(norm, from: scanned) {
                    Log.info("bye heard (wake mode)")
                    audio.clearPreRoll()
                    scanned = norm.count
                    send(["event": "bye"])
                    return
                }
                if let idx = matcher.match(norm, from: scanned) {
                    analyzer?.markCaptureStart()
                    capturing = true
                    captureFrom = idx
                    captureStarted = Date()
                    lastChange = Date()
                    lastQuestion = ""
                    Log.info("wake word heard")
                    send(["event": "wake_word", "phrase": matcher.phrase])
                } else {
                    scanned = max(scanned, norm.count - 3)
                }
            }
            if capturing {
                let q = words.count > captureFrom ? words[captureFrom...].joined(separator: " ") : ""
                if norm.count > captureFrom && matcher.matchBye(Array(norm[captureFrom...]), from: 0) {
                    Log.info("bye heard (capture)")
                    audio.clearPreRoll()
                    capturing = false
                    openListening = false
                    send(["event": "bye"])
                    endSession()
                    if detectWake { scheduleRestart(after: 0.3) }
                    return
                }
                if q != lastQuestion {
                    lastQuestion = q
                    lastChange = Date()
                    if !q.isEmpty { send(["event": "partial", "text": q]) }
                }
            }
            if result.isFinal {
                if capturing {
                    finish(lastQuestion)
                } else {
                    endSession()
                    failures = 0
                    scheduleRestart(after: 0.2)
                }
                return
            }
        }
        if let error = error as NSError? {
            if error.code == 216 { return }   // cancelled by us
            Log.debug("wake session error \(error.domain) \(error.code): \(error.localizedDescription)")
            if capturing {
                finish(lastQuestion)
            } else {
                endSession()
                failures += 1
                scheduleRestart(after: min(5.0, 0.5 * Double(failures)))
            }
        }
    }

    private func tick() {
        guard sessionActive else { return }
        let now = Date()
        if capturing {
            let idleMs = now.timeIntervalSince(lastChange) * 1000
            let incomplete = Endpointing.looksIncomplete(lastQuestion)
            let vadKnown = (analyzer?.silenceSeconds ?? 999) < 900   // the VAD has heard the player; otherwise fall back to the transcript alone
            let over = vadKnown && Endpointing.questionIsOver(silenceMs: (analyzer?.silenceSeconds ?? 0) * 1000, transcriptIdleMs: idleMs,
                                                              transcript: lastQuestion, hangoverMs: settings.hangoverMs)
            if !lastQuestion.isEmpty && (over || idleMs >= (silence + (incomplete ? 1.0 : 0)) * 1000) {
                Log.info(String(format: "question over: vad silence %.2f s, transcript idle %.2f s%@", analyzer?.silenceSeconds ?? -1, idleMs / 1000, incomplete ? " (ended on a dangling word)" : ""))
                finish(lastQuestion)
            } else if lastQuestion.isEmpty && now.timeIntervalSince(captureStarted) >= noSpeechTimeout {
                if openListening {
                    Log.info("open listening timed out")
                    capturing = false
                    openListening = false
                    noSpeechTimeout = WakeListener.noSpeechTimeout
                    send(["event": "listen_timeout", "reason": "silence"])
                    if !detectWake { stop() }
                } else {
                    finish("")
                }
            } else if now.timeIntervalSince(captureStarted) >= WakeListener.maxQuestion + (openListening ? noSpeechTimeout : 0) {
                finish(lastQuestion)
            }
        } else if now.timeIntervalSince(sessionStarted) >= WakeListener.maxSession {
            endSession()
            scheduleRestart(after: 0.1)
        }
    }

    private func finish(_ text: String) {
        capturing = false
        openListening = false
        noSpeechTimeout = WakeListener.noSpeechTimeout
        Log.info("wake final: \(text)")
        send(["event": "final", "text": text])
        let an = analyzer
        audio.core.dspQueue.async { an?.finish(note: "transcript '\(text)'") }
        audio.clearPreRoll()      // the restarted session must not hear the question again
        endSession()
        failures = 0
        if detectWake {
            scheduleRestart(after: 0.3)
        } else {
            enabled = false
        }
    }

}
