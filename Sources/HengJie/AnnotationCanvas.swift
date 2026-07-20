import AppKit

enum AnnotationTool: String, CaseIterable {
    case select, pen, line, arrow, rectangle, ellipse, highlighter, text, number, mosaic

    var title: String {
        switch self {
        case .select: "选择"
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

struct AnnotationPointRecord: Codable, Hashable, Sendable {
    var x: Double
    var y: Double
}

struct AnnotationMarkRecord: Codable, Hashable, Sendable {
    var tool: String
    var points: [AnnotationPointRecord]
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double
    var relativeLineWidth: Double
    var text: String?
}

private struct MosaicGridKey: Hashable {
    let x: Int
    let y: Int
}

final class AnnotationCanvas: NSView {
    let sourceImage: NSImage
    private let sourceBitmap: NSBitmapImageRep?
    var selectedTool: AnnotationTool = .select
    var selectedColor: NSColor = .systemRed
    var selectedLineWidth: CGFloat = 4
    var textProvider: (() -> String?)?
    var textEditProvider: ((String) -> String?)?
    var onHistoryChange: (() -> Void)?

    private let document = AnnotationDocument()
    var marks: [AnnotationMark] { document.marks }
    private var activePoints: [CGPoint] = []
    private var numberCounter = 1
    private var selectedMarkIndex: Int?
    private var editingStartPoint: CGPoint?
    private var editingOriginalPoints: [CGPoint] = []
    private var editingOriginalMark: AnnotationMark?
    private var editingEndpointIndex: Int?

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
    override var acceptsFirstResponder: Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        let oldSize = frame.size
        if oldSize.width > 0, oldSize.height > 0, newSize != oldSize {
            let scaleX = newSize.width / oldSize.width
            let scaleY = newSize.height / oldSize.height
            document.scale(x: scaleX, y: scaleY)
            activePoints = activePoints.map { CGPoint(x: $0.x * scaleX, y: $0.y * scaleY) }
        }
        super.setFrameSize(newSize)
    }

    override func draw(_ dirtyRect: NSRect) {
        sourceImage.draw(in: bounds)
        for (index, mark) in marks.enumerated() where renderingBounds(mark).intersects(dirtyRect) {
            draw(mark)
            if index == selectedMarkIndex { drawSelection(for: mark) }
        }
        if !activePoints.isEmpty {
            draw(AnnotationMark(tool: selectedTool, points: activePoints, color: selectedColor, lineWidth: selectedLineWidth, text: nil))
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if selectedTool == .select {
            selectedMarkIndex = hitTest(point)
            editingStartPoint = point
            editingOriginalPoints = selectedMarkIndex.map { marks[$0].points } ?? []
            editingOriginalMark = selectedMarkIndex.map { marks[$0] }
            editingEndpointIndex = endpointIndex(at: point)
            if event.clickCount == 2,
               let index = selectedMarkIndex,
               marks[index].tool == .text,
               let oldValue = marks[index].text,
               let value = textEditProvider?(oldValue), !value.isEmpty {
                var changed = marks[index]
                changed.text = value
                document.replace(at: index, with: changed)
                editingOriginalMark = document.marks[index]
                onHistoryChange?()
            }
            needsDisplay = true
            return
        }
        selectedMarkIndex = nil
        activePoints = [point]
        if selectedTool == .text, let text = textProvider?(), !text.isEmpty {
            commit(text: text)
        } else if selectedTool == .number {
            commit(text: String(numberCounter))
            numberCounter += 1
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if selectedTool == .select,
           let index = selectedMarkIndex,
           let start = editingStartPoint,
           marks.indices.contains(index) {
            let previousBounds = renderingBounds(marks[index])
            var changed = marks[index]
            if let endpoint = editingEndpointIndex, editingOriginalPoints.indices.contains(endpoint) {
                var points = editingOriginalPoints
                points[endpoint] = point
                changed.points = points
            } else {
                let delta = CGPoint(x: point.x - start.x, y: point.y - start.y)
                changed.points = editingOriginalPoints.map { CGPoint(x: $0.x + delta.x, y: $0.y + delta.y) }
            }
            document.updateTransient(at: index, mark: changed)
            setNeedsDisplay(previousBounds.union(renderingBounds(changed)).insetBy(dx: -12, dy: -12))
            return
        }
        let previousActiveBounds = activePoints.isEmpty ? CGRect.null : renderingBounds(
            AnnotationMark(tool: selectedTool, points: activePoints, color: selectedColor, lineWidth: selectedLineWidth, text: nil)
        )
        if [.pen, .highlighter, .mosaic].contains(selectedTool) {
            let minimumDistance = max(1.5, selectedLineWidth * 0.35)
            if let last = activePoints.last, hypot(point.x - last.x, point.y - last.y) < minimumDistance {
                activePoints[activePoints.count - 1] = point
            } else {
                activePoints.append(point)
            }
        }
        else if activePoints.count == 1 { activePoints.append(point) }
        else { activePoints[1] = point }
        let activeMark = AnnotationMark(tool: selectedTool, points: activePoints, color: selectedColor, lineWidth: selectedLineWidth, text: nil)
        setNeedsDisplay(previousActiveBounds.union(renderingBounds(activeMark)).insetBy(dx: -4, dy: -4))
    }

    override func mouseUp(with event: NSEvent) {
        if selectedTool == .select {
            if let index = selectedMarkIndex, let original = editingOriginalMark {
                document.commitTransient(at: index, before: original)
                onHistoryChange?()
            }
            editingStartPoint = nil
            editingOriginalPoints = []
            editingOriginalMark = nil
            editingEndpointIndex = nil
            return
        }
        guard ![.text, .number].contains(selectedTool), !activePoints.isEmpty else { return }
        let point = convert(event.locationInWindow, from: nil)
        if activePoints.count == 1 { activePoints.append(point) }
        commit(text: nil)
    }

    func undo() {
        guard document.undo() else { return }
        selectedMarkIndex = nil
        needsDisplay = true
        onHistoryChange?()
    }

    override func keyDown(with event: NSEvent) {
        if (event.keyCode == 51 || event.keyCode == 117), selectedTool == .select {
            deleteSelectedMark()
        } else {
            super.keyDown(with: event)
        }
    }

    var canUndo: Bool { document.canUndo }
    var canRedo: Bool { document.canRedo }

    func deleteSelectedMark() {
        guard let index = selectedMarkIndex, marks.indices.contains(index) else { return }
        document.remove(at: index)
        selectedMarkIndex = nil
        needsDisplay = true
        onHistoryChange?()
    }

    func annotationRecords() -> [AnnotationMarkRecord] {
        let width = max(1, bounds.width)
        let height = max(1, bounds.height)
        let dimension = max(1, min(width, height))
        return marks.map { mark in
            let color = mark.color.usingColorSpace(.deviceRGB) ?? mark.color
            return AnnotationMarkRecord(
                tool: mark.tool.rawValue,
                points: mark.points.map { .init(x: Double($0.x / width), y: Double($0.y / height)) },
                red: Double(color.redComponent), green: Double(color.greenComponent), blue: Double(color.blueComponent), alpha: Double(color.alphaComponent),
                relativeLineWidth: Double(mark.lineWidth / dimension), text: mark.text
            )
        }
    }

    func restore(records: [AnnotationMarkRecord]) {
        let width = max(1, bounds.width)
        let height = max(1, bounds.height)
        let dimension = max(1, min(width, height))
        let restored: [AnnotationMark] = records.compactMap { record -> AnnotationMark? in
            guard let tool = AnnotationTool(rawValue: record.tool), tool != .select else { return nil }
            return AnnotationMark(
                tool: tool,
                points: record.points.map { CGPoint(x: $0.x * width, y: $0.y * height) },
                color: NSColor(deviceRed: record.red, green: record.green, blue: record.blue, alpha: record.alpha),
                lineWidth: max(1, record.relativeLineWidth * dimension),
                text: record.text
            )
        }
        document.reset(restored)
        numberCounter = (marks.filter { $0.tool == .number }.compactMap { Int($0.text ?? "") }.max() ?? 0) + 1
        selectedMarkIndex = nil
        needsDisplay = true
        onHistoryChange?()
    }

    func redo() {
        guard document.redo() else { return }
        selectedMarkIndex = nil
        needsDisplay = true
        onHistoryChange?()
    }

    func applyStyleToSelection(color: NSColor, lineWidth: CGFloat) {
        guard let index = selectedMarkIndex, marks.indices.contains(index) else { return }
        let mark = marks[index]
        guard mark.color != color || abs(mark.lineWidth - lineWidth) > 0.01 else { return }
        var changed = mark
        changed.color = color
        changed.lineWidth = lineWidth
        document.replace(at: index, with: changed)
        needsDisplay = true
        onHistoryChange?()
    }

    func addWatermark(_ text: String) {
        document.append(AnnotationMark(tool: .text, points: [CGPoint(x: bounds.midX, y: bounds.midY)], color: .secondaryLabelColor.withAlphaComponent(0.35), lineWidth: 24, text: "⟲WATERMARK⟲\(text)"))
        needsDisplay = true
        onHistoryChange?()
    }

    func renderedCGImage() -> CGImage? {
        let trace = PerformanceTrace.begin("AnnotationRender")
        defer { PerformanceTrace.end("AnnotationRender", trace) }
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
        ) else { return nil }
        representation.size = bounds.size
        let context = NSGraphicsContext(bitmapImageRep: representation)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        sourceImage.draw(in: bounds)
        for mark in marks { draw(mark) }
        context?.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return representation.cgImage
    }

    private func commit(text: String?) {
        document.append(AnnotationMark(tool: selectedTool, points: activePoints, color: selectedColor, lineWidth: selectedLineWidth, text: text))
        activePoints.removeAll()
        needsDisplay = true
        onHistoryChange?()
    }

    private func hitTest(_ point: CGPoint) -> Int? {
        for index in marks.indices.reversed() {
            let mark = marks[index]
            guard let first = mark.points.first else { continue }
            if mark.tool == .text || mark.tool == .number {
                let rect = CGRect(origin: first, size: CGSize(width: max(70, CGFloat(mark.text?.count ?? 1) * max(10, mark.lineWidth * 3)), height: max(28, mark.lineWidth * 6))).insetBy(dx: -8, dy: -8)
                if rect.contains(point) { return index }
            } else if markBounds(mark).insetBy(dx: -12, dy: -12).contains(point) {
                return index
            }
        }
        return nil
    }

    private func endpointIndex(at point: CGPoint) -> Int? {
        guard let index = selectedMarkIndex, marks.indices.contains(index), [.arrow, .line, .mosaic].contains(marks[index].tool) else { return nil }
        let points = marks[index].points
        guard !points.isEmpty else { return nil }
        if hypot(points[0].x - point.x, points[0].y - point.y) <= 14 { return 0 }
        if let last = points.indices.last, hypot(points[last].x - point.x, points[last].y - point.y) <= 14 { return last }
        if marks[index].tool == .mosaic {
            return points.indices.min { lhs, rhs in
                hypot(points[lhs].x - point.x, points[lhs].y - point.y) < hypot(points[rhs].x - point.x, points[rhs].y - point.y)
            }.flatMap { hypot(points[$0].x - point.x, points[$0].y - point.y) <= 14 ? $0 : nil }
        }
        return nil
    }

    private func markBounds(_ mark: AnnotationMark) -> CGRect {
        guard let first = mark.points.first else { return .zero }
        return mark.points.dropFirst().reduce(CGRect(x: first.x, y: first.y, width: 0, height: 0)) { partial, point in
            partial.union(CGRect(x: point.x, y: point.y, width: 1, height: 1))
        }
    }

    private func renderingBounds(_ mark: AnnotationMark) -> CGRect {
        if mark.text?.hasPrefix("⟲WATERMARK⟲") == true { return bounds }
        guard let first = mark.points.first else { return .zero }
        if mark.tool == .text || mark.tool == .number {
            return CGRect(
                origin: first,
                size: CGSize(
                    width: max(70, CGFloat(mark.text?.count ?? 1) * max(10, mark.lineWidth * 3)),
                    height: max(28, mark.lineWidth * 6)
                )
            ).insetBy(dx: -8, dy: -8)
        }
        let padding = max(12, mark.tool == .highlighter ? mark.lineWidth * 4 : mark.lineWidth * 3)
        return markBounds(mark).insetBy(dx: -padding, dy: -padding)
    }

    private func drawSelection(for mark: AnnotationMark) {
        let rect = markBounds(mark).insetBy(dx: -6, dy: -6)
        NSColor.systemBlue.setStroke()
        let path = NSBezierPath(rect: rect.width < 4 || rect.height < 4 ? CGRect(x: rect.minX, y: rect.minY, width: max(18, rect.width), height: max(18, rect.height)) : rect)
        path.lineWidth = 1
        path.setLineDash([4, 3], count: 2, phase: 0)
        path.stroke()
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
        var painted = Set<MosaicGridKey>()
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
                        let key = MosaicGridKey(x: gridX, y: gridY)
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
