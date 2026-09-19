import Cocoa

final class HelperController {
    let options: Options
    let bridge: Bridge
    private let audio = AudioSource()
    private var hotKey: HotKey?
    private var speech: SpeechCapture?
    private var wake: WakeListener?
    private var keyDown = false
    private var keyDownTime = Date()
    private let tapThreshold: TimeInterval = 0.3

    init(options: Options) {
        self.options = options
        self.bridge = Bridge(port: options.port)
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
            if !self.options.noSpeech {
                let speech = SpeechCapture(localeId: self.options.locale, allowServer: self.options.allowServerSpeech, audio: self.audio) { [weak self] in
                    self?.bridge.send($0)
                }
                speech.onIdle = { [weak self] in self?.wake?.start() }
                self.speech = speech
                let wake = WakeListener(phrase: self.options.wakePhrase.isEmpty ? "hey filo" : self.options.wakePhrase,
                                        silenceMs: self.options.wakeSilenceMs,
                                        localeId: self.options.locale, allowServer: self.options.allowServerSpeech,
                                        audio: self.audio) { [weak self] in self?.bridge.send($0) }
                wake.detectWake = !self.options.wakePhrase.isEmpty
                self.wake = wake
                if wake.detectWake {
                    wake.start()
                    Log.info("wake word listening for '\(wake.phrase)'")
                }
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

    private func hotkeyLabel() -> String {
        return (options.mods + [options.key]).joined(separator: "+")
    }

    private func hotkeyChanged(pressed: Bool) {
        if pressed {
            guard !keyDown else { return }   // ignore key auto-repeat
            keyDown = true
            keyDownTime = Date()
            Log.info("hotkey down")
            bridge.send(["event": "hotkey_down"])
            wake?.stop()
            speech?.start()
        } else {
            guard keyDown else { return }
            keyDown = false
            let held = Date().timeIntervalSince(keyDownTime)
            let ms = Int(held * 1000)
            Log.info("hotkey up after \(ms) ms")
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
            wake?.stop()
        case "wake_resume":
            wake?.start()
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
