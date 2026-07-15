import AppKit
import HengJieCore
import UniformTypeIdentifiers

@MainActor
final class GIFRecordingConfigurationController: NSWindowController {
    var onStart: ((GIFRecordingOptions) -> Void)?
    var onCancel: (() -> Void)?
    private let fpsField = NSTextField()
    private let fpsStepper = NSStepper()
    private let qualityPopup = NSPopUpButton()
    private let cursorCheckbox = NSButton(checkboxWithTitle: "显示鼠标", target: nil, action: nil)
    private let sizeLabel = NSTextField(labelWithString: "")
    private let selectionRect: CGRect
    private let screen: NSScreen

    init(selectionRect: CGRect, screen: NSScreen) {
        self.selectionRect = selectionRect
        self.screen = screen
        let panel = GIFPanel(
            contentRect: CGRect(origin: .zero, size: CGSize(width: 610, height: 76)),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        panel.level = .statusBar
        panel.hasShadow = true
        panel.backgroundColor = .windowBackgroundColor
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        super.init(window: panel)
        buildUI()
        positionWindow()
    }

    required init?(coder: NSCoder) { nil }

    func present() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        let fps = AppPreferences.shared.gifFramesPerSecond
        fpsField.integerValue = fps
        fpsField.alignment = .center
        fpsField.translatesAutoresizingMaskIntoConstraints = false
        fpsField.widthAnchor.constraint(equalToConstant: 38).isActive = true
        fpsStepper.minValue = 1
        fpsStepper.maxValue = 30
        fpsStepper.increment = 1
        fpsStepper.integerValue = fps
        fpsStepper.target = self
        fpsStepper.action = #selector(stepFPS)
        qualityPopup.addItems(withTitles: GIFQuality.allCases.map(\.title))
        qualityPopup.selectItem(withTitle: AppPreferences.shared.gifQuality.title)
        qualityPopup.target = self
        qualityPopup.action = #selector(updateSize)
        cursorCheckbox.state = AppPreferences.shared.gifShowsCursor ? .on : .off

        let start = NSButton(title: "开始录制", target: self, action: #selector(startRecording))
        start.bezelStyle = .rounded
        start.keyEquivalent = "\r"
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancel))
        let controls = NSStackView(views: [
            NSTextField(labelWithString: "帧率"), fpsField, fpsStepper, NSTextField(labelWithString: "FPS"),
            NSTextField(labelWithString: "质量"), qualityPopup, cursorCheckbox, start, cancel
        ])
        controls.alignment = .centerY
        controls.spacing = 7
        controls.translatesAutoresizingMaskIntoConstraints = false
        sizeLabel.textColor = .secondaryLabelColor
        sizeLabel.font = .systemFont(ofSize: 11)
        sizeLabel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(controls)
        content.addSubview(sizeLabel)
        NSLayoutConstraint.activate([
            controls.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            controls.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -12),
            controls.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            sizeLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            sizeLabel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8)
        ])
        updateSize()
    }

    private func positionWindow() {
        guard let window else { return }
        let visible = screen.visibleFrame
        let size = window.frame.size
        let x = min(visible.maxX - size.width, max(visible.minX, selectionRect.minX))
        let below = selectionRect.minY - size.height - 8
        let y = below >= visible.minY ? below : min(visible.maxY - size.height, selectionRect.maxY + 8)
        window.setFrameOrigin(CGPoint(x: x, y: y))
    }

    private var selectedQuality: GIFQuality {
        GIFQuality.allCases.first { $0.title == qualityPopup.titleOfSelectedItem } ?? .standard
    }

    @objc private func stepFPS() { fpsField.integerValue = fpsStepper.integerValue }

    @objc private func updateSize() {
        let size = GIFOutputLayout.outputSize(
            selectionSize: selectionRect.size, backingScale: screen.backingScaleFactor, quality: selectedQuality
        )
        sizeLabel.stringValue = "输出约 \(Int(size.width)) × \(Int(size.height))，3 秒倒计时后开始"
    }

    @objc private func startRecording() {
        let fps = min(30, max(1, fpsField.integerValue))
        fpsField.integerValue = fps
        let options = GIFRecordingOptions(
            framesPerSecond: fps, quality: selectedQuality, showsCursor: cursorCheckbox.state == .on
        )
        AppPreferences.shared.gifFramesPerSecond = fps
        AppPreferences.shared.gifQuality = selectedQuality
        AppPreferences.shared.gifShowsCursor = options.showsCursor
        window?.orderOut(nil)
        onStart?(options)
    }

    @objc private func cancel() {
        window?.orderOut(nil)
        onCancel?()
    }
}

@MainActor
final class GIFRecordingControlController {
    private enum Phase { case countdown, recording, dismissed }

    var onStop: (() -> Void)?
    var onCancel: (() -> Void)?
    private let borderPanel: NSPanel
    private let controlPanel: GIFRecordingPanel
    private let recordingIndicator = NSTextField(labelWithString: "●")
    private let statusLabel = NSTextField(labelWithString: "准备录制…")
    private let optionsLabel: NSTextField
    private let stopButton = NSButton(title: "停止", target: nil, action: nil)
    private var phase: Phase = .countdown

