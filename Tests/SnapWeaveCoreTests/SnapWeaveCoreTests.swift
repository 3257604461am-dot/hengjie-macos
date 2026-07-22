import CoreGraphics
import XCTest
@testable import SnapWeaveCore

final class SnapWeaveCoreTests: XCTestCase {
    func testLegacyApplicationSupportDirectoryMigratesAtomically() throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: support) }
        let legacy = AppStoragePaths.legacyRoot(in: support)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data("history".utf8).write(to: legacy.appendingPathComponent("payload.txt"))

        XCTAssertEqual(AppStoragePaths.prepare(in: support), .migrated)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        XCTAssertEqual(
            try Data(contentsOf: AppStoragePaths.root(in: support).appendingPathComponent("payload.txt")),
            Data("history".utf8)
        )
    }

    func testCurrentDirectoryWinsWhenBothBrandDirectoriesExist() throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: support) }
        let current = AppStoragePaths.root(in: support)
        let legacy = AppStoragePaths.legacyRoot(in: support)
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)

        XCTAssertEqual(AppStoragePaths.prepare(in: support), .bothPresent)
        XCTAssertTrue(FileManager.default.fileExists(atPath: current.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path))
    }

    func testFailedMigrationLeavesLegacyDataUntouched() throws {
        struct ForcedFailure: Error {}
        let support = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: support) }
        let legacy = AppStoragePaths.legacyRoot(in: support)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        let payload = legacy.appendingPathComponent("payload.txt")
        try Data("history".utf8).write(to: payload)

        let result = AppStoragePaths.prepare(in: support, fileManager: .default) { _, _ in throw ForcedFailure() }
        guard case .failed = result else { return XCTFail("迁移失败必须返回 failed") }
        XCTAssertEqual(try Data(contentsOf: payload), Data("history".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: AppStoragePaths.root(in: support).path))
    }

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
        let session = try StitchSession(axis: .horizontal, limits: StitchLimits(maximumAxisLength: 500, maximumPixelCount: 1_000_000))
        let source = makePattern(width: 900, height: 160)
        try session.append(source.cropping(to: CGRect(x: 0, y: 0, width: 360, height: 160))!)
        XCTAssertThrowsError(try session.append(source.cropping(to: CGRect(x: 180, y: 0, width: 360, height: 160))!)) { error in
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
