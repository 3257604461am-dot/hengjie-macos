import AppKit

enum AnnotationTool: String, CaseIterable {
    case pen, line, arrow, rectangle, ellipse, highlighter, text, number, mosaic

    var title: String {
        switch self {
        case .pen: "画笔"
        case .line: "直线"
        case .arrow: "箭头"
        case .rectangle: "矩形"
        case .ellipse: "椭圆"
        case .highlighter: "高亮"
        case .text: "文字"
        case .number: "序号"
        case .mosaic: "马赛克"
        }
    }
}

struct AnnotationMark {
    var tool: AnnotationTool
    var points: [CGPoint]
    var color: NSColor
    var lineWidth: CGFloat
    var text: String?
}

final class AnnotationCanvas: NSView {
    let sourceImage: NSImage
    private let sourceBitmap: NSBitmapImageRep?
    var selectedTool: AnnotationTool = .arrow
    var selectedColor: NSColor = .systemRed
    var selectedLineWidth: CGFloat = 4
    var textProvider: (() -> String?)?
    var onHistoryChange: (() -> Void)?

    private(set) var marks: [AnnotationMark] = []
    private var redoMarks: [AnnotationMark] = []
    private var activePoints: [CGPoint] = []
    private var numberCounter = 1

    init(image: CGImage, displaySize: CGSize? = nil) {
        let logicalSize = displaySize ?? NSSize(width: image.width, height: image.height)
        sourceImage = NSImage(cgImage: image, size: logicalSize)
        sourceBitmap = NSBitmapImageRep(cgImage: image)
        super.init(frame: CGRect(origin: .zero, size: logicalSize))
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        let oldSize = frame.size
        if oldSize.width > 0, oldSize.height > 0, newSize != oldSize {
            let scaleX = newSize.width / oldSize.width
            let scaleY = newSize.height / oldSize.height
            for index in marks.indices {
                marks[index].points = marks[index].points.map { CGPoint(x: $0.x * scaleX, y: $0.y * scaleY) }
                marks[index].lineWidth *= min(scaleX, scaleY)
            }
            activePoints = activePoints.map { CGPoint(x: $0.x * scaleX, y: $0.y * scaleY) }
        }
        super.setFrameSize(newSize)
    }

    override func draw(_ dirtyRect: NSRect) {
        sourceImage.draw(in: bounds)
        for mark in marks { draw(mark) }
        if !activePoints.isEmpty {
            draw(AnnotationMark(tool: selectedTool, points: activePoints, color: selectedColor, lineWidth: selectedLineWidth, text: nil))
        }
    }

    override func mouseDown(with event: NSEvent) {
        activePoints = [convert(event.locationInWindow, from: nil)]
        if selectedTool == .text, let text = textProvider?(), !text.isEmpty {
            commit(text: text)
        } else if selectedTool == .number {
            commit(text: String(numberCounter))
            numberCounter += 1
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if [.pen, .highlighter, .mosaic].contains(selectedTool) { activePoints.append(point) }
        else if activePoints.count == 1 { activePoints.append(point) }
        else { activePoints[1] = point }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard ![.text, .number].contains(selectedTool), !activePoints.isEmpty else { return }
        let point = convert(event.locationInWindow, from: nil)
        if activePoints.count == 1 { activePoints.append(point) }
        commit(text: nil)
    }

    func undo() {
        guard let mark = marks.popLast() else { return }
        redoMarks.append(mark)
        needsDisplay = true
        onHistoryChange?()
    }

    func redo() {
        guard let mark = redoMarks.popLast() else { return }
        marks.append(mark)
        needsDisplay = true
        onHistoryChange?()
    }

    func addWatermark(_ text: String) {
        marks.append(AnnotationMark(tool: .text, points: [CGPoint(x: bounds.midX, y: bounds.midY)], color: .secondaryLabelColor.withAlphaComponent(0.35), lineWidth: 24, text: "⟲WATERMARK⟲\(text)"))
        redoMarks.removeAll()
        needsDisplay = true
        onHistoryChange?()
    }

    func renderedImage() -> NSImage {
        guard let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: sourceBitmap?.pixelsWide ?? Int(bounds.width),
            pixelsHigh: sourceBitmap?.pixelsHigh ?? Int(bounds.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return sourceImage }
        representation.size = bounds.size
        let context = NSGraphicsContext(bitmapImageRep: representation)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        sourceImage.draw(in: bounds)
        for mark in marks { draw(mark) }
        context?.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: bounds.size)
        image.addRepresentation(representation)
        return image
    }

    private func commit(text: String?) {
        marks.append(AnnotationMark(tool: selectedTool, points: activePoints, color: selectedColor, lineWidth: selectedLineWidth, text: text))
        activePoints.removeAll()
        redoMarks.removeAll()
        needsDisplay = true
        onHistoryChange?()
    }

