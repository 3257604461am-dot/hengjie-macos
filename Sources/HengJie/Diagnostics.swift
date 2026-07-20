import AppKit
import Foundation
import OSLog

final class DiagnosticLogger: @unchecked Sendable {
    static let shared = DiagnosticLogger()

    private let logger = Logger(subsystem: "com.wonderlab.hengjie", category: "runtime")
    private let directory: URL
    private let sessionURL: URL
    private let markerURL: URL
    private let ioQueue = DispatchQueue(label: "com.wonderlab.hengjie.diagnostics", qos: .utility)
    private var handle: FileHandle?

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("横截", isDirectory: true)
        directory = support.appendingPathComponent("Diagnostics", isDirectory: true)
        markerURL = directory.appendingPathComponent("active-session")
        sessionURL = directory.appendingPathComponent("session-\(DiagnosticLogger.fileTimestamp()).jsonl")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        rotateLogs()
        let previousSessionWasAbnormal = FileManager.default.fileExists(atPath: markerURL.path)
        FileManager.default.createFile(atPath: sessionURL.path, contents: nil)
        handle = try? FileHandle(forWritingTo: sessionURL)
        if previousSessionWasAbnormal { write(category: "lifecycle", event: "previous_session_abnormal", fields: [:]) }
        try? Data(Date().ISO8601Format().utf8).write(to: markerURL, options: .atomic)
        write(category: "lifecycle", event: "session_started", fields: ["version": appVersion])
    }

    func log(_ category: String, _ event: String, fields: [String: String] = [:]) {
        logger.info("\(category, privacy: .public).\(event, privacy: .public)")
        write(category: category, event: event, fields: fields)
    }

    func finishSession() {
        ioQueue.sync {
            writeImmediately(category: "lifecycle", event: "session_finished", fields: [:])
            try? handle?.synchronize()
            try? handle?.close()
            handle = nil
            try? FileManager.default.removeItem(at: markerURL)
        }
    }

    var logsDirectory: URL { directory }

    private func write(category: String, event: String, fields: [String: String]) {
        ioQueue.async { [self] in
            writeImmediately(category: category, event: event, fields: fields)
        }
    }

    private func writeImmediately(category: String, event: String, fields: [String: String]) {
        let safeFields = fields.mapValues { String($0.prefix(240)) }
        let object: [String: Any] = [
            "timestamp": Date().ISO8601Format(),
            "category": category,
            "event": event,
            "fields": safeFields
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        if handle == nil, FileManager.default.fileExists(atPath: sessionURL.path) {
            handle = try? FileHandle(forWritingTo: sessionURL)
        }
        _ = try? handle?.seekToEnd()
        try? handle?.write(contentsOf: data + Data([0x0A]))
    }

    private func rotateLogs() {
        let manager = FileManager.default
        let urls = (try? manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let cutoff = Date().addingTimeInterval(-7 * 24 * 60 * 60)
        var retained: [(URL, Date, Int64)] = []
        for url in urls where url.pathExtension == "jsonl" {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let date = values?.contentModificationDate ?? .distantPast
            if date < cutoff { try? manager.removeItem(at: url) }
            else { retained.append((url, date, Int64(values?.fileSize ?? 0))) }
        }
        var total = retained.reduce(Int64(0)) { $0 + $1.2 }
        for entry in retained.sorted(by: { $0.1 < $1.1 }) where total > 20 * 1_024 * 1_024 {
            try? manager.removeItem(at: entry.0)
            total -= entry.2
        }
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-"
        return "\(version) (\(build))"
    }

    private static func fileTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}

@MainActor
enum DiagnosticBundleExporter {
    static func present() {
        let alert = NSAlert()
        alert.messageText = "导出问题诊断"
        alert.informativeText = "诊断包包含横截运行日志、系统和权限信息，以及最近的横截崩溃报告。不会包含截图、GIF、OCR/翻译文字、剪贴板内容或快捷键配置，也不会自动上传。"
        alert.addButton(withTitle: "继续导出")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = "横截-诊断-\(timestamp()).zip"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let summary = diagnosticSummary()
        let logs = DiagnosticLogger.shared.logsDirectory
        Task {
            do {
                try await export(to: url, summary: summary, logsDirectory: logs)
                let done = NSAlert()
                done.messageText = "诊断包已导出"
                done.informativeText = url.path
                done.runModal()
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    private static func diagnosticSummary() -> [String: Any] {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-"
        let screens = NSScreen.screens.map {
            ["width": Int($0.frame.width), "height": Int($0.frame.height), "scale": $0.backingScaleFactor]
        }
        return [
            "generatedAt": Date().ISO8601Format(),
            "appVersion": version,
            "appBuild": build,
            "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
            "architecture": architectureName(),
            "screens": screens,
            "screenCapturePermission": PermissionManager.canCaptureScreen,
            "accessibilityPermission": PermissionManager.hasAccessibility,
            "privacy": "No screenshots, OCR text, clipboard payloads, GIFs or shortcut configuration are included."
        ]
    }

    private static func export(to destination: URL, summary: [String: Any], logsDirectory: URL) async throws {
        try await Task.detached(priority: .utility) {
            let manager = FileManager.default
            let staging = manager.temporaryDirectory.appendingPathComponent("HengJie-Diagnostics-\(UUID().uuidString)", isDirectory: true)
            defer { try? manager.removeItem(at: staging) }
            try manager.createDirectory(at: staging, withIntermediateDirectories: true)
            let summaryData = try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
            try summaryData.write(to: staging.appendingPathComponent("summary.json"), options: .atomic)

            let targetLogs = staging.appendingPathComponent("Logs", isDirectory: true)
            try? manager.copyItem(at: logsDirectory, to: targetLogs)

            let crashTarget = staging.appendingPathComponent("CrashReports", isDirectory: true)
            try manager.createDirectory(at: crashTarget, withIntermediateDirectories: true)
            let crashSource = manager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
            var copiedCrashes = 0
            if let reports = try? manager.contentsOfDirectory(at: crashSource, includingPropertiesForKeys: [.contentModificationDateKey]) {
                let cutoff = Date().addingTimeInterval(-7 * 24 * 60 * 60)
                for report in reports where report.lastPathComponent.localizedCaseInsensitiveContains("HengJie") || report.lastPathComponent.localizedCaseInsensitiveContains("横截") {
                    let modified = try? report.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                    guard (modified ?? .distantPast) >= cutoff else { continue }
                    try? manager.copyItem(at: report, to: crashTarget.appendingPathComponent(report.lastPathComponent))
                    copiedCrashes += 1
                }
            }
            if copiedCrashes == 0 {
                try Data("最近 7 天没有可读取的横截崩溃报告。\n".utf8)
                    .write(to: crashTarget.appendingPathComponent("README.txt"), options: .atomic)
            }

            try? manager.removeItem(at: destination)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-c", "-k", "--sequesterRsrc", staging.path, destination.path]
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw NSError(domain: "HengJieDiagnostics", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "无法生成诊断 ZIP。"])
            }
        }.value
    }

    private static func architectureName() -> String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}
