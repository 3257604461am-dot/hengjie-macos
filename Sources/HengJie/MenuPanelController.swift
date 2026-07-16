import AppKit

@MainActor
final class MenuPanelController: NSViewController, NSPopoverDelegate {
    struct Actions {
        let standard: () -> Void
        let delayed: () -> Void
        let vertical: () -> Void
        let horizontal: () -> Void
        let pin: () -> Void
        let text: () -> Void
        let gif: () -> Void
        let history: () -> Void
        let recentScreenshots: () -> Void
        let permissions: () -> Void
        let preferences: () -> Void
        let diagnostics: () -> Void
        let quit: () -> Void
    }

    private let actions: Actions
    private let popover = NSPopover()
    private let captureStatus = NSTextField(labelWithString: "")
    private let accessibilityStatus = NSTextField(labelWithString: "")
    private let historyStatus = NSTextField(labelWithString: "")
    private let screenshotHistoryStatus = NSTextField(labelWithString: "")

    init(actions: Actions) {
        self.actions = actions
        super.init(nibName: nil, bundle: nil)
        popover.contentViewController = self
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        preferredContentSize = CGSize(width: 348, height: 510)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        view = root

        let title = NSTextField(labelWithString: "横截")
        title.font = .systemFont(ofSize: 20, weight: .bold)
        let subtitle = NSTextField(labelWithString: "截图、记录与提取工具")
        subtitle.textColor = .secondaryLabelColor

        let header = NSStackView(views: [title, subtitle])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 2

        let actionRows = NSStackView(views: [
            row(actionButton("普通截图", symbol: "viewfinder", action: #selector(standard)), actionButton("延时截图", symbol: "timer", action: #selector(delayed))),
            row(actionButton("上下长截图", symbol: "arrow.up.and.down", action: #selector(vertical)), actionButton("左右长截图", symbol: "arrow.left.and.right", action: #selector(horizontal))),
            row(actionButton("钉住区域", symbol: "pin", action: #selector(pin)), actionButton("最近截图", symbol: "photo.stack", action: #selector(recentScreenshots))),
            row(actionButton("提取文字", symbol: "text.viewfinder", action: #selector(text)), actionButton("录制 GIF", symbol: "record.circle", action: #selector(gif))),
            row(actionButton("剪贴板历史", symbol: "clipboard", action: #selector(history)), actionButton("权限检查", symbol: "checkmark.shield", action: #selector(permissions)))
        ])
        actionRows.orientation = .vertical
        actionRows.spacing = 8

        [captureStatus, accessibilityStatus, historyStatus, screenshotHistoryStatus].forEach {
            $0.font = .systemFont(ofSize: 11)
            $0.textColor = .secondaryLabelColor
        }
        let statuses = NSStackView(views: [captureStatus, accessibilityStatus, historyStatus, screenshotHistoryStatus])
        statuses.orientation = .vertical
        statuses.alignment = .leading
        statuses.spacing = 4

        let settings = NSButton(title: "设置", target: self, action: #selector(preferences))
        let diagnostics = NSButton(title: "导出诊断", target: self, action: #selector(exportDiagnostics))
        let quit = NSButton(title: "退出", target: self, action: #selector(quitApp))
        [settings, diagnostics, quit].forEach { $0.bezelStyle = .inline }
        let footer = NSStackView(views: [settings, diagnostics, NSView(), quit])
        footer.spacing = 10

        let stack = NSStackView(views: [header, separator(), actionRows, separator(), statuses, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -14),
            actionRows.widthAnchor.constraint(equalTo: stack.widthAnchor),
            statuses.widthAnchor.constraint(equalTo: stack.widthAnchor),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        refreshStatus()
    }

    func toggle(relativeTo button: NSStatusBarButton) {
        if popover.isShown { popover.performClose(nil); return }
        refreshStatus()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    private func refreshStatus() {
        captureStatus.stringValue = "\(PermissionManager.canCaptureScreen ? "●" : "○") 屏幕录制权限\(PermissionManager.canCaptureScreen ? "已开启" : "未开启")"
        accessibilityStatus.stringValue = "\(PermissionManager.hasAccessibility ? "●" : "○") 辅助功能权限\(PermissionManager.hasAccessibility ? "已开启" : "未开启（仅自动滚动需要）")"
        let enabled = AppPreferences.shared.clipboardHistoryEnabled
        historyStatus.stringValue = "\(enabled ? "●" : "○") 剪贴板历史\(enabled ? "正在记录" : "已关闭")"
        let screenshotsEnabled = AppPreferences.shared.screenshotHistoryEnabled
        screenshotHistoryStatus.stringValue = "\(screenshotsEnabled ? "●" : "○") 最近截图\(screenshotsEnabled ? "正在保存草稿" : "已关闭")"
    }

    private func actionButton(_ title: String, symbol: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        button.imagePosition = .imageLeading
        button.alignment = .left
        button.bezelStyle = .rounded
        button.heightAnchor.constraint(equalToConstant: 42).isActive = true
        return button
    }

    private func row(_ left: NSButton, _ right: NSButton) -> NSStackView {
        let row = NSStackView(views: [left, right])
        row.distribution = .fillEqually
        row.spacing = 8
        return row
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        return box
    }

    private func perform(_ action: () -> Void) {
        popover.performClose(nil)
        action()
    }

    @objc private func standard() { perform(actions.standard) }
    @objc private func delayed() { perform(actions.delayed) }
    @objc private func vertical() { perform(actions.vertical) }
    @objc private func horizontal() { perform(actions.horizontal) }
    @objc private func pin() { perform(actions.pin) }
    @objc private func text() { perform(actions.text) }
    @objc private func gif() { perform(actions.gif) }
    @objc private func history() { perform(actions.history) }
    @objc private func recentScreenshots() { perform(actions.recentScreenshots) }
    @objc private func permissions() { perform(actions.permissions) }
    @objc private func preferences() { perform(actions.preferences) }
    @objc private func exportDiagnostics() { perform(actions.diagnostics) }
    @objc private func quitApp() { perform(actions.quit) }
}
