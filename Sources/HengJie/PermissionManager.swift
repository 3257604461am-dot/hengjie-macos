import AppKit
import ApplicationServices

enum PermissionManager {
    static var canCaptureScreen: Bool { CGPreflightScreenCaptureAccess() }
    static var hasAccessibility: Bool { AXIsProcessTrusted() }

    @discardableResult
    static func requestScreenCapture() -> Bool { CGRequestScreenCaptureAccess() }

    @discardableResult
    static func requestAccessibility() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func openPrivacyPane(_ kind: String) {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_\(kind)")!
        NSWorkspace.shared.open(url)
    }
}
