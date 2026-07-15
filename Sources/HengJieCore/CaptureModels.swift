import Foundation
import CoreGraphics

public enum CaptureMode: String, CaseIterable, Sendable {
    case standard
    case vertical
    case horizontal

    public var displayName: String {
        switch self {
        case .standard: "普通截图"
        case .vertical: "上下长截图"
        case .horizontal: "左右长截图"
        }
    }
}

public enum StitchAxis: Sendable {
    case vertical
    case horizontal
}

public enum ScrollDriver: String, CaseIterable, Sendable {
    case automatic
    case manual

    public var displayName: String { self == .automatic ? "自动滚动" : "手动滚动" }
    public static let `default`: ScrollDriver = .manual
}

public enum StitchDirection: Int, Sendable {
    case forward = 1
    case backward = -1
}

public struct StitchLimits: Sendable {
    public var maximumAxisLength: Int
    public var maximumPixelCount: Int

    public init(maximumAxisLength: Int = 100_000, maximumPixelCount: Int = 200_000_000) {
        self.maximumAxisLength = maximumAxisLength
        self.maximumPixelCount = maximumPixelCount
    }
}

public struct OverlapMatch: Equatable, Sendable {
    public let overlap: Int
    public let confidence: Double
    public let direction: StitchDirection

    public init(overlap: Int, confidence: Double, direction: StitchDirection) {
        self.overlap = overlap
        self.confidence = confidence
        self.direction = direction
    }
}

public enum StitchError: LocalizedError, Equatable {
    case incompatibleFrameSize
    case noReliableOverlap(confidence: Double)
    case directionReversed
    case limitReached
    case cannotCreateImage

    public var errorDescription: String? {
        switch self {
        case .incompatibleFrameSize: "截图区域尺寸发生变化，请恢复窗口大小后重试。"
        case let .noReliableOverlap(confidence): "未找到可靠的重叠区域（置信度 \(Int(confidence * 100))%）。"
        case .directionReversed: "检测到明显反向滚动，已暂停拼接。"
        case .limitReached: "长图已达到安全尺寸上限。"
        case .cannotCreateImage: "无法生成拼接图片。"
        }
    }
}
