import CoreGraphics
import Foundation

public struct OverlapEstimator: Sendable {
    public var minimumOverlapRatio: Double
    public var maximumOverlapRatio: Double
    public var minimumConfidence: Double
    public var minimumCandidateMargin: Double

    public init(
        minimumOverlapRatio: Double = 0.08,
        maximumOverlapRatio: Double = 0.96,
        minimumConfidence: Double = 0.76,
        minimumCandidateMargin: Double = 0.010
    ) {
        self.minimumOverlapRatio = minimumOverlapRatio
        self.maximumOverlapRatio = maximumOverlapRatio
        self.minimumConfidence = minimumConfidence
        self.minimumCandidateMargin = minimumCandidateMargin
    }

    public func estimate(previous: CGImage, next: CGImage, axis: StitchAxis) -> OverlapMatch? {
        guard case let .match(match) = analyze(previous: previous, next: next, axis: axis) else { return nil }
        return match
    }

    public func analyze(previous: CGImage, next: CGImage, axis: StitchAxis) -> OverlapEstimate {
        guard previous.width == next.width, previous.height == next.height,
              let coarseA = GrayImage(image: previous, maximumDimension: 280),
              let coarseB = GrayImage(image: next, maximumDimension: 280)
        else { return .insufficient(confidence: 0, coverage: 0) }

        if pixelChangeRatio(coarseA, coarseB) < 0.002 { return .unchanged }
        let coarse = search(coarseA, coarseB, axis: axis, overlapRange: nil, offsets: 0...0, step: 3)
        guard let coarseBest = coarse.best else { return .insufficient(confidence: 0, coverage: 0) }

        guard let fineA = GrayImage(image: previous, maximumDimension: 520),
              let fineB = GrayImage(image: next, maximumDimension: 520)
        else { return .insufficient(confidence: coarseBest.score, coverage: coarseBest.coverage) }

        let coarseLength = axis == .horizontal ? coarseA.width : coarseA.height
        let fineLength = axis == .horizontal ? fineA.width : fineA.height
        let projected = Int((Double(coarseBest.overlap) / Double(coarseLength) * Double(fineLength)).rounded())
        let radius = max(5, fineLength / 35)
        let fine = search(
            fineA,
            fineB,
            axis: axis,
            overlapRange: max(8, projected - radius)...min(fineLength - 2, projected + radius),
            offsets: -3...3,
            step: 1
        )
        guard let best = fine.best else { return .insufficient(confidence: 0, coverage: 0) }

        let margin = max(0, best.score - (fine.second?.score ?? 0))
        let ambiguity = min(1, margin / max(minimumCandidateMargin, 0.001))
        guard best.score >= minimumConfidence, best.coverage >= 0.22 else {
            return .insufficient(confidence: best.score, coverage: best.coverage)
        }
        guard margin >= minimumCandidateMargin || best.score >= 0.965 else {
            return .ambiguous(confidence: best.score, coverage: best.coverage)
        }

        let originalLength = axis == .horizontal ? previous.width : previous.height
        let orthogonalOriginal = axis == .horizontal ? previous.height : previous.width
        let fineOrthogonal = axis == .horizontal ? fineA.height : fineA.width
        let scaledOverlap = Int((Double(best.overlap) / Double(fineLength) * Double(originalLength)).rounded())
        let scaledOffset = Int((Double(best.offset) / Double(fineOrthogonal) * Double(orthogonalOriginal)).rounded())
        return .match(OverlapMatch(
            overlap: scaledOverlap,
            confidence: best.score,
            direction: best.direction,
            orthogonalOffset: scaledOffset,
            ambiguity: ambiguity,
            effectiveCoverage: best.coverage
        ))
    }

    private struct Candidate {
        let score: Double
        let overlap: Int
        let direction: StitchDirection
        let offset: Int
        let coverage: Double
    }

    private func search(
        _ a: GrayImage,
        _ b: GrayImage,
        axis: StitchAxis,
        overlapRange: ClosedRange<Int>?,
        offsets: ClosedRange<Int>,
        step: Int
    ) -> (best: Candidate?, second: Candidate?) {
        let length = axis == .horizontal ? a.width : a.height
        let minOverlap = max(8, Int(Double(length) * minimumOverlapRatio))
        let maxOverlap = min(length - 2, Int(Double(length) * maximumOverlapRatio))
        let range = overlapRange ?? minOverlap...maxOverlap
        guard range.lowerBound <= range.upperBound else { return (nil, nil) }

        var candidates: [Candidate] = []
        for direction in [StitchDirection.forward, .backward] {
            var overlap = range.lowerBound
            while overlap <= range.upperBound {
                for offset in offsets {
                    let result = similarity(a, b, overlap: overlap, axis: axis, direction: direction, orthogonalOffset: offset)
                    if result.coverage >= 0.12 {
                        candidates.append(Candidate(score: result.score, overlap: overlap, direction: direction, offset: offset, coverage: result.coverage))
                    }
                }
                overlap += max(1, step)
            }
        }
        candidates.sort { $0.score > $1.score }
        guard let best = candidates.first else { return (nil, nil) }
        let exclusion = max(3, length / 80)
        let second = candidates.dropFirst().first {
            $0.direction != best.direction || abs($0.overlap - best.overlap) > exclusion
        }
        return (best, second)
    }

