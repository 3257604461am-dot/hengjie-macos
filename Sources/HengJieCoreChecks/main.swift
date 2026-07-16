import Foundation
import CoreGraphics
import HengJieCore

enum CheckFailure: Error, CustomStringConvertible {
    case failed(String)
    var description: String { if case let .failed(message) = self { message } else { "" } }
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw CheckFailure.failed(message) }
}

func makePattern(width: Int, height: Int, seed: Int = 3) -> CGImage {
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let offset = (y * width + x) * 4
            var hash = UInt64(x) &* 73_856_093 &+ UInt64(y) &* 19_349_663 &+ UInt64(seed) &* 83_492_791
            hash = (hash ^ (hash >> 30)) &* 0xbf58476d1ce4e5b9
            hash = (hash ^ (hash >> 27)) &* 0x94d049bb133111eb
            hash ^= hash >> 31
            pixels[offset] = UInt8(truncatingIfNeeded: hash)
            pixels[offset + 1] = UInt8(truncatingIfNeeded: hash >> 9)
            pixels[offset + 2] = UInt8(truncatingIfNeeded: hash >> 17)
            pixels[offset + 3] = 255
        }
    }
    let provider = CGDataProvider(data: Data(pixels) as CFData)!
    return CGImage(
        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
    )!
}

