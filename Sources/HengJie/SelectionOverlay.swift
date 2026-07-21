import AppKit
import HengJieCore
import QuartzCore

enum SelectionConstraint: Equatable {
    case free
    case aspectRatio(CGFloat)
    case fixedPixels(CGSize)
}

@MainActor
final class SelectionOverlayController: NSWindowController {
    private let completion: (CGRect?) -> Void

    init(allowsConstraints: Bool = true, completion: @escaping (CGRect?) -> Void) {
        self.completion = completion
        let union = NSScreen.screens.map(\.frame).reduce(CGRect.null) { $0.union($1) }
        let panel = NSPanel(
            contentRect: union,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .screenSaver
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = false
        panel.acceptsMouseMovedEvents = true
        super.init(window: panel)
        let view = SelectionOverlayView(frame: CGRect(origin: .zero, size: union.size), allowsConstraints: allowsConstraints)
        view.onComplete = { [weak self] localRect in
            guard let self, let window = self.window else { return }
            let globalRect = localRect.offsetBy(dx: window.frame.minX, dy: window.frame.minY)
            self.finish(globalRect)
        }
        view.onCancel = { [weak self] in self?.finish(nil) }
        panel.contentView = view
    }

    required init?(coder: NSCoder) { nil }

    func begin() {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        window?.alphaValue = reduceMotion ? 1 : 0
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeFirstResponder(window?.contentView)
        guard !reduceMotion else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window?.animator().alphaValue = 1
        }
    }

    /// Dismisses a superseded selection without invoking its completion block.
    /// A newer capture session owns the coordinator state at that point.
    func dismiss() {
        window?.orderOut(nil)
    }

    private func finish(_ rect: CGRect?) {
        window?.orderOut(nil)
        completion(rect)
    }
}

final class SelectionOverlayView: NSView {
    var onComplete: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?
    private var start: CGPoint?
    private var current: CGPoint?
    private var cursorPoint = CGPoint.zero
    private var hoveredWindowRect: CGRect?
    private var phase: SelectionPhase = .idle
    private var constraint: SelectionConstraint = .free
    private weak var constraintBar: SelectionConstraintBar?
    private var cachedWindowRects: [CGRect] = []
    private var windowRefreshPending = false
    private var lastWindowRefresh = Date.distantPast
    private var redrawWorkItem: DispatchWorkItem?
    private var lastRedrawAt = Date.distantPast

    init(frame frameRect: NSRect, allowsConstraints: Bool) {
        super.init(frame: frameRect)
        if allowsConstraints {
            let bar = SelectionConstraintBar(frame: CGRect(x: 20, y: frameRect.height - 54, width: 590, height: 40))
            bar.onChange = { [weak self] value in
                self?.constraint = value
                self?.scheduleRedraw(force: true)
            }
            addSubview(bar)
            constraintBar = bar
        }
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let location = window?.mouseLocationOutsideOfEventStream {
            cursorPoint = convert(location, from: nil)
            positionConstraintBar(near: cursorPoint)
            refreshWindowRectsIfNeeded(force: true)
            scheduleRedraw(force: true)
        }
    }

    override func mouseDown(with event: NSEvent) {
        phase = .selecting
        start = convert(event.locationInWindow, from: nil)
        current = start
        scheduleRedraw(force: true)
    }

    override func rightMouseDown(with event: NSEvent) {
        onCancel?()
    }

    override func mouseDragged(with event: NSEvent) {
        current = constrainedPoint(convert(event.locationInWindow, from: nil))
        cursorPoint = current ?? .zero
        scheduleRedraw()
    }

    override func mouseMoved(with event: NSEvent) {
        cursorPoint = convert(event.locationInWindow, from: nil)
        hoveredWindowRect = windowRect(at: cursorPoint)
        refreshWindowRectsIfNeeded()
        scheduleRedraw()
    }

    override func mouseUp(with event: NSEvent) {
        current = constrainedPoint(convert(event.locationInWindow, from: nil))
        let rect = selectionRect.integral
        if !bounds.contains(rect) {
            let alert = NSAlert()
            alert.messageText = "固定选区超出屏幕"
            alert.informativeText = "请缩小固定尺寸，或从更靠近屏幕中央的位置开始框选。"
            alert.runModal()
            phase = .idle
            start = nil
            current = nil
            scheduleRedraw(force: true)
            return
        }
        if rect.width >= 4, rect.height >= 4 {
            phase = .selected
            onComplete?(rect)
        } else if let hoveredWindowRect {
            phase = .selected
            onComplete?(hoveredWindowRect.intersection(bounds))
        } else {
            phase = .idle
            start = nil
            current = nil
            scheduleRedraw(force: true)
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() }
        else { super.keyDown(with: event) }
    }