    private func similarity(
        _ a: GrayImage,
        _ b: GrayImage,
        overlap: Int,
        axis: StitchAxis,
        direction: StitchDirection,
        orthogonalOffset: Int
    ) -> (score: Double, coverage: Double) {
        let orthogonalLength = axis == .horizontal ? a.height : a.width
        let orthogonalInset = max(2, orthogonalLength / 20)
        let alongStep = max(1, overlap / 38)
        let orthogonalStep = max(1, orthogonalLength / 52)
        var luma = CorrelationAccumulator()
        var edge = CorrelationAccumulator()
        var considered = 0
        var samples = 0

        var along = 1
        while along < overlap - 1 {
            var orthogonal = orthogonalInset
            while orthogonal < orthogonalLength - orthogonalInset {
                considered += 1
                let shifted = orthogonal + orthogonalOffset
                guard shifted > 0, shifted < orthogonalLength - 1 else {
                    orthogonal += orthogonalStep
                    continue
                }
                let points = coordinates(
                    along: along,
                    oldOrthogonal: orthogonal,
                    newOrthogonal: shifted,
                    overlap: overlap,
                    axis: axis,
                    direction: direction,
                    width: a.width,
                    height: a.height
                )
                let oldValue = Int(a[points.oldX, points.oldY])
                let newValue = Int(b[points.newX, points.newY])
                let sameScreen = axis == .horizontal
                    ? Int(a[points.newX, points.oldY])
                    : Int(a[points.oldX, points.newY])

                // A pixel that stayed at the same screen coordinate but does not agree
                // with the proposed world-coordinate match is likely a frozen control.
                if abs(sameScreen - newValue) <= 2 && abs(oldValue - newValue) > 6 {
                    orthogonal += orthogonalStep
                    continue
                }
                luma.add(Double(oldValue), Double(newValue))
                edge.add(
                    Double(edgeValue(a, x: points.oldX, y: points.oldY)),
                    Double(edgeValue(b, x: points.newX, y: points.newY))
                )
                samples += 1
                orthogonal += orthogonalStep
            }
            along += alongStep
        }
        guard samples > 40 else { return (0, 0) }
        let coverage = considered == 0 ? 0 : Double(samples) / Double(considered)
        let score = 0.38 * luma.score + 0.62 * edge.score
        return (max(0, min(1, score)), coverage)
    }

    private func edgeValue(_ image: GrayImage, x: Int, y: Int) -> Int {
        let dx = abs(Int(image[x + 1, y]) - Int(image[x - 1, y]))
        let dy = abs(Int(image[x, y + 1]) - Int(image[x, y - 1]))
        return min(255, dx + dy)
    }

    private func pixelChangeRatio(_ a: GrayImage, _ b: GrayImage) -> Double {
        var changed = 0
        var count = 0
        for y in stride(from: 0, to: a.height, by: 3) {
            for x in stride(from: 0, to: a.width, by: 3) {
                if abs(Int(a[x, y]) - Int(b[x, y])) > 6 { changed += 1 }
                count += 1
            }
        }
        return count == 0 ? 0 : Double(changed) / Double(count)
    }

    private func coordinates(
        along: Int,
        oldOrthogonal: Int,
        newOrthogonal: Int,
        overlap: Int,
        axis: StitchAxis,
        direction: StitchDirection,
        width: Int,
        height: Int
    ) -> (oldX: Int, oldY: Int, newX: Int, newY: Int) {
        if axis == .horizontal {
            if direction == .forward { return (width - overlap + along, oldOrthogonal, along, newOrthogonal) }
            return (along, oldOrthogonal, width - overlap + along, newOrthogonal)
        }
        if direction == .forward { return (oldOrthogonal, height - overlap + along, newOrthogonal, along) }
        return (oldOrthogonal, along, newOrthogonal, height - overlap + along)
    }
}

private struct CorrelationAccumulator {
    private var sumA = 0.0
    private var sumB = 0.0
    private var sumAA = 0.0
    private var sumBB = 0.0
    private var sumAB = 0.0
    private var count = 0

    mutating func add(_ a: Double, _ b: Double) {
        sumA += a
        sumB += b
        sumAA += a * a
        sumBB += b * b
        sumAB += a * b
        count += 1
    }

    var score: Double {
        guard count > 8 else { return 0 }
        let n = Double(count)
        let covariance = n * sumAB - sumA * sumB
        let varianceA = n * sumAA - sumA * sumA
        let varianceB = n * sumBB - sumB * sumB
        guard varianceA > 1, varianceB > 1 else { return 0 }
        let correlation = covariance / sqrt(varianceA * varianceB)
        return max(0, min(1, (correlation + 1) / 2))
    }
}
