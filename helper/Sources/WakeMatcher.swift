import Foundation

/// Finds the wake phrase ("hey filo") in a live transcript. Speech recognisers
/// spell an invented name many ways, so the name matches a set of sound-alikes
/// and must follow a trigger word ("hey", "okay", ...) to avoid false wakes.
struct WakeMatcher {
    let phrase: String
    let triggers: Set<String>
    let names: Set<String>
    let merged: Set<String>
    let byeWords: Set<String> = ["bye", "goodbye", "byebye", "cya", "later", "farewell", "goodnight"]

    init(phrase: String) {
        let lower = phrase.lowercased()
        self.phrase = lower
        let parts = lower.split(separator: " ").map { WakeMatcher.normalize(String($0)) }.filter { !$0.isEmpty }
        let name = parts.last ?? "filo"
        var triggers: Set<String> = ["hey", "hay", "hei", "hi", "ok", "okay", "yo", "oi"]
        if parts.count >= 2 { triggers.insert(parts[0]) }
        self.triggers = triggers
        var names: Set<String> = [name]
        if name == "filo" {
            names.formUnion(["philo", "fillo", "phillo", "fila", "phila", "feelo", "feelow", "fellow", "phyllo",
                             "filho", "fielo", "philow", "file", "phil", "fil", "fillow", "fileo", "filoh", "philoh",
                             "vilo", "thilo", "hilo", "fido", "phylo", "fyllo", "pilo"])
        }
        self.names = names
        self.merged = Set(triggers.map { $0 + name })
    }

    static func normalize(_ token: String) -> String {
        return String(token.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    /// Index just past the name token of the first match at or after `from`, or nil.
    func match(_ tokens: [String], from: Int) -> Int? {
        var i = max(from, 0)
        while i < tokens.count {
            if i + 1 < tokens.count && triggers.contains(tokens[i]) && names.contains(tokens[i + 1]) {
                return i + 2
            }
            if merged.contains(tokens[i]) {
                return i + 1
            }
            i += 1
        }
        return nil
    }

    /// True when "bye filo" / "goodbye filo" / "filo bye" appears at or after `from`.
    func matchBye(_ tokens: [String], from: Int) -> Bool {
        var i = max(from, 0)
        while i < tokens.count {
            if i + 1 < tokens.count {
                if byeWords.contains(tokens[i]) && names.contains(tokens[i + 1]) { return true }
                if names.contains(tokens[i]) && byeWords.contains(tokens[i + 1]) { return true }
                // "bye bye filo"
                if i + 2 < tokens.count && byeWords.contains(tokens[i]) && byeWords.contains(tokens[i + 1]) && names.contains(tokens[i + 2]) { return true }
            }
            if tokens[i].hasPrefix("bye") && names.contains(String(tokens[i].dropFirst(3))) { return true }
            i += 1
        }
        return false
    }

    /// `filo-helper --test-matcher`: prints results, returns the number of failures.
    static func selfTest() -> Int {
        let m = WakeMatcher(phrase: "hey filo")
        var failures = 0
        func check(_ tokens: [String], from: Int = 0, expect: Int?, _ label: String) {
            let got = m.match(tokens.map(WakeMatcher.normalize), from: from)
            if got == expect {
                print("  ok: \(label)")
            } else {
                print("  FAIL: \(label) (got \(String(describing: got)), expected \(String(describing: expect)))")
                failures += 1
            }
        }
        check(["hey", "filo", "how", "do", "I"], expect: 2, "plain phrase")
        check(["Hey,", "Filo!", "what"], expect: 2, "punctuation and case")
        check(["so", "hey", "philo", "where"], expect: 3, "sound-alike after other words")
        check(["okay", "fellow"], expect: 2, "okay + fellow")
        check(["heyfilo", "help"], expect: 1, "merged token")
        check(["hey", "there", "filo"], expect: nil, "name must follow the trigger")
        check(["filo", "hey"], expect: nil, "wrong order")
        check(["hey", "filo"], from: 1, expect: nil, "already scanned")
        check(["I", "said", "hey", "filo", "again"], from: 2, expect: 4, "scan window")
        check([], expect: nil, "empty")
        func checkBye(_ tokens: [String], expect: Bool, _ label: String) {
            let got = m.matchBye(tokens.map(WakeMatcher.normalize), from: 0)
            if got == expect { print("  ok: \(label)") } else { print("  FAIL: \(label)"); failures += 1 }
        }
        checkBye(["bye", "filo"], expect: true, "bye filo")
        checkBye(["okay", "goodbye", "philo"], expect: true, "goodbye + sound-alike")
        checkBye(["Filo,", "bye!"], expect: true, "name then bye")
        checkBye(["bye", "bye", "filo"], expect: true, "bye bye filo")
        checkBye(["byefilo"], expect: true, "merged bye")
        checkBye(["bye", "there"], expect: false, "bye without the name")
        checkBye(["hey", "filo"], expect: false, "wake phrase is not bye")
        return failures
    }
}
