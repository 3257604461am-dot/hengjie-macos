import AppKit
import HengJieCore

@main
struct HengJieApp {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let captureHotKey = GlobalHotKey(id: 1)
    private let pinHotKey = GlobalHotKey(id: 2)
    private let textHotKey = GlobalHotKey(id: 3)
    private let gifHotKey = GlobalHotKey(id: 4)
    private let coordinator = CaptureCoordinator()
    private var preferencesController: PreferencesWindowController?
    private var gifMenuItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenu()
        captureHotKey.action = { [weak self] in self?.coordinator.begin(mode: .standard) }
        pinHotKey.action = { [weak self] in self?.coordinator.beginPin() }
        textHotKey.action = { [weak self] in self?.coordinator.beginTextExtraction() }
        gifHotKey.action = { [weak self] in self?.coordinator.beginGIFRecording() }
        captureHotKey.register(
            keyCode: AppPreferences.shared.hotKeyCode,
            modifiers: AppPreferences.shared.hotKeyModifiers
        )
        pinHotKey.register(
            keyCode: AppPreferences.shared.pinHotKeyCode,
            modifiers: AppPreferences.shared.pinHotKeyModifiers
        )
        textHotKey.register(
            keyCode: AppPreferences.shared.textHotKeyCode,
            modifiers: AppPreferences.shared.textHotKeyModifiers
        )
        gifHotKey.register(
            keyCode: AppPreferences.shared.gifHotKeyCode,
            modifiers: AppPreferences.shared.gifHotKeyModifiers
        )
        coordinator.onGIFRecordingStateChange = { [weak self] recording in
            self?.gifMenuItem?.title = recording ? "停止 GIF 录制" : "录制 GIF"
        }
        if !PermissionManager.canCaptureScreen {
            showPermissionIntroduction()
        }
    }

    private func setupMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: "横截")
        statusItem.button?.toolTip = "横截"
        let menu = NSMenu()
        menu.addItem(item("普通截图", #selector(standardCapture), "A", [.option, .shift]))
        menu.addItem(item("上下长截图", #selector(verticalCapture)))
        menu.addItem(item("左右长截图", #selector(horizontalCapture)))
        menu.addItem(item("钉住区域", #selector(pinRegion), "p", [.option, .shift]))
        menu.addItem(item("提取文字", #selector(extractText), "o", [.option, .shift]))
        let gif = item("录制 GIF", #selector(recordGIF), "g", [.option, .shift])
        gifMenuItem = gif
        menu.addItem(gif)
        menu.addItem(.separator())
        menu.addItem(item("权限检查…", #selector(checkPermissions)))
        menu.addItem(item("设置…", #selector(openPreferences)))
        menu.addItem(.separator())
        menu.addItem(item("退出横截", #selector(quit), "q", [.command]))
        statusItem.menu = menu
    }

    private func item(_ title: String, _ action: Selector, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = []) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = self
        return item
    }

    @objc private func standardCapture() { coordinator.begin(mode: .standard) }
    @objc private func verticalCapture() { coordinator.begin(mode: .vertical) }
    @objc private func horizontalCapture() { coordinator.begin(mode: .horizontal) }
    @objc private func pinRegion() { coordinator.beginPin() }
    @objc private func extractText() { coordinator.beginTextExtraction() }
    @objc private func recordGIF() { coordinator.beginGIFRecording() }
    @objc private func quit() { NSApplication.shared.terminate(nil) }

    @objc private func checkPermissions() {
        PermissionWindow.show()
    }

    @objc private func openPreferences() {
        let controller = PreferencesWindowController { [weak self] in
            guard let self else { return }
            self.captureHotKey.register(keyCode: AppPreferences.shared.hotKeyCode, modifiers: AppPreferences.shared.hotKeyModifiers)
            self.pinHotKey.register(keyCode: AppPreferences.shared.pinHotKeyCode, modifiers: AppPreferences.shared.pinHotKeyModifiers)
            self.textHotKey.register(keyCode: AppPreferences.shared.textHotKeyCode, modifiers: AppPreferences.shared.textHotKeyModifiers)
            self.gifHotKey.register(keyCode: AppPreferences.shared.gifHotKeyCode, modifiers: AppPreferences.shared.gifHotKeyModifiers)
        }
        preferencesController = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator.cancelGIFRecording()
        GIFTemporaryFiles.cleanupStaleFiles()
    }

    private func showPermissionIntroduction() {
        let alert = NSAlert()
        alert.messageText = "欢迎使用横截"
        alert.informativeText = "截图需要“屏幕录制”权限。滚动截图默认由你手动滚动；只有主动切换到自动滚动时才需要“辅助功能”权限。所有图片和文字识别都只在本机处理。"
        alert.addButton(withTitle: "开始授权")
        alert.addButton(withTitle: "稍后")
        if alert.runModal() == .alertFirstButtonReturn {
            _ = PermissionManager.requestScreenCapture()
        }
    }
}
