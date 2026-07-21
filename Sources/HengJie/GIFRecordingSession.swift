import AppKit
import CoreImage
import CoreMedia
import HengJieCore
import HengJieMedia
import ScreenCaptureKit

final class GIFRecordingSession: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    typealias Completion = (Result<GIFRecordingResult, Error>) -> Void
    typealias Progress = (_ duration: TimeInterval, _ estimatedBytes: Int64) -> Void

    let selectionRect: CGRect
    let options: GIFRecordingOptions
    let outputSize: CGSize
    var onProgress: Progress?
    var onCompletion: Completion?

    private let screen: NSScreen
    private let captureQueue = DispatchQueue(label: "com.wonderlab.hengjie.gif.capture", qos: .userInitiated)
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private var stream: SCStream?
    private var encoder: GIFStreamEncoder?
    private var pendingImage: CGImage?
    private var pendingTimestamp: TimeInterval?
    private var firstTimestamp: TimeInterval?
    private var lastTimestamp: TimeInterval?
    private var estimatedBytes: Int64 = 0
    private var stopping = false
    private var cancelled = false
    private var limitError: Error?
    private let stateLock = NSLock()
    private var stopRequested = false

    init(selectionRect: CGRect, screen: NSScreen, options: GIFRecordingOptions) {
        self.selectionRect = selectionRect
        self.screen = screen
        self.options = options
        outputSize = GIFOutputLayout.outputSize(
            selectionSize: selectionRect.size,
            backingScale: screen.backingScaleFactor,
            quality: options.quality
        )
        super.init()
    }

    func start() async throws {
        GIFTemporaryFiles.cleanupStaleFiles()
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            try throwIfStopRequested()
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let display = content.displays.first(where: { $0.displayID == CGDirectDisplayID(number.uint32Value) }) else {
                throw GIFRecordingError.displayUnavailable
            }
            let url = GIFTemporaryFiles.newURL()
            encoder = try GIFStreamEncoder(url: url, maximumFrameCount: options.framesPerSecond * Int(options.maximumDuration) + 1)
            try throwIfStopRequested()

            let filter = SCContentFilter(
                display: display,
                excludingApplications: content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier },
                exceptingWindows: []
            )
            let localRect = CGRect(
                x: selectionRect.minX - screen.frame.minX,
                y: screen.frame.maxY - selectionRect.maxY,
                width: selectionRect.width,
                height: selectionRect.height
            )
            let configuration = SCStreamConfiguration()
            configuration.sourceRect = localRect
            configuration.width = max(1, Int(outputSize.width))
            configuration.height = max(1, Int(outputSize.height))
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(options.framesPerSecond))
            configuration.queueDepth = 3
            configuration.pixelFormat = kCVPixelFormatType_32BGRA
            configuration.showsCursor = options.showsCursor
            configuration.capturesAudio = false
            configuration.captureResolution = .best

            let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
            self.stream = stream
            try throwIfStopRequested()
            try await stream.startCapture()
            if isStopRequested {
                try? await stream.stopCapture()
                throw CancellationError()
            }
        } catch {
            if let url = encoder?.url { try? FileManager.default.removeItem(at: url) }
            stream = nil
            throw error
        }
    }

    func stop(cancel: Bool = false) {
        stateLock.lock()
        stopRequested = true
        if cancel { cancelled = true }
        stateLock.unlock()
        captureQueue.async { [weak self] in
            guard let self, !self.stopping else { return }
            guard self.stream != nil else { return }
            self.stopping = true
            Task { [weak self] in
                guard let self else { return }
                do { try await self.stream?.stopCapture() }
                catch { if self.limitError == nil { self.limitError = error } }
                self.captureQueue.async { self.finish() }
            }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        captureQueue.async { [weak self] in
            guard let self, !self.stopping else { return }
            self.limitError = error
            self.stopping = true
            self.finish()
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .screen, !stopping, sampleBuffer.isValid,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let timestamp = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        guard timestamp.isFinite else { return }
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = ciContext.createCGImage(image, from: image.extent) else { return }
        consume(cgImage, timestamp: timestamp)
    }

    private func consume(_ image: CGImage, timestamp: TimeInterval) {
        if firstTimestamp == nil { firstTimestamp = timestamp }
        lastTimestamp = timestamp
        if let firstTimestamp {
            let duration = max(0, timestamp - firstTimestamp)
            estimatedBytes = max(
                GIFStreamEncoder.fileSize(at: encoder?.url ?? URL(fileURLWithPath: "/dev/null")),
                Int64(Double(max(1, encoder?.frameCount ?? 1)) * Double(image.width * image.height) * 0.125)
            )
            DispatchQueue.main.async { [weak self] in self?.onProgress?(duration, self?.estimatedBytes ?? 0) }
            if duration >= options.maximumDuration {
                stop()
                return
            }
            if estimatedBytes >= options.maximumFileSize {
                limitError = GIFRecordingError.maximumFileSizeReached
                stop()
                return
            }
        }

        guard let pendingImage, let pendingTimestamp else {
            self.pendingImage = image
            self.pendingTimestamp = timestamp
            return
        }
        if FrameChangeDetector.changeRatio(pendingImage, image) < 0.0001 { return }
        encoder?.add(pendingImage, delay: timestamp - pendingTimestamp)
        self.pendingImage = image
        self.pendingTimestamp = timestamp
    }

    private func finish() {
        defer { stream = nil }
        if isCancellationRequested {
            if let url = encoder?.url { try? FileManager.default.removeItem(at: url) }
            complete(.failure(CancellationError()))
            return
        }
        guard let encoder else { complete(.failure(GIFRecordingError.cannotCreateEncoder)); return }
        if let pendingImage, let pendingTimestamp {
            let finalTimestamp = lastTimestamp ?? pendingTimestamp
            encoder.add(pendingImage, delay: max(1 / Double(options.framesPerSecond), finalTimestamp - pendingTimestamp))
        }
        do {
            let fileSize = try encoder.finalize()
            let duration = max(1 / Double(options.framesPerSecond), (lastTimestamp ?? 0) - (firstTimestamp ?? 0))
            let result = GIFRecordingResult(
                url: encoder.url, pixelSize: outputSize, framesPerSecond: options.framesPerSecond,
                duration: duration, frameCount: encoder.frameCount, fileSize: fileSize
            )
            if let limitError { complete(.failure(GIFPartialResultError(error: limitError, result: result))) }
            else { complete(.success(result)) }
        } catch {
            try? FileManager.default.removeItem(at: encoder.url)
            complete(.failure(error))
        }
    }

    private func complete(_ result: Result<GIFRecordingResult, Error>) {
        DispatchQueue.main.async { [weak self] in self?.onCompletion?(result) }
    }

    private var isStopRequested: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stopRequested
    }

    private var isCancellationRequested: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return cancelled
    }

    private func throwIfStopRequested() throws {
        if isStopRequested { throw CancellationError() }
    }
}
