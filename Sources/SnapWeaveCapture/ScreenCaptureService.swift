import AppKit
import SnapWeaveCore
import ScreenCaptureKit

@MainActor
public final class ScreenCaptureService {
    private let contentProvider: CaptureContentProvider

    public init(contentProvider: CaptureContentProvider? = nil) {
        self.contentProvider = contentProvider ?? .shared
    }

    public enum CaptureError: LocalizedError {
        case noDisplay
        case permissionDenied
        case captureFailed

        public var errorDescription: String? {
            switch self {
            case .noDisplay: "选区不在可用显示器中。"
            case .permissionDenied: "需要授予屏幕录制权限。"
            case .captureFailed: "屏幕捕获失败。"
            }
        }
    }

    public func capture(globalRect: CGRect) async throws -> CGImage {
        let trace = PerformanceTrace.begin("ScreenCapture")
        defer { PerformanceTrace.end("ScreenCapture", trace) }
        guard CGPreflightScreenCaptureAccess() else { throw CaptureError.permissionDenied }
        let content = try await contentProvider.content()
        do {
            return try await capture(globalRect: globalRect, content: content)
        } catch CaptureError.captureFailed {
            contentProvider.invalidate()
            let refreshed = try await contentProvider.content(forceRefresh: true)
            return try await capture(globalRect: globalRect, content: refreshed)
        }
    }

    private func capture(globalRect: CGRect, content: SCShareableContent) async throws -> CGImage {
        let pieces = NSScreen.screens.compactMap { screen -> (NSScreen, CGRect)? in
            let intersection = screen.frame.intersection(globalRect)
            return intersection.isNull || intersection.isEmpty ? nil : (screen, intersection)
        }
        guard !pieces.isEmpty else { throw CaptureError.noDisplay }

        var images: [(CGImage, CGRect, CGFloat)] = []
        for (screen, intersection) in pieces {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let display = content.displays.first(where: { $0.displayID == CGDirectDisplayID(number.uint32Value) }) else { continue }
            let scale = screen.backingScaleFactor
            let localRect = CGRect(
                x: intersection.minX - screen.frame.minX,
                y: screen.frame.maxY - intersection.maxY,
                width: intersection.width,
                height: intersection.height
            )
            let filter = SCContentFilter(display: display, excludingApplications: content.applications.filter {
                $0.bundleIdentifier == Bundle.main.bundleIdentifier
            }, exceptingWindows: [])
            let configuration = SCStreamConfiguration()
            configuration.sourceRect = localRect
            configuration.width = max(1, Int(localRect.width * scale))
            configuration.height = max(1, Int(localRect.height * scale))
            configuration.showsCursor = false
            configuration.captureResolution = .best
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            images.append((image, intersection, scale))
        }
        guard !images.isEmpty else { throw CaptureError.captureFailed }
        if images.count == 1, let first = images.first { return first.0 }

        let maximumScale = images.map(\.2).max() ?? 1
        let width = Int(globalRect.width * maximumScale)
        let height = Int(globalRect.height * maximumScale)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw CaptureError.captureFailed }
        for (image, rect, _) in images {
            let destination = CGRect(
                x: (rect.minX - globalRect.minX) * maximumScale,
                y: (rect.minY - globalRect.minY) * maximumScale,
                width: rect.width * maximumScale,
                height: rect.height * maximumScale
            )
            context.draw(image, in: destination)
        }
        guard let result = context.makeImage() else { throw CaptureError.captureFailed }
        return result
    }
}
