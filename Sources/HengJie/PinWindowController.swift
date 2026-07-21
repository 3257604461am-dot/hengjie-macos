import AppKit
import HengJieAnnotation
import HengJieCore

@MainActor
final class PinWindowController: NSWindowController, NSWindowDelegate {
    private static var retained: [PinWindowController] = []
    private let toolbarHeight: CGFloat = 42
    private let imageAspectRatio: CGFloat
    private let canvas: AnnotationCanvas
    private let colorWell = NSColorWell()
    private let widthSlider = NSSlider(value: 4, minValue: 1, maxValue: 16, target: nil, action: nil)
    private var toolButtons: [NSButton] = []

    init(image: CGImage, displaySize: CGSize, preferredFrame: CGRect) {
        let screen = Self.targetScreen(for: preferredFrame) ?? NSScreen.main ?? NSScreen.screens.first
        let available = screen?.visibleFrame.size ?? CGSize(width: 1280, height: 800)
        let size = PinnedImageLayout.fittedSize(imageSize: displaySize, availableSize: CGSize(width: available.width, height: max(1, available.height - toolbarHeight)))
        imageAspectRatio = displaySize.width / max(1, displaySize.height)
        canvas = AnnotationCanvas(image: image, displaySize: size)

        let ratio = displaySize.width > 0 ? size.width / displaySize.width : 1
        let origin: CGPoint
        if ratio == 1 {
            origin = preferredFrame.origin
        } else if let screen {
            origin = CGPoint(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.midY - (size.height + toolbarHeight) / 2)
        } else {
            origin = .zero
        }

        let panel = EditablePinPanel(
            contentRect: CGRect(x: origin.x, y: origin.y, width: size.width, height: size.height + toolbarHeight),
            styleMask: [.borderless, .resizable], backing: .buffered, defer: false
        )
        panel.level = .statusBar
        panel.isMovableByWindowBackground = true
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentMinSize = CGSize(width: 280, height: 180 + toolbarHeight)
        super.init(window: panel)
        panel.delegate = self
        buildUI(in: panel)
        PinWindowController.retained.append(self)
    }

    required init?(coder: NSCoder) { nil }

    func present() {
        window?.orderFrontRegardless()
    }

    private func buildUI(in panel: NSPanel) {
        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        panel.contentView = content

        let toolbar = NSVisualEffectView()
        toolbar.material = .hudWindow
        toolbar.blendingMode = .withinWindow
        toolbar.state = .active
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        canvas.translatesAutoresizingMaskIntoConstraints = false
        canvas.autoresizingMask = [.width, .height]
        content.addSubview(toolbar)
        content.addSubview(canvas)

        let controls = NSStackView()
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 5
        controls.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(controls)

        for tool in [AnnotationTool.pen, .highlighter, .mosaic] {
            let button = makeButton(tool.title, #selector(selectTool(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(tool.rawValue)
            button.setButtonType(.toggle)
            button.state = tool == .pen ? .on : .off
            toolButtons.append(button)
            controls.addArrangedSubview(button)
        }
        canvas.selectedTool = .pen

        colorWell.color = .systemRed
        colorWell.supportsAlpha = true
        colorWell.target = self
        colorWell.action = #selector(updateStyle)
        colorWell.translatesAutoresizingMaskIntoConstraints = false
        colorWell.widthAnchor.constraint(equalToConstant: 34).isActive = true
        widthSlider.target = self
        widthSlider.action = #selector(updateStyle)
        widthSlider.translatesAutoresizingMaskIntoConstraints = false
        widthSlider.widthAnchor.constraint(equalToConstant: 72).isActive = true
        controls.addArrangedSubview(colorWell)
        controls.addArrangedSubview(widthSlider)
        controls.addArrangedSubview(makeButton("撤销", #selector(undo)))
        controls.addArrangedSubview(makeButton("复制", #selector(copyImage)))
        controls.addArrangedSubview(makeButton("解除钉", #selector(unpin)))

        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            toolbar.topAnchor.constraint(equalTo: content.topAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: toolbarHeight),
            canvas.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            canvas.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            canvas.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            controls.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 7),
            controls.trailingAnchor.constraint(lessThanOrEqualTo: toolbar.trailingAnchor, constant: -7),
            controls.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor)
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
    }

    @objc private func undo() { canvas.undo() }
    @objc private func copyImage() {
        guard let image = canvas.renderedCGImage() else { return }
        ImageExport.copy(image, displaySize: canvas.bounds.size)
    }
    @objc private func unpin() { close() }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        let proposedContent = sender.contentRect(forFrameRect: CGRect(origin: .zero, size: frameSize)).size
        let imageHeight = max(120, proposedContent.width / max(0.01, imageAspectRatio))
        let contentSize = CGSize(width: proposedContent.width, height: imageHeight + toolbarHeight)
        return sender.frameRect(forContentRect: CGRect(origin: .zero, size: contentSize)).size
    }

    func windowWillClose(_ notification: Notification) {
        PinWindowController.retained.removeAll { $0 === self }
    }

    private static func targetScreen(for frame: CGRect) -> NSScreen? {
        NSScreen.screens.max { first, second in
            first.frame.intersection(frame).area < second.frame.intersection(frame).area
        }
    }
}

private final class EditablePinPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private extension CGRect {
    var area: CGFloat { isNull || isEmpty ? 0 : width * height }
}
