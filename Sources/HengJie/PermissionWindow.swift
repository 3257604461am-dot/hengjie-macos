import AppKit

enum PermissionWindow {
    @MainActor
    static func show() {
        let screen = PermissionManager.canCaptureScreen ? "已授权" : "未授权"
        let accessibility = PermissionManager.hasAccessibility ? "已授权" : "未授权"
        let alert = NSAlert()
        alert.messageText = "权限检查"
        alert.informativeText = "屏幕录制：\(screen)\n辅助功能：\(accessibility)\n\n当前应用：\n\(Bundle.main.bundlePath)\n\n请只授权放在“应用程序”文件夹中的横截。手动滚动截图不需要辅助功能权限。"
        alert.addButton(withTitle: "申请权限")
        alert.addButton(withTitle: "完成")
        if alert.runModal() == .alertFirstButtonReturn {
            if !PermissionManager.canCaptureScreen { _ = PermissionManager.requestScreenCapture() }
            if !PermissionManager.hasAccessibility { _ = PermissionManager.requestAccessibility() }
        }
    }
}
