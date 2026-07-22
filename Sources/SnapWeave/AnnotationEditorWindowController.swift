import AppKit
import SnapWeaveAnnotation
import SnapWeaveCore

enum EditorPresentationMode {
    case inlineSelection
    case fitToWindow
}

@MainActor
final class AnnotationEditorWindowController: NSWindowController, NSWindowDelegate {
    private let canvas: AnnotationCanvas
    private let presentationMode: EditorPresentationMode
    private let closeHandler: (AnnotationEditorWindowController) -> Void
    private let historyID: UUID?
    private let colorWell = NSColorWell()
    private let widthSlider = NSSlider(value: 4, minValue: 1, maxValue: 16, target: nil, action: nil)
    private var toolButtons: [NSButton] = []
    private var undoButton: NSButton!
    private var redoButton: NSButton!
    private let scrollView = NSScrollView()
    private let zoomLabel = NSTextField(labelWithString: "100%")
    private var didApplyInitialFit = false

    init(
        image: CGImage,
        displaySize: CGSize? = nil,
        annotations: [AnnotationMarkRecord] = [],
        historyID: UUID? = nil,
        presentationMode: EditorPresentationMode = .fitToWindow,
        closeHandler: @escaping (AnnotationEditorWindowController) -> Void
    ) {
        canvas = AnnotationCanvas(image: image, displaySize: displaySize)
        self.presentationMode = presentationMode
        self.closeHandler = closeHandler
        self.historyID = historyID
        let visible = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1200, height: 800)
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: min(1280, visible.width * 0.88), height: min(860, visible.height * 0.88)),
            styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false
        )
        window.title = "SnapWeave — 标注"
        window.center()
        super.init(window: window)
        window.delegate = self
        buildUI()
        canvas.textProvider = { Self.requestText(title: "添加文字", prompt: "输入要标注的文字") }
        canvas.textEditProvider = { value in Self.requestText(title: "编辑文字", prompt: "修改标注文字", initialValue: value) }
        if !annotations.isEmpty { canvas.restore(records: annotations) }
        canvas.onHistoryChange = { [weak self] in
            guard let self else { return }
            updateHistoryButtons()
            if let historyID { ScreenshotHistoryService.shared.scheduleUpdate(id: historyID, annotations: canvas.annotationRecords()) }
        }
    }

    required init?(coder: NSCoder) { nil }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        let root = NSStackView()
        root.orientation = .vertical
        root.spacing = 0
        root.translatesAutoresizingMaskIntoConstraints = false

        let toolbar = NSStackView()
        toolbar.orientation = .horizontal
        toolbar.alignment = .centerY
        toolbar.spacing = 5
        toolbar.setHuggingPriority(.required, for: .vertical)

        for tool in AnnotationTool.allCases {
            let button = NSButton(title: tool.title, target: self, action: #selector(selectTool(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(tool.rawValue)
            button.bezelStyle = .texturedRounded
            button.setButtonType(.toggle)
            button.state = tool == .select ? .on : .off
            toolButtons.append(button)
            toolbar.addArrangedSubview(button)
        }
        colorWell.color = .systemRed
        colorWell.target = self
        colorWell.action = #selector(updateStyle)
        colorWell.translatesAutoresizingMaskIntoConstraints = false
        colorWell.widthAnchor.constraint(equalToConstant: 36).isActive = true
        widthSlider.target = self
        widthSlider.action = #selector(updateStyle)
        widthSlider.translatesAutoresizingMaskIntoConstraints = false
        widthSlider.widthAnchor.constraint(equalToConstant: 70).isActive = true
        toolbar.addArrangedSubview(colorWell)
        toolbar.addArrangedSubview(widthSlider)

        undoButton = button("撤销", #selector(undo))
        redoButton = button("重做", #selector(redo))
        let actions = NSStackView()
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 5
        actions.addArrangedSubview(undoButton)
        actions.addArrangedSubview(redoButton)
        actions.addArrangedSubview(button("删除标注", #selector(deleteSelectedMark)))
        actions.addArrangedSubview(button("适合", #selector(fitToWindow)))
        actions.addArrangedSubview(button("−", #selector(zoomOut)))
        zoomLabel.alignment = .center
        zoomLabel.translatesAutoresizingMaskIntoConstraints = false
        zoomLabel.widthAnchor.constraint(equalToConstant: 48).isActive = true
        actions.addArrangedSubview(zoomLabel)
        actions.addArrangedSubview(button("+", #selector(zoomIn)))
        actions.addArrangedSubview(button("100%", #selector(actualSize)))
        actions.addArrangedSubview(button("水印", #selector(addWatermark)))
        actions.addArrangedSubview(button("OCR", #selector(recognizeText)))
        actions.addArrangedSubview(button("复制", #selector(copyImage)))
        actions.addArrangedSubview(button("保存", #selector(saveImage)))

        let toolbarContainer = NSStackView(views: [toolbar, actions])
        toolbarContainer.orientation = .vertical
        toolbarContainer.alignment = .leading
        toolbarContainer.spacing = 5
        toolbarContainer.edgeInsets = NSEdgeInsets(top: 7, left: 10, bottom: 7, right: 10)
        toolbarContainer.setHuggingPriority(.required, for: .vertical)

        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = false
        scrollView.backgroundColor = .darkGray
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.001
        scrollView.maxMagnification = 4
        scrollView.contentView = CenteringClipView(frame: scrollView.bounds)
        scrollView.documentView = canvas
        root.addArrangedSubview(toolbarContainer)
        root.addArrangedSubview(scrollView)
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            root.topAnchor.constraint(equalTo: content.topAnchor),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
        updateHistoryButtons()
        DispatchQueue.main.async { [weak self] in self?.applyInitialFitIfNeeded() }
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .texturedRounded
        return button
    }

    @objc private func selectTool(_ sender: NSButton) {
        guard let value = sender.identifier?.rawValue, let tool = AnnotationTool(rawValue: value) else { return }
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
    @objc private func deleteSelectedMark() { canvas.deleteSelectedMark() }
    private func updateHistoryButtons() {
        undoButton?.isEnabled = canvas.canUndo
        redoButton?.isEnabled = canvas.canRedo
    }

    @objc private func fitToWindow() {
        window?.contentView?.layoutSubtreeIfNeeded()
        let available = scrollView.contentSize
        guard canvas.bounds.width > 0, canvas.bounds.height > 0, available.width > 0, available.height > 0 else { return }
        let scale = PreviewLayout.fitScale(imageSize: canvas.bounds.size, viewportSize: available)
        setZoom(max(scrollView.minMagnification, min(scrollView.maxMagnification, scale)))
    }

    @objc private func zoomIn() { setZoom(min(scrollView.maxMagnification, scrollView.magnification * 1.25)) }
    @objc private func zoomOut() { setZoom(max(scrollView.minMagnification, scrollView.magnification / 1.25)) }
    @objc private func actualSize() { setZoom(1) }

    private func setZoom(_ value: CGFloat) {
        scrollView.setMagnification(value, centeredAt: CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY))
        zoomLabel.stringValue = "\(Int((value * 100).rounded()))%"
    }

    private func applyInitialFitIfNeeded() {
        guard !didApplyInitialFit else { return }
        window?.contentView?.layoutSubtreeIfNeeded()
        guard scrollView.contentSize.width > 0, scrollView.contentSize.height > 0 else { return }
        didApplyInitialFit = true
        if presentationMode == .fitToWindow { fitToWindow() }
    }

    @objc private func addWatermark() {
        if let text = Self.requestText(title: "添加水印", prompt: "水印将以半透明方式平铺") { canvas.addWatermark(text) }
    }

    @objc private func copyImage() {
        guard let image = canvas.renderedCGImage() else { return }
        ImageExport.copy(image, displaySize: canvas.bounds.size)
        completeHistoryIfNeeded()
        transientNotice("已复制到剪贴板")
    }

    @objc private func saveImage() {
        guard let image = canvas.renderedCGImage() else { return }
        Task { [weak self] in
            do {
                if try await ImageExport.saveAsync(image, format: AppPreferences.shared.saveFormat) {
                    self?.completeHistoryIfNeeded()
                }
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    @objc private func recognizeText() {
        guard let image = canvas.renderedCGImage() else { return }
        let controller = OCRResultWindowController.presentRecognizing()
        controller.recognize(image, displaySize: canvas.bounds.size)
    }

    private func transientNotice(_ text: String) {
        window?.title = "SnapWeave — \(text)"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.window?.title = "SnapWeave — 标注" }
    }

    private func completeHistoryIfNeeded() {
        guard let historyID else { return }
        ScreenshotHistoryService.shared.complete(id: historyID, annotations: canvas.annotationRecords())
    }

    static func requestText(title: String, prompt: String, initialValue: String = "") -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = prompt
        let field = NSTextField(frame: CGRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = initialValue
        alert.accessoryView = field
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func windowWillClose(_ notification: Notification) { closeHandler(self) }
    func windowDidBecomeKey(_ notification: Notification) { applyInitialFitIfNeeded() }
}

final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var constrained = super.constrainBoundsRect(proposedBounds)
        guard let documentView else { return constrained }
        let documentFrame = documentView.frame
        if proposedBounds.width > documentFrame.width {
            constrained.origin.x = (documentFrame.width - proposedBounds.width) / 2
        }
        if proposedBounds.height > documentFrame.height {
            constrained.origin.y = (documentFrame.height - proposedBounds.height) / 2
        }
        return constrained
    }
}
