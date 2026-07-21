import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct GIFRecordingResult {
    public let url: URL
    public let pixelSize: CGSize
    public let framesPerSecond: Int
    public let duration: TimeInterval
    public let frameCount: Int
    public let fileSize: Int64

    public init(url: URL, pixelSize: CGSize, framesPerSecond: Int, duration: TimeInterval, frameCount: Int, fileSize: Int64) {
        self.url = url
        self.pixelSize = pixelSize
        self.framesPerSecond = framesPerSecond
        self.duration = duration
        self.frameCount = frameCount
        self.fileSize = fileSize
    }
}

public enum GIFRecordingError: LocalizedError {
    case selectionCrossesDisplays
    case displayUnavailable
    case cannotCreateEncoder
    case encodingFailed
    case noFrames
    case maximumFileSizeReached

    public var errorDescription: String? {
        switch self {
        case .selectionCrossesDisplays: "GIF 录制区域必须位于同一个显示器内，请重新框选。"
        case .displayUnavailable: "所选显示器已不可用。"
        case .cannotCreateEncoder: "无法创建 GIF 编码器。"
        case .encodingFailed: "GIF 编码失败，已尽可能保留完成部分。"
        case .noFrames: "录制期间没有捕获到有效画面。"
        case .maximumFileSizeReached: "GIF 已达到 1GB 安全上限并自动停止。"
        }
    }
}

public final class GIFStreamEncoder {
    public let url: URL
    private let destination: CGImageDestination
    public private(set) var frameCount = 0

    public init(url: URL, maximumFrameCount: Int) throws {
        self.url = url
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.gif.identifier as CFString, max(1, maximumFrameCount), nil
        ) else { throw GIFRecordingError.cannotCreateEncoder }
        self.destination = destination
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
        ] as CFDictionary)
    }

    public func add(_ image: CGImage, delay: TimeInterval) {
        let safeDelay = max(0.02, delay)
        CGImageDestinationAddImage(destination, image, [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: safeDelay,
                kCGImagePropertyGIFUnclampedDelayTime: safeDelay
            ]
        ] as CFDictionary)
        frameCount += 1
    }

    public func finalize() throws -> Int64 {
        guard frameCount > 0 else { throw GIFRecordingError.noFrames }
        guard CGImageDestinationFinalize(destination) else { throw GIFRecordingError.encodingFailed }
        return Self.fileSize(at: url)
    }

    public static func fileSize(at url: URL) -> Int64 {
        let value = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        return Int64(value ?? 0)
    }
}

public struct GIFPartialResultError: LocalizedError {
    public let error: Error
    public let result: GIFRecordingResult

    public init(error: Error, result: GIFRecordingResult) {
        self.error = error
        self.result = result
    }

    public var errorDescription: String? { error.localizedDescription }
}

public enum GIFTemporaryFiles {
    public static var directory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("com.wonderlab.hengjie/gif", isDirectory: true)
    }

    public static func newURL() -> URL {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("gif")
    }

    public static func cleanupStaleFiles() {
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for url in urls { try? FileManager.default.removeItem(at: url) }
    }
}