    private var selectionRect: CGRect {
        guard let start, let current else { return .zero }
        return CGRect(
            x: min(start.x, current.x), y: min(start.y, current.y),
            width: abs(current.x - start.x), height: abs(current.y - start.y)
        )
    }

    private func constrainedPoint(_ raw: CGPoint) -> CGPoint {
        guard let start else { return raw }
        let dx = raw.x - start.x
        let dy = raw.y - start.y
        let signX: CGFloat = dx < 0 ? -1 : 1
        let signY: CGFloat = dy < 0 ? -1 : 1
        switch constraint {
        case .free:
            return raw
        case let .aspectRatio(ratio):
            guard ratio > 0 else { return raw }
            let size = PreciseSelectionRules.constrainedSize(deltaWidth: dx, deltaHeight: dy, aspectRatio: ratio)
            return CGPoint(x: start.x + size.width * signX, y: start.y + size.height * signY)
        case let .fixedPixels(pixelSize):
            let scale = backingScale(at: start)
            let size = PreciseSelectionRules.logicalSize(pixelSize: pixelSize, backingScale: scale)
            return CGPoint(
                x: start.x + size.width * signX,
                y: start.y + size.height * signY
            )
        }
    }

    private func backingScale(at localPoint: CGPoint) -> CGFloat {
        guard let window else { return 1 }
        let global = window.convertPoint(toScreen: localPoint)
        return NSScreen.screens.first(where: { $0.frame.contains(global) })?.backingScaleFactor ?? 1
    }

    private func positionConstraintBar(near localPoint: CGPoint) {
        guard let bar = constraintBar, let window else { return }
        let global = window.convertPoint(toScreen: localPoint)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(global) }) ?? NSScreen.main else { return }
        let localScreen = screen.frame.offsetBy(dx: -window.frame.minX, dy: -window.frame.minY)
        let x = min(localScreen.maxX - bar.frame.width - 12, max(localScreen.minX + 12, localPoint.x - bar.frame.width / 2))
        bar.setFrameOrigin(CGPoint(x: x, y: localScreen.maxY - bar.frame.height - 12))
    }

    override func draw(_ dirtyRect: NSRect) {
        if SelectionDimmingPolicy.shouldDim(phase) {
            NSColor.black.withAlphaComponent(0.30).setFill()
            bounds.fill()
        }
        let rect = selectionRect
        if rect.isEmpty, let hoveredWindowRect {
            NSColor.systemBlue.setStroke()
            let hoverBorder = NSBezierPath(rect: hoveredWindowRect)
            hoverBorder.lineWidth = 2
            hoverBorder.stroke()
        }
        if !rect.isEmpty {
            NSGraphicsContext.current?.saveGraphicsState()
            NSGraphicsContext.current?.compositingOperation = .clear
            rect.fill()
            NSGraphicsContext.current?.restoreGraphicsState()
            NSColor.systemBlue.setStroke()
            let border = NSBezierPath(rect: rect)
            border.lineWidth = 2
            border.stroke()

            let scale = backingScale(at: start ?? rect.origin)
            let label = "\(Int(rect.width)) × \(Int(rect.height)) pt · \(Int(rect.width * scale)) × \(Int(rect.height * scale)) px"
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor.white,
                .backgroundColor: NSColor.systemBlue
            ]
            label.draw(at: CGPoint(x: rect.minX, y: max(2, rect.minY - 20)), withAttributes: attributes)
        }
        drawCancelHint(at: cursorPoint)
        drawMagnifier(at: cursorPoint)
    }

    private func drawCancelHint(at point: CGPoint) {
        guard point != .zero else { return }
        let size = CGSize(width: 210, height: 28)
        let x = min(bounds.maxX - size.width - 8, max(bounds.minX + 8, point.x + 18))
        let preferredY = point.y - size.height - 18
        let y = min(bounds.maxY - size.height - 8, max(bounds.minY + 8, preferredY))
        let box = CGRect(origin: CGPoint(x: x, y: y), size: size)
        NSColor.windowBackgroundColor.withAlphaComponent(0.94).setFill()
        NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).fill()
        "左键拖动框选 · 右键取消（Esc）".draw(
            at: CGPoint(x: box.minX + 8, y: box.minY + 7),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.labelColor
            ]
        )
    }

    private func drawMagnifier(at point: CGPoint) {
        guard point != .zero else { return }
        let box = CGRect(x: min(bounds.maxX - 128, point.x + 18), y: min(bounds.maxY - 58, point.y + 18), width: 110, height: 40)
        NSColor.windowBackgroundColor.withAlphaComponent(0.94).setFill()
        NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).fill()
        let global = window?.convertPoint(toScreen: point) ?? point
        let text = "x \(Int(global.x))  y \(Int(global.y))"
        text.draw(at: CGPoint(x: box.minX + 8, y: box.minY + 12), withAttributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.labelColor
        ])
    }

    private func windowRect(at localPoint: CGPoint) -> CGRect? {
        cachedWindowRects.first { $0.contains(localPoint) }
    }

    private func refreshWindowRectsIfNeeded(force: Bool = false) {
        guard let window, !windowRefreshPending,
              force || Date().timeIntervalSince(lastWindowRefresh) >= 0.12 else { return }
        windowRefreshPending = true
        let mainTop = NSScreen.screens.first?.frame.maxY ?? 0
        let windowOrigin = window.frame.origin
        let ownPID = ProcessInfo.processInfo.processIdentifier
        DispatchQueue.global(qos: .userInteractive).async {
            let info = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
            ) as? [[String: Any]] ?? []
            let rects = info.compactMap { entry -> CGRect? in
                guard (entry[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                      let ownerPID = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.intValue,
                      ownerPID != ownPID,
                      let dictionary = entry[kCGWindowBounds as String] as? NSDictionary,
                      let cgRect = CGRect(dictionaryRepresentation: dictionary as CFDictionary),
                      cgRect.width >= 4, cgRect.height >= 4 else { return nil }
                return CGRect(
                    x: cgRect.minX - windowOrigin.x,
                    y: mainTop - cgRect.maxY - windowOrigin.y,
                    width: cgRect.width,
                    height: cgRect.height
                )
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                cachedWindowRects = rects
                lastWindowRefresh = Date()
                windowRefreshPending = false
                hoveredWindowRect = windowRect(at: cursorPoint)
                scheduleRedraw()
            }
        }
    }

    private func scheduleRedraw(force: Bool = false) {
        if force {
            redrawWorkItem?.cancel()
            redrawWorkItem = nil
            lastRedrawAt = Date()
            needsDisplay = true
            return
        }
        guard redrawWorkItem == nil else { return }
        let interval = max(0, (1.0 / 60.0) - Date().timeIntervalSince(lastRedrawAt))
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            redrawWorkItem = nil
            lastRedrawAt = Date()
            needsDisplay = true
        }
        redrawWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: work)
    }
}

