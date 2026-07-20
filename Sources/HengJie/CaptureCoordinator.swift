import AppKit
import HengJieCore

@MainActor
final class CaptureCoordinator {
    var onGIFRecordingStateChange: ((Bool) -> Void)?
    private let service = ScreenCaptureService()
    private var selectionController: SelectionOverlayController?
    private var pinSelectionController: SelectionOverlayController?
    private var textSelectionController: SelectionOverlayController?
    private var standardController: StandardCaptureOverlayController?
    private var delayedSelectionController: SelectionOverlayController?
    private var delayedCaptureController: DelayedCaptureController?
    private var editorControllers: [AnnotationEditorWindowController] = []
    private var scrollController: ScrollCaptureController?
    private var gifSelectionController: SelectionOverlayController?
    private var gifConfigurationController: GIFRecordingConfigurationController?
    private var gifControlController: GIFRecordingControlController?
    private var gifPreviewController: GIFPreviewWindowController?
    private var gifSession: GIFRecordingSession?
    private var gifCountdownTask: Task<Void, Never>?

    var isGIFRecording: Bool { gifSession != nil }
    private var isGIFFlowActive: Bool {
        gifSelectionController != nil || gifConfigurationController != nil || gifControlController != nil || gifSession != nil || gifPreviewController != nil
    }

    init() { GIFTemporaryFiles.cleanupStaleFiles() }

    func begin(mode: CaptureMode) {
        guard allowCaptureWhileNotRecordingGIF() else { return }
        guard ensureCapturePermission() else { return }
        let selection = SelectionOverlayController { [weak self] rect in
            self?.selectionController = nil
            guard let rect else { return }
            if mode == .standard { self?.captureStandard(rect) }
            else { self?.captureScrolling(rect, mode: mode) }
        }
        selectionController = selection
        selection.begin()
    }

    func beginDelayedCapture() {
        guard allowCaptureWhileNotRecordingGIF() else { return }
        guard ensureCapturePermission() else { return }
        let selection = SelectionOverlayController { [weak self] rect in
            guard let self else { return }
            delayedSelectionController = nil
            guard let rect else { return }
            let countdown = DelayedCaptureController(selectionRect: rect)
            countdown.onReady = { [weak self, weak countdown] in
                self?.delayedCaptureController = nil
                countdown?.onReady = nil
                self?.captureStandard(rect)
            }
            countdown.onCancel = { [weak self] in self?.delayedCaptureController = nil }
            delayedCaptureController = countdown
            countdown.present()
        }
        delayedSelectionController = selection
        selection.begin()
    }

    func beginPin() {
        guard allowCaptureWhileNotRecordingGIF() else { return }
        guard ensureCapturePermission() else { return }
        let selection = SelectionOverlayController { [weak self] rect in
            self?.pinSelectionController = nil
            guard let rect else { return }
            self?.capturePin(rect)
        }
        pinSelectionController = selection
        selection.begin()
    }

    func beginTextExtraction() {
        guard allowCaptureWhileNotRecordingGIF() else { return }
        guard ensureCapturePermission() else { return }
        let selection = SelectionOverlayController { [weak self] rect in
            self?.textSelectionController = nil
            guard let rect else { return }
            self?.captureText(rect)
        }
        textSelectionController = selection
        selection.begin()
    }

    func beginGIFRecording() {
        if isGIFFlowActive {
            if gifSession != nil { stopGIFRecording() }
            else { cancelGIFRecording() }
            return
        }
        guard ensureCapturePermission() else { return }
        notifyGIFState()
        let selection = SelectionOverlayController { [weak self] rect in
            guard let self else { return }
            self.gifSelectionController = nil
            guard let rect else { self.finishGIFFlow(); return }
            self.configureGIFRecording(rect)
        }
        gifSelectionController = selection
        selection.begin()
    }

    func stopGIFRecording() {
        guard let session = gifSession else { return }
        gifControlController?.dismiss()
        session.stop()
    }

    func cancelGIFRecording() {
        gifCountdownTask?.cancel()
        gifCountdownTask = nil
        gifConfigurationController?.window?.orderOut(nil)
        gifConfigurationController = nil
        gifControlController?.dismiss()
        gifControlController = nil
        if let session = gifSession { session.stop(cancel: true) }
        else { finishGIFFlow() }
    }

