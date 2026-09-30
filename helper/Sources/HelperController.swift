import AVFoundation
import Cocoa

final class HelperController {
    let options: Options
    let bridge: Bridge
    private let audio: AudioSource
    private let settings = CaptureSettings()
    private var hotKey: HotKey?
    private var speech: SpeechCapture?
    private var wake: WakeListener?
    private var muteHotKey: HotKey?
    private var micMuted = false
    private var filoSpeaking = false
    private var frontApp: NSRunningApplication?    // the last app that was in front and is not Filo (the game)
    private var savedFront: NSRunningApplication?  // what focus_save recorded, given back by focus_restore
    private var keyDown = false
    private var keyDownTime = Date()
    private let tapThreshold: TimeInterval = 0.3

    init(options: Options) {
        self.options = options
        self.bridge = Bridge(port: options.port)
        self.audio = AudioSource(preRollMs: options.preRollMs)
        settings.pttTailMs = options.pttTailMs
        settings.hangoverMs = options.hangoverMs
        settings.debugAudioDir = options.debugAudioDir
        settings.debugAudioKeep = options.debugAudioKeep
        if !options.debugAudioDir.isEmpty {
            AudioDump.shared = AudioDump(path: options.debugAudioDir, keep: options.debugAudioKeep)
            Log.info("debug audio dump ON: \(options.debugAudioDir) (newest \(options.debugAudioKeep) kept)")
        }
    }

    func start() {
        bridge.onLine = { [weak self] dict in self?.handle(command: dict) }
        bridge.onDisconnect = {
            Log.info("Filo disconnected — exiting")
            exit(0)
        }
        Log.info("connecting to Filo on 127.0.0.1:\(options.port)")
        bridge.connect { [weak self] ok in
            guard let self = self else { return }
            guard ok else {
                Log.info("could not connect to Filo on port \(self.options.port) — exiting")
                exit(1)
            }
            Log.info("connected")
            self.setupHotkey()
            self.setupMuteHotkey()
            self.trackFrontApp()
            if !self.options.noSpeech {
                let speech = SpeechCapture(localeId: self.options.locale, allowServer: self.options.allowServerSpeech, audio: self.audio, settings: self.settings) { [weak self] in
                    self?.bridge.send($0)
                }
                speech.onIdle = { [weak self] in self?.wake?.start() }
                self.speech = speech
                let wake = WakeListener(phrase: self.options.wakePhrase.isEmpty ? "hey filo" : self.options.wakePhrase,
                                        silenceMs: self.options.wakeSilenceMs,
                                        localeId: self.options.locale, allowServer: self.options.allowServerSpeech,
                                        audio: self.audio, settings: self.settings) { [weak self] in self?.bridge.send($0) }
                wake.detectWake = !self.options.wakePhrase.isEmpty
                self.wake = wake
                if wake.detectWake {
                    wake.start()
                    Log.info("wake word listening for '\(wake.phrase)'")
                }
                self.enableWarmIfPossible()
            }
            self.sendReady()
            self.sendApps()
        }
    }

    private func setupHotkey() {
        guard let keyCode = KeyCodes.code(for: options.key) else {
            bridge.send(["event": "error", "code": "hotkey_unknown_key", "message": "Unknown hotkey key '\(options.key)' in config.json."])
            return
        }
        let mods = KeyCodes.modifiers(for: options.mods)
        hotKey = HotKey(keyCode: keyCode, modifiers: mods) { [weak self] pressed in
            self?.hotkeyChanged(pressed: pressed)
        }
        if hotKey == nil {
            bridge.send(["event": "error", "code": "hotkey_register_failed",
                         "message": "Could not register the hotkey \(hotkeyLabel()). Another app may already use it — change \"hotkey\" in config.json."])
        } else {
            Log.info("hotkey registered: \(hotkeyLabel())")
        }
    }

    /// The microphone engine may idle "warm" (so the last ~450 ms of audio is always buffered) only while the
    /// wake word keeps it on anyway, the user has not muted, and Filo is not speaking (it must never hear itself).
    private func enableWarmIfPossible() {
        let allowed = options.keepWarm && (wake?.detectWake ?? false) && !micMuted && !filoSpeaking
            && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        audio.setKeepWarm(allowed)
    }

    /// Backup for the mute button: toggles the microphone from anywhere, even with the overlay unclickable.
    private func setupMuteHotkey() {
        guard !options.muteKey.isEmpty, let code = KeyCodes.code(for: options.muteKey) else { return }
        muteHotKey = HotKey(id: 2, keyCode: code, modifiers: KeyCodes.modifiers(for: options.muteMods)) { [weak self] pressed in
            guard pressed, let self = self else { return }
            self.setMuted(!self.micMuted, source: "hotkey")
        }
        if muteHotKey == nil {
            Log.info("could not register the mute hotkey")
        } else {
            Log.info("mute hotkey registered: \((options.muteMods + [options.muteKey]).joined(separator: "+"))")
        }
    }