@MainActor
private final class SelectionConstraintBar: NSVisualEffectView {
    var onChange: ((SelectionConstraint) -> Void)?
    private let mode = NSPopUpButton()
    private let first = NSTextField(string: "16")
    private let second = NSTextField(string: "9")
    private let separator = NSTextField(labelWithString: ":")
    private let applyButton = NSButton(title: "应用", target: nil, action: nil)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 8
        mode.addItems(withTitles: ["自由选区", "1:1", "4:3", "16:9", "自定义比例", "固定像素"])
        mode.target = self
        mode.action = #selector(modeChanged)
        for field in [first, second] {
            field.alignment = .center
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 64).isActive = true
            field.isHidden = true
        }
        separator.isHidden = true
        applyButton.target = self
        applyButton.action = #selector(applyCustom)
        applyButton.bezelStyle = .rounded
        applyButton.controlSize = .small
        applyButton.isHidden = true
        let hint = NSTextField(labelWithString: "左键拖动框选 · 右键或 Esc 取消")
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: 11)
        let stack = NSStackView(views: [mode, first, separator, second, applyButton, hint])
        stack.alignment = .centerY
        stack.spacing = 7
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }

    @objc private func modeChanged() {
        let custom = mode.indexOfSelectedItem >= 4
        first.isHidden = !custom
        second.isHidden = !custom
        separator.isHidden = !custom
        applyButton.isHidden = !custom
        separator.stringValue = mode.indexOfSelectedItem == 5 ? "×" : ":"
        if mode.indexOfSelectedItem == 5 { first.stringValue = "1920"; second.stringValue = "1080" }
        else if mode.indexOfSelectedItem == 4 { first.stringValue = "16"; second.stringValue = "9" }
        switch mode.indexOfSelectedItem {
        case 0: onChange?(.free)
        case 1: onChange?(.aspectRatio(1))
        case 2: onChange?(.aspectRatio(4.0 / 3.0))
        case 3: onChange?(.aspectRatio(16.0 / 9.0))
        default: break
        }
    }

    @objc private func applyCustom() {
        guard let a = Double(first.stringValue), let b = Double(second.stringValue), a > 0, b > 0 else {
            NSSound.beep()
            return
        }
        if mode.indexOfSelectedItem == 5 { onChange?(.fixedPixels(CGSize(width: a, height: b))) }
        else { onChange?(.aspectRatio(CGFloat(a / b))) }
    }
}
