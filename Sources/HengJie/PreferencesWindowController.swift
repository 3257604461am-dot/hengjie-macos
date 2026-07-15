import AppKit
import Carbon

@MainActor
final class PreferencesWindowController: NSWindowController {
    private let onChange: () -> Void
    private let keyPopup = NSPopUpButton()
    private let modifierPopup = NSPopUpButton()
    private let pinKeyPopup = NSPopUpButton()
    private let pinModifierPopup = NSPopUpButton()
    private let textKeyPopup = NSPopUpButton()
    private let textModifierPopup = NSPopUpButton()
    private let gifKeyPopup = NSPopUpButton()
    private let gifModifierPopup = NSPopUpButton()
    private let formatPopup = NSPopUpButton()
    private let loginCheckbox = NSButton(checkboxWithTitle: "登录时启动横截", target: nil, action: nil)

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 440, height: 405),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.title = "横截设置"
        window.center()
        super.init(window: window)
        buildUI()
    }

    required init?(coder: NSCoder) { nil }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false

        keyPopup.addItems(withTitles: ["A", "S", "X", "P", "O", "G"])
        modifierPopup.addItems(withTitles: ["⌥⇧", "⌃⇧", "⌘⇧"])
        pinKeyPopup.addItems(withTitles: ["P", "A", "S", "X", "O", "G"])
        pinModifierPopup.addItems(withTitles: ["⌥⇧", "⌃⇧", "⌘⇧"])
        textKeyPopup.addItems(withTitles: ["O", "A", "S", "X", "P", "G"])
        textModifierPopup.addItems(withTitles: ["⌥⇧", "⌃⇧", "⌘⇧"])
        gifKeyPopup.addItems(withTitles: ["G", "A", "S", "X", "P", "O"])
        gifModifierPopup.addItems(withTitles: ["⌥⇧", "⌃⇧", "⌘⇧"])
        formatPopup.addItems(withTitles: ["PNG", "JPEG"])
        keyPopup.selectItem(withTitle: keyName(for: AppPreferences.shared.hotKeyCode))
        modifierPopup.selectItem(at: modifierIndex(for: AppPreferences.shared.hotKeyModifiers))
        pinKeyPopup.selectItem(withTitle: keyName(for: AppPreferences.shared.pinHotKeyCode))
        pinModifierPopup.selectItem(at: modifierIndex(for: AppPreferences.shared.pinHotKeyModifiers))
        textKeyPopup.selectItem(withTitle: keyName(for: AppPreferences.shared.textHotKeyCode))
        textModifierPopup.selectItem(at: modifierIndex(for: AppPreferences.shared.textHotKeyModifiers))
        gifKeyPopup.selectItem(withTitle: keyName(for: AppPreferences.shared.gifHotKeyCode))
        gifModifierPopup.selectItem(at: modifierIndex(for: AppPreferences.shared.gifHotKeyModifiers))
        formatPopup.selectItem(withTitle: AppPreferences.shared.saveFormat.uppercased())
        loginCheckbox.state = AppPreferences.shared.launchesAtLogin ? .on : .off

        let shortcut = NSStackView(views: [label("全局截图快捷键"), modifierPopup, keyPopup])
        shortcut.spacing = 10
        let pinShortcut = NSStackView(views: [label("钉住区域快捷键"), pinModifierPopup, pinKeyPopup])
        pinShortcut.spacing = 10
        let textShortcut = NSStackView(views: [label("提取文字快捷键"), textModifierPopup, textKeyPopup])
        textShortcut.spacing = 10
        let gifShortcut = NSStackView(views: [label("录制 GIF 快捷键"), gifModifierPopup, gifKeyPopup])
        gifShortcut.spacing = 10
        let format = NSStackView(views: [label("默认保存格式"), formatPopup])
        format.spacing = 10
        let note = NSTextField(wrappingLabelWithString: "自动滚动需要辅助功能权限；所有 OCR 和图片处理均在本机完成。")
        note.textColor = .secondaryLabelColor
        note.maximumNumberOfLines = 2
        let save = NSButton(title: "保存设置", target: self, action: #selector(saveSettings))
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"
        [shortcut, pinShortcut, textShortcut, gifShortcut, format, loginCheckbox, note, save].forEach(stack.addArrangedSubview)
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 28)
        ])
    }

    private func label(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        return label
    }

    @objc private func saveSettings() {
        let keyCodes: [String: UInt32] = ["A": 0, "S": 1, "G": 5, "X": 7, "O": 31, "P": 35]
        let modifiers: [UInt32] = [UInt32(optionKey | shiftKey), UInt32(controlKey | shiftKey), UInt32(cmdKey | shiftKey)]
        let captureCode = keyCodes[keyPopup.titleOfSelectedItem ?? "A"] ?? 0
        let captureModifiers = modifiers[modifierPopup.indexOfSelectedItem]
        let pinCode = keyCodes[pinKeyPopup.titleOfSelectedItem ?? "P"] ?? 35
        let pinModifiers = modifiers[pinModifierPopup.indexOfSelectedItem]
        let textCode = keyCodes[textKeyPopup.titleOfSelectedItem ?? "O"] ?? 31
        let textModifiers = modifiers[textModifierPopup.indexOfSelectedItem]
        let gifCode = keyCodes[gifKeyPopup.titleOfSelectedItem ?? "G"] ?? 5
        let gifModifiers = modifiers[gifModifierPopup.indexOfSelectedItem]
        let shortcuts = ["\(captureCode):\(captureModifiers)", "\(pinCode):\(pinModifiers)", "\(textCode):\(textModifiers)", "\(gifCode):\(gifModifiers)"]
        guard Set(shortcuts).count == shortcuts.count else {
            let alert = NSAlert()
            alert.messageText = "快捷键冲突"
            alert.informativeText = "普通截图、钉住区域、提取文字和 GIF 录制不能使用相同的全局快捷键。"
            alert.runModal()
            return
        }
        AppPreferences.shared.hotKeyCode = captureCode
        AppPreferences.shared.hotKeyModifiers = captureModifiers
        AppPreferences.shared.pinHotKeyCode = pinCode
        AppPreferences.shared.pinHotKeyModifiers = pinModifiers
        AppPreferences.shared.textHotKeyCode = textCode
        AppPreferences.shared.textHotKeyModifiers = textModifiers
        AppPreferences.shared.gifHotKeyCode = gifCode
        AppPreferences.shared.gifHotKeyModifiers = gifModifiers
        AppPreferences.shared.saveFormat = (formatPopup.titleOfSelectedItem ?? "PNG").lowercased()
        do { try AppPreferences.shared.setLaunchAtLogin(loginCheckbox.state == .on) }
        catch {
            let alert = NSAlert(error: error)
            alert.informativeText += "\n请先将横截.app 移到“应用程序”文件夹。"
            alert.runModal()
        }
        onChange()
        close()
    }

    private func keyName(for code: UInt32) -> String {
        [0: "A", 1: "S", 5: "G", 7: "X", 31: "O", 35: "P"][code] ?? "A"
    }

    private func modifierIndex(for modifiers: UInt32) -> Int {
        if modifiers & UInt32(controlKey) != 0 { return 1 }
        if modifiers & UInt32(cmdKey) != 0 { return 2 }
        return 0
    }
}
