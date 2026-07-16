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

func makeRepeatedGrid(width: Int, height: Int, cell: Int = 16) -> CGImage {
    var pixels = [UInt8](repeating: 255, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let offset = (y * width + x) * 4
            let line = x % cell == 0 || y % cell == 0
            let value: UInt8 = line ? 70 : 238
            pixels[offset] = value
            pixels[offset + 1] = value
            pixels[offset + 2] = value
            pixels[offset + 3] = 255
        }
    }
    let provider = CGDataProvider(data: Data(pixels) as CFData)!
    return CGImage(
        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
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
        let source = makePattern(width: 920, height: 220, seed: 77)
        let first = source.cropping(to: CGRect(x: 0, y: 4, width: 420, height: 180))!
        let second = source.cropping(to: CGRect(x: 210, y: 6, width: 420, height: 180))!
        let match = OverlapEstimator().estimate(previous: first, next: second, axis: .horizontal)
        try expect(match != nil, "轻微正交偏移不应导致拼接失败")
        try expect(abs(match?.orthogonalOffset ?? 99) <= 4, "正交偏移估算超出容差")
    }
    do {
        let grid = makeRepeatedGrid(width: 640, height: 180)
        let first = grid.cropping(to: CGRect(x: 0, y: 0, width: 360, height: 180))!
        let second = grid.cropping(to: CGRect(x: 64, y: 0, width: 360, height: 180))!
        let analysis = OverlapEstimator().analyze(previous: first, next: second, axis: .horizontal)
        if case .match = analysis { throw CheckFailure.failed("纯重复网格存在歧义时不应强行拼接") }
    }
    do {
        let session = try StitchSession(axis: .horizontal)
        let frame = makePattern(width: 320, height: 160, seed: 8)
        let initial = try session.appendAnalyzed(frame)
        let unchanged = try session.appendAnalyzed(frame)
        try expect(initial == .initial, "首帧状态错误")
        try expect(unchanged == .unchanged, "静止帧应被忽略")
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
        try expect(ClipboardHistoryRules.matches(searchText: "Hello 横截 テスト", query: "hello 横截"), "中英日搜索规范化错误")
        try expect(ClipboardHistoryRules.matches(searchText: "ＡＢＣ １２３", query: "abc 123"), "全角半角搜索错误")
        try expect(!ClipboardHistoryRules.matches(searchText: "横截截图", query: "横截 翻译"), "多关键词搜索必须全部命中")
    }
    do {
        let square = PreciseSelectionRules.constrainedSize(deltaWidth: 320, deltaHeight: 100, aspectRatio: 1)
        try expect(square == CGSize(width: 320, height: 320), "1:1 固定比例计算错误")
        let widescreen = PreciseSelectionRules.constrainedSize(deltaWidth: 160, deltaHeight: 200, aspectRatio: 16.0 / 9.0)
        try expect(abs(widescreen.width - 355.5555) < 0.01 && widescreen.height == 200, "16:9 固定比例计算错误")
        let retina = PreciseSelectionRules.logicalSize(pixelSize: CGSize(width: 1920, height: 1080), backingScale: 2)
        try expect(retina == CGSize(width: 960, height: 540), "Retina 固定像素换算错误")
        let now = Date()
        try expect(ScreenshotHistoryRetentionRules.isExpired(updatedAt: now.addingTimeInterval(-31 * 24 * 60 * 60), now: now), "截图历史 30 天清理未生效")
        try expect(!ScreenshotHistoryRetentionRules.exceedsCapacity(itemCount: 100, totalBytes: ScreenshotHistoryRetentionRules.maximumTotalBytes), "截图历史边界容量不应提前淘汰")
        try expect(ScreenshotHistoryRetentionRules.exceedsCapacity(itemCount: 101, totalBytes: 0), "截图历史 100 条限制未生效")
        try expect(ScreenshotHistoryRetentionRules.exceedsCapacity(itemCount: 1, totalBytes: ScreenshotHistoryRetentionRules.maximumTotalBytes + 1), "截图历史 2GB 限制未生效")
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
