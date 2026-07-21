import CoreGraphics
import Foundation

/// Metadata persisted while a scroll session is active. It deliberately contains
/// no pixels, so it is safe to include in diagnostics and crash recovery.
public struct StitchCheckpoint: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public let version: Int
    public let axis: String
    public let frameCount: Int
    public let direction: Int?
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let segmentNames: [String]
    public let createdAt: Date

    public init(
        axis: StitchAxis,
        frameCount: Int,
        direction: StitchDirection?,
        pixelSize: CGSize,
        segmentNames: [String],
        createdAt: Date = Date()
    ) {
        version = Self.currentVersion
        self.axis = axis == .horizontal ? "horizontal" : "vertical"
        self.frameCount = frameCount
        self.direction = direction?.rawValue
        pixelWidth = Int(pixelSize.width)
        pixelHeight = Int(pixelSize.height)
        self.segmentNames = segmentNames
        self.createdAt = createdAt
    }
}

/// Runs a deterministic frame sequence through the production stitch session.
/// UI code uses the same session; tests can therefore reproduce a problematic
/// capture without requiring ScreenCaptureKit or a live target application.
public final class StitchReplayRunner: @unchecked Sendable {
    public let axis: StitchAxis
    public let limits: StitchLimits

    public init(axis: StitchAxis, limits: StitchLimits = .init()) {
        self.axis = axis
        self.limits = limits
    }

    public func run(_ frames: [CGImage]) throws -> [StitchAppendResult] {
        let session = try StitchSession(axis: axis, limits: limits)
        var results: [StitchAppendResult] = []
        results.reserveCapacity(frames.count)
        for frame in frames {
            results.append(try session.appendAnalyzed(frame))
        }
        return results
    }
}
