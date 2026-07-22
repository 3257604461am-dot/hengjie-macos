import AppKit
import SnapWeaveAnnotation
import QuartzCore

@MainActor
final class StandardCaptureOverlayController: NSWindowController {
    private enum State { case editing, completed, cancelled }

    private let completion: () -> Void
    private var state: State = .editing

    init(image: CGImage, globalRect: CGRect, historyID: UUID? = nil, completion: @escaping () -> Void) {
        self.completion = completion
        let union = NSScreen.screens.map(\.frame).reduce(CGRect.null) { $0.union($1) }
        let panel = CapturePanel(contentRect: union, styleMask: [.borderless], backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.acceptsMouseMovedEvents = true
        super.init(window: panel)
        let localRect = globalRect.offsetBy(dx: -union.minX, dy: -union.minY)
        let editor = InlineEditingOverlayView(frame: CGRect(origin: .zero, size: union.size), image: image, selectionRect: localRect)
        editor.onFinish = { [weak self] image, annotations in
            ImageExport.copy(image, displaySize: globalRect.size)
            if let historyID { ScreenshotHistoryService.shared.complete(id: historyID, annotations: annotations) }
            self?.finish()
        }
        editor.onProjectChange = { annotations in
            if let historyID { ScreenshotHistoryService.shared.scheduleUpdate(id: historyID, annotations: annotations) }
        }
        editor.onCancel = { [weak self] in self?.cancel() }
        panel.contentView = editor
    }

    required init?(coder: NSCoder) { nil }

    func begin() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(window?.contentView)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func finish() {
        guard state == .editing else { return }
        state = .completed
        window?.orderOut(nil)
        completion()
    }

    private func cancel() {
        guard state != .completed, state != .cancelled else { return }
        state = .cancelled
        window?.orderOut(nil)
        completion()
    }
}

private final class CapturePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class InlineEditingOverlayView: NSView {
    var onFinish: ((CGImage, [AnnotationMarkRecord]) -> Void)?
    var onCancel: (() -> Void)?
    var onProjectChange: (([AnnotationMarkRecord]) -> Void)?
    private let canvas: AnnotationCanvas
    private let selectionRect: CGRect
    private let toolbar: InlineAnnotationToolbar

    init(frame: CGRect, image: CGImage, selectionRect: CGRect) {
        self.selectionRect = selectionRect
        canvas = AnnotationCanvas(image: image, displaySize: selectionRect.size)
        toolbar = InlineAnnotationToolbar(canvas: canvas)
        super.init(frame: frame)
        canvas.frame.origin = selectionRect.origin
        addSubview(canvas)
        addSubview(toolbar)
        positionToolbar()
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            toolbar.alphaValue = 0
            DispatchQueue.main.async { [weak toolbar] in
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.16
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    toolbar?.animator().alphaValue = 1
                }
            }
        }
        toolbar.onFinish = { [weak self] in
            guard let self else { return }
            guard let image = self.canvas.renderedCGImage() else { return }
            self.onFinish?(image, self.canvas.annotationRecords())
        }
        toolbar.onCancel = { [weak self] in self?.onCancel?() }
        canvas.onHistoryChange = { [weak self] in
            guard let self else { return }
            self.onProjectChange?(self.canvas.annotationRecords())
        }
    }

    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() }
        else if event.keyCode == 36, let image = canvas.renderedCGImage() { onFinish?(image, canvas.annotationRecords()) }
        else { super.keyDown(with: event) }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.48).setFill()
        bounds.fill()
        NSColor.systemBlue.setStroke()
        let border = NSBezierPath(rect: selectionRect)
        border.lineWidth = 2
        border.stroke()
    }

    private func positionToolbar() {
        let margin: CGFloat = 8
        let width = min(790, bounds.width - margin * 2)
        let height: CGFloat = 82
        let x = max(margin, min(selectionRect.minX, bounds.maxX - width - margin))
        let y = selectionRect.minY >= height + margin
            ? selectionRect.minY - height - margin
            : min(bounds.maxY - height - margin, selectionRect.maxY + margin)
        toolbar.frame = CGRect(x: x, y: y, width: width, height: height)
    }
}

