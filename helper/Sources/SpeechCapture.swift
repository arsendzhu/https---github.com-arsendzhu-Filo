import AVFoundation
import Foundation
import Speech

/// Push-to-talk speech capture: start() on key down, stop() on release (a `final` event follows),
/// cancel() on a tap. Prefers on-device recognition.
///
/// Audio timing (the "parts of my speech are missing" fix):
///  - the request starts with the ~450 ms of audio that was in the ring *before* the key went down, so a
///    player who starts talking as they press does not lose the first syllables;
///  - after the key is released the microphone keeps feeding the request for `pttTailMs` (300 ms), so the
///    last word is not cut off;
///  - the level meter and analysis run off the audio thread.
final class SpeechCapture {
    private let recognizer: SFSpeechRecognizer?
    private let audio: AudioSource
    private let settings: CaptureSettings
    private let consumerId = UUID()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let allowServer: Bool
    private let send: ([String: Any]) -> Void
    private(set) var active = false
    /// Microphone muted by the user: a capture session may not start.
    var micMuted = false
    private var stopping = false
    private var finalSent = false
    private var lastPartial = ""
    private var timeoutWork: DispatchWorkItem?
    private var tailWork: DispatchWorkItem?
    private var analyzer: CaptureAnalyzer?
    private var startedAt = Date()
    private var wantsStart = false
    /// Called on the main thread whenever a capture session ends (final sent or cancelled).
    var onIdle: (() -> Void)?

    init(localeId: String, allowServer: Bool, audio: AudioSource, settings: CaptureSettings, send: @escaping ([String: Any]) -> Void) {
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeId)) ?? SFSpeechRecognizer()
        self.allowServer = allowServer
        self.audio = audio
        self.settings = settings
        self.send = send
    }

    func statusInfo() -> [String: Any] {
        return [
            "enabled": true,
            "available": recognizer?.isAvailable ?? false,
            "on_device": recognizer?.supportsOnDeviceRecognition ?? false,
            "speech_auth": Permissions.name(SFSpeechRecognizer.authorizationStatus()),
            "mic_auth": Permissions.name(AVCaptureDevice.authorizationStatus(for: .audio)),
        ]
    }

    // MARK: - lifecycle

    func start() {
        guard !active, !micMuted else { return }
        wantsStart = true
        guard let recognizer = recognizer, recognizer.isAvailable else {
            send(["event": "error", "code": "speech_unavailable",
                  "message": "Speech recognition isn't available on this Mac right now. Tap the key to type instead."])
            return
        }
        Permissions.request { [weak self] ok, code, message in
            guard let self = self else { return }
            guard ok else {
                self.wantsStart = false
                self.send(["event": "error", "code": code, "message": message])
                return
            }
            guard self.wantsStart else {
                // The key was released while a permission dialog was up.
                self.send(["event": "error", "code": "retry", "message": "Permissions granted — hold the key and ask again."])
                return
            }
            self.begin(recognizer)
        }
    }

    /// Hold ended: keep listening for the tail, then finish recognition and emit `final` (2.5 s fallback).
    func stop() {
        wantsStart = false
        guard active else {
            send(["event": "final", "text": lastPartial])
            lastPartial = ""
            onIdle?()
            return
        }
        guard !stopping else { return }
        stopping = true
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.active else { return }   // a tap may have cancelled during the tail
            self.audio.remove(self.consumerId)
            self.request?.endAudio()
            let fallback = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                self.emitFinal(self.lastPartial)
            }
            self.timeoutWork = fallback
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: fallback)
        }
        tailWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, settings.pttTailMs) / 1000.0, execute: work)
    }

    /// Tap: discard whatever was captured.
    func cancel() {
        wantsStart = false
        guard active else { return }
        task?.cancel()
        cleanup()
    }

    // MARK: - internals

    private func begin(_ recognizer: SFSpeechRecognizer) {
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition && !allowServer {
            req.requiresOnDeviceRecognition = true
        }
        req.taskHint = .search
        if !settings.vocabulary.isEmpty {
            req.contextualStrings = Array(settings.vocabulary.prefix(100))
        }
        if #available(macOS 13.0, *) {
            req.addsPunctuation = true
        }
        let an = CaptureAnalyzer(label: "ptt", hangoverMs: settings.hangoverMs)
        var lastLevel = Date.distantPast
        do {
            // live: only request.append on the audio thread; dsp (levels, VAD, dump) on the analysis queue
            try audio.add(consumerId, preRoll: true, { buffer in
                req.append(buffer)
            }, dsp: { [weak self] samples, rate in
                an.feed(samples, rate: rate)
                let now = Date()
                if now.timeIntervalSince(lastLevel) > 0.06 {
                    lastLevel = now
                    self?.send(["event": "level", "value": AudioSource.level(of: samples)])
                }
            })
        } catch {
            send(["event": "error", "code": "no_input_device", "message": "No microphone input was found (\(error))."])
            onIdle?()
            return
        }
        analyzer = an
        request = req
        active = true
        stopping = false
        finalSent = false
        lastPartial = ""
        startedAt = Date()
        Log.debug("ptt capture started (on-device: \(req.requiresOnDeviceRecognition), \(Int(audio.core.preRollMs)) ms pre-roll, \(req.contextualStrings.count) hint words)")
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            DispatchQueue.main.async { self?.handle(result: result, error: error) }
        }
    }

    private func handle(result: SFSpeechRecognitionResult?, error: Error?) {
        guard active else { return }
        if let result = result {
            let text = result.bestTranscription.formattedString
            if result.isFinal {
                emitFinal(text)
                return
            }
            if text != lastPartial {
                lastPartial = text
                send(["event": "partial", "text": text])
            }
        }
        if let error = error as NSError? {
            Log.debug("ptt recognition error \(error.domain) \(error.code): \(error.localizedDescription)")
            if error.code == 216 { return }   // cancelled by us
            if stopping || error.code == 1110 {   // 1110: no speech detected
                emitFinal(lastPartial)
            } else {
                send(["event": "error", "code": "recognition", "message": "Speech recognition failed: \(error.localizedDescription)"])
                cleanup()
            }
        }
    }

    private func emitFinal(_ text: String) {
        guard !finalSent else { return }
        finalSent = true
        timeoutWork?.cancel()
        timeoutWork = nil
        Log.info("ptt final: \(text)")
        send(["event": "final", "text": text])
        task?.cancel()
        cleanup()
    }

    private func cleanup() {
        let wasActive = active
        active = false
        stopping = false
        request = nil
        task = nil
        timeoutWork?.cancel()
        timeoutWork = nil
        tailWork?.cancel()
        tailWork = nil
        audio.remove(consumerId)
        if wasActive {
            let an = analyzer
            let note = String(format: "held %.1f s, transcript '%@'", Date().timeIntervalSince(startedAt), lastPartial)
            audio.core.dspQueue.async { an?.finish(note: note) }   // after the last audio chunk was analysed
            analyzer = nil
            onIdle?()
        }
    }
}
