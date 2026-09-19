import AVFoundation
import Foundation
import Speech

enum Permissions {
    static let micMessage = "Microphone access is off. Turn it on for Filo Helper in System Settings › Privacy & Security › Microphone."
    static let speechMessage = "Speech recognition is off. Turn it on for Filo Helper in System Settings › Privacy & Security › Speech Recognition."

    /// Asks for speech recognition, then microphone access (prompting when undetermined).
    /// completion(ok, errorCode, errorMessage) on the main thread.
    static func request(_ completion: @escaping (Bool, String, String) -> Void) {
        let afterSpeech: (Bool) -> Void = { ok in
            guard ok else { completion(false, "speech_denied", speechMessage); return }
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized:
                completion(true, "", "")
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    DispatchQueue.main.async { completion(granted, granted ? "" : "mic_denied", granted ? "" : micMessage) }
                }
            default:
                completion(false, "mic_denied", micMessage)
            }
        }
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            afterSpeech(true)
        case .notDetermined:
            SFSpeechRecognizer.requestAuthorization { status in
                DispatchQueue.main.async { afterSpeech(status == .authorized) }
            }
        default:
            afterSpeech(false)
        }
    }

    static func name(_ s: SFSpeechRecognizerAuthorizationStatus) -> String {
        switch s {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .restricted: return "restricted"
        default: return "not_determined"
        }
    }

    static func name(_ s: AVAuthorizationStatus) -> String {
        switch s {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .restricted: return "restricted"
        default: return "not_determined"
        }
    }
}
