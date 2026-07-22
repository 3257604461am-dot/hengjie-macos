import AppKit
import Carbon

struct HotKeyBinding: Codable, Hashable, Sendable {
    let keyCode: UInt32
    let modifiers: UInt32

    var displayString: String {
        var value = ""
        if modifiers & UInt32(controlKey) != 0 { value += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { value += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { value += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { value += "⌘" }
        return value + KeyCodeDisplay.name(for: keyCode)
    }

    static let captureDefault = HotKeyBinding(keyCode: 0, modifiers: UInt32(optionKey | shiftKey))
    static let pinDefault = HotKeyBinding(keyCode: 35, modifiers: UInt32(optionKey | shiftKey))
    static let textDefault = HotKeyBinding(keyCode: 31, modifiers: UInt32(optionKey | shiftKey))
    static let gifDefault = HotKeyBinding(keyCode: 5, modifiers: UInt32(optionKey | shiftKey))
    static let historyDefault = HotKeyBinding(keyCode: 9, modifiers: UInt32(controlKey | shiftKey))
}

enum HotKeyRegistrationError: LocalizedError {
    case duplicate
    case unavailable(HotKeyBinding)

    var errorDescription: String? {
        switch self {
        case .duplicate: "快捷键配置存在重复组合。"
        case let .unavailable(binding): "快捷键 \(binding.displayString) 已被系统或其他应用占用。"
        }
    }
}

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
                    event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                    MemoryLayout<EventHotKeyID>.size, nil, &identifier
                )
                let object = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
                guard status == noErr, identifier.signature == OSType(0x484A4945), identifier.id == object.identifierID
                else { return OSStatus(eventNotHandledErr) }
                Task { @MainActor in object.action?() }
                return noErr
            },
            1, &eventType, pointer, &eventHandler
        )
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }

    func register(_ binding: HotKeyBinding) -> Result<Void, HotKeyRegistrationError> {
        unregister()
        let identifier = EventHotKeyID(signature: OSType(0x484A4945), id: identifierID)
        let status = RegisterEventHotKey(binding.keyCode, binding.modifiers, identifier, GetApplicationEventTarget(), 0, &hotKeyRef)
        if status != noErr {
            hotKeyRef = nil
            return .failure(.unavailable(binding))
        }
        return .success(())
    }

    func register(keyCode: UInt32, modifiers: UInt32) {
        _ = register(.init(keyCode: keyCode, modifiers: modifiers))
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
    }
}

@MainActor
final class GlobalHotKeyRegistry {
    private struct Entry {
        let hotKey: GlobalHotKey
        var binding: HotKeyBinding?
    }
    private var entries: [String: Entry] = [:]

    func install(name: String, id: UInt32, action: @escaping () -> Void) {
        let hotKey = GlobalHotKey(id: id)
        hotKey.action = action
        entries[name] = Entry(hotKey: hotKey, binding: nil)
    }

    func apply(_ bindings: [String: HotKeyBinding]) -> Result<Void, HotKeyRegistrationError> {
        guard Set(bindings.values).count == bindings.count else { return .failure(.duplicate) }
        let old = entries.mapValues(\.binding)
        let hadPriorConfiguration = old.values.contains { $0 != nil }
        for name in entries.keys {
            entries[name]?.hotKey.unregister()
            entries[name]?.binding = nil
        }
        for name in bindings.keys.sorted() {
            guard var entry = entries[name], let binding = bindings[name] else { continue }
            switch entry.hotKey.register(binding) {
            case .success:
                entry.binding = binding
                entries[name] = entry
            case let .failure(error):
                entries.values.forEach { $0.hotKey.unregister() }
                let fallback = hadPriorConfiguration ? old.compactMapValues { $0 } : bindings.filter { $0.key != name }
                for (fallbackName, fallbackBinding) in fallback {
                    guard var oldEntry = entries[fallbackName] else { continue }
                    _ = oldEntry.hotKey.register(fallbackBinding)
                    oldEntry.binding = fallbackBinding
                    entries[fallbackName] = oldEntry
                }
                return .failure(error)
            }
        }
        return .success(())
    }
}

private enum KeyCodeDisplay {
    static func name(for code: UInt32) -> String {
        let names: [UInt32: String] = [
            0:"A", 1:"S", 2:"D", 3:"F", 4:"H", 5:"G", 6:"Z", 7:"X", 8:"C", 9:"V", 11:"B",
            12:"Q", 13:"W", 14:"E", 15:"R", 16:"Y", 17:"T", 18:"1", 19:"2", 20:"3", 21:"4", 22:"6",
            23:"5", 24:"=", 25:"9", 26:"7", 27:"-", 28:"8", 29:"0", 30:"]", 31:"O", 32:"U", 33:"[",
            34:"I", 35:"P", 36:"↩", 37:"L", 38:"J", 39:"'", 40:"K", 41:";", 42:"\\", 43:",", 44:"/",
            45:"N", 46:"M", 47:".", 49:"Space", 50:"`", 122:"F1", 120:"F2", 99:"F3", 118:"F4",
            96:"F5", 97:"F6", 98:"F7", 100:"F8", 101:"F9", 109:"F10", 103:"F11", 111:"F12"
        ]
        return names[code] ?? "Key \(code)"
    }
}

@MainActor
final class ShortcutRecorderControl: NSControl {
    var binding: HotKeyBinding? { didSet { updateTitle() } }
    private var recording = false

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        recording = true
        needsDisplay = true
        toolTip = "按下新的快捷键；Delete 清除，Esc 取消"
    }

    override func resignFirstResponder() -> Bool {
        recording = false
        updateTitle()
        return super.resignFirstResponder()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { recording = false; updateTitle(); return }
        if event.keyCode == 51 || event.keyCode == 117 { binding = nil; recording = false; return }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        guard modifiers & UInt32(cmdKey | optionKey | controlKey) != 0 else {
            toolTip = "快捷键至少需要包含 ⌘、⌥ 或 ⌃"
            NSSound.beep()
            return
        }
        binding = HotKeyBinding(keyCode: UInt32(event.keyCode), modifiers: modifiers)
        recording = false
        sendAction(action, to: target)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        path.fill()
        (recording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = recording ? 2 : 1
        path.stroke()
        let text = recording ? "请按下快捷键…" : (binding?.displayString ?? "未设置")
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .medium),
            .foregroundColor: recording ? NSColor.controlAccentColor : NSColor.labelColor
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(at: CGPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attributes)
    }

    private func updateTitle() { needsDisplay = true }
}