@MainActor
final class InlineAnnotationToolbar: NSVisualEffectView {
    var onFinish: (() -> Void)?
    var onCancel: (() -> Void)?
    private let canvas: AnnotationCanvas
    private var toolButtons: [NSButton] = []
    private let colorWell = NSColorWell()
    private let widthSlider = NSSlider(value: 4, minValue: 1, maxValue: 16, target: nil, action: nil)

    init(canvas: AnnotationCanvas) {
        self.canvas = canvas
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 9
        buildUI()
        canvas.textProvider = { AnnotationEditorWindowController.requestText(title: "添加文字", prompt: "输入要标注的文字") }
        canvas.textEditProvider = { value in AnnotationEditorWindowController.requestText(title: "编辑文字", prompt: "修改标注文字", initialValue: value) }
    }

    required init?(coder: NSCoder) { nil }

    private func buildUI() {
        let tools = NSStackView()
        tools.orientation = .horizontal
        tools.spacing = 4
        for tool in AnnotationTool.allCases {
            let button = makeButton(tool.title, #selector(selectTool(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(tool.rawValue)
            button.setButtonType(.toggle)
            button.state = tool == .select ? .on : .off
            toolButtons.append(button)
            tools.addArrangedSubview(button)
        }
        colorWell.color = .systemRed
        colorWell.target = self
        colorWell.action = #selector(updateStyle)
        colorWell.widthAnchor.constraint(equalToConstant: 34).isActive = true
        widthSlider.target = self
        widthSlider.action = #selector(updateStyle)
        widthSlider.widthAnchor.constraint(equalToConstant: 64).isActive = true
        tools.addArrangedSubview(colorWell)
        tools.addArrangedSubview(widthSlider)

        let actions = NSStackView()
        actions.orientation = .horizontal
        actions.spacing = 5
        [
            makeButton("撤销", #selector(undo)), makeButton("重做", #selector(redo)),
            makeButton("删除标注", #selector(deleteSelected)),
            makeButton("水印", #selector(addWatermark)), makeButton("OCR", #selector(recognizeText)),
            makeButton("保存", #selector(saveImage)),
            makeButton("取消", #selector(cancel)), makeButton("完成", #selector(finish))
        ].forEach(actions.addArrangedSubview)
        actions.arrangedSubviews.last?.setContentHuggingPriority(.required, for: .horizontal)

        let root = NSStackView(views: [tools, actions])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 6
        root.edgeInsets = NSEdgeInsets(top: 7, left: 8, bottom: 7, right: 8)
        root.translatesAutoresizingMaskIntoConstraints = false
        addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: leadingAnchor), root.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            root.topAnchor.constraint(equalTo: topAnchor), root.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    private func makeButton(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .texturedRounded
        button.controlSize = .small
        return button
    }

    @objc private func selectTool(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let tool = AnnotationTool(rawValue: raw) else { return }
        canvas.selectedTool = tool
        toolButtons.forEach { $0.state = $0 === sender ? .on : .off }
    }
    @objc private func updateStyle() {
        canvas.selectedColor = colorWell.color
        canvas.selectedLineWidth = CGFloat(widthSlider.doubleValue)
        canvas.applyStyleToSelection(color: colorWell.color, lineWidth: CGFloat(widthSlider.doubleValue))
    }
    @objc private func undo() { canvas.undo() }
    @objc private func redo() { canvas.redo() }
    @objc private func deleteSelected() { canvas.deleteSelectedMark() }
    @objc private func addWatermark() {
        if let text = AnnotationEditorWindowController.requestText(title: "添加水印", prompt: "水印将以半透明方式平铺") { canvas.addWatermark(text) }
    }
    @objc private func recognizeText() {
        guard let image = canvas.renderedCGImage() else { return }
        let controller = OCRResultWindowController.presentRecognizing()
        controller.recognize(image, displaySize: canvas.bounds.size)
    }
    @objc private func saveImage() {
        guard let image = canvas.renderedCGImage() else { return }
        Task {
            do { _ = try await ImageExport.saveAsync(image, format: AppPreferences.shared.saveFormat) }
            catch { NSAlert(error: error).runModal() }
        }
    }
    @objc private func cancel() { onCancel?() }
    @objc private func finish() { onFinish?() }
}
