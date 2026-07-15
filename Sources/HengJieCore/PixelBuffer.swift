import CoreGraphics
import Foundation

struct GrayImage {
    let width: Int
    let height: Int
    let pixels: [UInt8]

    init?(image: CGImage, maximumDimension: Int = 720) {
        let scale = min(1, Double(maximumDimension) / Double(max(image.width, image.height)))
        let targetWidth = max(1, Int(Double(image.width) * scale))
        let targetHeight = max(1, Int(Double(image.height) * scale))
        var storage = [UInt8](repeating: 0, count: targetWidth * targetHeight)
        let rendered = storage.withUnsafeMutableBytes { bytes -> Bool in
            guard let address = bytes.baseAddress,
                  let context = CGContext(
                    data: address,
                    width: targetWidth,
                    height: targetHeight,
                    bitsPerComponent: 8,
                    bytesPerRow: targetWidth,
                    space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGImageAlphaInfo.none.rawValue
                  ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
            return true
        }
        guard rendered else { return nil }
        width = targetWidth
        height = targetHeight
        pixels = storage
    }

    subscript(_ x: Int, _ y: Int) -> UInt8 { pixels[y * width + x] }
}
