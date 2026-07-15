import AppKit
import HengJieCore

@MainActor
final class SelectionOverlayController: NSWindowController {
    private let completion: (CGRect?) -> Void

    init(completion: @escaping (CGRect?) -> Void) {
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
        let view = SelectionOverlayView(frame: CGRect(origin: .zero, size: union.size))
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
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeFirstResponder(window?.contentView)
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

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let location = window?.mouseLocationOutsideOfEventStream {
            cursorPoint = convert(location, from: nil)
            needsDisplay = true
        }
    }

    override func mouseDown(with event: NSEvent) {
        phase = .selecting
        start = convert(event.locationInWindow, from: nil)
        current = start
        needsDisplay = true
    }

    override func rightMouseDown(with event: NSEvent) {
        onCancel?()
    }

    override func mouseDragged(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        cursorPoint = current ?? .zero
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        cursorPoint = convert(event.locationInWindow, from: nil)
        hoveredWindowRect = windowRect(at: cursorPoint)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        let rect = selectionRect.integral
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
            needsDisplay = true
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

            let label = "\(Int(rect.width)) × \(Int(rect.height))"
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
        guard let window else { return nil }
        let appKitPoint = window.convertPoint(toScreen: localPoint)
        let mainTop = NSScreen.screens.first?.frame.maxY ?? 0
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for entry in info {
            guard (entry[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let ownerPID = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.intValue,
                  ownerPID != ProcessInfo.processInfo.processIdentifier,
                  let boundsDictionary = entry[kCGWindowBounds as String] as? NSDictionary,
                  let cgRect = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary) else { continue }
            let appKitRect = CGRect(x: cgRect.minX, y: mainTop - cgRect.maxY, width: cgRect.width, height: cgRect.height)
            if appKitRect.contains(appKitPoint) {
                return appKitRect.offsetBy(dx: -window.frame.minX, dy: -window.frame.minY)
            }
        }
        return nil
    }
}
