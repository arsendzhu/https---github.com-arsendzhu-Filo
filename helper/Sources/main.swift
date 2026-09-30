// Filo Helper — the only macOS-specific process in Phase 0.
// Provides what a Godot overlay cannot do by itself on macOS:
//   1. a global push-to-talk hotkey (Carbon RegisterEventHotKey, no Accessibility permission needed)
//   2. on-device speech recognition while the key is held (Speech framework)
//   3. the list of running apps, for game detection
// It talks to the Godot app over a localhost TCP socket with newline-delimited JSON.
import Cocoa

struct Options {
    var port: Int = 47821
    var key = "space"
    var mods: [String] = ["option"]
    var allowServerSpeech = false
    var locale = "en-US"
    var noSpeech = false
    var verbose = false
    var wakePhrase = ""          // empty = wake word off
    var wakeSilenceMs = 1500
    var testMatcher = false
    var muteKey = ""             // empty = no mute hotkey
    var muteMods: [String] = []
    var parentPid: Int32 = 0     // Filo's own process, never treated as "the game" when giving focus back
}

func parseOptions() -> Options {
    var o = Options()
    let args = Array(CommandLine.arguments.dropFirst())
    var i = 0
    func next() -> String? {
        i += 1
        return i < args.count ? args[i] : nil
    }
    while i < args.count {
        switch args[i] {
        case "--port": if let v = next(), let p = Int(v) { o.port = p }
        case "--key": if let v = next() { o.key = v }
        case "--mods":
            if let v = next() {
                o.mods = v.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            }
        case "--locale": if let v = next() { o.locale = v }
        case "--allow-server-speech": o.allowServerSpeech = true
        case "--no-speech": o.noSpeech = true
        case "--verbose": o.verbose = true
        case "--wake-word": if let v = next() { o.wakePhrase = v }
        case "--wake-silence-ms": if let v = next(), let ms = Int(v) { o.wakeSilenceMs = ms }
        case "--test-matcher": o.testMatcher = true
        case "--mute-key": if let v = next() { o.muteKey = v }
        case "--mute-mods":
            if let v = next() {
                o.muteMods = v.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            }
        case "--parent-pid": if let v = next(), let p = Int32(v) { o.parentPid = p }
        default: break   // ignore LaunchServices args such as -psn_...
        }
        i += 1
    }
    return o
}

let options = parseOptions()
Log.verbose = options.verbose
if options.testMatcher {
    print("wake matcher self-test:")
    let failures = WakeMatcher.selfTest()
    print(failures == 0 ? "all matcher checks passed" : "\(failures) matcher checks failed")
    exit(failures == 0 ? 0 : 1)
}
Log.setupFile()
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = HelperController(options: options)
controller.start()
app.run()
