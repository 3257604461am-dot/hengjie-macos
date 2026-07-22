import CoreGraphics

public enum FrameChangeDetector {
    public static func changeRatio(_ first: CGImage, _ second: CGImage) -> Double {
        guard let a = GrayImage(image: first, maximumDimension: 320),
              let b = GrayImage(image: second, maximumDimension: 320),
              a.width == b.width, a.height == b.height else { return 1 }
        var changed = 0
        var count = 0
        let step = 2
        for y in stride(from: 0, to: a.height, by: step) {
            for x in stride(from: 0, to: a.width, by: step) {
                if abs(Int(a[x, y]) - Int(b[x, y])) > 8 { changed += 1 }
                count += 1
            }
        }
        return count == 0 ? 0 : Double(changed) / Double(count)
    }
}
