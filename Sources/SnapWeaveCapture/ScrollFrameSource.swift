import AppKit
import CoreImage
import CoreMedia
import ScreenCaptureKit

public actor ScrollFrameSource {
    private let rect: CGRect
    private let snapshotService: ScreenCaptureService
    private var stream: SCStream?
    private var output: ScrollStreamOutput?
    private var fallbackTask: Task<Void, Never>?
    private var continuation: AsyncStream<CGImage>.Continuation?

    public init(rect: CGRect, snapshotService: ScreenCaptureService) {
        self.rect = rect
        self.snapshotService = snapshotService
    }

    public func start() async throws -> AsyncStream<CGImage> {
        var storedContinuation: AsyncStream<CGImage>.Continuation?
        let frames = AsyncStream<CGImage>(bufferingPolicy: .bufferingNewest(4)) { value in
            storedContinuation = value
        }
        continuation = storedContinuation

        let screen = await MainActor.run { () -> (frame: CGRect, scale: CGFloat, displayID: CGDirectDisplayID)? in
            let matching = NSScreen.screens.filter {
                let intersection = $0.frame.intersection(rect)
                return !intersection.isNull && !intersection.isEmpty
            }
            guard matching.count == 1, let screen = matching.first, screen.frame.contains(rect),
                  let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return (screen.frame, screen.backingScaleFactor, CGDirectDisplayID(number.uint32Value))
        }
        guard let screen else {
            startSnapshotFallback()
            return frames
        }

        let content = try await CaptureContentProvider.shared.content()
        guard let display = content.displays.first(where: { $0.displayID == screen.displayID }) else {
            startSnapshotFallback()
            return frames
        }

        let localRect = CGRect(
            x: rect.minX - screen.frame.minX,
            y: screen.frame.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
        let excluded = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = localRect
        configuration.width = max(1, Int(localRect.width * screen.scale))
        configuration.height = max(1, Int(localRect.height * screen.scale))
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 12)
        configuration.queueDepth = 3
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.pixelFormat = kCVPixelFormatType_32BGRA

        let output = ScrollStreamOutput { [weak self] image in
            Task { await self?.yield(image) }
        }
        let stream = SCStream(filter: filter, configuration: configuration, delegate: output)
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue)
        self.output = output
        self.stream = stream
        try await stream.startCapture()
        return frames
    }

    public func stop() async {
        fallbackTask?.cancel()
        fallbackTask = nil
        continuation?.finish()
        continuation = nil
        if let stream { try? await stream.stopCapture() }
        stream = nil
        output = nil
    }

    private func startSnapshotFallback() {
        fallbackTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                if let image = try? await snapshotService.capture(globalRect: rect) {
                    await yield(image)
                }
                try? await Task.sleep(for: .milliseconds(120))
            }
        }
    }

    private func yield(_ image: CGImage) {
        continuation?.yield(image)
    }
}

private final class ScrollStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "com.wonderlab.snapweave.scroll-stream", qos: .userInitiated)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let onFrame: @Sendable (CGImage) -> Void

    init(onFrame: @escaping @Sendable (CGImage) -> Void) {
        self.onFrame = onFrame
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let pixelBuffer = sampleBuffer.imageBuffer else { return }
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = context.createCGImage(image, from: image.extent) else { return }
        onFrame(cgImage)
    }
}
