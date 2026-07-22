import AppKit

@MainActor
final class DelayedCaptureController: NSWindowController {
    var onReady: (() -> Void)?
    var onCancel: (() -> Void)?

    private let secondsPopup = NSPopUpButton()
    private let statusLabel = NSTextField(labelWithString: "选择延时时间")
    private let startButton = NSButton(title: "开始倒计时", target: nil, action: nil)
    private let cancelButton = NSButton(title: "取消", target: nil, action: nil)
    private var countdownTask: Task<Void, Never>?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var completed = false

    init(selectionRect: CGRect) {
        let panel = DelayPanel(
            contentRect: CGRect(x: 0, y: 0, width: 300, height: 104),
            styleMask: [.titled, .nonactivatingPanel, .utilityWindow], backing: .buffered, defer: false
        )
        panel.title = "延时截图"
        panel.level = .screenSaver
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        super.init(window: panel)
        buildUI()
        position(near: selectionRect)
    }

    required init?(coder: NSCoder) { nil }

    func present() {
        showWindow(nil)
        window?.orderFrontRegardless()
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        secondsPopup.addItems(withTitles: ["3 秒", "5 秒", "10 秒"])
        let values = [3, 5, 10]
        secondsPopup.selectItem(at: values.firstIndex(of: AppPreferences.shared.delayedCaptureSeconds) ?? 0)
        startButton.target = self
        startButton.action = #selector(startCountdown)
        startButton.bezelStyle = .rounded
        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        cancelButton.bezelStyle = .rounded
        statusLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        let controls = NSStackView(views: [secondsPopup, NSView(), cancelButton, startButton])
        controls.spacing = 8
        let root = NSStackView(views: [statusLabel, controls])
        root.orientation = .vertical
        root.spacing = 12
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            root.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            controls.widthAnchor.constraint(equalTo: root.widthAnchor)
        ])
    }

    private func position(near rect: CGRect) {
        guard let window else { return }
        let screen = NSScreen.screens.first(where: { !$0.frame.intersection(rect).isNull }) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? rect
        let size = window.frame.size
        let x = min(visible.maxX - size.width, max(visible.minX, rect.minX))
        let above = rect.maxY + 10
        let y = above + size.height <= visible.maxY ? above : max(visible.minY, rect.minY - size.height - 10)
        window.setFrameOrigin(CGPoint(x: x, y: y))
    }

    @objc private func startCountdown() {
        let values = [3, 5, 10]
        let seconds = values[max(0, secondsPopup.indexOfSelectedItem)]
        AppPreferences.shared.delayedCaptureSeconds = seconds
        secondsPopup.isEnabled = false
        startButton.isEnabled = false
        installCancellationMonitors()
        countdownTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for value in stride(from: seconds, through: 1, by: -1) {
                guard !Task.isCancelled else { return }
                statusLabel.stringValue = "\(value)"
                window?.title = "延时截图 · \(value)"
                try? await Task.sleep(for: .seconds(1))
            }
            guard !Task.isCancelled else { return }
            completed = true
            removeCancellationMonitors()
            window?.orderOut(nil)
            onReady?()
        }
    }

    @objc func cancel() {
        guard !completed else { return }
        countdownTask?.cancel()
        removeCancellationMonitors()
        window?.orderOut(nil)
        onCancel?()
    }

    private func installCancellationMonitors() {
        let mask: NSEvent.EventTypeMask = [.keyDown, .rightMouseDown]
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            if event.type == .rightMouseDown || event.keyCode == 53 { self?.cancel(); return nil }
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            guard event.type == .rightMouseDown || event.keyCode == 53 else { return }
            Task { @MainActor in self?.cancel() }
        }
    }

    private func removeCancellationMonitors() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor); self.localMonitor = nil }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor); self.globalMonitor = nil }
    }
}

private final class DelayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { (windowController as? DelayedCaptureController)?.perform(#selector(DelayedCaptureController.cancel)) }
        else { super.keyDown(with: event) }
    }
    override func rightMouseDown(with event: NSEvent) {
        (windowController as? DelayedCaptureController)?.perform(#selector(DelayedCaptureController.cancel))
    }
}
