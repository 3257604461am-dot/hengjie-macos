import AppKit

enum AnnotationCommand {
    case insert(index: Int, mark: AnnotationMark)
    case remove(index: Int, mark: AnnotationMark)
    case replace(index: Int, before: AnnotationMark, after: AnnotationMark)
}

/// Owns editable annotation state. Undo entries store only the affected mark,
/// avoiding full-document copies for long pen and mosaic paths.
final class AnnotationDocument {
    private(set) var marks: [AnnotationMark] = []
    private var undoStack: [AnnotationCommand] = []
    private var redoStack: [AnnotationCommand] = []
    private let maximumUndoCount = 100

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    func reset(_ values: [AnnotationMark]) {
        marks = values
        undoStack.removeAll(keepingCapacity: true)
        redoStack.removeAll(keepingCapacity: true)
    }

    func append(_ mark: AnnotationMark) {
        execute(.insert(index: marks.count, mark: mark))
    }

    func remove(at index: Int) {
        guard marks.indices.contains(index) else { return }
        execute(.remove(index: index, mark: marks[index]))
    }

    func replace(at index: Int, with mark: AnnotationMark) {
        guard marks.indices.contains(index) else { return }
        let before = marks[index]
        guard !Self.isEquivalent(before, mark) else { return }
        execute(.replace(index: index, before: before, after: mark))
    }

    func updateTransient(at index: Int, mark: AnnotationMark) {
        guard marks.indices.contains(index) else { return }
        marks[index] = mark
    }

    func commitTransient(at index: Int, before: AnnotationMark) {
        guard marks.indices.contains(index) else { return }
        let after = marks[index]
        guard !Self.isEquivalent(before, after) else { return }
        record(.replace(index: index, before: before, after: after))
    }

    func scale(x: CGFloat, y: CGFloat) {
        let widthScale = min(x, y)
        for index in marks.indices {
            marks[index].points = marks[index].points.map { CGPoint(x: $0.x * x, y: $0.y * y) }
            marks[index].lineWidth *= widthScale
        }
        undoStack.removeAll(keepingCapacity: true)
        redoStack.removeAll(keepingCapacity: true)
    }

    @discardableResult
    func undo() -> Bool {
        guard let command = undoStack.popLast() else { return false }
        applyInverse(command)
        redoStack.append(command)
        return true
    }

    @discardableResult
    func redo() -> Bool {
        guard let command = redoStack.popLast() else { return false }
        apply(command)
        undoStack.append(command)
        return true
    }

    private func execute(_ command: AnnotationCommand) {
        apply(command)
        record(command)
    }

    private func record(_ command: AnnotationCommand) {
        undoStack.append(command)
        if undoStack.count > maximumUndoCount {
            undoStack.removeFirst(undoStack.count - maximumUndoCount)
        }
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
        lhs.tool == rhs.tool && lhs.points == rhs.points && lhs.color == rhs.color &&
            abs(lhs.lineWidth - rhs.lineWidth) < 0.001 && lhs.text == rhs.text
    }
}
