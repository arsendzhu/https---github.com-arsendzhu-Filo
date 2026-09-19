import Carbon.HIToolbox

/// Key-name -> macOS virtual key code, and modifier names -> Carbon flags.
enum KeyCodes {
    static let table: [String: UInt32] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "equal": 24, "=": 24,
        "9": 25, "7": 26, "minus": 27, "-": 27, "8": 28, "0": 29,
        "rightbracket": 30, "]": 30, "o": 31, "u": 32, "leftbracket": 33, "[": 33, "i": 34, "p": 35,
        "return": 36, "enter": 36, "l": 37, "j": 38, "quote": 39, "'": 39, "k": 40,
        "semicolon": 41, ";": 41, "backslash": 42, "\\": 42, "comma": 43, ",": 43,
        "slash": 44, "/": 44, "n": 45, "m": 46, "period": 47, ".": 47,
        "tab": 48, "space": 49, "grave": 50, "`": 50, "delete": 51, "backspace": 51, "escape": 53, "esc": 53,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100,
        "f9": 101, "f10": 109, "f11": 103, "f12": 111, "f13": 105, "f14": 107, "f15": 113,
        "f16": 106, "f17": 64, "f18": 79, "f19": 80, "f20": 90,
        "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
        "left": 123, "right": 124, "down": 125, "up": 126,
    ]

    static func code(for name: String) -> UInt32? {
        return table[name.lowercased().trimmingCharacters(in: .whitespaces)]
    }

    static func modifiers(for names: [String]) -> UInt32 {
        var flags: UInt32 = 0
        for n in names {
            switch n.lowercased() {
            case "command", "cmd": flags |= UInt32(cmdKey)
            case "option", "alt", "opt": flags |= UInt32(optionKey)
            case "control", "ctrl": flags |= UInt32(controlKey)
            case "shift": flags |= UInt32(shiftKey)
            default: break
            }
        }
        return flags
    }
}
