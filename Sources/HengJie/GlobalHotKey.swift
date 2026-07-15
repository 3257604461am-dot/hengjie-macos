import AppKit
import Carbon

@MainActor
final class GlobalHotKey {
    private let identifierID: UInt32
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    var action: (() -> Void)?

    init(id: UInt32) {
        identifierID = id
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
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
                let object = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
                guard status == noErr,
                      identifier.signature == OSType(0x484A4945),
                      identifier.id == object.identifierID else { return OSStatus(eventNotHandledErr) }
                Task { @MainActor in object.action?() }
                return noErr
            },
            1,
            &eventType,
            pointer,
            &eventHandler
        )
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }

    func register(keyCode: UInt32, modifiers: UInt32) {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        let identifier = EventHotKeyID(signature: OSType(0x484A4945), id: identifierID)
        RegisterEventHotKey(keyCode, modifiers, identifier, GetApplicationEventTarget(), 0, &hotKeyRef)
    }
}
