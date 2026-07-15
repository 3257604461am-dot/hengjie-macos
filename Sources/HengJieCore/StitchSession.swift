import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public final class StitchSession {
    public let axis: StitchAxis
    public let limits: StitchLimits
    public private(set) var frameCount = 0
    public private(set) var direction: StitchDirection?
    public private(set) var pixelSize: CGSize = .zero

    private let estimator: OverlapEstimator
    private var lastFrame: CGImage?
    private var segments: [(url: URL, size: CGSize)] = []
    private let directory: URL

    public init(axis: StitchAxis, limits: StitchLimits = .init(), estimator: OverlapEstimator = .init()) throws {
        self.axis = axis
        self.limits = limits
        self.estimator = estimator
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HengJie-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    @discardableResult
    public func append(_ frame: CGImage) throws -> OverlapMatch? {
        guard let previous = lastFrame else {
            try store(frame, prepend: false)
            lastFrame = frame
            frameCount = 1
            pixelSize = CGSize(width: frame.width, height: frame.height)
            return nil
        }
        guard previous.width == frame.width, previous.height == frame.height else {
            throw StitchError.incompatibleFrameSize
        }
        guard let match = estimator.estimate(previous: previous, next: frame, axis: axis) else {
            throw StitchError.noReliableOverlap(confidence: 0)
        }
        if let direction, direction != match.direction { throw StitchError.directionReversed }
        direction = match.direction

        let strip: CGImage?
        if axis == .horizontal {
            let newWidth = frame.width - match.overlap
            let x = match.direction == .forward ? match.overlap : 0
            strip = frame.cropping(to: CGRect(x: x, y: 0, width: newWidth, height: frame.height))
        } else {
            let newHeight = frame.height - match.overlap
            let y = match.direction == .forward ? match.overlap : 0
            strip = frame.cropping(to: CGRect(x: 0, y: y, width: frame.width, height: newHeight))
        }
        guard let strip, strip.width > 0, strip.height > 0 else {
            throw StitchError.noReliableOverlap(confidence: match.confidence)
        }
        let proposed = CGSize(
            width: pixelSize.width + (axis == .horizontal ? CGFloat(strip.width) : 0),
            height: pixelSize.height + (axis == .vertical ? CGFloat(strip.height) : 0)
        )
        let axisLength = axis == .horizontal ? Int(proposed.width) : Int(proposed.height)
        guard axisLength <= limits.maximumAxisLength,
              Int(proposed.width * proposed.height) <= limits.maximumPixelCount else {
            throw StitchError.limitReached
        }
        try store(strip, prepend: match.direction == .backward)
        lastFrame = frame
        frameCount += 1
        pixelSize = proposed
        return match
    }

    public func render() throws -> CGImage {
        let width = Int(pixelSize.width)
        let height = Int(pixelSize.height)
        guard width > 0, height > 0,
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { throw StitchError.cannotCreateImage }

        var cursor = 0
        for segment in segments {
            guard let source = CGImageSourceCreateWithURL(segment.url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { continue }
            if axis == .horizontal {
                context.draw(image, in: CGRect(x: cursor, y: 0, width: image.width, height: image.height))
                cursor += image.width
            } else {
                // Core Graphics has a bottom-left canvas; place the first captured segment at the top.
                let y = height - cursor - image.height
                context.draw(image, in: CGRect(x: 0, y: y, width: image.width, height: image.height))
                cursor += image.height
            }
        }
        guard let result = context.makeImage() else { throw StitchError.cannotCreateImage }
        return result
    }

    private func store(_ image: CGImage, prepend: Bool) throws {
        let url = directory.appendingPathComponent(String(format: "%06d.png", frameCount))
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw StitchError.cannotCreateImage
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw StitchError.cannotCreateImage }
        let entry = (url, CGSize(width: image.width, height: image.height))
        if prepend { segments.insert(entry, at: 0) } else { segments.append(entry) }
    }
}
