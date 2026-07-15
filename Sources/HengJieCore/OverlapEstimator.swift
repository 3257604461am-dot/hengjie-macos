import CoreGraphics
import Foundation

public struct OverlapEstimator: Sendable {
    public var minimumOverlapRatio: Double
    public var maximumOverlapRatio: Double
    public var minimumConfidence: Double

    public init(
        minimumOverlapRatio: Double = 0.15,
        maximumOverlapRatio: Double = 0.94,
        minimumConfidence: Double = 0.82
    ) {
        self.minimumOverlapRatio = minimumOverlapRatio
        self.maximumOverlapRatio = maximumOverlapRatio
        self.minimumConfidence = minimumConfidence
    }

    public func estimate(previous: CGImage, next: CGImage, axis: StitchAxis) -> OverlapMatch? {
        guard let a = GrayImage(image: previous, maximumDimension: 240),
              let b = GrayImage(image: next, maximumDimension: 240),
              a.width == b.width, a.height == b.height else { return nil }

        let length = axis == .horizontal ? a.width : a.height
        let minOverlap = max(8, Int(Double(length) * minimumOverlapRatio))
        let maxOverlap = min(length - 2, Int(Double(length) * maximumOverlapRatio))
        guard maxOverlap > minOverlap else { return nil }

        var best: (score: Double, overlap: Int, direction: StitchDirection) = (-1, 0, .forward)
        let coarseStep = 1
        for direction in [StitchDirection.forward, .backward] {
            var overlap = minOverlap
            while overlap <= maxOverlap {
                let score = similarity(a, b, overlap: overlap, axis: axis, direction: direction)
                if score > best.score { best = (score, overlap, direction) }
                overlap += coarseStep
            }
        }

        let refineStart = max(minOverlap, best.overlap - coarseStep)
        let refineEnd = min(maxOverlap, best.overlap + coarseStep)
        for direction in [StitchDirection.forward, .backward] {
            for overlap in refineStart...refineEnd {
                let score = similarity(a, b, overlap: overlap, axis: axis, direction: direction)
                if score > best.score { best = (score, overlap, direction) }
            }
        }

        guard best.score >= minimumConfidence else { return nil }
        let originalLength = axis == .horizontal ? previous.width : previous.height
        let scaledOverlap = Int((Double(best.overlap) / Double(length) * Double(originalLength)).rounded())
        return OverlapMatch(overlap: scaledOverlap, confidence: best.score, direction: best.direction)
    }

    private func similarity(
        _ a: GrayImage,
        _ b: GrayImage,
        overlap: Int,
        axis: StitchAxis,
        direction: StitchDirection
    ) -> Double {
        let orthogonalLength = axis == .horizontal ? a.height : a.width
        let orthogonalInset = max(1, orthogonalLength / 12)
        let sampleStep = max(1, min(a.width, a.height) / 180)
        var sumOld = 0.0
        var sumNew = 0.0
        var sumOldSquared = 0.0
        var sumNewSquared = 0.0
        var sumProduct = 0.0
        var samples = 0

        var along = 0
        while along < overlap {
            var orthogonal = orthogonalInset
            while orthogonal < orthogonalLength - orthogonalInset {
                let points = coordinates(
                    along: along,
                    orthogonal: orthogonal,
                    overlap: overlap,
                    axis: axis,
                    direction: direction,
                    width: a.width,
                    height: a.height
                )
                let oldValue = Int(a[points.oldX, points.oldY])
                let newValue = Int(b[points.newX, points.newY])

                // Ignore pixels that remained at the same screen coordinate. This masks
                // sticky headers, frozen columns and floating controls.
                let sameCoordinateOld = axis == .horizontal ? a[points.newX, points.oldY] : a[points.oldX, points.newY]
                if abs(Int(sameCoordinateOld) - newValue) > 3 || abs(oldValue - newValue) < 4 {
                    let old = Double(oldValue)
                    let new = Double(newValue)
                    sumOld += old
                    sumNew += new
                    sumOldSquared += old * old
                    sumNewSquared += new * new
                    sumProduct += old * new
                    samples += 1
                }
                orthogonal += sampleStep
            }
            along += sampleStep
        }
        guard samples > 32 else { return 0 }
        let count = Double(samples)
        let covariance = count * sumProduct - sumOld * sumNew
        let oldVariance = count * sumOldSquared - sumOld * sumOld
        let newVariance = count * sumNewSquared - sumNew * sumNew
        guard oldVariance > 1, newVariance > 1 else { return 0 }
        let correlation = covariance / sqrt(oldVariance * newVariance)
        return max(0, min(1, (correlation + 1) / 2))
    }

    private func coordinates(
        along: Int,
        orthogonal: Int,
        overlap: Int,
        axis: StitchAxis,
        direction: StitchDirection,
        width: Int,
        height: Int
    ) -> (oldX: Int, oldY: Int, newX: Int, newY: Int) {
        if axis == .horizontal {
            if direction == .forward {
                return (width - overlap + along, orthogonal, along, orthogonal)
            }
            return (along, orthogonal, width - overlap + along, orthogonal)
        }
        if direction == .forward {
            return (orthogonal, height - overlap + along, orthogonal, along)
        }
        return (orthogonal, along, orthogonal, height - overlap + along)
    }
}
