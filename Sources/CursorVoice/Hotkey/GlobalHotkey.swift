import Foundation
import Carbon.HIToolbox

/// Thin wrapper around Carbon's RegisterEventHotKey. Single hotkey at a time.
@MainActor
final class GlobalHotkey {
    var onPress: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private static var shared: GlobalHotkey? // for trampolining out of the C callback
    private let signature: FourCharCode = 0x43525356  // 'CRSV'

    init() { Self.shared = self }

    func register(keyCode: UInt32, modifiers: UInt32) {
        unregisterSync()
        installEventHandlerIfNeeded()

        let hkID = EventHotKeyID(signature: signature, id: 1)
        let status = RegisterEventHotKey(keyCode, modifiers, hkID, GetApplicationEventTarget(), 0, &hotKeyRef)
        if status == noErr {
            NSLog("CursorVoice: hotkey registered (keyCode=\(keyCode), mods=\(modifiers))")
        } else {
            NSLog("CursorVoice: hotkey register FAILED (status=\(status)) — likely a collision with another app")
        }
    }

    func unregister() { unregisterSync() }

    private func unregisterSync() {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref); hotKeyRef = nil }
    }

    private func installEventHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hkID = EventHotKeyID()
            GetEventParameter(event,
                              EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID),
                              nil,
                              MemoryLayout<EventHotKeyID>.size,
                              nil,
                              &hkID)
            DispatchQueue.main.async {
                NSLog("CursorVoice: hotkey fired")
                GlobalHotkey.shared?.onPress?()
            }
            return noErr
        }, 1, &spec, nil, &eventHandler)
    }
}
