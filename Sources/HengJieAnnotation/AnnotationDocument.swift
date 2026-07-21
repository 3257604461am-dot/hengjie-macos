import AppKit

public enum AnnotationTool: String, CaseIterable, Sendable {
    case select, pen, line, arrow, rectangle, ellipse, highlighter, text, number, mosaic

    public var title: String {
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

public struct AnnotationMark {
    public var id: UUID
    public var tool: AnnotationTool
    public var points: [CGPoint]
    public var color: NSColor
    public var lineWidth: CGFloat
    public var text: String?

    public init(id: UUID = UUID(), tool: AnnotationTool, points: [CGPoint], color: NSColor, lineWidth: CGFloat, text: String?) {
        self.id = id
        self.tool = tool
        self.points = points
        self.color = color
        self.lineWidth = lineWidth
        self.text = text
    }
}

public struct AnnotationPointRecord: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

public struct AnnotationMarkRecord: Codable, Hashable, Sendable {
    public var id: UUID?
    public var tool: String
    public var points: [AnnotationPointRecord]
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double
    public var relativeLineWidth: Double
    public var text: String?

    public init(
        id: UUID? = nil,
        tool: String,
        points: [AnnotationPointRecord],
        red: Double,
        green: Double,
        blue: Double,
        alpha: Double,
        relativeLineWidth: Double,
        text: String?
    ) {
        self.id = id
        self.tool = tool
        self.points = points
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
        self.relativeLineWidth = relativeLineWidth
        self.text = text
    }
}

private enum AnnotationCommand {
    case insert(index: Int, mark: AnnotationMark)
    case remove(index: Int, mark: AnnotationMark)
    case replace(index: Int, before: AnnotationMark, after: AnnotationMark)
}

public final class AnnotationDocument {
    public private(set) var marks: [AnnotationMark] = []
    private var undoStack: [AnnotationCommand] = []
    private var redoStack: [AnnotationCommand] = []
    private let maximumUndoCount = 100

    public init() {}
    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    public func reset(_ values: [AnnotationMark]) {
        marks = values
        undoStack.removeAll(keepingCapacity: true)
        redoStack.removeAll(keepingCapacity: true)
    }

    public func append(_ mark: AnnotationMark) { execute(.insert(index: marks.count, mark: mark)) }

    public func remove(at index: Int) {
        guard marks.indices.contains(index) else { return }
        execute(.remove(index: index, mark: marks[index]))
    }

    public func replace(at index: Int, with mark: AnnotationMark) {
        guard marks.indices.contains(index) else { return }
        let before = marks[index]
        guard !Self.isEquivalent(before, mark) else { return }
        execute(.replace(index: index, before: before, after: mark))
    }

    public func updateTransient(at index: Int, mark: AnnotationMark) {
        guard marks.indices.contains(index) else { return }
        marks[index] = mark
    }

    public func commitTransient(at index: Int, before: AnnotationMark) {
        guard marks.indices.contains(index) else { return }
        let after = marks[index]
        guard !Self.isEquivalent(before, after) else { return }
        record(.replace(index: index, before: before, after: after))
    }

    public func scale(x: CGFloat, y: CGFloat) {
        let widthScale = min(x, y)
        for index in marks.indices {
            marks[index].points = marks[index].points.map { CGPoint(x: $0.x * x, y: $0.y * y) }
            marks[index].lineWidth *= widthScale
        }
        undoStack.removeAll(keepingCapacity: true)
        redoStack.removeAll(keepingCapacity: true)
    }

    @discardableResult public func undo() -> Bool {
        guard let command = undoStack.popLast() else { return false }
        applyInverse(command)
        redoStack.append(command)
        return true
    }

    @discardableResult public func redo() -> Bool {
        guard let command = redoStack.popLast() else { return false }
        apply(command)
        undoStack.append(command)
        return true
    }

    private func execute(_ command: AnnotationCommand) { apply(command); record(command) }
    private func record(_ command: AnnotationCommand) {
        undoStack.append(command)
        if undoStack.count > maximumUndoCount { undoStack.removeFirst(undoStack.count - maximumUndoCount) }
        redoStack.removeAll(keepingCapacity: true)
    }
    private func apply(_ command: AnnotationCommand) {
        switch command {
        case let .insert(index, mark): marks.insert(mark, at: min(index, marks.count))
        case let .remove(index, _): if marks.indices.contains(index) { marks.remove(at: index) }
        case let .replace(index, _, after): if marks.indices.contains(index) { marks[index] = after }
        }
    }
    private func applyInverse(_ command: AnnotationCommand) {
        switch command {
        case let .insert(index, _): if marks.indices.contains(index) { marks.remove(at: index) }
        case let .remove(index, mark): marks.insert(mark, at: min(index, marks.count))
        case let .replace(index, before, _): if marks.indices.contains(index) { marks[index] = before }
        }
    }
    private static func isEquivalent(_ lhs: AnnotationMark, _ rhs: AnnotationMark) -> Bool {
        lhs.id == rhs.id && lhs.tool == rhs.tool && lhs.points == rhs.points && lhs.color == rhs.color &&
            abs(lhs.lineWidth - rhs.lineWidth) < 0.001 && lhs.text == rhs.text
    }
}
