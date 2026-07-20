import AppKit
import ScreenCaptureKit

/// Coalesces simultaneous ScreenCaptureKit discovery requests and briefly caches
/// the result. The cache is intentionally short lived so window/display changes
/// are reflected without making every screenshot rediscover the whole desktop.
@MainActor
final class CaptureContentProvider {
    static let shared = CaptureContentProvider()

    private var cachedContent: SCShareableContent?
    private var cachedAt = Date.distantPast
    private var inFlight: Task<SCShareableContent, Error>?
    private let lifetime: TimeInterval = 1

    func content(forceRefresh: Bool = false) async throws -> SCShareableContent {
        if !forceRefresh, let cachedContent, Date().timeIntervalSince(cachedAt) < lifetime {
            return cachedContent
        }
        if let inFlight { return try await inFlight.value }

        let task = Task {
            try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        }
        inFlight = task
        do {
            let content = try await task.value
            cachedContent = content
            cachedAt = Date()
            inFlight = nil
            return content
        } catch {
            inFlight = nil
            throw error
        }
    }

    func invalidate() {
        cachedContent = nil
        cachedAt = .distantPast
    }
}