func runChecks() throws {
    do {
        let source = makePattern(width: 920, height: 180)
        let first = source.cropping(to: CGRect(x: 0, y: 0, width: 420, height: 180))!
        let second = source.cropping(to: CGRect(x: 210, y: 0, width: 420, height: 180))!
        let session = try StitchSession(axis: .horizontal)
        try session.append(first)
        let match = try session.append(second)
        try expect(match?.direction == .forward, "横向向右方向识别失败")
        try expect(abs((match?.overlap ?? 0) - 210) <= 4, "横向重叠量不准确")
        let rendered = try session.render()
        try expect(abs(rendered.width - 630) <= 4, "横向输出宽度不准确")
    }
    do {
        let source = makePattern(width: 920, height: 180)
        let first = source.cropping(to: CGRect(x: 300, y: 0, width: 420, height: 180))!
        let second = source.cropping(to: CGRect(x: 80, y: 0, width: 420, height: 180))!
        let session = try StitchSession(axis: .horizontal)
        try session.append(first)
        let match = try session.append(second)
        try expect(match?.direction == .backward, "横向向左方向识别失败")
        try expect(abs((match?.overlap ?? 0) - 200) <= 4, "向左重叠量不准确")
    }
    do {
        let source = makePattern(width: 220, height: 900)
        let first = source.cropping(to: CGRect(x: 0, y: 400, width: 220, height: 400))!
        let second = source.cropping(to: CGRect(x: 0, y: 200, width: 220, height: 400))!
        let session = try StitchSession(axis: .vertical)
        try session.append(first)
        let match = try session.append(second)
        try expect(match != nil && abs((match?.overlap ?? 0) - 200) <= 4, "纵向拼接失败")
        let rendered = try session.render()
        try expect(abs(rendered.height - 600) <= 4, "纵向输出高度不准确")
    }
    do {
        let session = try StitchSession(axis: .horizontal)
        try session.append(makePattern(width: 300, height: 120))
        do {
            try session.append(makePattern(width: 301, height: 120))
            throw CheckFailure.failed("尺寸变化未被拒绝")
        } catch StitchError.incompatibleFrameSize {}
    }
    do {
        let source = makePattern(width: 800, height: 100)
        let first = source.cropping(to: CGRect(x: 0, y: 0, width: 300, height: 100))!
        let second = source.cropping(to: CGRect(x: 200, y: 0, width: 300, height: 100))!
        let session = try StitchSession(axis: .horizontal, limits: StitchLimits(maximumAxisLength: 350, maximumPixelCount: 100_000))
        try session.append(first)
        do {
            try session.append(second)
            throw CheckFailure.failed("长图长度上限未生效")
        } catch StitchError.limitReached {}
    }
    do {
        let first = makePattern(width: 320, height: 180)
        try expect(FrameChangeDetector.changeRatio(first, makePattern(width: 320, height: 180)) < 0.001, "相同帧被判定为变化")
        try expect(FrameChangeDetector.changeRatio(first, makePattern(width: 320, height: 180, seed: 19)) > 0.1, "不同帧未被识别")
    }
    do {
        let first = makePattern(width: 400, height: 180, seed: 2)
        let unrelated = makePattern(width: 400, height: 180, seed: 97)
        let unrelatedMatch = OverlapEstimator().estimate(previous: first, next: unrelated, axis: .horizontal)
        try expect(unrelatedMatch == nil, "无关帧不应被拼接")
    }
    do {
        let source = makePattern(width: 900, height: 180, seed: 41)
        let first = source.cropping(to: CGRect(x: 0, y: 0, width: 400, height: 180))!
        let scrolled = source.cropping(to: CGRect(x: 150, y: 0, width: 400, height: 180))!
        let frozen = first.cropping(to: CGRect(x: 0, y: 0, width: 48, height: 180))!
        let second = overlay(frozen: frozen, on: scrolled)
        let match = OverlapEstimator().estimate(previous: first, next: second, axis: .horizontal)
        try expect(match?.direction == .forward, "冻结列场景方向识别失败")
        try expect(abs((match?.overlap ?? 0) - 250) <= 6, "冻结列场景重叠量不准确")
    }
    do {
        try expect(ScrollDriver.default == .manual, "滚动截图默认模式必须为手动")
        let wideScale = PreviewLayout.fitScale(imageSize: CGSize(width: 10_000, height: 500), viewportSize: CGSize(width: 1_000, height: 700))
        let tallScale = PreviewLayout.fitScale(imageSize: CGSize(width: 500, height: 10_000), viewportSize: CGSize(width: 1_000, height: 700))
        try expect(abs(wideScale - 0.096) < 0.0001, "超宽长图适屏比例错误")
        try expect(abs(tallScale - 0.0672) < 0.0001, "超高长图适屏比例错误")
        let captureRect = CGRect(x: 100, y: 100, width: 500, height: 300)
        try expect(AutomaticScrollPolicy.shouldInject(mouseLocation: CGPoint(x: 300, y: 200), captureRect: captureRect), "选区内应允许自动滚动")
        try expect(!AutomaticScrollPolicy.shouldInject(mouseLocation: CGPoint(x: 650, y: 200), captureRect: captureRect), "鼠标移出选区后必须停止自动滚动")
    }
    do {
        try expect(!SelectionDimmingPolicy.shouldDim(.idle), "等待框选时不得显示全屏蒙版")
        try expect(SelectionDimmingPolicy.shouldDim(.selecting), "开始框选后必须显示全屏蒙版")
        try expect(SelectionDimmingPolicy.shouldDim(.selected), "选区完成后必须保留选区外蒙版")
        let regular = PinnedImageLayout.fittedSize(imageSize: CGSize(width: 500, height: 300), availableSize: CGSize(width: 1200, height: 800))
        try expect(regular == CGSize(width: 500, height: 300), "普通钉图应保持原始显示尺寸")
        let wide = PinnedImageLayout.fittedSize(imageSize: CGSize(width: 10_000, height: 1_000), availableSize: CGSize(width: 1_200, height: 800))
        try expect(abs(wide.width - 984) < 0.01 && abs(wide.height - 98.4) < 0.01, "超宽钉图适配尺寸错误")
    }
    do {
        try expect(TextLanguage.detect(in: "这是中文识别与翻译测试") == .chinese, "中文语言检测失败")
        try expect(TextLanguage.detect(in: "This is an English recognition test.") == .english, "英语语言检测失败")
        try expect(TextLanguage.detect(in: "これは日本語の認識テストです。") == .japanese, "日语语言检测失败")
        try expect(TextLanguage.chinese.defaultTarget == .english, "中文默认目标语言错误")
        try expect(TextLanguage.japanese.defaultTarget == .chinese, "日语默认目标语言错误")
        try expect(TextLanguage.english.defaultTarget == .chinese, "英语默认目标语言错误")
    }
    do {
        let high = GIFOutputLayout.outputSize(selectionSize: CGSize(width: 800, height: 500), backingScale: 2, quality: .high)
        let standard = GIFOutputLayout.outputSize(selectionSize: CGSize(width: 800, height: 500), backingScale: 2, quality: .standard)
        let compact = GIFOutputLayout.outputSize(selectionSize: CGSize(width: 800, height: 500), backingScale: 2, quality: .compact)
        try expect(high == CGSize(width: 1600, height: 1000), "GIF 高清尺寸错误")
        try expect(standard == CGSize(width: 1200, height: 750), "GIF 标准尺寸错误")
        try expect(compact == CGSize(width: 800, height: 500), "GIF 小文件尺寸错误")
        let limited = GIFOutputLayout.outputSize(selectionSize: CGSize(width: 5000, height: 3000), backingScale: 2, quality: .high)
        try expect(limited.width <= 4096 && limited.height <= 4096 && limited.width * limited.height <= 16_000_000, "GIF 安全尺寸限制错误")
        try expect(GIFRecordingOptions(framesPerSecond: 0).framesPerSecond == 1, "GIF 最低帧率限制错误")
        try expect(GIFRecordingOptions(framesPerSecond: 60).framesPerSecond == 30, "GIF 最高帧率限制错误")
    }
    do {
        let now = Date()
        let stale = now.addingTimeInterval(-31 * 24 * 60 * 60)
        try expect(ClipboardHistoryRules.isExpired(lastUsedAt: stale, isPinned: false, now: now), "30 天历史清理未生效")
        try expect(!ClipboardHistoryRules.isExpired(lastUsedAt: stale, isPinned: true, now: now), "固定历史不应自动过期")
        try expect(!ClipboardHistoryRules.canAcceptItem(
            itemBytes: ClipboardHistoryRules.maximumItemBytes + 1,
            currentCount: 0,
            currentBytes: 0,
            hasEvictableItem: true
        ), "超过 50MB 的剪贴板内容未被拒绝")
        try expect(!ClipboardHistoryRules.canAcceptItem(
            itemBytes: 10,
            currentCount: ClipboardHistoryRules.maximumItemCount,
            currentBytes: 100,
            hasEvictableItem: false
        ), "全固定且满 100 条时不应继续接收")
        try expect(ClipboardHistoryRules.normalizedPreview("  第一行\n\n第二行  ") == "第一行 第二行", "历史摘要规范化错误")
    }
}

func overlay(frozen: CGImage, on image: CGImage) -> CGImage {
    let context = CGContext(
        data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    context.draw(frozen, in: CGRect(x: 0, y: 0, width: frozen.width, height: frozen.height))
    return context.makeImage()!
}

do {
    try runChecks()
    print("✓ 横截核心检查全部通过")
} catch {
    fputs("✗ \(error)\n", stderr)
    exit(1)
}