    private func draw(_ mark: AnnotationMark) {
        guard let first = mark.points.first else { return }
        if mark.tool == .mosaic { drawMosaic(mark); return }
        if mark.tool == .text || mark.tool == .number { drawText(mark, at: first); return }
        let path = NSBezierPath()
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.lineWidth = mark.tool == .highlighter ? mark.lineWidth * 4 : mark.lineWidth
        mark.color.withAlphaComponent(mark.tool == .highlighter ? 0.32 : mark.color.alphaComponent).setStroke()

        if [.rectangle, .ellipse].contains(mark.tool), let last = mark.points.last {
            let rect = CGRect(x: min(first.x, last.x), y: min(first.y, last.y), width: abs(last.x - first.x), height: abs(last.y - first.y))
            let shape = mark.tool == .rectangle ? NSBezierPath(rect: rect) : NSBezierPath(ovalIn: rect)
            shape.lineWidth = path.lineWidth
            shape.stroke()
            return
        }
        path.move(to: first)
        for point in mark.points.dropFirst() { path.line(to: point) }
        path.stroke()
        if mark.tool == .arrow, let last = mark.points.last, mark.points.count > 1 {
            drawArrowHead(from: mark.points[mark.points.count - 2], to: last, color: mark.color, width: mark.lineWidth)
        }
    }

    private func drawArrowHead(from: CGPoint, to: CGPoint, color: NSColor, width: CGFloat) {
        let angle = atan2(to.y - from.y, to.x - from.x)
        let size = max(10, width * 4)
        let path = NSBezierPath()
        path.move(to: to)
        path.line(to: CGPoint(x: to.x - size * cos(angle - .pi / 6), y: to.y - size * sin(angle - .pi / 6)))
        path.move(to: to)
        path.line(to: CGPoint(x: to.x - size * cos(angle + .pi / 6), y: to.y - size * sin(angle + .pi / 6)))
        path.lineWidth = width
        path.lineCapStyle = .round
        color.setStroke()
        path.stroke()
    }

    private func drawText(_ mark: AnnotationMark, at point: CGPoint) {
        guard var text = mark.text else { return }
        if text.hasPrefix("⟲WATERMARK⟲") {
            text.removeFirst("⟲WATERMARK⟲".count)
            drawWatermarkGrid(text, color: mark.color)
            return
        }
        if mark.tool == .number {
            let size = max(22, mark.lineWidth * 6)
            mark.color.setFill()
            NSBezierPath(ovalIn: CGRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size)).fill()
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size * 0.55, weight: .bold), .foregroundColor: NSColor.white]
            let valueSize = text.size(withAttributes: attrs)
            text.draw(at: CGPoint(x: point.x - valueSize.width / 2, y: point.y - valueSize.height / 2), withAttributes: attrs)
        } else {
            text.draw(at: point, withAttributes: [.font: NSFont.systemFont(ofSize: max(16, mark.lineWidth * 5), weight: .medium), .foregroundColor: mark.color])
        }
    }

    private func drawWatermarkGrid(_ text: String, color: NSColor) {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 24, weight: .medium), .foregroundColor: color]
        for y in stride(from: CGFloat(60), through: bounds.height, by: 150) {
            for x in stride(from: CGFloat(20), through: bounds.width, by: 260) {
                NSGraphicsContext.saveGraphicsState()
                let transform = NSAffineTransform()
                transform.translateX(by: x, yBy: y)
                transform.rotate(byDegrees: -25)
                transform.concat()
                text.draw(at: .zero, withAttributes: attributes)
                NSGraphicsContext.restoreGraphicsState()
            }
        }
    }

    private func drawMosaic(_ mark: AnnotationMark) {
        guard let bitmap = sourceBitmap, !mark.points.isEmpty else { return }
        let block = max(10, Int(mark.lineWidth * 3))
        let radius = CGFloat(block * 2)
        var painted = Set<String>()
        for index in mark.points.indices {
            let start = index == 0 ? mark.points[index] : mark.points[index - 1]
            let end = mark.points[index]
            let distance = hypot(end.x - start.x, end.y - start.y)
            let steps = max(1, Int(distance / CGFloat(block / 2)))
            for step in 0...steps {
                let fraction = CGFloat(step) / CGFloat(steps)
                let point = CGPoint(x: start.x + (end.x - start.x) * fraction, y: start.y + (end.y - start.y) * fraction)
                let minGridX = Int((point.x - radius) / CGFloat(block))
                let maxGridX = Int((point.x + radius) / CGFloat(block))
                let minGridY = Int((point.y - radius) / CGFloat(block))
                let maxGridY = Int((point.y + radius) / CGFloat(block))
                for gridY in minGridY...maxGridY {
                    for gridX in minGridX...maxGridX {
                        let center = CGPoint(x: CGFloat(gridX * block + block / 2), y: CGFloat(gridY * block + block / 2))
                        guard hypot(center.x - point.x, center.y - point.y) <= radius else { continue }
                        let key = "\(gridX):\(gridY)"
                        guard painted.insert(key).inserted else { continue }
                        let px = min(max(0, Int(center.x / max(1, bounds.width) * CGFloat(bitmap.pixelsWide))), bitmap.pixelsWide - 1)
                        let py = min(max(0, bitmap.pixelsHigh - 1 - Int(center.y / max(1, bounds.height) * CGFloat(bitmap.pixelsHigh))), bitmap.pixelsHigh - 1)
                        (bitmap.colorAt(x: px, y: py) ?? .gray).setFill()
                        CGRect(x: gridX * block, y: gridY * block, width: block + 1, height: block + 1).fill()
                    }
                }
            }
        }
    }
}
