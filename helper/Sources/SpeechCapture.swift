import AVFoundation
import Foundation
import Speech

/// Push-to-talk speech capture: start() on key down, stop() on release (a
/// `final` event follows), cancel() on a tap. Prefers on-device recognition.
final class SpeechCapture {
    private let recognizer: SFSpeechRecognizer?
    private let audio: AudioSource
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
    private var lastLevelSent = Date.distantPast
    private var timeoutWork: DispatchWorkItem?
    private var wantsStart = false
    /// Called on the main thread whenever a capture session ends (final sent or cancelled).
    var onIdle: (() -> Void)?

    init(localeId: String, allowServer: Bool, audio: AudioSource, send: @escaping ([String: Any]) -> Void) {
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeId)) ?? SFSpeechRecognizer()
        self.allowServer = allowServer
        self.audio = audio
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

    /// Hold ended: finish recognition and emit `final` (with a 2.5 s fallback).
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
        audio.remove(consumerId)
        request?.endAudio()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.emitFinal(self.lastPartial)
        }
        timeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
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
        if #available(macOS 13.0, *) {
            req.addsPunctuation = true
        }
        do {
            try audio.add(consumerId) { [weak self] buffer in
                req.append(buffer)
                self?.reportLevel(buffer)
            }
        } catch {
            send(["event": "error", "code": "no_input_device", "message": "No microphone input was found (\(error))."])
            onIdle?()
            return
        }
        request = req
        active = true
        stopping = false
        finalSent = false
        lastPartial = ""
        Log.debug("ptt capture started (on-device: \(req.requiresOnDeviceRecognition))")
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
        audio.remove(consumerId)
        if wasActive { onIdle?() }
    }

    private func reportLevel(_ buffer: AVAudioPCMBuffer) {
        let now = Date()
        guard now.timeIntervalSince(lastLevelSent) > 0.06 else { return }
        lastLevelSent = now
        send(["event": "level", "value": AudioSource.level(of: buffer)])
    }
}
