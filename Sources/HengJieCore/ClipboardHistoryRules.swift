import Foundation

public enum ClipboardHistoryRules {
    public static let maximumItemCount = 100
    public static let maximumItemBytes: Int64 = 50 * 1_024 * 1_024
    public static let maximumTotalBytes: Int64 = 1_024 * 1_024 * 1_024
    public static let retentionInterval: TimeInterval = 30 * 24 * 60 * 60

    public static func isExpired(lastUsedAt: Date, isPinned: Bool, now: Date = Date()) -> Bool {
        !isPinned && lastUsedAt < now.addingTimeInterval(-retentionInterval)
    }

    public static func canAcceptItem(
        itemBytes: Int64,
        currentCount: Int,
        currentBytes: Int64,
        hasEvictableItem: Bool
    ) -> Bool {
        guard itemBytes >= 0, itemBytes <= maximumItemBytes else { return false }
        let exceedsCollection = currentCount >= maximumItemCount || currentBytes + itemBytes > maximumTotalBytes
        return !exceedsCollection || hasEvictableItem
    }

    public static func normalizedPreview(_ value: String, maximumLength: Int = 500) -> String {
        String(value
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(maximumLength))
    }
}
