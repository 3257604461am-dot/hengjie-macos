import AppKit
import Carbon

@MainActor
final class PreferencesWindowController: NSWindowController {
    private let onChange: () -> Void
    private let onClearHistory: () -> Void
    private let keyPopup = NSPopUpButton()
    private let modifierPopup = NSPopUpButton()
    private let pinKeyPopup = NSPopUpButton()
    private let pinModifierPopup = NSPopUpButton()
    private let textKeyPopup = NSPopUpButton()
    private let textModifierPopup = NSPopUpButton()
    private let gifKeyPopup = NSPopUpButton()
    private let gifModifierPopup = NSPopUpButton()
    private let historyKeyPopup = NSPopUpButton()
    private let historyModifierPopup = NSPopUpButton()
    private let formatPopup = NSPopUpButton()
    private let loginCheckbox = NSButton(checkboxWithTitle: "登录时启动横截", target: nil, action: nil)
    private let historyCheckbox = NSButton(checkboxWithTitle: "启用剪贴板历史（仅本机保存）", target: nil, action: nil)

    init(onChange: @escaping () -> Void, onClearHistory: @escaping () -> Void) {
        self.onChange = onChange
        self.onClearHistory = onClearHistory
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 470, height: 500),
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

        let keys = ["A", "S", "X", "P", "O", "G", "V"]
        keyPopup.addItems(withTitles: keys)
        modifierPopup.addItems(withTitles: ["⌥⇧", "⌃⇧", "⌘⇧"])
        pinKeyPopup.addItems(withTitles: keys)
        pinModifierPopup.addItems(withTitles: ["⌥⇧", "⌃⇧", "⌘⇧"])
        textKeyPopup.addItems(withTitles: keys)
        textModifierPopup.addItems(withTitles: ["⌥⇧", "⌃⇧", "⌘⇧"])
        gifKeyPopup.addItems(withTitles: keys)
        gifModifierPopup.addItems(withTitles: ["⌥⇧", "⌃⇧", "⌘⇧"])
        historyKeyPopup.addItems(withTitles: keys)
        historyModifierPopup.addItems(withTitles: ["⌥⇧", "⌃⇧", "⌘⇧"])
        formatPopup.addItems(withTitles: ["PNG", "JPEG"])
        keyPopup.selectItem(withTitle: keyName(for: AppPreferences.shared.hotKeyCode))
        modifierPopup.selectItem(at: modifierIndex(for: AppPreferences.shared.hotKeyModifiers))
        pinKeyPopup.selectItem(withTitle: keyName(for: AppPreferences.shared.pinHotKeyCode))
        pinModifierPopup.selectItem(at: modifierIndex(for: AppPreferences.shared.pinHotKeyModifiers))
        textKeyPopup.selectItem(withTitle: keyName(for: AppPreferences.shared.textHotKeyCode))
        textModifierPopup.selectItem(at: modifierIndex(for: AppPreferences.shared.textHotKeyModifiers))
        gifKeyPopup.selectItem(withTitle: keyName(for: AppPreferences.shared.gifHotKeyCode))
        gifModifierPopup.selectItem(at: modifierIndex(for: AppPreferences.shared.gifHotKeyModifiers))
        historyKeyPopup.selectItem(withTitle: keyName(for: AppPreferences.shared.historyHotKeyCode))
        historyModifierPopup.selectItem(at: modifierIndex(for: AppPreferences.shared.historyHotKeyModifiers))
        formatPopup.selectItem(withTitle: AppPreferences.shared.saveFormat.uppercased())
        loginCheckbox.state = AppPreferences.shared.launchesAtLogin ? .on : .off
        historyCheckbox.state = AppPreferences.shared.clipboardHistoryEnabled ? .on : .off

