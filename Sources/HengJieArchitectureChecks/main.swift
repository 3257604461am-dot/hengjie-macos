import AppKit
import Foundation
import HengJieAnnotation
import HengJieCapture
import HengJieHistory

enum CheckFailure: Error, CustomStringConvertible {
    case failed(String)
    var description: String { if case let .failed(message) = self { message } else { "" } }
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw CheckFailure.failed(message) }
}

@main
struct ArchitectureChecks {
    static func main() async {
        do {
            try checkAnnotationCommands()
            try checkCaptureSessionIsolation()
            try await checkSQLiteTransactions()
            print("✓ 横截架构检查全部通过")
        } catch {
            fputs("✗ \(error)\n", stderr)
            exit(1)
        }
    }

    @MainActor
    private static func checkCaptureSessionIsolation() throws {
        let registry = CaptureSessionRegistry()
        let old = registry.begin(.selecting)
        let current = registry.begin(.capturing)
        try expect(!registry.transition(.editing, for: old), "旧捕获会话仍可覆盖当前状态")
        registry.finish(old)
        try expect(registry.current == current, "旧捕获会话错误结束了当前会话")
        try expect(registry.transition(.editing, for: current), "当前捕获会话无法推进")
        registry.finish(current)
        try expect(registry.current == nil && registry.state == .idle, "捕获会话未幂等清理")
    }

    private static func checkAnnotationCommands() throws {
        let document = AnnotationDocument()
        let id = UUID()
        let original = AnnotationMark(id: id, tool: .arrow, points: [.zero, CGPoint(x: 40, y: 20)], color: .systemRed, lineWidth: 4, text: nil)
        document.append(original)
        try expect(document.marks.first?.id == id, "标注图层 ID 未保留")
        var moved = original
        moved.points = [CGPoint(x: 10, y: 10), CGPoint(x: 50, y: 30)]
        document.replace(at: 0, with: moved)
        try expect(document.undo(), "标注替换无法撤销")
        try expect(document.marks.first?.points == original.points, "撤销未恢复原始标注")
        try expect(document.redo(), "标注替换无法重做")
        try expect(document.marks.first?.points == moved.points, "重做未恢复变更标注")
    }

    private static func checkSQLiteTransactions() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("HengJie-HistoryCheck-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let index = try SQLiteHistoryIndex(url: directory.appendingPathComponent("index.sqlite"))
        let rows = [
            SQLiteHistoryRow(id: "1", sortValue: 2, kind: "text", isPinned: false, byteCount: 8, searchText: "横截 test", metadata: Data("{\"id\":1}".utf8)),
            SQLiteHistoryRow(id: "2", sortValue: 1, kind: "image", isPinned: true, byteCount: 16, searchText: nil, metadata: Data("{\"id\":2}".utf8))
        ]
        try await index.replace(rows)
        let loaded = try await index.load()
        try expect(loaded.map(\.id) == ["1", "2"], "SQLite 历史顺序或数据错误")
        try expect(loaded.last?.isPinned == true, "SQLite 固定状态未保留")
        try await index.deleteAll()
        let cleared = try await index.load()
        try expect(cleared.isEmpty, "SQLite 清空事务失败")
    }
}
