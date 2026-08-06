import AppKit
import Carbon.HIToolbox

/// Global shortcut registration via Carbon's `RegisterEventHotKey`.
///
/// Chosen over `CGEventTap` deliberately: an event tap requires Accessibility permission,
/// but the shortcut is how the user *reaches* the onboarding screen that asks for it.
/// Carbon hot keys work with no permission at all. The API is long-deprecated and equally
/// long-supported; there is no modern replacement for process-wide hot keys.
final class GlobalHotkey {

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private let handler: () -> Void

    private static var instances: [UInt32: GlobalHotkey] = [:]
    private static var nextID: UInt32 = 1
    private let id: UInt32

    /// Defaults to Ctrl-Space: Cmd-Space is Spotlight and Option-Space is the common
    /// Raycast/Alfred binding, while Ctrl-Space is effectively free on macOS.
    init?(
        keyCode: UInt32 = UInt32(kVK_Space),
        modifiers: UInt32 = UInt32(controlKey),
        handler: @escaping () -> Void
    ) {
        self.handler = handler
        self.id = Self.nextID
        Self.nextID += 1
        Self.instances[id] = self

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ -> OSStatus in
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr else { return status }
                DispatchQueue.main.async {
                    GlobalHotkey.instances[hotKeyID.id]?.handler()
                }
                return noErr
            },
            1,
            &eventType,
            nil,
            &eventHandler
        )
        guard installStatus == noErr else { return nil }

        let hotKeyID = EventHotKeyID(signature: OSType(0x5753_5748), id: id) // 'WSWH'
        let registerStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        guard registerStatus == noErr else { return nil }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
        Self.instances[id] = nil
    }
}
