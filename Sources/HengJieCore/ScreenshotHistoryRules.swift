import Foundation

public enum PreciseSelectionRules {
    public static func constrainedSize(deltaWidth: CGFloat, deltaHeight: CGFloat, aspectRatio: CGFloat) -> CGSize {
        guard aspectRatio > 0 else { return CGSize(width: abs(deltaWidth), height: abs(deltaHeight)) }
        var width = abs(deltaWidth)
        var height = abs(deltaHeight)
        if height == 0 || width / max(1, height) > aspectRatio { height = width / aspectRatio }
        else { width = height * aspectRatio }
        return CGSize(width: width, height: height)
    }

    public static func logicalSize(pixelSize: CGSize, backingScale: CGFloat) -> CGSize {
        let scale = max(1, backingScale)
        return CGSize(width: max(1, pixelSize.width / scale), height: max(1, pixelSize.height / scale))
    }
}

public enum ScreenshotHistoryRetentionRules {
    public static let maximumItemCount = 100
    public static let maximumTotalBytes: Int64 = 2 * 1_024 * 1_024 * 1_024
    public static let retentionInterval: TimeInterval = 30 * 24 * 60 * 60

    public static func isExpired(updatedAt: Date, now: Date = Date()) -> Bool {
        updatedAt < now.addingTimeInterval(-retentionInterval)
    }

    public static func exceedsCapacity(itemCount: Int, totalBytes: Int64) -> Bool {
        itemCount > maximumItemCount || totalBytes > maximumTotalBytes
    }
}