    init(selectionRect: CGRect, screen: NSScreen, options: GIFRecordingOptions) {
        optionsLabel = NSTextField(labelWithString: "\(options.framesPerSecond) FPS · \(options.quality.title) · 鼠标\(options.showsCursor ? "开" : "关")")
        borderPanel = NSPanel(contentRect: selectionRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        borderPanel.level = .statusBar
        borderPanel.backgroundColor = .clear
        borderPanel.isOpaque = false
        borderPanel.hasShadow = false
        borderPanel.ignoresMouseEvents = true
        borderPanel.hidesOnDeactivate = false
        borderPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let border = GIFBorderView(frame: CGRect(origin: .zero, size: selectionRect.size))
        borderPanel.contentView = border

        controlPanel = GIFRecordingPanel(
            contentRect: CGRect(origin: .zero, size: CGSize(width: 570, height: 48)),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        controlPanel.level = .statusBar
        controlPanel.hasShadow = true
        controlPanel.backgroundColor = .windowBackgroundColor
        controlPanel.isMovableByWindowBackground = true
        controlPanel.hidesOnDeactivate = false
        controlPanel.becomesKeyOnlyIfNeeded = true
        controlPanel.worksWhenModal = true
        controlPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let visible = screen.visibleFrame
        let panelSize = controlPanel.frame.size
        let centeredX = selectionRect.midX - panelSize.width / 2
        let x = min(visible.maxX - panelSize.width, max(visible.minX, centeredX))
        let above = selectionRect.maxY + 8
        let below = selectionRect.minY - panelSize.height - 8
        let y = above + panelSize.height <= visible.maxY ? above : max(visible.minY, below)
        controlPanel.setFrameOrigin(CGPoint(x: x, y: y))
        buildUI()
    }

    func presentCountdown(_ value: Int) {
        guard phase != .dismissed else { return }
        phase = .countdown
        statusLabel.stringValue = "\(value) 秒后开始录制"
        recordingIndicator.textColor = .systemOrange
        stopButton.isEnabled = false
        borderPanel.orderFrontRegardless()
        controlPanel.orderFrontRegardless()
    }

    func presentRecording() {
        guard phase != .dismissed else { return }
        phase = .recording
        statusLabel.stringValue = "00:00 · 估算 0 KB"
        recordingIndicator.textColor = .systemRed
        stopButton.isEnabled = true
        borderPanel.orderFrontRegardless()
        controlPanel.orderFrontRegardless()
    }

    func update(duration: TimeInterval, bytes: Int64) {
        guard phase == .recording else { return }
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        statusLabel.stringValue = String(format: "%02d:%02d · 估算 %@", minutes, seconds, ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
    }

    func dismiss() {
        guard phase != .dismissed else { return }
        phase = .dismissed
        borderPanel.orderOut(nil)
        controlPanel.orderOut(nil)
    }

    private func buildUI() {
        guard let content = controlPanel.contentView else { return }
        statusLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        recordingIndicator.textColor = .systemOrange
        recordingIndicator.font = .systemFont(ofSize: 12, weight: .bold)
        optionsLabel.textColor = .secondaryLabelColor
        optionsLabel.font = .systemFont(ofSize: 11)
        stopButton.target = self
        stopButton.action = #selector(stop)
        stopButton.bezelStyle = .rounded
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancel))
        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.heightAnchor.constraint(equalToConstant: 22).isActive = true
        let stack = NSStackView(views: [recordingIndicator, statusLabel, optionsLabel, divider, stopButton, cancel])
        stack.alignment = .centerY
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor)
        ])
    }

    @objc private func stop() { onStop?() }
    @objc private func cancel() { onCancel?() }
}

@MainActor
final class GIFPreviewWindowController: NSWindowController, NSWindowDelegate {
    enum Action { case saved, rerecord, discarded }
    var onAction: ((Action) -> Void)?
    private let result: GIFRecordingResult

    init(result: GIFRecordingResult) {
        self.result = result
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 760, height: 600),
            styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false
        )
        window.title = "横截 — GIF 预览"
        window.center()
        super.init(window: window)
        window.delegate = self
        buildUI()
    }

    required init?(coder: NSCoder) { nil }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        let imageView = NSImageView()
        imageView.image = NSImage(contentsOf: result.url)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.animates = true
        imageView.wantsLayer = true
        imageView.layer?.backgroundColor = NSColor.black.cgColor
        let metadata = NSTextField(labelWithString: String(
            format: "%d × %d · %d FPS · %.1f 秒 · %@",
            Int(result.pixelSize.width), Int(result.pixelSize.height), result.framesPerSecond, result.duration,
            ByteCountFormatter.string(fromByteCount: result.fileSize, countStyle: .file)
        ))
        metadata.textColor = .secondaryLabelColor
        let save = NSButton(title: "保存 GIF", target: self, action: #selector(saveGIF))
        save.keyEquivalent = "\r"
        let rerecord = NSButton(title: "重新录制", target: self, action: #selector(rerecord))
        let discard = NSButton(title: "放弃", target: self, action: #selector(discard))
        let actions = NSStackView(views: [metadata, save, rerecord, discard])
        actions.alignment = .centerY
        actions.spacing = 8
        let root = NSStackView(views: [imageView, actions])
        root.orientation = .vertical
        root.spacing = 10
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            root.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14)
        ])
    }

    @objc private func saveGIF() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.gif]
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        panel.nameFieldStringValue = "横截 GIF \(formatter.string(from: Date())).gif"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.copyItem(at: result.url, to: destination)
            cleanup()
            onAction?(.saved)
        } catch { NSAlert(error: error).runModal() }
    }

    @objc private func rerecord() { cleanup(); onAction?(.rerecord) }
    @objc private func discard() { cleanup(); onAction?(.discarded) }

    func windowWillClose(_ notification: Notification) {
        if FileManager.default.fileExists(atPath: result.url.path) {
            try? FileManager.default.removeItem(at: result.url)
            onAction?(.discarded)
        }
    }

    private func cleanup() {
        try? FileManager.default.removeItem(at: result.url)
        window?.delegate = nil
        close()
    }
}

private final class GIFPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class GIFRecordingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class GIFBorderView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemRed.setStroke()
        let path = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1))
        path.lineWidth = 2
        path.stroke()
    }
}
