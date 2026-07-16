import AppKit
import HengJieCore

@MainActor
final class ScrollCaptureController: NSWindowController {
    private let captureRect: CGRect
    private let axis: StitchAxis
    private let captureService: ScreenCaptureService
    private let frameSource: ScrollFrameSource
    private let completion: (Result<CGImage, Error>) -> Void
    private let session: StitchSession
    private var driver: ScrollDriver
    private var captureTask: Task<Void, Never>?
    private var paused = false
    private var completed = false
    private var lastAutoScrollAt = Date.distantPast

    private let statusLabel = NSTextField(labelWithString: "准备采集…")
    private let progressLabel = NSTextField(labelWithString: "0 帧")
    private let driverButton = NSButton()
    private let pauseButton = NSButton()
    private let retryButton = NSButton()

    init(
        rect: CGRect,
        axis: StitchAxis,
        captureService: ScreenCaptureService,
        completion: @escaping (Result<CGImage, Error>) -> Void
    ) throws {
        captureRect = rect
        self.axis = axis
        self.captureService = captureService
        frameSource = ScrollFrameSource(rect: rect, snapshotService: captureService)
        self.completion = completion
        session = try StitchSession(axis: axis)
        driver = .default
        let panel = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 500, height: 112),
            styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false
        )
        panel.title = axis == .horizontal ? "左右滚动截图" : "上下滚动截图"
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        super.init(window: panel)
        buildUI()
    }

    required init?(coder: NSCoder) { nil }

    func begin() {
        guard let window else { return }
        let screenFrame = NSScreen.main?.visibleFrame ?? .zero
        window.setFrameOrigin(CGPoint(x: screenFrame.midX - window.frame.width / 2, y: screenFrame.maxY - window.frame.height - 24))
        showWindow(nil)
        window.orderFrontRegardless()
        DiagnosticLogger.shared.log("stitch", "session_started", fields: ["axis": axis == .horizontal ? "horizontal" : "vertical"])
        captureTask = Task { [weak self] in await self?.captureLoop() }
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        statusLabel.font = .systemFont(ofSize: 13, weight: .medium)
        statusLabel.lineBreakMode = .byTruncatingTail
        progressLabel.textColor = .secondaryLabelColor
        driverButton.title = driver.displayName
        driverButton.target = self
        driverButton.action = #selector(toggleDriver)
        driverButton.bezelStyle = .rounded
        pauseButton.title = "暂停"
        pauseButton.target = self
        pauseButton.action = #selector(togglePause)
        pauseButton.bezelStyle = .rounded
        retryButton.title = "重试当前段"
        retryButton.target = self
        retryButton.action = #selector(retryCurrentSegment)
        retryButton.bezelStyle = .rounded
        retryButton.isHidden = true
        let finish = NSButton(title: "完成", target: self, action: #selector(finishCapture))
        finish.bezelStyle = .rounded
        finish.keyEquivalent = "\r"
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelCapture))
        cancel.bezelStyle = .rounded

        let labels = NSStackView(views: [statusLabel, progressLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        let controls = NSStackView(views: [driverButton, pauseButton, retryButton, finish, cancel])
        controls.spacing = 8
        let root = NSStackView(views: [labels, controls])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 12
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            root.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            root.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -12)
        ])
        updateStatus("请保持目标窗口大小不变，然后开始滚动")
    }

    private func captureLoop() async {
        do {
            let frames = try await frameSource.start()
            for await frame in frames {
                guard !Task.isCancelled, !completed else { break }
                if !paused {
                    do {
                        let stitchSession = session
                        let result = try await Task.detached(priority: .userInitiated) {
                            try stitchSession.appendAnalyzed(frame)
                        }.value
                        switch result {
                        case .initial:
                            updateProgress(confidence: nil)
                        case let .accepted(match):
                            updateProgress(confidence: match.confidence)
                            DiagnosticLogger.shared.log("stitch", "frame_accepted", fields: [
                                "confidence": String(format: "%.3f", match.confidence),
                                "coverage": String(format: "%.3f", match.effectiveCoverage),
                                "ambiguity": String(format: "%.3f", match.ambiguity),
                                "overlap": "\(match.overlap)"
                            ])
                        case .unchanged:
                            break
                        case .waitingForMoreFrames:
                            updateStatus("正在寻找可靠的中间帧…")
                        case let .paused(reason):
                            pauseFor(reason)
                        }
                    } catch StitchError.limitReached {
                        updateStatus("已达到长图尺寸上限，正在完成")
                        finishCapture()
                        return
                    }
                }
                if driver == .automatic, PermissionManager.hasAccessibility,
                   Date().timeIntervalSince(lastAutoScrollAt) >= 0.62 {
                    lastAutoScrollAt = Date()
                    if !postScrollEvent() { updateStatus("鼠标已离开截图区域，自动滚动暂时停止") }
                }
            }
        } catch {
            paused = true
            retryButton.isHidden = false
            updateStatus(error.localizedDescription)
        }
        await frameSource.stop()
    }

    @discardableResult
    private func postScrollEvent() -> Bool {
        guard AutomaticScrollPolicy.shouldInject(mouseLocation: NSEvent.mouseLocation, captureRect: captureRect) else { return false }
        let delta: Int32 = -180
        let event: CGEvent?
        if axis == .horizontal {
            event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: delta, wheel3: 0)
        } else {
            event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0)
        }
        event?.post(tap: .cghidEventTap)
        return event != nil
    }

    @objc private func toggleDriver() {
        if driver == .automatic {
            driver = .manual
        } else if PermissionManager.hasAccessibility {
            driver = .automatic
        } else {
            _ = PermissionManager.requestAccessibility()
            driver = .manual
        }
        driverButton.title = driver.displayName
        updateStatus(driver == .manual ? "请用触控板或鼠标沿选定方向滚动" : "请将鼠标停在截图区域内；移出区域将自动暂停")
    }

    @objc private func togglePause() {
        paused.toggle()
        pauseButton.title = paused ? "继续" : "暂停"
        retryButton.isHidden = !paused
        if !paused { session.retryCurrentSegment() }
        updateStatus(paused ? "已暂停" : (driver == .manual ? "请继续手动滚动" : "正在自动滚动"))
    }

    @objc private func retryCurrentSegment() {
        session.retryCurrentSegment()
        paused = false
        retryButton.isHidden = true
        pauseButton.title = "暂停"
        updateStatus("请回到上一位置，然后沿原方向缓慢滚动")
    }

    @objc private func finishCapture() {
        guard !completed else { return }
        completed = true
        captureTask?.cancel()
        Task { [weak self] in
            guard let self else { return }
            await frameSource.stop()
            do {
                let stitchSession = session
                let image = try await Task.detached(priority: .userInitiated) { try stitchSession.render() }.value
                DiagnosticLogger.shared.log("stitch", "session_finished", fields: ["frames": "\(session.frameCount)", "pixels": "\(Int(session.pixelSize.width))x\(Int(session.pixelSize.height))"])
                close()
                completion(.success(image))
            } catch {
                close()
                completion(.failure(error))
            }
        }
    }

    @objc private func cancelCapture() {
        guard !completed else { return }
        completed = true
        captureTask?.cancel()
        Task { await frameSource.stop() }
        close()
        DiagnosticLogger.shared.log("stitch", "session_cancelled", fields: ["frames": "\(session.frameCount)"])
        completion(.failure(CancellationError()))
    }

    private func updateStatus(_ text: String) { statusLabel.stringValue = text }
    private func pauseFor(_ reason: StitchPauseReason) {
        paused = true
        retryButton.isHidden = false
        pauseButton.title = "继续手动滚动"
        updateStatus(reason.message)
        DiagnosticLogger.shared.log("stitch", "session_paused", fields: ["reason": reason.rawValue])
    }
    private func updateProgress(confidence: Double?) {
        let axisLength = axis == .horizontal ? Int(session.pixelSize.width) : Int(session.pixelSize.height)
        let confidenceText = confidence.map { " · 匹配 \(Int($0 * 100))%" } ?? ""
        progressLabel.stringValue = "\(session.frameCount) 帧 · \(axisLength) px\(confidenceText)"
        updateStatus(driver == .manual ? "正在监听手动滚动" : "正在自动滚动")
    }
}