        let shortcut = NSStackView(views: [label("全局截图快捷键"), modifierPopup, keyPopup])
        shortcut.spacing = 10
        let pinShortcut = NSStackView(views: [label("钉住区域快捷键"), pinModifierPopup, pinKeyPopup])
        pinShortcut.spacing = 10
        let textShortcut = NSStackView(views: [label("提取文字快捷键"), textModifierPopup, textKeyPopup])
        textShortcut.spacing = 10
        let gifShortcut = NSStackView(views: [label("录制 GIF 快捷键"), gifModifierPopup, gifKeyPopup])
        gifShortcut.spacing = 10
        let historyShortcut = NSStackView(views: [label("剪贴板历史快捷键"), historyModifierPopup, historyKeyPopup])
        historyShortcut.spacing = 10
        let format = NSStackView(views: [label("默认保存格式"), formatPopup])
        format.spacing = 10
        let clearHistory = NSButton(title: "清空全部剪贴板历史…", target: self, action: #selector(clearAllHistory))
        clearHistory.bezelStyle = .rounded
        let note = NSTextField(wrappingLabelWithString: "自动滚动需要辅助功能权限；剪贴板历史、OCR 和图片处理均在本机完成。")
        note.textColor = .secondaryLabelColor
        note.maximumNumberOfLines = 2
        let save = NSButton(title: "保存设置", target: self, action: #selector(saveSettings))
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"
        [shortcut, pinShortcut, textShortcut, gifShortcut, historyShortcut, format, loginCheckbox, historyCheckbox, clearHistory, note, save].forEach(stack.addArrangedSubview)
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
        let keyCodes: [String: UInt32] = ["A": 0, "S": 1, "G": 5, "X": 7, "V": 9, "O": 31, "P": 35]
        let modifiers: [UInt32] = [UInt32(optionKey | shiftKey), UInt32(controlKey | shiftKey), UInt32(cmdKey | shiftKey)]
        let captureCode = keyCodes[keyPopup.titleOfSelectedItem ?? "A"] ?? 0
        let captureModifiers = modifiers[modifierPopup.indexOfSelectedItem]
        let pinCode = keyCodes[pinKeyPopup.titleOfSelectedItem ?? "P"] ?? 35
        let pinModifiers = modifiers[pinModifierPopup.indexOfSelectedItem]
        let textCode = keyCodes[textKeyPopup.titleOfSelectedItem ?? "O"] ?? 31
        let textModifiers = modifiers[textModifierPopup.indexOfSelectedItem]
        let gifCode = keyCodes[gifKeyPopup.titleOfSelectedItem ?? "G"] ?? 5
        let gifModifiers = modifiers[gifModifierPopup.indexOfSelectedItem]
        let historyCode = keyCodes[historyKeyPopup.titleOfSelectedItem ?? "V"] ?? 9
        let historyModifiers = modifiers[historyModifierPopup.indexOfSelectedItem]
        let shortcuts = ["\(captureCode):\(captureModifiers)", "\(pinCode):\(pinModifiers)", "\(textCode):\(textModifiers)", "\(gifCode):\(gifModifiers)", "\(historyCode):\(historyModifiers)"]
        guard Set(shortcuts).count == shortcuts.count else {
            let alert = NSAlert()
            alert.messageText = "快捷键冲突"
            alert.informativeText = "普通截图、钉住区域、提取文字、GIF 录制和剪贴板历史不能使用相同的全局快捷键。"
            alert.runModal()
            return
        }
        let enableHistory = historyCheckbox.state == .on
        if enableHistory && !AppPreferences.shared.clipboardHistoryConsentCompleted {
            let alert = NSAlert()
            alert.messageText = "启用剪贴板历史？"
            alert.informativeText = "横截会从启用后开始，把文字、链接、富文本和静态图片保存在本机，最长 30 天、最多 100 条。不会记录 GIF、文件、音视频及带密码或临时标记的内容；未正确标记的敏感内容仍可能被记录。"
            alert.addButton(withTitle: "同意并启用")
            alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            AppPreferences.shared.clipboardHistoryConsentCompleted = true
        }
        AppPreferences.shared.hotKeyCode = captureCode
        AppPreferences.shared.hotKeyModifiers = captureModifiers
        AppPreferences.shared.pinHotKeyCode = pinCode
        AppPreferences.shared.pinHotKeyModifiers = pinModifiers
        AppPreferences.shared.textHotKeyCode = textCode
        AppPreferences.shared.textHotKeyModifiers = textModifiers
        AppPreferences.shared.gifHotKeyCode = gifCode
        AppPreferences.shared.gifHotKeyModifiers = gifModifiers
        AppPreferences.shared.historyHotKeyCode = historyCode
        AppPreferences.shared.historyHotKeyModifiers = historyModifiers
        AppPreferences.shared.clipboardHistoryEnabled = enableHistory
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

    @objc private func clearAllHistory() {
        let alert = NSAlert()
        alert.messageText = "清空全部剪贴板历史？"
        alert.informativeText = "固定记录也会被删除，此操作无法撤销。"
        alert.addButton(withTitle: "全部清空")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn { onClearHistory() }
    }

    private func keyName(for code: UInt32) -> String {
        [0: "A", 1: "S", 5: "G", 7: "X", 9: "V", 31: "O", 35: "P"][code] ?? "A"
    }

    private func modifierIndex(for modifiers: UInt32) -> Int {
        if modifiers & UInt32(controlKey) != 0 { return 1 }
        if modifiers & UInt32(cmdKey) != 0 { return 2 }
        return 0
    }
}
