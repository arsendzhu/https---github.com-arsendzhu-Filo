import Carbon.HIToolbox
import Foundation

/// A global hotkey via Carbon's RegisterEventHotKey: works while any app is
/// focused and does not require the Accessibility permission. Reports both
/// press and release so the app can do push-to-talk.
final class HotKey {
    typealias Handler = (Bool) -> Void

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let handler: Handler

    init?(keyCode: UInt32, modifiers: UInt32, handler: @escaping Handler) {
        self.handler = handler
        var types = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let installStatus = InstallEventHandler(GetEventDispatcherTarget(), { (_, event, userData) -> OSStatus in
            guard let event = event, let userData = userData else { return OSStatus(eventNotHandledErr) }
            let me = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
            let kind = GetEventKind(event)
            me.handler(kind == UInt32(kEventHotKeyPressed))
            return noErr
        }, types.count, &types, selfPtr, &handlerRef)
        guard installStatus == noErr else {
            Log.info("InstallEventHandler failed: \(installStatus)")
            return nil
        }
        let hotKeyID = EventHotKeyID(signature: 0x46494C4F /* 'FILO' */, id: 1)
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetEventDispatcherTarget(), 0, &hotKeyRef)
        guard status == noErr else {
            Log.info("RegisterEventHotKey failed: \(status)")
            if let h = handlerRef { RemoveEventHandler(h) }
            return nil
        }
    }

    deinit {
        if let r = hotKeyRef { UnregisterEventHotKey(r) }
        if let h = handlerRef { RemoveEventHandler(h) }
    }
}