    /// Microphone off/on. Muted = no wake listening, no push-to-talk capture, the audio engine stopped
    /// (so macOS' orange microphone indicator goes away). Always acknowledged with `mute_state`.
    private func setMuted(_ muted: Bool, source: String) {
        micMuted = muted
        wake?.micMuted = muted
        speech?.micMuted = muted
        if muted {
            speech?.cancel()
            wake?.stop()
            audio.suspend()          // engine off and the buffered audio dropped: nothing is kept while muted
        } else {
            audio.resume()
            wake?.start()
            enableWarmIfPossible()
        }
        Log.info("microphone \(muted ? "muted" : "unmuted") (\(source))")
        bridge.send(["event": "mute_state", "muted": muted, "source": source])
    }

    // MARK: focus hand-back for the typed-question box

    private func trackFrontApp() {
        func consider(_ app: NSRunningApplication?) {
            guard let app = app, app.activationPolicy == .regular else { return }
            let me = ProcessInfo.processInfo.processIdentifier
            if app.processIdentifier == me || app.processIdentifier == options.parentPid { return }
            frontApp = app
        }
        consider(NSWorkspace.shared.frontmostApplication)
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            consider(note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
        }
    }

    private func hotkeyLabel() -> String {
        return (options.mods + [options.key]).joined(separator: "+")
    }

    private func hotkeyChanged(pressed: Bool) {
        if pressed {
            guard !keyDown else { return }   // ignore key auto-repeat
            keyDown = true
            keyDownTime = Date()
            Log.info("hotkey down")
            if micMuted { return }   // muted: nothing to listen for; a tap still opens the typed box
            bridge.send(["event": "hotkey_down"])
            wake?.stop()
            speech?.start()
        } else {
            guard keyDown else { return }
            keyDown = false
            let held = Date().timeIntervalSince(keyDownTime)
            let ms = Int(held * 1000)
            Log.info("hotkey up after \(ms) ms")
            if micMuted {
                if held < tapThreshold {
                    bridge.send(["event": "tap", "duration_ms": ms])
                } else {
                    bridge.send(["event": "error", "code": "muted",
                                 "message": "The microphone is muted. Click the mic button to unmute, or tap the key to type."])
                }
                return
            }
            if held < tapThreshold {
                speech?.cancel()
                bridge.send(["event": "tap", "duration_ms": ms])
                if speech == nil || !(speech?.active ?? false) { wake?.start() }
            } else {
                bridge.send(["event": "hotkey_up", "duration_ms": ms])
                if let speech = speech {
                    speech.stop()
                } else {
                    bridge.send(["event": "final", "text": ""])
                }
            }
        }
    }

    private func sendReady() {
        bridge.send([
            "event": "ready",
            "hotkey": hotkeyLabel(),
            "hotkey_registered": hotKey != nil,
            "wake_word": (wake?.detectWake ?? false) ? (wake?.phrase ?? "") : "",
            "follow_up": speech != nil,
            "speech": speech?.statusInfo() ?? ["enabled": false],
            "pid": Int(ProcessInfo.processInfo.processIdentifier),
        ])
    }

    private func sendApps() {
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .map { ["name": $0.localizedName ?? "", "bundle_id": $0.bundleIdentifier ?? ""] }
        bridge.send(["event": "apps", "apps": apps])
    }

    private func handle(command dict: [String: Any]) {
        switch dict["cmd"] as? String ?? "" {
        case "ping":
            bridge.send(["event": "pong"])
        case "list_apps":
            sendApps()
        case "wake_pause":
            // Fully stop (not just soft-pause) while Filo speaks: with no
            // acoustic echo cancellation on a laptop mic+speakers, a session
            // left running would otherwise keep transcribing Filo's own
            // voice the whole time it talks. wake_resume starts a clean,
            // fresh session right after, which is simple and race-free.
            filoSpeaking = true
            audio.setKeepWarm(false)
            audio.clearPreRoll()      // never replay Filo's own voice into the next request
            wake?.stop()
        case "wake_resume":
            filoSpeaking = false
            wake?.start()
            enableWarmIfPossible()
        case "set_vocab":
            if let words = dict["words"] as? [String] {
                settings.vocabulary = Array(words.filter { !$0.isEmpty }.prefix(100))
                Log.info("vocabulary hints: \(settings.vocabulary.count) words")
            }
        case "listen_open":
            let ms = (dict["timeout_ms"] as? Int) ?? (Int((dict["timeout_ms"] as? Double) ?? 30000))
            if let wake = wake {
                wake.listenOpen(timeout: Double(ms) / 1000.0)
            } else {
                bridge.send(["event": "listen_timeout", "reason": "no_speech"])
            }
        case "listen_stop":
            wake?.cancelCapture()
        case "set_wake":
            if let on = dict["enabled"] as? Bool {
                if on { wake?.start() } else { wake?.stop() }
            }
        case "set_mute":
            if let m = dict["muted"] as? Bool { setMuted(m, source: "command") }
        case "focus_save":
            savedFront = frontApp
            Log.debug("focus saved: \(frontApp?.localizedName ?? "none")")
        case "focus_restore":
            let target = savedFront ?? frontApp
            savedFront = nil
            if let app = target, !app.isTerminated {
                Log.info("giving focus back to \(app.localizedName ?? "the game")")
                app.activate(options: [.activateIgnoringOtherApps])
            }
        case "quit":
            Log.info("quit requested")
            exit(0)
        case "simulate_hotkey":   // test hook: {"cmd":"simulate_hotkey","pressed":true}
            if let p = dict["pressed"] as? Bool { hotkeyChanged(pressed: p) }
        default:
            break
        }
    }
}
