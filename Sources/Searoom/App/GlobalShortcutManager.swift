import Carbon
import Foundation

final class GlobalShortcutManager: @unchecked Sendable {
    private static let signature: OSType = 0x4844_524D // HDRM

    private var hotKey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private let action: @Sendable () -> Void

    init(action: @escaping @Sendable () -> Void) {
        self.action = action
        installEventHandler()
    }

    deinit {
        unregister()
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }

    @discardableResult
    func register(_ shortcut: GlobalShortcut) -> OSStatus {
        unregister()
        guard shortcut.modifiers.hasPrimaryModifier else { return OSStatus(paramErr) }

        let identifier = EventHotKeyID(signature: Self.signature, id: 1)
        let status = RegisterEventHotKey(
            UInt32(shortcut.keyCode),
            carbonModifiers(shortcut.modifiers),
            identifier,
            GetApplicationEventTarget(),
            0,
            &hotKey
        )
        if status != noErr { hotKey = nil }
        return status
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
    }

    private func installEventHandler() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let callback: EventHandlerUPP = { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &identifier
            )
            guard status == noErr, identifier.signature == GlobalShortcutManager.signature else {
                return OSStatus(eventNotHandledErr)
            }
            let manager = Unmanaged<GlobalShortcutManager>.fromOpaque(context).takeUnretainedValue()
            manager.action()
            return noErr
        }

        InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
    }

    private func carbonModifiers(_ modifiers: ShortcutModifiers) -> UInt32 {
        var result: UInt32 = 0
        if modifiers.contains(.command) { result |= UInt32(cmdKey) }
        if modifiers.contains(.option) { result |= UInt32(optionKey) }
        if modifiers.contains(.control) { result |= UInt32(controlKey) }
        if modifiers.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }
}