    private func configureGIFRecording(_ rect: CGRect) {
        let screens = NSScreen.screens.filter {
            let intersection = $0.frame.intersection(rect)
            return !intersection.isNull && !intersection.isEmpty
        }
        guard screens.count == 1, let screen = screens.first,
              abs(screen.frame.intersection(rect).width - rect.width) < 1,
              abs(screen.frame.intersection(rect).height - rect.height) < 1 else {
            show(GIFRecordingError.selectionCrossesDisplays)
            finishGIFFlow()
            return
        }
        let controller = GIFRecordingConfigurationController(selectionRect: rect, screen: screen)
        controller.onCancel = { [weak self] in self?.finishGIFFlow() }
        controller.onStart = { [weak self] options in
            self?.gifConfigurationController = nil
            self?.startGIFCountdown(rect: rect, screen: screen, options: options)
        }
        gifConfigurationController = controller
        controller.present()
        notifyGIFState()
    }

    private func startGIFCountdown(rect: CGRect, screen: NSScreen, options: GIFRecordingOptions) {
        let control = GIFRecordingControlController(selectionRect: rect, screen: screen, options: options)
        control.onStop = { [weak self] in self?.stopGIFRecording() }
        control.onCancel = { [weak self] in self?.cancelGIFRecording() }
        gifControlController = control
        gifCountdownTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for value in stride(from: 3, through: 1, by: -1) {
                guard !Task.isCancelled else { return }
                control.presentCountdown(value)
                try? await Task.sleep(for: .seconds(1))
            }
            guard !Task.isCancelled else { return }
            self.gifCountdownTask = nil
            await self.startGIFSession(rect: rect, screen: screen, options: options)
        }
        notifyGIFState()
    }

    private func startGIFSession(rect: CGRect, screen: NSScreen, options: GIFRecordingOptions) async {
        let session = GIFRecordingSession(selectionRect: rect, screen: screen, options: options)
        session.onProgress = { [weak self] duration, bytes in
            self?.gifControlController?.update(duration: duration, bytes: bytes)
        }
        session.onCompletion = { [weak self] result in self?.handleGIFCompletion(result) }
        gifSession = session
        notifyGIFState()
        do {
            try await session.start()
            guard gifSession === session else { session.stop(cancel: true); return }
            gifControlController?.presentRecording()
        } catch {
            session.onCompletion = nil
            session.stop(cancel: true)
            gifSession = nil
            gifControlController?.dismiss()
            gifControlController = nil
            if !(error is CancellationError) { show(error) }
            finishGIFFlow()
        }
    }

    private func handleGIFCompletion(_ result: Result<GIFRecordingResult, Error>) {
        gifSession = nil
        gifControlController?.dismiss()
        gifControlController = nil
        switch result {
        case let .success(recording): presentGIFPreview(recording)
        case let .failure(error as GIFPartialResultError):
            let alert = NSAlert()
            alert.messageText = "GIF 已自动停止"
            alert.informativeText = error.localizedDescription + "\n已完成部分仍可预览和保存。"
            alert.runModal()
            presentGIFPreview(error.result)
        case let .failure(error) where error is CancellationError:
            finishGIFFlow()
        case let .failure(error):
            show(error)
            finishGIFFlow()
        }
    }

    private func presentGIFPreview(_ result: GIFRecordingResult) {
        let controller = GIFPreviewWindowController(result: result)
        controller.onAction = { [weak self] action in
            guard let self else { return }
            self.gifPreviewController = nil
            self.notifyGIFState()
            if action == .rerecord { self.beginGIFRecording() }
        }
        gifPreviewController = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        notifyGIFState()
    }

    private func finishGIFFlow() {
        gifCountdownTask?.cancel()
        gifCountdownTask = nil
        gifSelectionController = nil
        gifConfigurationController = nil
        gifControlController?.dismiss()
        gifControlController = nil
        gifSession = nil
        gifPreviewController = nil
        notifyGIFState()
    }

    private func allowCaptureWhileNotRecordingGIF() -> Bool {
        guard !isGIFFlowActive else {
            let alert = NSAlert()
            alert.messageText = "GIF 录制正在进行"
            alert.informativeText = "请先停止或取消 GIF 录制。"
            alert.runModal()
            return false
        }
        return true
    }

    private func notifyGIFState() { onGIFRecordingStateChange?(isGIFRecording) }

    private func ensureCapturePermission() -> Bool {
        guard PermissionManager.canCaptureScreen else {
            let alert = NSAlert()
            alert.messageText = "需要屏幕录制权限"
            alert.informativeText = "当前运行位置：\n\(Bundle.main.bundlePath)\n\n请先将横截放到“应用程序”文件夹，再为这一份应用授权。授权后必须完全退出并重新打开横截。"
            alert.addButton(withTitle: "重新申请权限")
            alert.addButton(withTitle: "取消")
            if alert.runModal() == .alertFirstButtonReturn {
                if PermissionManager.requestScreenCapture() {
                    let restart = NSAlert()
                    restart.messageText = "权限已授予"
                    restart.informativeText = "macOS 需要重新启动横截后才能开始截图。"
                    restart.addButton(withTitle: "退出横截")
                    restart.runModal()
                    NSApplication.shared.terminate(nil)
                } else {
                    PermissionManager.openPrivacyPane("ScreenCapture")
                }
            }
            return false
        }
        return true
    }

    private func captureStandard(_ rect: CGRect) {
        Task {
            do {
                let image = try await service.capture(globalRect: rect)
                let historyID = ScreenshotHistoryService.shared.create(image: image, displaySize: rect.size, kind: .standard)
                let controller = StandardCaptureOverlayController(image: image, globalRect: rect, historyID: historyID) { [weak self] in
                    self?.standardController = nil
                }
                standardController = controller
                controller.begin()
            } catch {
                show(error)
            }
        }
    }

    private func capturePin(_ rect: CGRect) {
        Task {
            do {
                let image = try await service.capture(globalRect: rect)
                PinWindowController(image: image, displaySize: rect.size, preferredFrame: rect).present()
            } catch {
                show(error)
            }
        }
    }

    private func captureText(_ rect: CGRect) {
        let controller = OCRResultWindowController.presentRecognizing { [weak self] in
            self?.beginTextExtraction()
        }
        Task {
            do {
                let image = try await service.capture(globalRect: rect)
                controller.recognize(image, displaySize: rect.size)
            } catch {
                controller.fail(with: error)
            }
        }
    }

    private func captureScrolling(_ rect: CGRect, mode: CaptureMode) {
        let axis: StitchAxis = mode == .horizontal ? .horizontal : .vertical
        do {
            let controller = try ScrollCaptureController(rect: rect, axis: axis, captureService: service) { [weak self] result in
                self?.scrollController = nil
                switch result {
                case let .success(image): self?.presentEditor(image, kind: mode == .horizontal ? .horizontal : .vertical)
                case let .failure(error) where error is CancellationError: break
                case let .failure(error): self?.show(error)
                }
            }
            scrollController = controller
            controller.begin()
        } catch {
            show(error)
        }
    }

    private func presentEditor(_ image: CGImage, kind: ScreenshotHistoryKind? = nil) {
        Task { [weak self] in
            guard let self else { return }
            let displaySize = CGSize(width: image.width, height: image.height)
            let historyID: UUID? = if let kind {
                ScreenshotHistoryService.shared.create(image: image, displaySize: displaySize, kind: kind)
            } else { nil }
            presentEditor(image: image, displaySize: displaySize, annotations: [], historyID: historyID)
        }
    }

    func editScreenshotProject(_ loaded: LoadedScreenshotProject) {
        presentEditor(
            image: loaded.image,
            displaySize: CGSize(width: loaded.project.displayWidth, height: loaded.project.displayHeight),
            annotations: loaded.project.annotations,
            historyID: loaded.item.id
        )
    }

    func editClipboardImage(_ image: CGImage) {
        guard allowCaptureWhileNotRecordingGIF() else { return }
        presentEditor(image: image, displaySize: CGSize(width: image.width, height: image.height), annotations: [], historyID: nil)
    }

    private func presentEditor(image: CGImage, displaySize: CGSize, annotations: [AnnotationMarkRecord], historyID: UUID?) {
        let controller = AnnotationEditorWindowController(
            image: image, displaySize: displaySize, annotations: annotations, historyID: historyID, presentationMode: .fitToWindow
        ) { [weak self] controller in
            self?.editorControllers.removeAll { $0 === controller }
        }
        editorControllers.append(controller)
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func show(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.runModal()
    }
}
