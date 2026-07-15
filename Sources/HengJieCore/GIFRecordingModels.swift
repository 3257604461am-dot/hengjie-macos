import CoreGraphics
import Foundation

public enum GIFQuality: String, CaseIterable, Sendable {
    case high
    case standard
    case compact

    public var title: String {
        switch self {
        case .high: "高清 100%"
        case .standard: "标准 75%"
        case .compact: "小文件 50%"
        }
    }

    public var scale: CGFloat {
        switch self {
        case .high: 1
        case .standard: 0.75
        case .compact: 0.5
        }
    }
}

public struct GIFRecordingOptions: Sendable {
    public var framesPerSecond: Int
    public var quality: GIFQuality
    public var showsCursor: Bool
    public var maximumDuration: TimeInterval
    public var maximumFileSize: Int64

    public init(
        framesPerSecond: Int = 15,
        quality: GIFQuality = .standard,
        showsCursor: Bool = true,
        maximumDuration: TimeInterval = 300,
        maximumFileSize: Int64 = 1_000_000_000
    ) {
        self.framesPerSecond = min(30, max(1, framesPerSecond))
        self.quality = quality
        self.showsCursor = showsCursor
        self.maximumDuration = maximumDuration
        self.maximumFileSize = maximumFileSize
    }
}

public enum GIFOutputLayout {
    public static func outputSize(
        selectionSize: CGSize,
        backingScale: CGFloat,
        quality: GIFQuality,
        maximumDimension: CGFloat = 4096,
        maximumPixelCount: CGFloat = 16_000_000
    ) -> CGSize {
        guard selectionSize.width > 0, selectionSize.height > 0 else { return .zero }
        var width = selectionSize.width * max(1, backingScale) * quality.scale
        var height = selectionSize.height * max(1, backingScale) * quality.scale
        let dimensionScale = min(1, maximumDimension / max(width, height))
        let pixelScale = min(1, sqrt(maximumPixelCount / max(1, width * height)))
        let safetyScale = min(dimensionScale, pixelScale)
        width = max(1, floor(width * safetyScale))
        height = max(1, floor(height * safetyScale))
        return CGSize(width: width, height: height)
    }
}
