import CoreGraphics
import XCTest
@testable import HengJieCore

final class HengJieCoreTests: XCTestCase {
    func testHorizontalReplayAcceptsForwardFrames() throws {
        let source = makePattern(width: 900, height: 160)
        let frames = [
            source.cropping(to: CGRect(x: 0, y: 0, width: 360, height: 160))!,
            source.cropping(to: CGRect(x: 180, y: 0, width: 360, height: 160))!,
            source.cropping(to: CGRect(x: 360, y: 0, width: 360, height: 160))!
        ]
        let results = try StitchReplayRunner(axis: .horizontal).run(frames)
        XCTAssertEqual(results.first, .initial)
        XCTAssertTrue(results.dropFirst().contains { if case .accepted = $0 { return true }; return false })
    }

    func testCheckpointRoundTripsWithoutPixels() throws {
        let session = try StitchSession(axis: .vertical)
        try session.append(makePattern(width: 120, height: 180))
        let checkpoint = try session.writeCheckpoint()
        let data = try JSONEncoder().encode(checkpoint)
        let decoded = try JSONDecoder().decode(StitchCheckpoint.self, from: data)
        XCTAssertEqual(decoded, checkpoint)
        XCTAssertEqual(decoded.version, StitchCheckpoint.currentVersion)
        XCTAssertEqual(decoded.pixelWidth, 120)
        XCTAssertTrue(decoded.segmentNames.allSatisfy { $0.hasSuffix(".png") })
    }

    func testRepeatedGridIsRejectedAsAmbiguous() {
        let image = makeGrid(width: 640, height: 180)
        let first = image.cropping(to: CGRect(x: 0, y: 0, width: 360, height: 180))!
        let second = image.cropping(to: CGRect(x: 64, y: 0, width: 360, height: 180))!
        let result = OverlapEstimator().analyze(previous: first, next: second, axis: .horizontal)
        if case .match = result { XCTFail("重复网格不得被强行接受") }
    }

    func testLimitsRejectOversizedReplay() throws {
        let session = try StitchSession(axis: .horizontal, limits: StitchLimits(maximumAxisLength: 400, maximumPixelCount: 100_000))
        let source = makePattern(width: 900, height: 100)
        try session.append(source.cropping(to: CGRect(x: 0, y: 0, width: 300, height: 100))!)
        XCTAssertThrowsError(try session.append(source.cropping(to: CGRect(x: 200, y: 0, width: 300, height: 100))!)) { error in
            XCTAssertEqual(error as? StitchError, .limitReached)
        }
    }

    private func makePattern(width: Int, height: Int) -> CGImage {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                pixels[i] = UInt8((x * 37 + y * 13) & 255)
                pixels[i + 1] = UInt8((x * 11 + y * 47) & 255)
                pixels[i + 2] = UInt8((x * 17 + y * 29) & 255)
                pixels[i + 3] = 255
            }
        }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: CGDataProvider(data: Data(pixels) as CFData)!, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)!
    }

    private func makeGrid(width: Int, height: Int) -> CGImage {
        var pixels = [UInt8](repeating: 238, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width where x % 16 == 0 || y % 16 == 0 {
                let i = (y * width + x) * 4
                pixels[i] = 70; pixels[i + 1] = 70; pixels[i + 2] = 70; pixels[i + 3] = 255
            }
        }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: CGDataProvider(data: Data(pixels) as CFData)!, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)!
    }
}
